// Real audio levels for the waveform, from a Core Audio process tap.
//
// The waveform used to be a pair of sine functions. It looked like a waveform
// and it was connected to nothing, so a DJ segment animated identically whether
// the DJ was mid-sentence or silent. This reads the actual audio.
//
// Scope is deliberately one process, never a global tap. `CATapDescription` can
// take a global tap and it is one line shorter, but then a menu bar decoration
// would be reading every sound on the machine, including the other browser tab
// and whatever is on a call. Tapping only the pid that MediaRemote says is
// playing is both narrower and exactly the audio being drawn.
//
// Creating a tap needs no permission. Starting the aggregate device that
// contains it is what trips the one-time "System Audio Recording" TCC grant, and
// that grant lands on the process responsible for this one, which is SketchyBar.
// Everything here fails soft: no permission, no tap, no pid, and the caller gets
// nil levels and keeps the synthetic animation.

import Accelerate
import AudioToolbox
import CoreAudio
import CoreGraphics
import Foundation

// 1024 samples at 48kHz is a 21ms window. Long enough for a usable low end (a
// bin is 47Hz) and short enough that the bars track speech rather than smearing
// it into an average.
let tapWindowSize = 1024
let tapLog2n = vDSP_Length(10)  // log2(1024), asserted in the self-test

// Below 60Hz is rumble that only ever pins the first bar. The top used to be
// 12kHz, which on six log-spaced bands handed the last bar everything above
// 4962Hz: measured over real playback that bar was above the noise floor 10% of
// the time on a podcast and 43% on music, so a sixth of the meter was a fixture
// rather than a level. 6kHz gives it 2783Hz upward, which is inside the range
// where speech sibilance and music actually put energy.
//
// This is a display range, not a filter. Content above the top edge is simply not
// drawn, which is the right trade for six bars: spending one of them on air means
// five bars for everything audible.
let tapBandLowHz: Double = 60
let tapBandHighHz: Double = 6000

// The quiet end of the scale. -58dBFS reads as silence for this purpose: room
// tone in a podcast recording sits above it, a paused stream does not.
let tapFloorDb: Float = -58

// Lift applied before normalising, and it is not a fudge factor. Measured: a
// full-scale sine through this window and scaling peaks at about -13dBFS in its
// own bin, because a Hann window throws away half the coherent gain and the
// scaling divides by the full transform length. Real audio reads lower again,
// since its energy is spread over many bins instead of sitting in one. Without
// the lift the bars only ever use the bottom of the slot.
let tapGainDb: Float = 13

// MARK: - The pure half, which needs no tap and is therefore testable

// A Hann window, precomputed once. Skipping the window puts a wide skirt on
// every tone, which shows up as all bars lifting together on a single note
// instead of one bar moving.
func tapHannWindow(_ count: Int) -> [Float] {
    var window = [Float](repeating: 0, count: count)
    vDSP_hann_window(&window, vDSP_Length(count), Int32(vDSP_HANN_DENORM))
    return window
}

// Magnitude per FFT bin for one window of mono samples.
//
// vDSP's real-to-complex transform wants the input packed as even/odd halves of
// a split complex, which is what vDSP_ctoz does, and it returns a result scaled
// by 2, which is what the 0.5 undoes. Both are easy to get wrong and neither is
// visible by looking at the picture, so the self-test drives this with tones at
// known frequencies rather than trusting it.
func tapBinMagnitudes(
    samples: [Float], window: [Float], setup: FFTSetup
) -> [Float] {
    let n = samples.count
    let half = n / 2
    var windowed = [Float](repeating: 0, count: n)
    vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))

    var real = [Float](repeating: 0, count: half)
    var imag = [Float](repeating: 0, count: half)
    var magnitudes = [Float](repeating: 0, count: half)

    real.withUnsafeMutableBufferPointer { realPtr in
        imag.withUnsafeMutableBufferPointer { imagPtr in
            var split = DSPSplitComplex(
                realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
            windowed.withUnsafeBufferPointer { input in
                input.baseAddress!.withMemoryRebound(
                    to: DSPComplex.self, capacity: half
                ) { interleaved in
                    vDSP_ctoz(interleaved, 2, &split, 1, vDSP_Length(half))
                }
            }
            vDSP_fft_zrip(setup, &split, 1, tapLog2n, FFTDirection(kFFTDirection_Forward))
            // Bin 0 packs DC in realp and Nyquist in imagp. Neither is a band
            // anyone looks at, and leaving Nyquist in place would make bin 0
            // read as loud on silence, so it goes.
            imagPtr[0] = 0
            vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
        }
    }
    var scale: Float = 0.5 / Float(n)
    vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(half))
    return magnitudes
}

// Bin magnitudes folded into `bands` log-spaced bands, each 0...1.
//
// Log spacing because linear spacing spends three quarters of the bars on the
// top two octaves, where nothing happens, and crams a voice into the first two.
// Peak rather than mean within a band, because a mean over a wide high band
// buries a real transient under the empty bins next to it.
func tapBands(
    magnitudes: [Float], sampleRate: Double, bands: Int,
    lowHz: Double = tapBandLowHz, highHz: Double = tapBandHighHz,
    floorDb: Float = tapFloorDb, gainDb: Float = tapGainDb
) -> [CGFloat] {
    guard bands > 0, magnitudes.count > 1, sampleRate > 0 else {
        return Array(repeating: 0, count: max(0, bands))
    }
    let binHz = sampleRate / Double(magnitudes.count * 2)
    let ratio = highHz / lowHz
    return (0..<bands).map { band in
        let lo = lowHz * pow(ratio, Double(band) / Double(bands))
        let hi = lowHz * pow(ratio, Double(band + 1) / Double(bands))
        // At the bottom a band is narrower than a bin, so round outwards and
        // always take at least one: otherwise the first bars are permanently
        // dead because their range falls between two bins.
        let first = max(1, Int(lo / binHz))
        let last = min(magnitudes.count - 1, max(first, Int((hi / binHz).rounded(.up)) - 1))
        var peak: Float = 0
        for bin in first...last where magnitudes[bin] > peak { peak = magnitudes[bin] }
        let db = 20 * log10(max(peak, 1e-9)) + gainDb
        return CGFloat(min(1, max(0, (db - floorDb) / -floorDb)))
    }
}

// MARK: - The half that needs a tap

func tapProcessObject(forPID pid: pid_t) -> AudioObjectID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var input = pid
    var object = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address,
        UInt32(MemoryLayout<pid_t>.size), &input, &size, &object)
    guard status == noErr, object != kAudioObjectUnknown else { return nil }
    return object
}

final class SpectrumTap {
    // A ring of raw samples, written by the audio callback and read by whoever
    // is drawing. Only the copy happens on the audio side: the FFT is the
    // reader's problem, on the reader's thread, because a transform under an
    // audio deadline is how you get dropouts in the thing you are listening to.
    private var ring = [Float](repeating: 0, count: tapWindowSize * 4)
    private var writeIndex = 0
    private var framesSeen: UInt64 = 0
    private var lock = os_unfair_lock_s()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let window = tapHannWindow(tapWindowSize)
    private let queue = DispatchQueue(label: "mediawatch.tap", qos: .userInteractive)

    // Built once and kept for the life of the object, not per start. Creating it
    // in start and destroying it in stop meant a reader could be mid-FFT with a
    // setup that the teardown was freeing, which is a crash rather than a glitch.
    private let setup: FFTSetup? = vDSP_create_fftsetup(tapLog2n, FFTRadix(kFFTRadix2))

    // Written by the lifecycle queue, read by whoever is drawing, so it lives
    // under the same lock as the samples rather than being a bare Bool.
    private var running = false

    private(set) var sampleRate: Double = 48000
    private(set) var tappedPID: pid_t?

    // Generous on purpose. The first start is what raises the permission
    // dialog, and AudioDeviceStart stays blocked for as long as that dialog is
    // up, so this is really "how long does a person get to read it and click".
    // Four seconds was the first value here and it gave up while the prompt was
    // still on screen. Nothing waits on this: it is spent on its own queue, so a
    // long deadline is free and only the hang case ever pays it.
    let startTimeout: TimeInterval = 45

    var isRunning: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return running
    }

    deinit {
        stop()
        if let setup { vDSP_destroy_fftsetup(setup) }
    }

    // True only if audio is actually flowing to us. A tap that was created but
    // whose aggregate would not start is a failure, and reporting it as success
    // would leave the waveform frozen at silence rather than falling back.
    func start(pid: pid_t) -> Bool {
        stop()
        guard let object = tapProcessObject(forPID: pid) else { return false }

        let description = CATapDescription(stereoMixdownOfProcesses: [object])
        description.name = "mediawatch waveform"
        // Private, so it never shows up as a capture device other apps can pick,
        // and unmuted, so tapping does not silence what the user is listening to.
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &newTap) == noErr,
              newTap != kAudioObjectUnknown
        else { return false }
        tapID = newTap

        guard let format = streamFormat(of: newTap) else {
            stop()
            return false
        }
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 48000
        let channels = max(1, Int(format.mChannelsPerFrame))

        // Tap-only aggregate. No main sub-device and no sub-device list on
        // purpose: including them pins the aggregate to the output device's
        // sample rate, which breaks the moment the user switches to a headset
        // running at a different one.
        let uid = UUID().uuidString
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "mediawatch waveform tap",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapAutoStartKey: 1,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    // Compensates for the tap and the device running off
                    // different clocks. Without it the stream slowly slips.
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(
            aggregate as CFDictionary, &newAggregate) == noErr,
            newAggregate != kAudioObjectUnknown
        else {
            stop()
            return false
        }
        aggregateID = newAggregate

        guard setup != nil else {
            stop()
            return false
        }

        var newProc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(
            &newProc, newAggregate, queue
        ) { [weak self] _, input, _, _, _ in
            self?.absorb(input, channels: channels)
        }
        guard procStatus == noErr, let newProc else {
            stop()
            return false
        }
        ioProcID = newProc

        // The TCC gate is here, and it does not politely return an error.
        //
        // Measured 2026-09-09 on macOS 26.6.2: from an unbundled, adhoc-signed
        // binary launched by SketchyBar, this call never returns. It parks in
        // HAL_HardwarePlugIn_DeviceStart -> mach_msg waiting on a decision that
        // cannot be presented, because the responsible process has no bundle
        // identity and no NSAudioCaptureUsageDescription to prompt with. A
        // sample showed 1560 of 1560 samples in that one frame.
        //
        // So it runs somewhere disposable and is waited on with a deadline. If
        // it never answers, that thread stays parked, which costs one thread.
        // Calling it inline cost the entire pill: applyQueue is the draw path,
        // and it froze on its last frame until the process was killed.
        let finished = DispatchSemaphore(value: 0)
        var startStatus: OSStatus = -1
        DispatchQueue.global(qos: .userInitiated).async {
            startStatus = AudioDeviceStart(newAggregate, newProc)
            finished.signal()
        }
        guard finished.wait(timeout: .now() + startTimeout) == .success,
              startStatus == noErr
        else {
            // Deliberately not torn down. The call may still be parked inside
            // the HAL holding these objects, and destroying them underneath it
            // is a use-after-free with extra steps. Orphan them and stop asking.
            ioProcID = nil
            aggregateID = AudioObjectID(kAudioObjectUnknown)
            tapID = AudioObjectID(kAudioObjectUnknown)
            return false
        }
        tappedPID = pid
        os_unfair_lock_lock(&lock)
        running = true
        os_unfair_lock_unlock(&lock)
        return true
    }

    func stop() {
        os_unfair_lock_lock(&lock)
        running = false
        os_unfair_lock_unlock(&lock)
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        tappedPID = nil
        os_unfair_lock_lock(&lock)
        framesSeen = 0
        os_unfair_lock_unlock(&lock)
    }

    // Everything this does is a mixdown and a copy. The lock is held for that
    // and nothing else, so the drawing side can never stall the audio side for
    // longer than a memcpy of one buffer.
    private func absorb(_ input: UnsafePointer<AudioBufferList>, channels: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, let raw = first.mData else { return }
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * max(1, channels))
        guard frames > 0 else { return }
        let samples = raw.assumingMemoryBound(to: Float.self)

        os_unfair_lock_lock(&lock)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels {
                sum += samples[frame * channels + channel]
            }
            ring[writeIndex] = sum / Float(channels)
            writeIndex = (writeIndex + 1) % ring.count
        }
        framesSeen += UInt64(frames)
        os_unfair_lock_unlock(&lock)
    }

    // nil rather than zeros when there is nothing to report, so the caller can
    // tell "silent" from "not listening" and only the second one falls back.
    func levels(bands: Int) -> [CGFloat]? {
        guard let setup, bands > 0 else { return nil }
        var window = [Float](repeating: 0, count: tapWindowSize)
        os_unfair_lock_lock(&lock)
        let enough = running && framesSeen >= UInt64(tapWindowSize)
        if enough {
            var index = (writeIndex - tapWindowSize + ring.count) % ring.count
            for position in 0..<tapWindowSize {
                window[position] = ring[index]
                index = (index + 1) % ring.count
            }
        }
        os_unfair_lock_unlock(&lock)
        guard enough else { return nil }
        let magnitudes = tapBinMagnitudes(
            samples: window, window: self.window, setup: setup)
        return tapBands(magnitudes: magnitudes, sampleRate: sampleRate, bands: bands)
    }

    private func streamFormat(of tap: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd) == noErr
        else { return nil }
        return asbd
    }
}

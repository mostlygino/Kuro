// The meeting watch: whether a call app has the microphone, so the pill can be
// a meeting clock for the length of a call.
//
// A meeting does not publish itself to Now Playing. In a Teams meeting on
// 2026-10-06 Now Playing still named a paused video in Dia, and the pill sat in
// silence. What a call always does is capture audio, and since macOS 14 Core
// Audio says which process is doing it (kAudioProcessPropertyIsRunningInput on
// each process object): that morning, `com.microsoft.teams2.modulehost`, input
// and output both. No permission is needed to ask.
//
// A call starts when a call app captures input. It carries on while that app
// still has input or output running, so a mute that pauses capture does not end
// it, and it only ends after `callEndGrace` with neither, so a moment of silence
// between devices does not either. While a call is on the pill, Now Playing
// updates are held, not dropped; when it ends, a track that is playing comes
// back, and otherwise the pill settles into silence.

import CoreAudio
import CoreGraphics
import Foundation

let callPollInterval: TimeInterval = 2
let callEndGrace: TimeInterval = 6

private func audioProcessObjects() -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

private func flag(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr && value != 0
}

private func processBundleID(_ object: AudioObjectID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyBundleID,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
          let text = value?.takeRetainedValue() else { return nil }
    return (text as String).lowercased()
}

/// The call apps using audio right now: those capturing input, and those with
/// any audio at all.
func callAudio() -> (capturing: String?, sounding: Set<String>) {
    var capturing: String?
    var sounding = Set<String>()
    for object in audioProcessObjects() {
        guard let id = processBundleID(object), isCallApp(id) else { continue }
        let input = flag(object, kAudioProcessPropertyIsRunningInput)
        let output = flag(object, kAudioProcessPropertyIsRunningOutput)
        if input || output { sounding.insert(id) }
        if input, capturing == nil { capturing = id }
    }
    return (capturing, sounding)
}

/// The call on the pill, if any, and what Now Playing said meanwhile.
var activeCall: String?
var callLastHeard = Date.distantPast
var heldPayload: (state: NowPlaying?, artwork: CGImage?)?
var callWatchTimer: DispatchSourceTimer?

func callState(_ bundleID: String) -> NowPlaying {
    NowPlaying(
        title: "Call", artist: "", playing: true,
        artworkKey: discCacheKey(artworkHash: "", source: .call),
        displayMode: .track, source: .call, bundleID: bundleID)
}

func watchCalls() {
    let timer = DispatchSource.makeTimerSource(queue: applyQueue)
    timer.schedule(deadline: .now() + 1, repeating: callPollInterval, leeway: .milliseconds(200))
    timer.setEventHandler { checkCall() }
    timer.resume()
    callWatchTimer = timer
}

func checkCall() {
    let audio = callAudio()
    let now = Date()
    if let current = activeCall {
        if audio.sounding.contains(current) || audio.capturing != nil {
            callLastHeard = now
            return
        }
        guard now.timeIntervalSince(callLastHeard) >= callEndGrace else { return }
        endCall()
        return
    }
    guard let app = audio.capturing else { return }
    activeCall = app
    callLastHeard = now
    cancelPauseHide()
    cancelGapHide()
    hiddenForPause = false
    syncTransportGlyph(playing: true)
    showTrack(callState(app))
}

func endCall() {
    activeCall = nil
    let held = heldPayload
    heldPayload = nil
    // A track still playing comes back; anything else, a pause or nothing at
    // all, is silence.
    if let held, let state = held.state, state.playing {
        currentArtwork = held.artwork
        commit(state)
    } else {
        enterSilence()
    }
}

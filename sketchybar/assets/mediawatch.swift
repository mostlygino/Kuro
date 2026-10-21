import Accelerate
import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

// Event-driven Now Playing for SketchyBar. Consumes `media-control stream`,
// renders circular album-disc frames into the user cache, and only swaps those
// frames while playback is actually running.
//
// SketchyBar cannot rotate an image (it loads a static PNG via
// CGImageCreateWithPNGDataProvider). Smooth spin is 60 pre-rendered frames
// pushed over SketchyBar's mach port, not a `sketchybar` process per frame.

let mediaControlBin = "/opt/homebrew/bin/media-control"

// Render at exactly the size the disc is drawn at, times discPixelScale, and let
// SketchyBar show it at the inverse (MEDIA_DISC_SCALE 0.5 for 2x) and no other.
//
// Rendering large and letting SketchyBar shrink it was the quality problem: the
// frame was resampled twice, once here by CoreGraphics and again by SketchyBar's
// own scaler on the way to the screen. Both attached displays are 1x (a 3440px
// 34" panel is ~109 PPI), so 24pt is 24 physical pixels and there is nothing to
// gain from a larger source. 1:1 is the sharpest this can be.
//
// The built-in Retina panel is the main screen again (2026-09-29), and a 24px
// cover there was upscaled into a soft blur, the one unsharp thing on a bar of
// 2x marks. So the cover is drawn at 2x and shown at MEDIA_DISC_SCALE 0.5; on a
// 1x screen SketchyBar downsamples it, which stays sharp. Only the cover: the
// podcast bars and the video dot keep their 24px canvases (slotPixelSize), where
// every pixel is placed by hand, and restingDiscScale shows each shape at its
// own inverse.
let discPointSize: CGFloat = 24
let discPixelScale: CGFloat = 2
let discPixelSize = Int(discPointSize * discPixelScale)
// The canvas for everything in the slot that is not the cover.
let slotPixelSize = Int(discPointSize)
// The same slot in three shapes. A circle is the right picture for a record and
// the wrong one for everything else: a podcast has no B-side to spin, and a
// video thumbnail is 16:9, so cropping it round threw away most of the frame and
// then rotated what was left.
//
// Video was a 42x24 banner in a widened 46pt slot first, and it was called ugly
// on sight for two reasons that both hold up. Its corners leaned on
// `background.image.corner_radius`, which SketchyBar accepts as a property (a
// nonsense one is rejected outright, so it exists) but which is not what makes
// the disc round: `drawDisc` clips the ellipse into the PNG itself. So the
// "rounded banner" was a bare rectangle. And a flat-topped rectangle wedged
// against a capsule's curve reads as cramped no matter what its corners do.
//
// A 24x24 rounded tile fixed the shape and kept the thumbnail, and the thumbnail
// was the remaining problem: a 16:9 frame in 24 square pixels is a smear of
// colour, not a picture of anything, and showing album art for something that
// has no album was the habit rather than the intent. Video is now a record dot
// that pulses. No artwork at all, so there is nothing to be unreadable.
let dotPixelSize = 24
// 10px across in a 24px canvas. Small enough to read as a dot rather than a
// blob, big enough that the rim has pixels to be round with.
let dotDiameter: CGFloat = 10
// 48 frames at spinInterval is one 2s cycle. Slow on purpose: this sits in a
// menu bar all day, and a 1Hz hard blink is a strobe, not an indicator.
let dotFrameCount = 48
// Never off. A dot that vanishes leaves a 28pt hole with the title still offset
// past it, which looks like the icon failed to load rather than like a blink.
let dotAlphaFloor: CGFloat = 0.3
// The dimmest frame, which is where a paused dot rests. See parkDiscFrame.
let dotRestFrame = dotFrameCount / 2
let discItemWidth = 28
let discCornerRadius = 12
// Six bars at the shared 2pt pitch. Wider margins are what the DJ waveform uses
// to sit inside a 204pt pill; at 24pt there is nothing to inset from.
let discWaveSideMargin: CGFloat = 1
// One revolution is 2.5s. 36 frames over that was 14.4 fps, visibly stepped on a
// small disc; 60 was 24 fps, 6 degrees a frame. Music and podcasts are what
// this pill shows most of the day, so they run at the display's own 60 fps
// since 2026-09-29: 150 frames, 2.4 degrees a step, and the canned podcast bars
// likewise. The cost is SketchyBar's, not the watcher's, because every swap
// redraws the bar: measured 7% of its CPU at 24 fps and 17.5% at 60 while
// something plays. The other shapes, the video dot and the service marks,
// breathe slowly and keep 24 fps (slotRestInterval), where 60 would be spent
// on a change nobody could see.
let frameCount = 150
let spinInterval: TimeInterval = 2.5 / TimeInterval(frameCount)
let waveformFrameCount = 180
let waveformInterval: TimeInterval = 3.0 / TimeInterval(waveformFrameCount)
let slotRestInterval: TimeInterval = 1.0 / 24.0

/// How often the slot steps a frame for what it is showing: the cover and the
/// podcast bars at 60 fps, the silence at 6, everything else at 24.
func slotInterval(for source: MediaSource?) -> TimeInterval {
    switch source {
    case .music?: return spinInterval
    case .podcast?: return waveformInterval
    case .silence?: return silenceInterval
    default: return slotRestInterval
    }
}
// The live waveform is redrawn on this tick instead of the 24fps one the cached
// sequences run at. Measured on a real podcast capture, 24fps moves a bar 0.64px
// per frame and 60fps moves it 0.28px, so the step is less than half the size and
// the bars read as sliding rather than snapping.
//
// The cached sequences deliberately do not follow: their frame counts encode
// their own timing (2.5s per revolution, 2s per blink), so ticking them at 60
// would just run all three animations 2.5x fast. They advance off a time
// accumulator instead, and ticks that move nothing push nothing.
//
// It also buys window overlap for free. The FFT window is 1024 samples, 21ms at
// 48kHz, so at a 41.7ms tick consecutive frames analysed disjoint audio and
// nothing was carried between them. At 16.7ms they overlap.
let liveInterval: TimeInterval = 1.0 / 60.0
// Only a fallback now: the real width is measured off the text it replaces, so
// that the pill does not change size when the DJ takes over. Used when that
// measurement fails.
let waveformFallbackWidth = 204
let waveformPixelHeight = 24
let waveformBarWidth: CGFloat = 2
let waveformBarGap: CGFloat = 2
let waveformSideMargin: CGFloat = 17
// How quiet the quietest frame is allowed to get. The DJ row keeps the original
// value; the disc slot needs a much higher one, because six bars have no shape
// left to read once they are all short. See waveformHeights.
let waveformEnvelopeFloor: CGFloat = 0.18
let discWaveEnvelopeFloor: CGFloat = 0.46
// Six bars sample the same spatial function 43 of them do, and six samples
// rarely land on its peaks, so the disc row topped out around 14 of the 22px
// available and read as timid rather than compact. This buys the peaks back. The
// height clamp in waveformHeights is what keeps it from overshooting the slot.
let discWaveAmplitude: CGFloat = 1.3
// Narrower than this stops reading as a waveform at all, so a very short title
// gets a slightly wider wave rather than four bars.
let waveformMinWidth = 96

// Keeps the bar pitch and the side margin constant at any width, so a wave
// rendered for a short title has the same density as one for a long title
// instead of the same number of bars stretched out. At 204 this is the 43 bars
// the fixed-width version had.
// The margin is a parameter because the same waveform now gets drawn at two very
// different sizes. At 204pt it insets 17 to sit inside the pill's own padding; at
// 24pt in the disc slot there is nothing to inset from and a 17pt margin would
// leave no room for a single bar.
func waveformBars(forWidth width: Int, sideMargin: CGFloat = waveformSideMargin) -> Int {
    let usable = CGFloat(width) - 2 * sideMargin + waveformBarGap
    return max(4, Int(usable / (waveformBarWidth + waveformBarGap)))
}
let waveformCacheVersion = "waveform-v3"
// The handoff frames, played forwards to arrive and backwards to leave. Baking
// the entrance into the image is the only way to fade it: SketchyBar has no
// alpha for `background.image`, and the earlier attempt at using
// `background.image.scale` instead was a zoom, which is the wrong verb. Screen
// captures of it showed a 37pt smudge in the middle of a 206pt pill opening
// outwards. These rise out of a flat 2px line at full width instead, so nothing
// changes size or position at any point.
let waveformEntryCount = 16
// The entry ramp faded opacity from 0, which meant its first frame was blank and
// the pill went empty for one frame at the exact handover point: text at alpha 0
// and a waveform not yet visible. Amplitude still starts at 0, so frame 0 is the
// flat 2px row the rest of the set grows out of, but now at an opacity you can
// actually see. Nothing about the sequence changed, only that its first frame
// stopped being invisible.
let waveformEntryOpacityFloor: CGFloat = 0.55
let waveformEntryCacheVersion = "waveform-entry-v3"
let maxArtworkBytes = 2 * 1024 * 1024
// Bump this whenever the disc drawing changes, so already-cached frames from the
// old look are ignored instead of being served forever. Every cache key derives
// from it, fallback included, so the two cannot drift apart.
let cachePrefix = "g33-"
// Nine rather than eight because the podcast waveform now holds one of these
// slots permanently. It shares the LRU (its directory carries the same prefix,
// so initialiseCacheOrder sweeps it like any other), and without the extra slot
// adding it would have quietly cost a cover.
let maxCachedAlbums = 9
// Every distinct title length is a distinct wave width, so these accumulate the
// same way album art does and need the same ceiling. Roughly 90 small PNGs per
// width.
let maxCachedWaveWidths = 8
let thumbnailMaxPixels = 256
let allowedMimes: Set<String> = [
    "image/jpeg", "image/jpg", "image/png", "image/x-png",
]
let allowedUTIs: Set<String> = ["public.jpeg", "public.png"]

let env = ProcessInfo.processInfo.environment
let playingColor = env["MEDIA_COLOR"] ?? "0xff88c0d0"
let pausedColor = env["MEDIA_PAUSED_COLOR"] ?? "0xaa88c0d0"
let playingScale = env["MEDIA_DISC_SCALE"] ?? "1.0"
let pausedScale = env["MEDIA_DISC_PAUSED_SCALE"] ?? "1.0"
// Single source of truth with sketchybarrc's label.max_chars. If the watcher
// composes a longer string than SketchyBar is willing to draw, SketchyBar wins
// and the tail disappears with no warning, so these two have to agree.
let labelMaxChars = Int(env["MEDIA_LABEL_MAX"] ?? "") ?? 90
let fieldMaxChars = 160
let artistColor = env["MEDIA_ARTIST_COLOR"] ?? "0xff8e8e93"
let artistPausedColor = env["MEDIA_ARTIST_PAUSED_COLOR"] ?? "0x668e8e93"
let sepColor = env["MEDIA_SEP_COLOR"] ?? "0x998e8e93"
let sepPausedColor = env["MEDIA_SEP_PAUSED_COLOR"] ?? "0x558e8e93"
// The bracket's own chrome, so the capsule can arrive and leave with what is
// inside it rather than snapping around it. Fair game for this watcher to own:
// menubar_reveal.sh writes `background.drawing` on media_pill and never its
// colours, which is the same split the item properties already follow.
let pillColor = env["PILL_COLOR"] ?? "0xd91c1c1e"
// The pill's trailing gap. It normally lives on `media_artist` as
// `label.padding_right`, which means it goes away with that item, and the title
// then sits flush against the capsule's border while the disc still has its 8pt
// on the other side. That was always true of a track with no artist; podcasts
// made it the ordinary case. `media` takes the padding over when the artist is
// not drawn, so it belongs to the pill rather than to one member of it.
let pillTextPad = Int(env["PILL_TEXT_PAD"] ?? "") ?? 9
// The silence's title. Never drawn, since the silence is the note alone, but it
// is what tells it apart from a track wherever two states are compared.
let silenceLabel = "Silence"
let silenceColor = artistColor
let pillBorderColor = env["BORDER_COLOR"] ?? "0x59ffffff"
let pillShadowColor = env["SHADOW_COLOR"] ?? "0x80000000"

enum MediaDisplayMode: Equatable {
    case track
    case spotifyDJ
}

// What the disc slot should be a picture of. `displayMode` is about the whole
// pill and is Spotify's alone; this is about the one item, and every player
// feeds it.
enum MediaSource: Equatable {
    case music
    case podcast
    case video
    // A video playing in a browser tab. In practice that is YouTube, which is
    // what the icon says; see classifySource for why it cannot be told apart
    // from Vimeo or Twitch without asking the browser for its URL.
    case youtube
    // Anything else a browser tab is playing: a music site, an embedded clip, a
    // web radio stream.
    case browser
    // A meeting or call client holding the Now Playing session.
    case call
    // A browser tab on a service mediaservice.swift has recognised: Netflix,
    // Twitch, Disney+ and the rest, each with a mark of its own.
    case service(WebService)
    // A video app, drawn with its own app icon rather than the record dot.
    case videoApp(String)
    // Nothing at all: no player, or a pause long enough to count as stopping.
    // The pill used to take itself away for this; since 2026-09-29 it stays and
    // says so, with its own mark. See silenceState.
    case silence
}

struct NowPlaying: Equatable {
    var title: String
    var artist: String
    var playing: Bool
    var artworkKey: String
    var displayMode: MediaDisplayMode
    var source: MediaSource
    // Carried on the state rather than kept in a global for the same reason the
    // artwork is: the stream thread writes this and applyQueue reads it. The
    // audio tap needs it to know whose pid to tap, and only Spotify is tapped.
    var bundleID: String
}

let spotifyBundleID = "com.spotify.client"

// Only Apple's is asserted by name, because it is the only one on this machine
// and inventing bundle ids for clients I cannot check is how a list like this
// silently stops matching. The substrings carry the long tail: every podcast
// client I can find puts one of these in its identifier, and no music player
// does.
let podcastBundleIDs: Set<String> = ["com.apple.podcasts"]

func isPodcastApp(_ bundleID: String) -> Bool {
    let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if id.isEmpty { return false }
    if podcastBundleIDs.contains(id) { return true }
    return id.contains("podcast") || id.contains("pocketcast") || id.contains("overcast")
}

// A cover is square. A video thumbnail is not. Measured 600x600 (1.00) off
// Spotify and 150x83 (1.81) off a YouTube tab in Dia, so the gap is wide enough
// that this threshold does not have to be delicate. Reading the artwork rather
// than the bundle id means this covers every browser and every site without a
// list to keep up to date.
let videoAspectThreshold: CGFloat = 1.3

func artworkAspect(_ image: CGImage?) -> CGFloat? {
    guard let image, image.width > 0, image.height > 0 else { return nil }
    return CGFloat(image.width) / CGFloat(image.height)
}

// Spotify is the one player that carries both kinds behind a single bundle id,
// and MediaRemote has no field that separates them: `mediaType` came back
// `...TypeAudio` for a song, and MediaRemote has no podcast type at all, so it
// would say the same for an episode. Two signals stand in for the missing one.
//
// This is the free one, and it decides the frame that is about to be drawn.
//
// The first version of it tested for a missing album and a missing track number,
// reasoning from the song case alone, and a real episode proved it wrong on both
// counts within the hour. Measured 2026-09-09 on Diggnation: `album` is *not*
// empty, it carries the show name, and `trackNumber` is *present*, it is 0. A
// song was `artist` "Drake", `album` "ICEMAN", track 14.
//
// So the fields that separate them are artist and track number, and the mirror
// image is the tell: an episode has no artist and no track number, a song has
// both. Requiring both keeps a DJ segment out too, since that carries artist
// "DJ X".
func spotifyMetadataLooksLikeEpisode(_ payload: [String: Any]) -> Bool {
    let artist = (payload["artist"] as? String ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard artist.isEmpty else { return false }
    let track = (payload["trackNumber"] as? Int)
        ?? (payload["trackNumber"] as? NSNumber)?.intValue
    return (track ?? 0) == 0
}

// And this is the authoritative one, cached per track because it costs a
// subprocess. Spotify's scripting interface hands back the track URI, and
// `spotify:episode:` against `spotify:track:` is a fact rather than an
// inference. Measured at 144ms, which is why it runs behind the draw and not in
// front of it: the heuristic above picks the first frame, this corrects it if it
// disagrees, and a correction is a re-commit rather than a flicker because the
// answer lands well inside the pill's own fade.
//
// This is the one piece of state in this file that applyQueue cannot own by
// itself. Everything else is touched only once a payload has reached that queue,
// but classification happens in parsePayload, on the stream thread, and the
// answer arrives on a third. A lock is the right size for it: every critical
// section below is a single dictionary or set operation.
let spotifyKindLock = NSLock()
var spotifyURIKind: [String: Bool] = [:]
var spotifyProbesInFlight: Set<String> = []
// A track that has been asked about and did not answer. Without this, refusing
// the Automation prompt turns into a subprocess storm: the answer never gets
// cached, so the next payload asks again, ten times a second, at 144ms a go.
var spotifyUnanswered: Set<String> = []
var spotifyProbeFailures = 0
var spotifyProbeDisabled = false
// Three in a row is not a wedged Spotify, it is a permission that is not
// coming. Stop asking for the rest of the session and leave the metadata
// heuristic to it.
let maxSpotifyProbeFailures = 3

func knownSpotifyKind(_ id: String) -> Bool? {
    spotifyKindLock.lock()
    defer { spotifyKindLock.unlock() }
    return spotifyURIKind[id]
}

// Returns false when this track is already answered, already refused to answer,
// or already being asked about.
func claimSpotifyProbe(_ id: String) -> Bool {
    spotifyKindLock.lock()
    defer { spotifyKindLock.unlock() }
    guard !spotifyProbeDisabled, spotifyURIKind[id] == nil,
          !spotifyUnanswered.contains(id), !spotifyProbesInFlight.contains(id)
    else { return false }
    spotifyProbesInFlight.insert(id)
    return true
}

func finishSpotifyProbe(_ id: String, episode: Bool?) {
    spotifyKindLock.lock()
    defer { spotifyKindLock.unlock() }
    spotifyProbesInFlight.remove(id)
    guard let episode else {
        spotifyUnanswered.insert(id)
        if spotifyUnanswered.count > 64 { spotifyUnanswered.removeAll() }
        spotifyProbeFailures += 1
        if spotifyProbeFailures >= maxSpotifyProbeFailures {
            spotifyProbeDisabled = true
            logErr("spotify track lookup keeps failing, falling back to metadata only")
        }
        return
    }
    // One answer clears the count: the failures worth latching on are
    // consecutive ones, not a wedged moment during a track change.
    spotifyProbeFailures = 0
    // Bounded for the same reason the artwork cache is: a long session is
    // thousands of tracks, and only the one being asked about is ever needed.
    if spotifyURIKind.count > 64 { spotifyURIKind.removeAll() }
    spotifyURIKind[id] = episode
}

func isSpotifyDJ(_ payload: [String: Any]) -> Bool {
    func normalized(_ key: String) -> String? {
        guard let value = payload[key] as? String else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    let duration = (payload["duration"] as? Double)
        ?? (payload["duration"] as? NSNumber)?.doubleValue

    // The title is deliberately not part of the fingerprint. It was, at "up
    // next", because that is what the one payload this was first measured
    // against happened to say. But the title is the only field the DJ varies:
    // the greeting that opens a session says something else, so pinning it sent
    // that first segment down the track path and drew Spotify's own metadata as
    // if it were a song, reading "Welcome / DJ X" in the pill. Reported
    // 2026-09-09.
    //
    // What is left still only matches the DJ. A real track carries a duration,
    // so `duration == 0` alone rules out Spotify's whole catalogue, and the
    // artist and album have to be exactly "DJ X" and "DJ" on top of that.
    return normalized("bundleIdentifier") == "com.spotify.client"
        && normalized("artist") == "dj x"
        && normalized("album") == "dj"
        && duration == 0
}

// Every piece of mutable state below is read and written from this one queue,
// including from the spin timer. The spin used to run on its own queue, which
// meant the timer read framePaths and frameIndex while commit was reassigning
// them from underneath it. An unsynchronised array swap under a 24fps reader is
// not a race you get to lose gracefully.
let applyQueue = DispatchQueue(label: "mediawatch.apply")
// The spin timer and the metadata path both talk to the same mach port from
// different queues. Funnelling every send through one serial queue keeps two
// messages from interleaving on the wire.
let ipcQueue = DispatchQueue(label: "mediawatch.ipc")
var spinTimer: DispatchSourceTimer?
var framePaths: [URL] = []
var frameIndex = 0
var spinClock: TimeInterval = 0
var renderedArtworkKey: String?
var waveformTimer: DispatchSourceTimer?
var waveformPaths: [URL] = []
var waveformIndex = 0
var waveClock: TimeInterval = 0
var lastApplied: NowPlaying?
var pendingWorkItem: DispatchWorkItem?
var cacheOrder: [String] = []
// Scale is not a per-frame property, so it is only sent when it actually
// changes. Re-sending it with every metadata update was pure churn.
var lastDiscScale: String?

// Mode changes are tweened by hand, one plain `--set` per step, because the
// SketchyBar animator does nothing here (see runSketchybar). Swapping the whole
// centre pill in a single message is a hard cut: the disc, title and separator
// vanish and 204pt of waveform appears between two frames.
//
// Text out, then wave in, rather than a crossfade, and that is forced by the
// layout rather than chosen. Both are members of the same bracket, so anything
// drawn at the same time claims its own width and the pill would balloon to hold
// the pair: measured at 443pt with both up.
//
// What used to make the entry read as the player being wiped out was not this
// sequence at all. It was `hidePlayer`: a track ending emits a payload with no
// title and no artist, that used to tear the pill down outright, and the DJ then
// arrived on an empty bar with no "from" state left to fade from. The gap is
// held now (see `emptyPayloadGrace`), so the fade below is what actually runs.
let transitionDuration: TimeInterval = 0.22
let transitionStepInterval: TimeInterval = 1.0 / 60.0
var transitionTimer: DispatchSourceTimer?
// The track the DJ exit fade is heading towards, and the flag saying one is in
// flight. Non-nil only for the length of that fade.
var pendingTrack: NowPlaying?
// The handoff frames, loaded once. The wave has no image scale of its own any
// more: its entrance is baked into these instead, which removes both the zoom
// and a whole class of "the number moved but nobody sent it" bug.
var waveformEntryPaths: [URL] = []
// What the wave item's width was last told to be, so the running loop can stop
// resending it 24 times a second. Same trick as lastDiscScale.
var lastWaveWidth: Int?
// The width the currently cached frames were drawn at. The item's width has to
// track this exactly: SketchyBar does not clip `background.image` to the item
// box, so a 204px image in a 60pt item reported a 204pt rect and drew straight
// over the cover next to it.
var waveformRenderedWidth = waveformFallbackWidth
// The width the paths in waveformPaths were actually drawn at, so a segment at a
// new width re-renders and one at a width already on disk does not.
var waveformCachedWidth: Int?

// The track items are auto-sized, so their combined width does not exist as a
// number anywhere until the bar has drawn them. Reading it back is the only way
// to know what the wave has to match. One spawn per handoff, not per frame.
// Bounded, because this runs on the apply queue and that queue stalling is how
// the whole bar stops responding. A missed measurement only costs a snap on one
// handoff; a blocked queue costs everything.
func queryItem(_ name: String) -> [String: Any]? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    task.arguments = ["sketchybar", "--query", name]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do { try task.run() } catch { return nil }

    let done = DispatchSemaphore(value: 0)
    var data = Data()
    DispatchQueue.global(qos: .userInitiated).async {
        data = pipe.fileHandleForReading.readDataToEndOfFile()
        done.signal()
    }
    guard done.wait(timeout: .now() + 0.2) == .success else {
        task.terminate()
        return nil
    }
    task.waitUntilExit()
    guard task.terminationStatus == 0 else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

// The horizontal run the three text items occupy, which is exactly what the
// wave has to take over now that the disc stays put. Measured off the items
// themselves rather than derived from the pill, because deriving it would need
// the disc's contribution and the bracket's own padding as constants and neither
// is reported anywhere.
// The whole pill, not the text run: with the cover hidden for a DJ segment the
// waveform is the only thing left in the bracket, so it has to account for the
// disc's slot too. Asking the bracket beats adding up its members, which report
// overlapping rects once an item carries a background image wider than its box.
func queryPillWidth() -> CGFloat? {
    guard let pill = queryItem("media_pill"), let rect = itemRect(fromQuery: pill)
    else { return nil }
    return rect.width > 0 ? rect.width : nil
}

// A hidden artist still reports its last rect, so the drawing flag decides
// whether that rect counts. Without this a track with no artist would size the
// wave to a slot that is not on screen.

// Split out from the spawn so the parsing is testable without a running bar.
// bounding_rects is keyed by display and lists every display the bar is on. The
// ones the pill is not currently on carry negative origins, so this takes the
// rightmost entry rather than assuming "display-1".
func itemRect(fromQuery obj: [String: Any]) -> (origin: CGFloat, width: CGFloat)? {
    guard let rects = obj["bounding_rects"] as? [String: Any] else { return nil }
    let found = rects.values.compactMap { entry -> (CGFloat, CGFloat)? in
        guard let dict = entry as? [String: Any],
            let size = dict["size"] as? [Any], let width = size.first as? Double, width > 0,
            let origin = dict["origin"] as? [Any], let x = origin.first as? Double
        else { return nil }
        return (CGFloat(x), CGFloat(width))
    }
    guard let best = found.max(by: { $0.0 < $1.0 }) else { return nil }
    return (origin: best.0, width: best.1)
}

// The wave item width that occupies a given run of the pill, which is the span
// itself. `bounding_rects` excludes an item's own padding, so a span measured
// from the title's left edge to the artist's right edge is missing the title's
// `padding_left` and the artist's `padding_right`, and includes the two 2pt gaps
// between the three items. The wave's own 1pt padding on each side replaces
// exactly the 1pt of outer padding the run was missing, so the two cancel.
//
// Verified against a real track: title 1647..1745, separator 1747..1769, artist
// 1771..1821, span 174, and a 174pt wave reproduces the 204pt pill exactly. The
// earlier `span - 2` left the pill 2pt narrower in DJ mode.
// A bracket adds nothing of its own around a lone member, so the wave item's own
// padding is the entire difference between the image and the pill it has to
// fill. Measured, not derived: rendering the wave at 204/172/120/240 with the
// track items hidden gave a pill of exactly 206/174/122/242.
let waveformPaddingTotal: CGFloat = 2

func waveWidth(forPill pill: CGFloat) -> CGFloat {
    max(1, pill - waveformPaddingTotal)
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("mediawatch: \(message)\n".utf8))
    exit(1)
}

func logErr(_ message: String) {
    FileHandle.standardError.write(Data("mediawatch: \(message)\n".utf8))
}

func cacheRoot() throws -> URL {
    let base = try FileManager.default.url(
        for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    )
    let root = base.appendingPathComponent("sketchybar-media", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

func initialiseCacheOrder() {
    let fm = FileManager.default
    guard let root = try? cacheRoot(),
          let entries = try? fm.contentsOfDirectory(
              at: root,
              includingPropertiesForKeys: [.contentModificationDateKey],
              options: [.skipsHiddenFiles]
          )
    else { return }

    let albums = entries.filter { $0.lastPathComponent.hasPrefix(cachePrefix) }
        .sorted {
            let left = (try? $0.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast
            return left < right
        }
    let excess = max(0, albums.count - maxCachedAlbums)
    for url in albums.prefix(excess) {
        try? fm.removeItem(at: url)
    }
    cacheOrder = albums.dropFirst(excess).map(\.lastPathComponent)
}

func sanitizeLabel(_ raw: String) -> String {
    let collapsed = raw
        .replacingOccurrences(of: "\u{0000}", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\t", with: " ")
    // Control characters only. The quote, backtick, backslash and dollar filter
    // that used to live here was defending against a shell that is not in the
    // path: the message goes over a mach port as a NUL-separated argument block
    // and nothing re-parses it (see encodeArgs). It was also lossy in a way
    // people notice, turning "A$AP Rocky" into "AAP Rocky".
    //
    // Removing it is only safe *because* the transport was fixed on 2026-09-07.
    // If anything here ever goes back to being flattened into one string, this
    // filter has to come back with it, and stripping `'` too.
    //
    // NUL in particular still has to go: it would end an argument early in the
    // block, which is the one byte that still carries meaning down there.
    let scalars = collapsed.unicodeScalars.filter { $0.value >= 32 }
    let trimmed = String(String.UnicodeScalarView(scalars))
        .trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return "" }
    // This cap is a sanity bound on the IPC message, not a layout decision.
    // Layout is composeLabel's job. It used to be 47, which silently truncated
    // long titles before anything could reason about the space available.
    if trimmed.count <= fieldMaxChars { return trimmed }
    let idx = trimmed.index(trimmed.startIndex, offsetBy: fieldMaxChars)
    return String(trimmed[..<idx])
}

// Streaming metadata staples a lot onto a title that is not the song:
// "(feat. Someone)", "- Remastered 2011", "(Radio Edit)", "[Bonus Track]".
// On a bar that is already trading width with the clock, it is the first thing
// that should go.
//
// **Noise is only removed from a trailing bracket group or a trailing dash
// suffix, and only when the whole of that group reads as noise.** That
// narrowness is the entire safety story. Stripping every parenthetical would eat
// "(Don't Fear) The Reaper", and matching these words anywhere in the string
// would eat "Live and Let Die". A group has to be both in the junk position and
// junk all the way through.
//
// Three lists rather than one regex, because this is a tuning table and it will
// get edited. Add to the list, not to the parser.

// Whole group is exactly this. Catches "(Live)" and "(Explicit)" without
// touching "(Live at Wembley 1985)" logic below or any real title word.
let noiseExact: Set<String> = [
    "live", "explicit", "clean", "demo", "acoustic", "instrumental",
    "remaster", "remastered", "mono", "stereo", "edit", "single", "deluxe",
    "bonus track", "bonus", "reissue", "original mix", "radio edit",
]

// A *credit*: "(feat. X)", "(with X)". Carries a name after it, so a prefix test
// is the only thing that works. Credits are the one class removed from anywhere
// in the title rather than only from the end, because a featured artist is never
// part of the song's name no matter where the service put it. Without that,
// "Old Town Road (feat. Billy Ray Cyrus) - Remix" keeps the credit purely
// because a suffix we deliberately preserve happens to sit behind it.
let creditPrefixes = [
    "feat.", "feat ", "ft.", "ft ", "featuring", "with ", "w/",
]

// Group starts with this, and only counts at the end. "from " is provenance
// rather than a credit ("[From Barbie The Album]"), and a title is allowed to
// start a real parenthetical with it.
let noisePrefixes = creditPrefixes + ["from "]

// Group ends with this. Generalises the long tail of "<something> Version" and
// "<something> Edit" tags, which are endless to enumerate: acoustic, single,
// album, extended, re-recorded, radio, 7". Note " mix" is deliberately absent,
// for the same reason "remix" is: a mix is a different recording that someone
// chose to play, not a tag stapled onto the one they chose.
let noiseSuffixes = [
    " version", " edit", " edition", " remaster", " remastered", " mono", " stereo",
]

// Group contains this anywhere. Reserved for phrases specific enough that they
// cannot show up inside a real song name.
let noiseSubstrings = [
    "remaster", "radio edit", "single version", "album version",
    "extended version", "extended mix", "original mix", "bonus track",
    "deluxe", "anniversary edition", "reissue", "mono version",
    "stereo version", "digital remaster", "live at", "live from", "live in",
    "live version", "motion picture", "soundtrack", "explicit",
]

// Separators a service puts before a version suffix. Written as escapes because
// the en and em dash are invisible next to a hyphen in a source file, and the
// difference decides whether a title cleans up or not.
let noiseSeparators = [" - ", " \u{2013} ", " \u{2014} "]

// "Song feat. Someone" with no brackets at all. Needs the leading space so a
// track legitimately called "Feat" or "Ft" survives.
let bareFeatTokens = [" feat. ", " feat ", " ft. ", " ft ", " featuring ", " w/ "]

func isCreditSegment(_ raw: String) -> Bool {
    let s = raw.lowercased().trimmingCharacters(in: .whitespaces)
    return creditPrefixes.contains { s.hasPrefix($0) }
}

// Position independent, unlike everything else here, so it walks the whole
// string. Restarts from the beginning after a removal because the indices move.
func stripCreditGroups(_ raw: String) -> String {
    var out = raw
    var from = out.startIndex
    while from < out.endIndex,
          let open = out[from...].firstIndex(where: { $0 == "(" || $0 == "[" }) {
        let closer: Character = out[open] == "(" ? ")" : "]"
        guard let close = out[out.index(after: open)...].firstIndex(of: closer) else { break }
        if isCreditSegment(String(out[out.index(after: open)..<close])) {
            out.removeSubrange(open...close)
            from = out.startIndex
        } else {
            from = out.index(after: close)
        }
    }
    // Removing a group from the middle leaves a double space behind it.
    return out.split(separator: " ", omittingEmptySubsequences: true)
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespaces)
}

func isNoiseSegment(_ raw: String) -> Bool {
    let s = raw.lowercased().trimmingCharacters(in: .whitespaces)
    if s.isEmpty { return false }
    if noiseExact.contains(s) { return true }
    if noisePrefixes.contains(where: { s.hasPrefix($0) }) { return true }
    if noiseSuffixes.contains(where: { s.hasSuffix($0) }) { return true }
    return noiseSubstrings.contains(where: { s.contains($0) })
}

// Loops, because the junk stacks: "Song (feat. X) - Remastered 2011" needs two
// passes, and the order it stacks in is not fixed.
func stripTrailingNoise(_ raw: String) -> String {
    var out = raw.trimmingCharacters(in: .whitespaces)
    var changed = true
    while changed {
        changed = false

        if let last = out.last, last == ")" || last == "]" {
            let open: Character = last == ")" ? "(" : "["
            if let idx = out.lastIndex(of: open) {
                let inner = String(out[out.index(after: idx)..<out.index(before: out.endIndex)])
                let head = String(out[out.startIndex..<idx])
                    .trimmingCharacters(in: .whitespaces)
                // Never strip a title down to nothing. A track actually called
                // "(Live)" keeps its name.
                if isNoiseSegment(inner), !head.isEmpty {
                    out = head
                    changed = true
                    continue
                }
            }
        }

        for separator in noiseSeparators {
            guard let r = out.range(of: separator, options: .backwards) else { continue }
            let suffix = String(out[r.upperBound...])
            let head = String(out[out.startIndex..<r.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            if isNoiseSegment(suffix), !head.isEmpty {
                out = head
                changed = true
                break
            }
        }
    }
    return out
}

// Case-insensitive search on the original string rather than on a lowercased
// copy: lowercasing is not always length preserving in Unicode, so indices taken
// from the copy can land mid-character in the original.
func stripBareFeat(_ raw: String) -> String {
    var cut: String.Index?
    for token in bareFeatTokens {
        guard let r = raw.range(of: token, options: [.caseInsensitive]) else { continue }
        if cut == nil || r.lowerBound < cut! { cut = r.lowerBound }
    }
    guard let cut else { return raw }
    let head = String(raw[raw.startIndex..<cut]).trimmingCharacters(in: .whitespaces)
    return head.isEmpty ? raw : head
}

// Credits first, so removing one can expose a version tag that is now trailing.
func cleanTitle(_ raw: String) -> String {
    let stripped = stripBareFeat(stripTrailingNoise(stripCreditGroups(raw)))
    return stripped.isEmpty ? raw : stripped
}

// The artist field only ever gets the feature credit removed. It is not given
// the bracket and suffix treatment, because a band name is allowed to look like
// anything and there is no junk-position convention to lean on. Multiple artists
// stay: "Simon & Garfunkel" and "A, B" are the answer to "who is this", not
// noise.
func cleanArtist(_ raw: String) -> String {
    let stripped = stripBareFeat(raw)
    return stripped.isEmpty ? raw : stripped
}

// The title is what the user asked to always see whole; the artist is context.
// So when the pair does not fit the budget, the artist is what gets dropped,
// rather than chopping the tail off the title.
//
// The two land in different SketchyBar slots: the title in `icon` and the artist
// in `label`. A SketchyBar label carries exactly one colour and has no rich text,
// so telling title from artist at a glance needs two slots. `icon` is just a
// second text field with its own font and colour, which is cheaper than adding
// another item to the right_pill bracket.
// A hard `prefix` used to be enough because the budget was only ever reached by
// pathological titles. Once video came in it is reached by ordinary ones, and a
// sentence chopped mid-word with no mark looks like a bug rather than a
// shortening. The ellipsis is paid for out of the budget, so a clipped label is
// never wider than one that fitted exactly.
func clipLabel(_ text: String, to budget: Int) -> String {
    guard text.count > budget, budget > 1 else { return String(text.prefix(budget)) }
    let head = String(text.prefix(budget - 1))
    // Break on the last word boundary rather than mid-word. "Rick Astley - Never
    // Gonna Give You Up (Of…" is what a bare prefix produced, and an orphaned
    // opening bracket reads as a rendering fault rather than a shortening. The
    // floor is there because a single very long word has no boundary worth
    // finding, and falling back to a mid-word cut beats returning two words.
    var kept = head
    let boundaryFloor = (budget * 2) / 3
    if let space = head.lastIndex(of: " "),
       head.distance(from: head.startIndex, to: space) >= boundaryFloor
    {
        kept = String(head[head.startIndex..<space])
    }
    // Trailing only. A leading dash can be part of a real title, and
    // trimmingCharacters would take both ends.
    let danglers = CharacterSet(charactersIn: " -,;:([{/&+")
    while let last = kept.unicodeScalars.last, danglers.contains(last) {
        kept.unicodeScalars.removeLast()
    }
    return kept + "\u{2026}"
}

// Music titles are track names and fit. A podcast episode title and a YouTube
// title are sentences: measured 2026-09-09, "Is College Still Worth It When
// Entry-Level Jobs Are Disappearing?" is 65 characters and "Rick Astley - Never
// Gonna Give You Up (Official Video)" is 54, both comfortably inside the 86 the
// one global budget allowed. That is why neither ever clipped and why the pill
// grew to most of the screen.
let videoLabelMaxChars = 42

func labelBudget(for source: MediaSource) -> Int {
    switch source {
    case .music: return labelMaxChars
    // A show name is short by nature, so this is a guard against a pathological
    // one rather than a working limit.
    case .podcast: return min(labelMaxChars, videoLabelMaxChars)
    case .video, .youtube, .browser, .call, .service, .videoApp: return min(labelMaxChars, videoLabelMaxChars)
    case .silence: return labelMaxChars
    }
}

func composeParts(
    title: String, artist: String, budget: Int = labelMaxChars
) -> (title: String, artist: String) {
    let head = clipLabel(title, to: budget)
    if head.isEmpty { return (clipLabel(artist, to: budget), "") }
    if artist.isEmpty { return (head, "") }
    // Reserve for what sits between the two slots. It was 3 when that gap was
    // pure padding; since 2026-09-07 it is 9pt, a `~`, and 9pt more, so roughly
    // 24pt against Avenir Next 13's ~6.5pt average character.
    let separatorBudget = 4
    if head.count + artist.count + separatorBudget <= budget {
        return (head, artist)
    }
    return (head, "")
}

func decodeArtwork(_ base64: String, mime: String) -> CGImage? {
    let normalised = mime.lowercased().split(separator: ";")[0]
        .trimmingCharacters(in: .whitespaces)
    guard allowedMimes.contains(String(normalised)) else { return nil }
    guard let data = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]) else {
        return nil
    }
    guard !data.isEmpty, data.count <= maxArtworkBytes else { return nil }
    guard let source = CGImageSourceCreateWithData(data as CFData, [
        kCGImageSourceShouldCache: false,
    ] as CFDictionary) else { return nil }
    let uti = CGImageSourceGetType(source) as String?
    guard let uti, allowedUTIs.contains(uti) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixels,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

func artworkKey(from data: String) -> String {
    let digest = SHA256.hash(data: Data(data.utf8))
    return cachePrefix + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
}

func fillFallback(ctx: CGContext, rect: CGRect) {
    ctx.setFillColor(CGColor(red: 0.16, green: 0.16, blue: 0.17, alpha: 1))
    ctx.fillEllipse(in: rect)
}

// The disc is round, so a cover that is not square has to be centre-cropped.
// Drawing it straight into a square rect squashes it, which was silently
// distorting any non-square artwork.
func aspectFillRect(for image: CGImage, in rect: CGRect) -> CGRect {
    let w = CGFloat(image.width)
    let h = CGFloat(image.height)
    guard w > 0, h > 0 else { return rect }
    let factor = max(rect.width / w, rect.height / h)
    let fw = w * factor
    let fh = h * factor
    return CGRect(x: rect.midX - fw / 2, y: rect.midY - fh / 2, width: fw, height: fh)
}

// One square, pre-filtered copy of the cover at twice the disc's pixel size,
// built once per album. Every frame then rotates *this* down by 2x instead of
// reducing the 256px thumbnail by more than 10x on each of 60 frames. Two gentle
// steps alias far less than one big one, and it is also 60x less work.
func squareSource(from image: CGImage) -> CGImage? {
    let side = discPixelSize * 2
    guard let ctx = CGContext(
        data: nil,
        width: side,
        height: side,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    let rect = CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side))
    ctx.interpolationQuality = .high
    ctx.draw(image, in: aspectFillRect(for: image, in: rect))
    return ctx.makeImage()
}

func drawDisc(into ctx: CGContext, image: CGImage?, angle: CGFloat) {
    let size = CGFloat(discPixelSize)
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    ctx.clear(rect)
    ctx.saveGState()
    ctx.addEllipse(in: rect)
    ctx.clip()
    ctx.translateBy(x: size / 2, y: size / 2)
    ctx.rotate(by: angle)
    ctx.translateBy(x: -size / 2, y: -size / 2)
    if let image {
        ctx.interpolationQuality = .high
        ctx.draw(image, in: aspectFillRect(for: image, in: rect))
    } else {
        fillFallback(ctx: ctx, rect: rect)
    }
    ctx.restoreGState()

    // Everything below is deliberately minimal. At 24 physical pixels a hairline
    // rim and a ringed spindle are sub-pixel detail: they do not read as gloss,
    // they read as dirt on the artwork. The earlier version drew a 0.7px rim, a
    // 0.6px ring around the hole and a three-stop gradient, and that is a large
    // part of what made the disc look cheap.
    //
    // Only gradients are used from here on, and that is the point: a gradient is
    // evaluated per pixel, so it cannot go blocky. Filled shapes can, and did.
    ctx.saveGState()
    ctx.addEllipse(in: rect)
    ctx.clip()
    let sheen = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.10),
            CGColor(red: 0, green: 0, blue: 0, alpha: 0.10),
        ] as CFArray,
        locations: [0, 1]
    )
    if let sheen {
        ctx.drawLinearGradient(
            sheen,
            start: CGPoint(x: size * 0.5, y: size),
            end: CGPoint(x: size * 0.5, y: 0),
            options: []
        )
    }
    // A glint of light up and to the left that does not turn with the record:
    // it is drawn after the rotation is undone, so the artwork spins under a
    // fixed highlight, the way a real record turns under the room's light. At
    // 2x this is the one detail the disc has pixels for.
    let glint = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.20),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0),
        ] as CFArray,
        locations: [0, 1]
    )
    if let glint {
        let spot = CGPoint(x: size * 0.32, y: size * 0.72)
        ctx.drawRadialGradient(glint, startCenter: spot, startRadius: 0,
                               endCenter: spot, endRadius: size * 0.38, options: [])
    }
    ctx.restoreGState()

    // The spindle hole, as a radial gradient rather than a filled ellipse.
    //
    // fillEllipse at this size was the single worst thing on the disc: a 5px
    // circle has no room to describe a curve, so it came out as a blocky black
    // square sitting in the middle of the artwork, which read as a rendering
    // defect rather than a hole. A radial gradient has no outline to alias, so it
    // stays round and fades into the art instead of stamping on it.
    ctx.saveGState()
    ctx.addEllipse(in: rect)
    ctx.clip()
    let core = CGColor(red: 0.06, green: 0.06, blue: 0.07, alpha: 0.92)
    let spindle = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            core,
            core.copy(alpha: 0.80) ?? core,
            CGColor(red: 0.06, green: 0.06, blue: 0.07, alpha: 0),
        ] as CFArray,
        locations: [0, 0.5, 1]
    )
    if let spindle {
        let centre = CGPoint(x: size / 2, y: size / 2)
        ctx.drawRadialGradient(
            spindle,
            startCenter: centre,
            startRadius: 0,
            endCenter: centre,
            endRadius: 3.4 * discPixelScale,
            options: []
        )
    }
    ctx.restoreGState()
}

func pngData(from image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
}

// `amplitude` scales the envelope without touching the bar geometry, so at 0
// every bar is its 2px floor and the row reads as a quiet line rather than a
// shrunken waveform. That distinction is the whole point of the entry frames:
// a waveform is supposed to rise out of a flat line, not zoom in from a dot.
// `levels` is measured audio, one value per bar in 0...1, and when it is present
// it replaces the synthetic texture and the synthetic envelope both. The
// geometry does not change with it: same 2px floor, same cap, same centre
// weighting, so a live row and a canned one are recognisably the same waveform
// driven from two different places rather than two different animations.
//
// `amplitude` still applies, because it is what the DJ handoff tween rides on.
// At 0 a live row collapses to its floor exactly like a canned one does.
func waveformHeights(
    frame: Int, barCount: Int, amplitude: CGFloat = 1,
    envelopeFloor: CGFloat = waveformEnvelopeFloor,
    levels: [CGFloat]? = nil
) -> [CGFloat] {
    if let levels, !levels.isEmpty {
        return (0..<barCount).map { bar in
            // Resample rather than assume: the caller asks for the bar count it
            // is drawing, and the tap is asked for that same count, but a width
            // change between the two would otherwise index off the end.
            let source = levels.count == barCount
                ? levels[bar]
                : levels[min(levels.count - 1, bar * levels.count / max(1, barCount))]
            return min(
                CGFloat(waveformPixelHeight - 2),
                max(2, 2 + source * amplitude * CGFloat(waveformPixelHeight - 4))
            )
        }
    }
    let wrapped = ((frame % waveformFrameCount) + waveformFrameCount) % waveformFrameCount
    let phase = CGFloat(wrapped) / CGFloat(waveformFrameCount) * 2 * .pi
    // Integer phase multiples make the last frame meet the first without a
    // seam. The previous hard-coded "quiet frame" ranges snapped several bars
    // by more than 9px in one tick, which looked broken even at 18fps.
    //
    // The floor is a parameter because the same envelope reads completely
    // differently at the two widths this now draws at. Across 43 bars a quiet
    // frame still looks like a wave, because there is enough of it left to see
    // the shape. Across the six bars that fit in the disc slot the same frame is
    // six flat stubs, and one in four looked like the animation had died.
    let envelope = min(
        0.82,
        max(
            envelopeFloor,
            0.48 + 0.22 * sin(phase * 2 + 0.5) + 0.14 * sin(phase * 5 - 0.8)
        )
    )

    return (0..<barCount).map { bar in
        let x = CGFloat(bar)
        let broad = sin(x * 0.29 - phase)
        let detail = sin(x * 0.73 + phase * 2)
        let texture = 0.28 + 0.72 * abs(broad * 0.38 + detail * 0.62)
        return min(
            CGFloat(waveformPixelHeight - 2),
            max(2, 2 + texture * envelope * amplitude * CGFloat(waveformPixelHeight - 4))
        )
    }
}

func drawWaveform(
    into ctx: CGContext, frame: Int, width: Int, amplitude: CGFloat = 1, opacity: CGFloat = 1,
    sideMargin: CGFloat = waveformSideMargin,
    envelopeFloor: CGFloat = waveformEnvelopeFloor,
    levels: [CGFloat]? = nil
) {
    let canvas = CGRect(
        x: 0, y: 0, width: CGFloat(width), height: CGFloat(waveformPixelHeight)
    )
    ctx.clear(canvas)
    let barCount = waveformBars(forWidth: width, sideMargin: sideMargin)
    let heights = waveformHeights(
        frame: frame, barCount: barCount, amplitude: amplitude, envelopeFloor: envelopeFloor,
        levels: levels)
    let barWidth = waveformBarWidth
    let gap = waveformBarGap
    let usedWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * gap
    let startX = (CGFloat(width) - usedWidth) / 2

    for (index, height) in heights.enumerated() {
        let distanceFromCentre = abs(
            CGFloat(index) - CGFloat(barCount - 1) / 2
        ) / max(1, CGFloat(barCount - 1) / 2)
        let alpha = (0.52 + (1 - distanceFromCentre) * 0.42) * min(1, max(0, opacity))
        let rect = CGRect(
            x: startX + CGFloat(index) * (barWidth + gap),
            y: (CGFloat(waveformPixelHeight) - height) / 2,
            width: barWidth,
            height: height
        )
        ctx.setFillColor(CGColor(red: 0.96, green: 0.96, blue: 0.97, alpha: alpha))
        ctx.addPath(
            CGPath(
                roundedRect: rect,
                cornerWidth: barWidth / 2,
                cornerHeight: barWidth / 2,
                transform: nil
            )
        )
        ctx.fillPath()
    }
}

// Album-independent, so this is rendered once ever and then served from disk.
// Index 0 is a silent, invisible row; the last index is the running waveform at
// full strength, which is what the loop frames pick up from.
func renderWaveformEntryFrames(width: Int) throws -> [URL] {
    let root = try cacheRoot()
        .appendingPathComponent(waveformEntryCacheVersion, isDirectory: true)
        .appendingPathComponent("w\(width)", isDirectory: true)
    let fm = FileManager.default
    let urls = (0..<waveformEntryCount).map {
        root.appendingPathComponent(String(format: "entry-%02d.png", $0))
    }
    if urls.allSatisfy({ fm.fileExists(atPath: $0.path) }) {
        return urls
    }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)

    for (index, url) in urls.enumerated() {
        let t = CGFloat(index) / CGFloat(waveformEntryCount - 1)
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: waveformPixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw NSError(domain: "mediawatch.waveform", code: 3) }
        // The phase advances across the set so the row is already alive while it
        // rises, rather than a still image that starts moving once it arrives.
        drawWaveform(
            into: ctx, frame: index, width: width, amplitude: t,
            opacity: waveformEntryOpacityFloor + (1 - waveformEntryOpacityFloor) * t)
        guard let image = ctx.makeImage(), let data = pngData(from: image) else {
            throw NSError(domain: "mediawatch.waveform", code: 4)
        }
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try? fm.removeItem(at: url)
        try fm.moveItem(at: tmp, to: url)
    }
    return urls
}

func renderWaveformFrames(width: Int) throws -> [URL] {
    let root = try cacheRoot()
        .appendingPathComponent(waveformCacheVersion, isDirectory: true)
        .appendingPathComponent("w\(width)", isDirectory: true)
    let fm = FileManager.default
    let urls = (0..<waveformFrameCount).map {
        root.appendingPathComponent(String(format: "frame-%02d.png", $0))
    }
    if urls.allSatisfy({ fm.fileExists(atPath: $0.path) }) {
        return urls
    }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)

    for (index, url) in urls.enumerated() {
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: waveformPixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw NSError(domain: "mediawatch.waveform", code: 1) }
        drawWaveform(into: ctx, frame: index, width: width)
        guard let image = ctx.makeImage(), let data = pngData(from: image) else {
            throw NSError(domain: "mediawatch.waveform", code: 2)
        }
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try? fm.removeItem(at: url)
        try fm.moveItem(at: tmp, to: url)
    }
    return urls
}

// The cache path per shape. Music keeps the bare artwork hash, so every disc
// already on disk stays valid and nothing re-renders on first run after this
// change.
func discCacheKey(artworkHash: String, source: MediaSource) -> String {
    switch source {
    case .music: return artworkHash
    // Same argument as the waveform below: the dot is not a picture of the
    // thumbnail, so keying it by artwork would lay down 48 fresh frames per
    // video to draw the same dot.
    case .video: return cachePrefix + "recdot"
    // The waveform is not a picture of the cover, so keying it by artwork would
    // lay down 72 fresh frames for every episode of every show to draw the same
    // six bars. One render serves all of them.
    case .podcast: return cachePrefix + "discwave"
    // Same argument again. The version is in the key so a change to how the icons
    // are drawn cannot be hidden behind a render already on disk.
    case .youtube: return cachePrefix + "icon-v4-youtube"
    case .browser: return cachePrefix + "icon-v4-browser"
    case .call: return cachePrefix + "icon-v4-call"
    case .service(let service): return cachePrefix + "mark-v1-" + service.rawValue
    case .videoApp(let bundleID): return cachePrefix + "app-v1-" + bundleID
    case .silence: return cachePrefix + "silence-v6"
    }
}

func writeFrame(_ data: Data, to url: URL) throws {
    let fm = FileManager.default
    let tmp = url.appendingPathExtension("tmp")
    try data.write(to: tmp, options: .atomic)
    _ = try? fm.removeItem(at: url)
    try fm.moveItem(at: tmp, to: url)
}

func discContext(width: Int) -> CGContext? {
    CGContext(
        data: nil,
        width: width,
        height: slotPixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
}

// The podcast shape: the DJ waveform's own drawing at the disc's size. Reusing it
// means the six bars in the slot move on the same envelope as the wide row that
// replaces the title during a DJ segment, so the two never look like two
// different animations that happen to share a pill.
func renderDiscWaveFrames(key: String) throws -> [URL] {
    let root = try cacheRoot().appendingPathComponent(key, isDirectory: true)
    let fm = FileManager.default
    let urls = (0..<waveformFrameCount).map {
        root.appendingPathComponent(String(format: "frame-%02d.png", $0))
    }
    if urls.allSatisfy({ fm.fileExists(atPath: $0.path) }) {
        touchCache(key)
        pruneCache()
        return urls
    }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    for (index, url) in urls.enumerated() {
        guard let ctx = discContext(width: slotPixelSize) else {
            throw NSError(domain: "mediawatch.discwave", code: 1)
        }
        drawWaveform(
            into: ctx, frame: index, width: slotPixelSize, amplitude: discWaveAmplitude,
            sideMargin: discWaveSideMargin, envelopeFloor: discWaveEnvelopeFloor)
        guard let image = ctx.makeImage(), let data = pngData(from: image) else {
            throw NSError(domain: "mediawatch.discwave", code: 2)
        }
        try writeFrame(data, to: url)
    }
    touchCache(key)
    pruneCache()
    return urls
}

// MARK: - Live audio levels

// One tap for the process, held only while a waveform is actually on screen and
// the thing playing is Spotify. A menu bar decoration should not keep an audio
// tap open to draw a dot for a YouTube video.
let spectrumTap = SpectrumTap()

// Raw magnitudes jitter enough to read as noise rather than as a level, so the
// bars chase the reading instead of taking it. Attack is fast so a transient
// shows on the frame it lands; release is slow so a bar falls back over roughly a
// quarter second instead of snapping to the floor between two syllables.
//
// Time constants rather than per-frame fractions, because a fraction silently
// means something different at every rate: the old 0.55 attack was tuned at 24fps
// and became a much tighter filter the moment the live path went to 60. The
// coefficient is derived from the time that actually elapsed, so a late frame
// smooths by the right amount instead of by the amount a punctual frame would.
let levelAttackTau: TimeInterval = 0.040
let levelReleaseTau: TimeInterval = 0.220
var smoothedLevels: [CGFloat] = []
var lastLevelSample: TimeInterval?

// 1 - e^(-dt/tau) is the standard one-pole step: dt == tau closes ~63% of the
// gap. Clamped because a long stall must not overshoot past the target.
func levelCoefficient(dt: TimeInterval, tau: TimeInterval) -> CGFloat {
    guard dt > 0, tau > 0 else { return 1 }
    return CGFloat(min(1, 1 - exp(-dt / tau)))
}

// nil means "not listening", which is the caller's cue to draw the canned
// animation. All-zero means "listening, and it is silent", which is a real
// reading and must not fall back, because a DJ pausing between sentences is
// exactly the thing this feature exists to show.
func smoothedAudioLevels(bars: Int) -> [CGFloat]? {
    guard bars > 0, let raw = spectrumTap.levels(bands: bars) else {
        smoothedLevels = []
        lastLevelSample = nil
        return nil
    }
    let now = ProcessInfo.processInfo.systemUptime
    defer { lastLevelSample = now }
    guard smoothedLevels.count == bars, let previousSample = lastLevelSample else {
        smoothedLevels = raw
        return raw
    }
    let dt = now - previousSample
    let attack = levelCoefficient(dt: dt, tau: levelAttackTau)
    let release = levelCoefficient(dt: dt, tau: levelReleaseTau)
    smoothedLevels = zip(smoothedLevels, raw).map { previous, next in
        previous + (next - previous) * (next > previous ? attack : release)
    }
    return smoothedLevels
}

// The tap follows what is on screen, not what is playing. A waveform is only
// ever drawn for a podcast or a DJ segment, both of which are Spotify, so
// everything else releases it: there is no reason to hold an audio tap open to
// spin a cover or blink a dot, and holding one would mean the recording state
// is on whenever the pill is.
// Real levels for any podcast app the tap can reach, not only Spotify: Apple
// Podcasts' bars used to be the canned loop while Spotify's moved to the voice.
// The tap is per process, so it follows whichever app is playing.
func wantsAudioLevels(_ state: NowPlaying) -> Bool {
    guard state.playing else { return false }
    if state.displayMode == .spotifyDJ { return state.bundleID == spotifyBundleID }
    return state.source == .podcast
        && (state.bundleID == spotifyBundleID || isPodcastApp(state.bundleID))
}

// Two strikes, then stop asking for the session. A refused or unpromptable grant
// does not fail fast: it costs the start timeout every time, and retrying that
// on every track change would be a new orphaned tap each go.
let maxTapStartFailures = 2
var tapStartFailures = 0

// The tap's lifecycle never touches applyQueue. Nothing here is allowed to hold
// up a draw, because AudioDeviceStart demonstrably blocks for as long as it
// likes and applyQueue is what puts frames on screen.
let tapQueue = DispatchQueue(label: "mediawatch.tap.lifecycle")
var tapStartInFlight = false

func syncSpectrumTap(_ state: NowPlaying) {
    guard wantsAudioLevels(state) else {
        if spectrumTap.isRunning {
            tapQueue.async { spectrumTap.stop() }
        }
        smoothedLevels = []
        return
    }
    guard let pid = NSRunningApplication
        .runningApplications(withBundleIdentifier: state.bundleID)
        .first?.processIdentifier
    else { return }
    // Tapping another app than the one now playing: let it go, and tap this one.
    if spectrumTap.isRunning, spectrumTap.tappedPID != pid, !tapStartInFlight {
        tapQueue.async { spectrumTap.stop() }
        smoothedLevels = []
        return
    }
    guard !spectrumTap.isRunning, !tapStartInFlight,
          tapStartFailures < maxTapStartFailures
    else { return }
    tapStartInFlight = true
    tapQueue.async {
        let ok = spectrumTap.start(pid: pid)
        applyQueue.async {
            tapStartInFlight = false
            guard !ok else {
                tapStartFailures = 0
                return
            }
            tapStartFailures += 1
            if tapStartFailures >= maxTapStartFailures {
                logErr(
                    "audio tap would not start, staying on the drawn waveform. "
                        + "System Audio Recording has to be granted to the watcher "
                        + "before live levels can work.")
            }
        }
    }
}

// Live frames cannot be cached by content, so they are written to a ring of
// names and overwritten forever. Rotating the name is insurance: SketchyBar may
// or may not cache an image by path, and eight names cost nothing while making
// the answer irrelevant. The directory carries no `g32-` prefix on purpose, so
// neither cache pruner sweeps it.
let liveRingSize = 8
var liveRingIndex = 0

func liveWaveURL(
    width: Int, levels: [CGFloat], amplitude: CGFloat, opacity: CGFloat,
    sideMargin: CGFloat, envelopeFloor: CGFloat
) -> URL? {
    guard let root = try? cacheRoot().appendingPathComponent("live", isDirectory: true)
    else { return nil }
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    liveRingIndex = (liveRingIndex + 1) % liveRingSize
    let url = root.appendingPathComponent(
        String(format: "w%d-%d.png", width, liveRingIndex))
    guard let ctx = CGContext(
        data: nil, width: width, height: waveformPixelHeight, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    drawWaveform(
        into: ctx, frame: 0, width: width, amplitude: amplitude, opacity: opacity,
        sideMargin: sideMargin, envelopeFloor: envelopeFloor, levels: levels)
    guard let image = ctx.makeImage(), let data = pngData(from: image) else { return nil }
    try? writeFrame(data, to: url)
    return url
}

// The dot's own colour, taken off the same env var the title uses so the pill
// stays one palette. Parsed here because everywhere else colour is a string
// handed to SketchyBar; this is the one place that has to draw with it.
func drawColor(_ hex: String, alpha: CGFloat) -> CGColor {
    guard hex.hasPrefix("0x"), hex.count == 10,
        let value = UInt32(hex.dropFirst(2), radix: 16)
    else { return CGColor(red: 1, green: 1, blue: 1, alpha: alpha) }
    return CGColor(
        red: CGFloat((value >> 16) & 0xff) / 255,
        green: CGFloat((value >> 8) & 0xff) / 255,
        blue: CGFloat(value & 0xff) / 255,
        alpha: alpha)
}

// One 2s cycle. cos starts the loop at full brightness, so frame 0 is the dot at
// its brightest and a freshly drawn pill never fades up from nothing.
//
// The 0.65 exponent is the difference between a blink and a strobe: a bare
// cosine spends as long dim as it does bright, which at this size reads as the
// icon flickering. Pulling the curve up makes it sit near full brightness and
// dip briefly, which is what a recording light actually does.
func dotAlpha(frame: Int, count: Int) -> CGFloat {
    guard count > 1 else { return 1 }
    let phase = CGFloat(frame % count) / CGFloat(count) * 2 * .pi
    let wave = (cos(phase) + 1) / 2
    return dotAlphaFloor + (1 - dotAlphaFloor) * pow(wave, 0.65)
}

// A radial gradient, not fillEllipse, and for the reason this file learned the
// hard way on the spindle hole: a filled circle this small has no room to
// describe its own curve and comes out with visible stair-steps. A gradient is
// evaluated per pixel, so the rim antialiases itself. Solid to 0.78 of the
// radius, then out to nothing, which is about a pixel of edge.
func drawRecordDot(into ctx: CGContext, frame: Int) {
    let size = CGFloat(dotPixelSize)
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
    let alpha = dotAlpha(frame: frame, count: dotFrameCount)
    let centre = CGPoint(x: size / 2, y: size / 2)
    guard let ink = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            drawColor(playingColor, alpha: alpha),
            drawColor(playingColor, alpha: alpha),
            drawColor(playingColor, alpha: 0),
        ] as CFArray,
        locations: [0, 0.78, 1]
    ) else { return }
    ctx.drawRadialGradient(
        ink, startCenter: centre, startRadius: 0, endCenter: centre,
        endRadius: dotDiameter / 2, options: [])
}

// The video shape. Keyed by nothing but itself, like the waveform: the dot does
// not depend on what is playing, so one render serves every video there will
// ever be.
func renderRecordDotFrames(key: String) throws -> [URL] {
    let root = try cacheRoot().appendingPathComponent(key, isDirectory: true)
    let fm = FileManager.default
    let urls = (0..<dotFrameCount).map {
        root.appendingPathComponent(String(format: "frame-%02d.png", $0))
    }
    if urls.allSatisfy({ fm.fileExists(atPath: $0.path) }) {
        touchCache(key)
        pruneCache()
        return urls
    }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    for (index, url) in urls.enumerated() {
        guard let ctx = discContext(width: dotPixelSize) else {
            throw NSError(domain: "mediawatch.recdot", code: 1)
        }
        drawRecordDot(into: ctx, frame: index)
        guard let image = ctx.makeImage(), let data = pngData(from: image) else {
            throw NSError(domain: "mediawatch.recdot", code: 2)
        }
        try writeFrame(data, to: url)
    }
    touchCache(key)
    pruneCache()
    return urls
}

// The icon shapes: an SF Symbol drawn once into the slot, one frame, no motion.
//
// SF Symbols rather than Nerd Font glyphs because these sit next to album art
// and have to hold up at that size: the Nerd Font set is drawn for 13pt text,
// and at 24px its brand marks turn into blobs. SF Symbols are the system's own
// icon language, so they also read as belonging to the Mac rather than to a
// theme.
//
// A still frame on purpose. The cover spins because a record spins and the
// waveform moves because it is the audio; a globe has no reason to do either,
// and an animation with no meaning is just the bar asking to be looked at.
//
// Tinted, which is the one place on this bar outside the album art that carries
// colour, and for the same reason: the slot is where "what is this" gets
// answered, and YouTube red and Teams purple answer it before the text does.
// Colours are the symbol's palette, first layer first. A single colour paints
// every layer the same, which is fine for the globe and the pair of heads and
// wrong for the play button: its triangle is a layer of its own, and one colour
// drew the whole thing as a flat red block. White on red is also simply what the
// YouTube mark looks like.
struct SlotIcon {
    let symbol: String
    let palette: [CGColor]
    // How it moves while playing. A breath is the same slow swell the video dot
    // has, scaled down so it reads as alive rather than as flashing. A wave lights
    // the symbol's own sound bars in turn, for the one icon that has any.
    let motion: SlotIconMotion
}

enum SlotIconMotion {
    case breathe
    case wave
}

func slotIcon(for source: MediaSource) -> SlotIcon? {
    switch source {
    case .youtube:
        return SlotIcon(symbol: "play.rectangle.fill", palette: [
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
            CGColor(srgbRed: 1.0, green: 0.0, blue: 0.2, alpha: 1),
        ], motion: .breathe)
    case .browser:
        return SlotIcon(symbol: "globe", palette: [
            CGColor(srgbRed: 0.82, green: 0.82, blue: 0.84, alpha: 1),
        ], motion: .breathe)
    case .call:
        // The variant with sound waves beside the heads, because it animates: SF
        // Symbols' variable value lights the wave layers in turn, which is a call
        // being a call rather than a picture of two people.
        return SlotIcon(symbol: "person.2.wave.2.fill", palette: [
            CGColor(srgbRed: 0.48, green: 0.51, blue: 0.92, alpha: 1),
        ], motion: .wave)
    case .service(let service):
        return symbolMark(for: service)
    case .music, .podcast, .video, .videoApp, .silence:
        return nil
    }
}

// Points, inside a 24pt slot. Large enough to be the first thing read in the
// pill, small enough to leave the same margin the cover keeps from the edge.
let slotIconPointSize: CGFloat = 15

// Icons are drawn at twice the slot's pixel size and shown at half scale. The
// cover and the waveform stay at 1:1, see discPixelScale for why; an icon is
// line art with hairline edges, and at 1x on the retina panel it was upscaled
// into something closer to a smudge than a symbol. On a 1x external the half
// scale is a plain downsample, which costs line art nothing.
let slotIconPixelScale = 2

// Frames per loop and the swell's range. 48 frames is the same two-second loop
// the video dot uses, so every animated shape in the slot keeps one tempo. The
// breath never drops below 72% alpha or 94% size: enough to be alive, never
// enough to read as the icon failing to load.
let slotIconFrameCount = 48
let slotIconAlphaFloor: CGFloat = 0.72
let slotIconScaleFloor: CGFloat = 0.94
// Where a paused icon rests: the quietest point of the breath, the same place
// the video dot parks.
let slotIconRestFrame = slotIconFrameCount / 2

// One frame of an icon's loop. `phase` runs 0..1 over the loop. The breath is a
// cosine with an eased top so the icon lingers full and passes quickly through
// its quiet point, the same shape as the dot's pulse; the wave sweeps the symbol's
// variable value from nothing to every bar lit.
func drawSlotIcon(_ icon: SlotIcon, into ctx: CGContext, size: Int, phase: CGFloat) {
    let canvas = CGFloat(size)
    ctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
    let scale = CGFloat(slotIconPixelScale)
    let swell = pow((cos(phase * 2 * .pi) + 1) / 2, 0.65)

    let alpha: CGFloat
    let grow: CGFloat
    let variable: Double?
    switch icon.motion {
    case .breathe:
        alpha = slotIconAlphaFloor + (1 - slotIconAlphaFloor) * swell
        grow = slotIconScaleFloor + (1 - slotIconScaleFloor) * swell
        variable = nil
    case .wave:
        // Steady heads, moving waves: a call icon that throbs as a whole reads as
        // an alert, and the waves alone say "someone is talking". Two sweeps per
        // loop, because the symbol has only two wave layers and one sweep over
        // two seconds held each step for most of a second, which reads as a slow
        // blink rather than as speech.
        alpha = 1
        grow = 1
        variable = Double((phase * 2).truncatingRemainder(dividingBy: 1))
    }

    let palette = NSImage.SymbolConfiguration(
        paletteColors: icon.palette.map { NSColor(cgColor: $0) ?? .white })
    let base = variable.map {
        NSImage(systemSymbolName: icon.symbol, variableValue: $0, accessibilityDescription: nil)
    } ?? NSImage(systemSymbolName: icon.symbol, accessibilityDescription: nil)
    func configured(_ points: CGFloat) -> NSImage? {
        base?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: points, weight: .semibold).applying(palette))
    }
    // Sized by point size, then fitted to the slot by its widest side. Symbols
    // are not square: the call icon with its sound waves is half as wide again as
    // it is tall, and at the shared point size its outer wave ran off the canvas.
    // Fitting against a fixed margin rather than shrinking every icon keeps the
    // square ones exactly as large as they were.
    let target = slotIconPointSize * scale * grow
    guard let probe = configured(target) else { return }
    let room = canvas * 0.9
    let fit = min(1, room / max(probe.size.width, probe.size.height))
    guard let symbol = fit < 1 ? configured(target * fit) : probe else { return }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let drawn = symbol.size
    // Not rounded to whole pixels. At 2x a half-pixel offset is invisible, and
    // snapping a symbol that grows by fractions of a point every frame is what
    // makes a smooth swell step.
    symbol.draw(
        in: NSRect(x: (canvas - drawn.width) / 2, y: (canvas - drawn.height) / 2,
                   width: drawn.width, height: drawn.height),
        from: .zero, operation: .sourceOver, fraction: alpha)
    NSGraphicsContext.restoreGraphicsState()
}

func renderIconFrames(_ icon: SlotIcon, key: String) throws -> [URL] {
    let root = try cacheRoot().appendingPathComponent(key, isDirectory: true)
    let fm = FileManager.default
    let urls = (0..<slotIconFrameCount).map {
        root.appendingPathComponent(String(format: "frame-%02d.png", $0))
    }
    if urls.allSatisfy({ fm.fileExists(atPath: $0.path) }) {
        touchCache(key)
        pruneCache()
        return urls
    }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let side = slotPixelSize * slotIconPixelScale
    for (index, url) in urls.enumerated() {
        guard let ctx = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw NSError(domain: "mediawatch.icon", code: 1) }
        drawSlotIcon(icon, into: ctx, size: side,
                     phase: CGFloat(index) / CGFloat(slotIconFrameCount))
        guard let image = ctx.makeImage(), let data = pngData(from: image) else {
            throw NSError(domain: "mediawatch.icon", code: 2)
        }
        try writeFrame(data, to: url)
    }
    touchCache(key)
    pruneCache()
    return urls
}

func renderDiscFrames(image: CGImage?, key: String, source: MediaSource) throws -> [URL] {
    if let icon = slotIcon(for: source) { return try renderIconFrames(icon, key: key) }
    switch source {
    case .silence: return try renderMarkFrames(key: key) { drawSilenceMark(into: $0, size: $1, phase: $2) }
    case .music: return try renderFrames(image: image, key: key)
    case .podcast: return try renderDiscWaveFrames(key: key)
    case .service(let service):
        if let mark = glyphMark(for: service) {
            return try renderMarkFrames(key: key) { drawGlyphMark(mark, into: $0, size: $1, phase: $2) }
        }
        if let app = standInApp(for: service),
           let icon = appIconImage(bundleID: app, pixels: slotPixelSize * slotIconPixelScale) {
            return try renderMarkFrames(key: key) { drawAppIcon(icon, into: $0, size: $1, phase: $2) }
        }
        return try renderRecordDotFrames(key: key)
    case .videoApp(let bundleID):
        if let icon = appIconImage(bundleID: bundleID, pixels: slotPixelSize * slotIconPixelScale) {
            return try renderMarkFrames(key: key) { drawAppIcon(icon, into: $0, size: $1, phase: $2) }
        }
        return try renderRecordDotFrames(key: key)
    case .video, .youtube, .browser, .call: return try renderRecordDotFrames(key: key)
    }
}

// Nothing playing: a music note, the system's own `music.note` glyph in
// semibold, filled top to bottom with the pink-to-red of Apple Music. It is the
// one splash of colour the pill keeps when nothing is playing, and it says what
// the pill is for. It does not move. The only motion is a slow glow over eight
// seconds, the way a sleeping machine's light breathes.
//
// Its predecessors, all on 2026-09-29: a row of bars with a breath running
// through them (it read as sound, the one thing silence is not), five grey
// dots, and a drawn pause button (called ugly, fairly).
// Eight seconds a breath over the same 48 frames every mark has: 6 frames a
// second, so the silence costs the bar a quarter of the redraws a breathing
// service mark does, and each step moves the glow by under 1%.
let silenceInterval: TimeInterval = 8.0 / TimeInterval(slotIconFrameCount)
let silenceNoteTop = CGColor(srgbRed: 0xff / 255, green: 0x8f / 255, blue: 0xa3 / 255, alpha: 1)
let silenceNoteBottom = CGColor(srgbRed: 0xfa / 255, green: 0x3c / 255, blue: 0x5c / 255, alpha: 1)
func drawSilenceMark(into ctx: CGContext, size: Int, phase: CGFloat) {
    let canvas = CGFloat(size)
    ctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
    let glow = (1 - cos(phase * 2 * .pi)) / 2
    let config = NSImage.SymbolConfiguration(pointSize: canvas * 0.62, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    guard let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else { return }
    // Fitted to 76% of the slot by its taller side: the size of the other slot
    // icons, a little under the cover.
    let fit = min(1, canvas * 0.76 / max(note.size.width, note.size.height))
    let drawn = CGSize(width: note.size.width * fit, height: note.size.height * fit)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    note.draw(in: NSRect(x: (canvas - drawn.width) / 2, y: (canvas - drawn.height) / 2,
                         width: drawn.width, height: drawn.height),
              from: .zero, operation: .sourceOver, fraction: 0.88 + 0.12 * glow)
    NSGraphicsContext.restoreGraphicsState()
    // The gradient only where the glyph is, keeping its alpha and its edges.
    ctx.saveGState()
    ctx.setBlendMode(.sourceIn)
    if let fill = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: [silenceNoteTop, silenceNoteBottom] as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(fill, start: CGPoint(x: 0, y: (canvas + drawn.height) / 2),
                               end: CGPoint(x: 0, y: (canvas - drawn.height) / 2), options: [])
    }
    ctx.restoreGState()
}

// A paused animation has to rest somewhere defined. Stopping the timer wherever
// it happened to be is fine for the cover and the waveform, because any angle of
// a disc is still a disc, but it leaves the dot on a coin flip between bright
// and dim, and a bright dot on a paused pill reads as still playing.
func parkDiscFrame(for source: MediaSource) {
    guard framePaths.count > 1 else { return }
    // The frames on screen have to be the source's own. A paused track's
    // heartbeat landing while the silence is up is the case this guards: its
    // `.music` would drain the silence's note as if it were a cover.
    guard (lastApplied?.source == .silence) == (source == .silence) else { return }
    if source == .video {
        frameIndex = dotRestFrame
    } else if slotIcon(for: source) != nil || drawnAsMark(source) {
        frameIndex = slotIconRestFrame
    } else if source == .music {
        drainCover()
        return
    } else {
        return
    }
    setFrameImage()
}

// Paused, the cover's colour drains out once the record has run down: the
// frame it stopped on goes to greyscale over a third of a second, a little
// darker at the end, so a paused pill reads as paused from across the room.
// Playing again brings the colour straight back with the spin. `background.image`
// has no alpha or saturation of its own, so the drain is a handful of frames,
// rendered from the stopped frame on first use and kept beside it.
let drainLevels = 8
let drainDuration: TimeInterval = 0.35
var drainTimer: DispatchSourceTimer?

func cancelDrain() {
    drainTimer?.cancel()
    drainTimer = nil
}

func drainFrames(for frame: URL) -> [URL] {
    let dir = frame.deletingLastPathComponent()
    let stem = frame.deletingPathExtension().lastPathComponent
    let urls = (1...drainLevels).map { dir.appendingPathComponent("\(stem)-drain-\($0).png") }
    if urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) { return urls }
    guard let src = CGImageSourceCreateWithURL(frame as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return [] }
    let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    for (i, url) in urls.enumerated() {
        let k = CGFloat(i + 1) / CGFloat(drainLevels)
        guard let ctx = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [] }
        ctx.draw(image, in: rect)
        ctx.addEllipse(in: rect)
        ctx.clip()
        ctx.setBlendMode(.saturation)
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: k))
        ctx.fill(rect)
        ctx.setBlendMode(.multiply)
        ctx.setFillColor(CGColor(red: 0.78, green: 0.78, blue: 0.8, alpha: k))
        ctx.fill(rect)
        guard let out = ctx.makeImage(), let data = pngData(from: out),
              (try? writeFrame(data, to: url)) != nil else { return [] }
    }
    return urls
}

func drainCover() {
    cancelDrain()
    guard let frame = framePaths[safe: frameIndex] else { return }
    let levels = drainFrames(for: frame)
    guard !levels.isEmpty else { return }
    let started = DispatchTime.now().uptimeNanoseconds
    var shown = -1
    let timer = DispatchSource.makeTimerSource(queue: applyQueue)
    timer.schedule(deadline: .now(), repeating: transitionStepInterval)
    timer.setEventHandler {
        guard drainTimer === timer else { return }
        let elapsed = TimeInterval(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        let raw = min(1, CGFloat(elapsed / drainDuration))
        let index = min(levels.count - 1, Int(easeInOutCubic(raw) * CGFloat(levels.count - 1) + 0.5))
        if index != shown {
            shown = index
            runSketchybar(["--set", "media_disc", "background.image=\(levels[index].path)"])
        }
        if raw >= 1 { cancelDrain() }
    }
    drainTimer = timer
    timer.resume()
}

func renderFrames(image: CGImage?, key: String) throws -> [URL] {
    let root = try cacheRoot().appendingPathComponent(key, isDirectory: true)
    let fm = FileManager.default
    if fm.fileExists(atPath: root.path) {
        let existing = (0..<frameCount).map {
            root.appendingPathComponent(String(format: "frame-%02d.png", $0))
        }
        if existing.allSatisfy({ fm.fileExists(atPath: $0.path) }) {
            touchCache(key)
            pruneCache()
            return existing
        }
    }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)

    let source = image.flatMap(squareSource) ?? image
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    // Every frame on its own core. This runs on applyQueue in the middle of a
    // track change, and at 150 frames a serial render held the queue, and with
    // it the change's own animation, for 287ms; the frames share nothing but
    // the read-only source, so they parallelise cleanly.
    let urls = (0..<frameCount).map {
        root.appendingPathComponent(String(format: "frame-%02d.png", $0))
    }
    var failed = false
    let failure = NSLock()
    DispatchQueue.concurrentPerform(iterations: frameCount) { i in
        let angle = CGFloat(i) / CGFloat(frameCount) * 2 * .pi
        guard let ctx = CGContext(
            data: nil,
            width: discPixelSize,
            height: discPixelSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { failure.lock(); failed = true; failure.unlock(); return }
        drawDisc(into: ctx, image: source, angle: angle)
        guard let cg = ctx.makeImage(), let data = pngData(from: cg) else {
            failure.lock(); failed = true; failure.unlock(); return
        }
        let url = urls[i]
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try? fm.removeItem(at: url)
            try fm.moveItem(at: tmp, to: url)
        } catch {
            failure.lock(); failed = true; failure.unlock()
        }
    }
    if failed { throw NSError(domain: "mediawatch", code: 2) }
    touchCache(key)
    pruneCache()
    return urls
}

func touchCache(_ key: String) {
    cacheOrder.removeAll { $0 == key }
    cacheOrder.append(key)
}

// Same job as pruneCache, for the per-width waveform directories. Ordered by
// modification date rather than kept in a list, because the width set is small
// and the directories are the only record of what has been rendered.
func pruneWaveformWidths() {
    let fm = FileManager.default
    guard let root = try? cacheRoot() else { return }
    for version in [waveformCacheVersion, waveformEntryCacheVersion] {
        let dir = root.appendingPathComponent(version, isDirectory: true)
        guard let widths = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { continue }
        let byAge = widths.filter { $0.lastPathComponent.hasPrefix("w") }
            .sorted {
                let l = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let r = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return l < r
            }
        guard byAge.count > maxCachedWaveWidths else { continue }
        for old in byAge.prefix(byAge.count - maxCachedWaveWidths) {
            try? fm.removeItem(at: old)
        }
    }
}

// Frame layouts have changed twice, and each change moved the cache version
// rather than migrating, which leaves the previous version's directory behind
// holding files nothing will ever read again.
func pruneStaleWaveformVersions() {
    let fm = FileManager.default
    guard let root = try? cacheRoot(),
        let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    else { return }
    let keep = Set([waveformCacheVersion, waveformEntryCacheVersion])
    for entry in entries {
        let name = entry.lastPathComponent
        guard name.hasPrefix("waveform-"), !keep.contains(name) else { continue }
        try? fm.removeItem(at: entry)
    }
}

func pruneCache() {
    guard cacheOrder.count > maxCachedAlbums else { return }
    let fm = FileManager.default
    guard let root = try? cacheRoot() else { return }
    while cacheOrder.count > maxCachedAlbums {
        let old = cacheOrder.removeFirst()
        try? fm.removeItem(at: root.appendingPathComponent(old, isDirectory: true))
    }
}

// Arguments go to SketchyBar as a NUL-separated block, never as one string that
// something downstream has to split again. There used to be a `quoteCli` here
// that wrapped any value containing a space in double quotes, and a matching
// splitter in sketchybar_ipc.c; a track title with an apostrophe could break out
// of that and set properties on other items. See sketchybar_ipc.c for the full
// account. Building the block here means a label is bytes, not syntax.
func encodeArgs(_ args: [String]) -> [UInt8] {
    var buffer: [UInt8] = []
    for arg in args {
        buffer.append(contentsOf: arg.utf8)
        buffer.append(0)
    }
    return buffer
}

// No `--animate` anywhere, and that is a finding rather than a preference.
//
// On SketchyBar 2.24.0 here, `--animate <curve> <frames> --set <item> <prop>=<v>`
// leaves the property at its old value. Measured 2026-09-07 against icon.color,
// label.color, icon.y_offset and background.color, on four different items, with
// every curve, at 10 and 120 frames, item drawing and hidden. Sampling mid-flight
// during a 2s animation showed no intermediate values either, so the animator
// never runs rather than finishing on the wrong value.
//
// It went unnoticed for so long because the failure is partial: non-animatable
// properties in the same message still land, so `drawing`, the `icon` text and
// `background.image` all worked and an animated `--set` looked fine. Only the
// colours were being dropped, which is why a paused track never actually dimmed
// despite MEDIA_PAUSED_COLOR being correct and sent.
//
// So every send is a plain `--set`. If a later SketchyBar fixes the animator,
// the wrapper to restore is a `--animate <curve> <frames>` prefix on this
// message, and the call site that wanted it most is applyVisible.
@discardableResult
func runSketchybar(_ args: [String]) -> Bool {
    let buffer = encodeArgs(args)
    guard !buffer.isEmpty else { return false }
    return ipcQueue.sync {
        buffer.withUnsafeBufferPointer { raw in
            guard let base = raw.baseAddress else { return false }
            return base.withMemoryRebound(to: CChar.self, capacity: raw.count) { p in
                sketchybar_send_args(p, UInt32(raw.count)) == 0
            }
        }
    }
}

// Every item this watcher ever draws. Hiding is derived from the list rather
// than written out separately, so adding an item cannot leave it stranded on
// screen after the rest of the pill goes away: adding `media_sep` here in 2026-09
// was a one-line change for exactly that reason.
let trackItems = ["media_disc", "media", "media_sep", "media_artist"]
let mediaItems = ["media_wave"] + trackItems
// A DJ segment is the waveform alone. The cover was kept on screen for a while
// on the theory that an empty pill mid-handoff was the thing that read as the
// player being wiped out; it was not. The wipe was `hidePlayer` tearing the pill
// down during the gap between the song ending and the DJ starting, which is
// fixed above, and a disc parked next to the waveform just looked wrong.
let djHiddenItems = trackItems
let hideAll = mediaItems.flatMap { ["--set", $0, "drawing=off"] }

// The instant teardown. Error paths and a cold empty payload use this directly,
// because there is either nothing on screen to fade or nothing left to trust.
// The paths that are a normal end to playback go through `fadePlayerOut` first.
func hidePlayer() {
    cancelDrain()
    runSketchybar(hideAll)
    playerDrawn = false
    playerPresence = 1
    runSketchybar(pillChromeArgs(1))
    cancelGapHide()
    cancelPauseHide()
    stopSpin()
    stopWaveform()
    // Nothing on screen means nothing to visualise, so the tap goes with it.
    // Leaving it running would keep the machine in a recording state to draw a
    // pill that is not there.
    spectrumTap.stop()
    smoothedLevels = []
    // A tween outliving the thing it was fading would draw it back on.
    cancelTransition()
    lastApplied = nil
    framePaths = []
    renderedArtworkKey = nil
    lastDiscScale = nil
}

// A track ending emits a payload with no title and no artist before the next one
// loads, and Spotify's DJ takes a moment to announce itself. Tearing the pill
// down for that gap is what made the DJ arrive on an empty bar rather than out
// of the song: `hidePlayer` also clears `lastApplied`, so by the time the DJ
// payload landed there was no "from" state left and `enterDJ` skipped the fade
// entirely and just planted the waveform. Long enough to cover the gap, short
// enough that a player actually quitting still clears the pill promptly.
let emptyPayloadGrace: TimeInterval = 2.0
var gapTimer: DispatchSourceTimer?

// How long a pause may last before the pill turns to silence. It took itself
// away here until 2026-09-29; now it swaps to silenceState. A pause is also how
// you answer the door, and a pill that changes the instant the music stops and
// changes back ten seconds later is a flicker, not a feature. 30s is long enough
// that a short pause never blinks it, short enough that the bar says so by the
// time you have moved on.
//
// Overridable from colors.sh through the environment, so it can be tuned
// without a rebuild, and so a live test does not have to sit through the real
// thing.
let pauseHideAfter = TimeInterval(env["MEDIA_PAUSE_HIDE_AFTER"] ?? "") ?? 30
var pauseTimer: DispatchSourceTimer?
// Set once a pause has turned the pill to silence, cleared by the next playing state.
// Without it the pill came straight back: `hidePlayer` clears `lastApplied`, so
// the very next paused heartbeat looks like a brand-new state and redraws the
// pill it was supposed to be leaving alone. Paused payloads arrive every few
// seconds for as long as a track stays loaded, so this is not an edge case, it
// is the whole of the time the pill is meant to be gone.
var hiddenForPause = false

// `MEDIAWATCH_DEBUG=1` traces the pause-hide decisions to /tmp, because the
// watcher's stderr goes nowhere once the rc has backgrounded it.
let debugPauseHide = !(env["MEDIAWATCH_DEBUG"] ?? "").isEmpty
func tracePause(_ message: String) {
    guard debugPauseHide else { return }
    let line = "\(Date()) \(message)\n"
    if let handle = FileHandle(forWritingAtPath: "/tmp/mediawatch-debug.log") {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: "/tmp/mediawatch-debug.log", contents: Data(line.utf8))
    }
}

func cancelPauseHide() {
    pauseTimer?.cancel()
    pauseTimer = nil
}

func armPauseHide() {
    guard pauseTimer == nil else { return }
    tracePause("arm pause-hide in \(pauseHideAfter)s")
    let timer = DispatchSource.makeTimerSource(queue: applyQueue)
    timer.schedule(deadline: .now() + pauseHideAfter)
    timer.setEventHandler {
        guard pauseTimer === timer else { return }
        pauseTimer = nil
        // Still paused is the whole condition. Anything that started playing in
        // the meantime has already cancelled this timer on its way through.
        tracePause("pause-hide fired, lastApplied.playing=\(String(describing: lastApplied?.playing))")
        guard let state = lastApplied, !state.playing else { return }
        tracePause("pause-hide: to silence")
        hiddenForPause = true
        enterSilence()
    }
    timer.resume()
    pauseTimer = timer
}

// What the pill shows when nothing is playing, instead of taking itself away:
// the word and a mark of its own, drawn and animated like any other source. It
// is a track as far as the rest of this file is concerned, which is the point:
// music starting swaps it out the way one song swaps out another, the word
// lifting away and the cover springing in, and music stopping swaps it back.
// "Playing", so that its mark breathes; titleShade gives it its own grey.
let silenceState = NowPlaying(
    title: silenceLabel, artist: "", playing: true, artworkKey: discCacheKey(artworkHash: "", source: .silence),
    displayMode: .track, source: .silence, bundleID: "")

/// The normal end of playback: the player went away, or a pause outlasted
/// pauseHideAfter. Errors still use hidePlayer, because what failed may be the
/// drawing itself.
func enterSilence() {
    cancelGapHide()
    guard lastApplied != silenceState || !playerDrawn else { return }
    syncTransportGlyph(playing: false)
    showTrack(silenceState)
}

// How present the whole pill is: 1 fully there, 0 gone. Tracked rather than
// recomputed because an interrupted fade has to carry on from where it actually
// is. Playback starting halfway through the stop fade-out is the case that
// otherwise shows a step, and it is not rare: a pause at the end of a queue
// then a keypress is the normal way this pill comes back.
var playerPresence: CGFloat = 1
// Whether any of the pill's items are drawn at all, which is a different
// question from how visible they are: an interrupted fade leaves them drawn but
// faint. This is what decides whether the capsule has to arrive or is already
// there.
var playerDrawn = false

func cancelGapHide() {
    gapTimer?.cancel()
    gapTimer = nil
}

func armGapHide() {
    cancelGapHide()
    let timer = DispatchSource.makeTimerSource(queue: applyQueue)
    timer.schedule(deadline: .now() + emptyPayloadGrace)
    timer.setEventHandler {
        guard gapTimer === timer else { return }
        gapTimer = nil
        enterSilence()
    }
    timer.resume()
    gapTimer = timer
}

// Stops the timer only. runTween uses this to make way for the tween a
// completion is about to start, which must not forget where it is going.
func stopTween() {
    transitionTimer?.cancel()
    transitionTimer = nil
    playbackToggling = false
}

// Set while the running tween is a play/pause toggle, which a second toggle may
// take over. Any other tween owns the pill until it finishes.
var playbackToggling = false

// Abandons the transition outright. Anything that hides the pill uses this, so a
// fade cannot resume against a pill that is no longer there and a half-finished
// exit cannot leave pendingTrack set, which would make the next DJ segment think
// a fade it never started is already running.
func cancelTransition() {
    stopTween()
    pendingTrack = nil
}

// Fixed precision keeps a tween from emitting 0.6499999999999999 and keeps
// consecutive steps comparable when deciding whether a value actually moved.
func scaleArg(_ value: CGFloat) -> String {
    String(format: "%.3f", Double(value))
}

// Cubic ease-in-out, and the curve is the whole reason the first attempt still
// read as a jump. It was `easeOutExpo`, 1 - 2^(-10t), which is 0.50 at t=0.1 and
// 0.88 at t=0.3: three quarters of the movement landed in the first 36ms of a
// 180ms window and the rest was imperceptible settling, so the effective
// transition was two or three frames. Ease-out belongs on something arriving
// from rest. A handoff has two ends that both matter, so the movement has to be
// spread across the window and leave gently at both.
func easeInOutCubic(_ t: CGFloat) -> CGFloat {
    let c = min(1, max(0, t))
    return c < 0.5 ? 4 * c * c * c : 1 - pow(-2 * c + 2, 3) / 2
}

// A handoff has two halves that meet in the middle, and ease-in-out on both put
// their slow ends against each other: measured 100ms in which the text was
// already fully transparent and the wave had not yet risen far enough to read,
// which is the "and then the wave shows up afterwards" part of the complaint.
// The half that leaves eases *in* and the half that arrives eases *out*, so the
// gentle ends sit at the outside of the whole movement and the join is tight.
// Cubic on purpose rather than something sharper: `easeOutExpo` is what read as
// a pop the first time round.
enum TweenCurve {
    case leaving
    case arriving
    // Raw progress, for a step that shapes its several properties itself.
    case linear

    func apply(_ t: CGFloat) -> CGFloat {
        let c = min(1, max(0, t))
        switch self {
        case .leaving: return c * c * c
        case .arriving: return 1 - pow(1 - c, 3)
        case .linear: return c
        }
    }
}

// A damped spring from 0 to 1, about 6% past the target before it settles, and
// settled by the end: the shape of a system spring rather than of a curve. Used
// for the new cover landing, which is the one thing in a track change that
// should feel like it arrived rather than faded in.
func springProgress(_ t: CGFloat) -> CGFloat {
    let c = min(1, max(0, t))
    return c >= 1 ? 1 : 1 - exp(-6.5 * c) * cos(2.4 * .pi * c)
}

// Progress is derived from the clock rather than counted in ticks, so a step the
// queue was too busy to run shortens the tween instead of stretching it.
//
// Uptime, not `Date`. A backward wall-clock correction landing inside the 180ms
// window would make elapsed negative, and the easing clamps its input, so the
// tween would sit pinned at its start value and never reach terminating
// progress. Uptime cannot go backwards.
func runTween(curve: TweenCurve,
              duration: TimeInterval = transitionDuration,
              step: @escaping (CGFloat, TimeInterval) -> Void,
              completion: @escaping () -> Void) {
    stopTween()
    let started = DispatchTime.now().uptimeNanoseconds
    let timer = DispatchSource.makeTimerSource(queue: applyQueue)
    timer.schedule(deadline: .now(), repeating: transitionStepInterval)
    timer.setEventHandler {
        guard transitionTimer === timer else { return }
        let elapsed =
            TimeInterval(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        let raw = min(1, CGFloat(elapsed / duration))
        step(curve.apply(raw), elapsed)
        if raw >= 1 {
            stopTween()
            completion()
        }
    }
    transitionTimer = timer
    timer.resume()
}

// Colours arrive as 0xAARRGGBB strings from colors.sh. Fading means scaling the
// alpha byte and leaving the rest alone, so a dimmed paused colour stays that
// colour on the way out instead of drifting through the playing one.
func fadedColor(_ hex: String, _ amount: CGFloat) -> String {
    guard hex.hasPrefix("0x"), hex.count == 10,
        let value = UInt32(hex.dropFirst(2), radix: 16)
    else { return hex }
    let alpha = CGFloat((value >> 24) & 0xff) * min(1, max(0, amount))
    return String(format: "0x%02x%06x", UInt32(alpha.rounded()), value & 0x00ff_ffff)
}

func restingDiscScale(_ state: NowPlaying) -> CGFloat {
    // MEDIA_DISC_SCALE is the cover's: 0.5 for its 2x frames. The other shapes
    // are drawn on 24px canvases, so they show at that times discPixelScale, and
    // icons at that over their own slotIconPixelScale.
    let base = CGFloat(Double(state.playing ? playingScale : pausedScale) ?? 1)
    if slotIcon(for: state.source) != nil || drawnAsMark(state.source) {
        return base * discPixelScale / CGFloat(slotIconPixelScale)
    }
    return state.source == .music ? base : base * discPixelScale
}

// The cover's share of the handoff. A DJ segment is the waveform on its own, so
// the disc has to go, and scale is the only lever there is: `background.image`
// has no alpha. Shrinking it over the same 220ms as the text dim means the pill
// hands over its contents rather than dropping them, and by the time the wave
// rises the cover is already gone.
//
// Scaling the disc does not move anything else. Measured at 1.0, 0.5 and 0.0 the
// pill stayed 216pt, because the item's slot comes from its geometry and not
// from the image inside it, and 0 draws nothing rather than falling back to full
// size. So this needs no floor and the shrink cannot ripple into the layout.
func discScaleArg(_ amount: CGFloat, state: NowPlaying) -> String {
    scaleArg(restingDiscScale(state) * min(1, max(0, amount)))
}

// Dims the three text items and shrinks the disc with them. `amount` is 1 for
// fully present and 0 for gone. Text has real alpha through its colour byte,
// which is why that half of the handoff is a true fade while the wave half has
// to be baked into images.
func trackChromeArgs(_ amount: CGFloat, state: NowPlaying) -> [String] {
    let titleColor = titleShade(state)
    let subColor = state.playing ? artistColor : artistPausedColor
    let sepShade = state.playing ? sepColor : sepPausedColor
    // The spin is the other writer of the disc's scale and skips a write when the
    // value looks unchanged. Clearing what it remembers is what lets it put the
    // resting scale back once the tween has finished with the disc.
    lastDiscScale = nil
    return [
        "--set", "media", "icon.color=\(fadedColor(titleColor, amount))",
        "--set", "media_sep", "label.color=\(fadedColor(sepShade, amount))",
        "--set", "media_artist", "label.color=\(fadedColor(subColor, amount))",
        "--set", "media_disc", "background.image.scale=\(discScaleArg(amount, state: state))",
    ]
}

func setTrackChrome(_ amount: CGFloat, state: NowPlaying) {
    runSketchybar(trackChromeArgs(amount, state: state))
}

// One track giving way to the next, while the pill stays up. It used to be a
// hard cut: title, artist, cover and pill width all changed in one message.
//
// Now the old text lifts a few points and fades, the cover shrinks, the content
// swaps while nothing is legible, and the new text rises into place while the
// new cover springs back up. Out is short and in is longer, the way system
// transitions weight them: leaving should get out of the way, arriving is the
// part that is looked at. When only the cover changed the text stays put and
// only the cover moves.
let trackLeaveDuration: TimeInterval = 0.16
let trackArriveDuration: TimeInterval = 0.32
// Points the text travels. Enough to read as movement, not enough to read as
// the text going anywhere.
let trackLift: CGFloat = 3
// How small the cover gets before the swap. Not zero: a cover that vanishes and
// reappears is a blink, one that dips and comes back is a change.
let trackCoverDip: CGFloat = 0.25

// `text` is how present the words are, 0 to 1; `lift` their offset in points,
// positive up; `cover` the disc's share of its resting scale, which may run
// past 1 while the spring overshoots.
func trackSwapArgs(text: CGFloat, lift: CGFloat, cover: CGFloat, state: NowPlaying) -> [String] {
    let titleColor = titleShade(state)
    let subColor = state.playing ? artistColor : artistPausedColor
    let sepShade = state.playing ? sepColor : sepPausedColor
    let offset = Int(lift.rounded())
    lastDiscScale = nil
    return [
        "--set", "media", "icon.color=\(fadedColor(titleColor, text))", "icon.y_offset=\(offset)",
        "--set", "media_sep", "label.color=\(fadedColor(sepShade, text))", "label.y_offset=\(offset)",
        "--set", "media_artist", "label.color=\(fadedColor(subColor, text))", "label.y_offset=\(offset)",
        "--set", "media_disc",
        "background.image.scale=\(scaleArg(restingDiscScale(state) * max(0, cover)))",
    ]
}

// Whether `next` is something else playing rather than the same thing with a
// new playback state or a fresh heartbeat.
/// The title's colour for a state: bright playing, dim paused, and the quiet
/// grey of the silence, which is always "playing" so that its mark breathes.
func titleShade(_ state: NowPlaying) -> String {
    state.source == .silence ? silenceColor : (state.playing ? playingColor : pausedColor)
}

func isDifferentTrack(_ previous: NowPlaying, _ next: NowPlaying) -> Bool {
    previous.title != next.title || previous.artist != next.artist
        || previous.artworkKey != next.artworkKey || previous.source != next.source
}

func textChanged(_ previous: NowPlaying, _ next: NowPlaying) -> Bool {
    previous.title != next.title || previous.artist != next.artist
}

// Blends two 0xAARRGGBB colours channel by channel, alpha included, so a paused
// grey and a playing white meet through the colours in between rather than
// through a dimmed copy of either.
func mixColor(_ from: String, _ to: String, _ t: CGFloat) -> String {
    guard let a = UInt32(from.dropFirst(2), radix: 16), let b = UInt32(to.dropFirst(2), radix: 16)
    else { return t < 0.5 ? from : to }
    let c = min(1, max(0, t))
    func channel(_ shift: UInt32) -> UInt32 {
        let x = CGFloat((a >> shift) & 0xff), y = CGFloat((b >> shift) & 0xff)
        return UInt32((x + (y - x) * c).rounded()) << shift
    }
    return String(format: "0x%08x", channel(24) | channel(16) | channel(8) | channel(0))
}

// Playing to paused or back, same track, pill up. The text eases between its
// playing and paused colours, and the disc runs down to a stop or winds back up
// to speed over the same beat instead of stopping and starting dead. It used to
// be one message: the colours snapped and the cover froze mid-turn.
let playbackToggleDuration: TimeInterval = 0.45

// What the toggle last drew per text item, so a second toggle inside the first
// carries on from there instead of snapping back to the far end and starting
// over. A double tap on a media key does exactly that.
var toggleShown: [String: String] = [:]

func togglePlayback(from previous: NowPlaying, to state: NowPlaying) {
    let interrupting = playbackToggling
    lastApplied = state
    syncSpectrumTap(state)
    func start(_ item: String, _ nominal: String) -> String {
        interrupting ? (toggleShown[item] ?? nominal) : nominal
    }
    let colours = [
        ("media", "icon.color", start("media", previous.playing ? playingColor : pausedColor),
         state.playing ? playingColor : pausedColor),
        ("media_sep", "label.color", start("media_sep", previous.playing ? sepColor : sepPausedColor),
         state.playing ? sepColor : sepPausedColor),
        ("media_artist", "label.color",
         start("media_artist", previous.playing ? artistColor : artistPausedColor),
         state.playing ? artistColor : artistPausedColor),
    ]
    // The spin likewise ramps from whatever speed it is at.
    let fromRate = interrupting ? spinRate : (state.playing ? 0 : 1)
    let toRate: Double = state.playing ? 1 : 0
    if state.playing, spinTimer == nil || interrupting { startSpin(rate: fromRate) }
    runTween(
        curve: .linear, duration: playbackToggleDuration,
        step: { raw, _ in
            let blend = easeInOutCubic(raw)
            runSketchybar(colours.flatMap { item, property, from, to -> [String] in
                let shown = mixColor(from, to, blend)
                toggleShown[item] = shown
                return ["--set", item, "\(property)=\(shown)"]
            })
            // Eased out both ways: winding up reaches speed early, running down
            // loses most of its speed early and coasts into the stop.
            spinRate = fromRate + (toRate - fromRate) * Double(TweenCurve.arriving.apply(raw))
        },
        completion: {
            spinRate = 1
            if state.playing {
                if spinTimer == nil { startSpin() }
            } else {
                stopSpin()
                parkDiscFrame(for: state.source)
            }
        })
    playbackToggling = true
}

// The play/pause button in the transport strip, kept in step with the player
// from here rather than read back after a click, so it is right however the
// music was toggled: the strip, the media keys, or the app itself. It
// crossfades to the new glyph through motionwatch; with no motionwatch it is
// set outright.
let transportPlayGlyph = "\u{F040A}"
let transportPauseGlyph = "\u{F03E4}"
let transportColor = env["TEXT_COLOR"] ?? "0xfff5f5f7"
var transportShowsPlaying: Bool?
let motionPidFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".cache/sketchybar/motion/.pid")

func motionwatchRunning() -> Bool {
    guard let text = try? String(contentsOf: motionPidFile, encoding: .utf8),
          let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return false }
    return kill(pid, 0) == 0
}

func syncTransportGlyph(playing: Bool) {
    guard transportShowsPlaying != playing else { return }
    let first = transportShowsPlaying == nil
    transportShowsPlaying = playing
    // Pause while playing, play while paused: the button shows what it does.
    let glyph = playing ? transportPauseGlyph : transportPlayGlyph
    guard !first, motionwatchRunning() else {
        runSketchybar(["--set", "transport.playpause", "icon=\(glyph)"])
        return
    }
    let clear = fadedColor(transportColor, 0)
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("sketchybar.motionwatch.tween"), object: nil,
        userInfo: ["args": [
            "transport.playpause", "icon.color", "-", clear, "0", "80", "out",
            "transport.playpause", "icon", "=", glyph, "80", "0", "linear",
            "transport.playpause", "icon.color", clear, transportColor, "80", "200", "out",
        ]],
        deliverImmediately: true)
}

// The track the swap is heading for is `pendingTrack`, shared with the DJ exit:
// payloads landing inside the out half retarget it rather than restarting.
// Whether the words are part of this swap, fixed when it starts.
var swapMovesText = true

func leaveTrack(_ previous: NowPlaying) {
    // Both the spin and the swap write the disc's scale.
    stopSpin()
    let movesText = swapMovesText
    runTween(
        curve: .leaving, duration: trackLeaveDuration,
        step: { progress, _ in
            runSketchybar(trackSwapArgs(
                text: movesText ? 1 - progress : 1,
                lift: movesText ? trackLift * progress : 0,
                cover: 1 - (1 - trackCoverDip) * progress,
                state: previous))
        },
        completion: {
            guard let target = pendingTrack else { return }
            pendingTrack = nil
            drawTrack(target, fadeIn: false, swap: true)
        })
}

// The capsule itself: fill, border and shadow all carry their alpha in the top
// byte, so one `fadedColor` pass takes the whole thing down together. Without
// this the pill snapped to full width and full opacity as an empty shell and its
// contents then faded in inside it, which is the same "bare capsule" the DJ
// handoff already had to be talked out of.
func pillChromeArgs(_ amount: CGFloat) -> [String] {
    [
        "--set", "media_pill",
        "background.color=\(fadedColor(pillColor, amount))",
        "background.border_color=\(fadedColor(pillBorderColor, amount))",
        "background.shadow.color=\(fadedColor(pillShadowColor, amount))",
    ]
}

// Everything the pill is made of, moved as one. Text has real alpha and the disc
// has scale; the wave has neither, so its share is the baked entry ramp, the same
// frames the DJ handoff rides. One message per step for the track case, because
// two would double 60fps of IPC for no visible gain.
func setPlayerPresence(_ amount: CGFloat, state: NowPlaying) {
    playerPresence = amount
    if state.displayMode == .spotifyDJ {
        runSketchybar(pillChromeArgs(amount))
        setWaveformEntryFrame(amount)
        return
    }
    runSketchybar(pillChromeArgs(amount) + trackChromeArgs(amount, state: state))
}

// Fades the pill out and only then hides it, so the last thing seen is it
// leaving rather than it already gone. `finish` does the real hiding and
// whatever bookkeeping the site needs, and runs only if the fade completes:
// runTween drops a cancelled tween's completion, which is exactly right here,
// because anything that interrupts a fade-out wants the pill kept.
func fadePlayerOut(_ state: NowPlaying, then finish: @escaping () -> Void) {
    // A handoff in flight is a second writer on the same properties, and its
    // target is no longer wanted.
    cancelTransition()
    // Both frame loops write what this animates.
    stopSpin()
    stopWaveform()
    let from = playerPresence
    runTween(
        curve: .leaving,
        step: { progress, _ in setPlayerPresence(from * (1 - progress), state: state) },
        completion: {
            finish()
            // Back to full alpha while nothing is drawn, so nothing that shows
            // the pill later has to know a fade ever happened. Invisible: a
            // bracket with no drawn members parks itself at -9999 and draws
            // nothing, verified by hiding all five members and capturing.
            playerPresence = 1
            runSketchybar(pillChromeArgs(1))
        })
}

// Brings the pill up from wherever it currently is, which is 0 for an entrance
// and something in between when a fade-out was interrupted part way.
func fadePlayerIn(_ state: NowPlaying, then finish: @escaping () -> Void = {}) {
    let from = playerPresence
    guard from < 1 else {
        finish()
        return
    }
    runTween(
        curve: .arriving,
        step: { progress, _ in
            setPlayerPresence(from + (1 - from) * progress, state: state)
        },
        completion: {
            setPlayerPresence(1, state: state)
            finish()
        })
}

// One message, one set of colours. This used to fork on `changingTrack`: a new
// track sent the text dim and then a second message warmed it up, which was a
// fade that never ran (see runSketchybar). Without a working animator the two
// messages were just the paused colour flickering to the playing one microseconds
// later, so the fork is gone and the destination is sent straight away.
// Width and corner radius, which are the only two things that separate the three
// shapes once the frames themselves are rendered.
//
// These are values, not drawing flags, so they stay on this side of the
// ownership line that `applyTrackVisible` documents: menubar_reveal.sh can hide
// and restore the slot underneath this without the two colliding.
func discShapeArgs(_ source: MediaSource) -> [String] {
    switch source {
    case .music:
        return ["width=\(discItemWidth)", "background.image.corner_radius=\(discCornerRadius)"]
    // Square corners, because rounding a row of bars clips the outer two.
    case .podcast:
        return ["width=\(discItemWidth)", "background.image.corner_radius=0"]
    // The dot is a small mark on a transparent canvas, so there is no edge for a
    // radius to round. Rounding here would clip the canvas, not the dot.
    case .video, .youtube, .browser, .call, .service, .videoApp, .silence:
        return ["width=\(discItemWidth)", "background.image.corner_radius=0"]
    }
}

func applyVisible(_ state: NowPlaying) {
    if state.displayMode == .spotifyDJ {
        applyDJVisible()
        return
    }
    applyTrackVisible(state, discDrawing: true)
}

// `fade` folds the entry state of a transition into the same message that makes
// the items visible. Showing them at full strength and dimming them a message
// later is one frame of the finished pill flashing before the fade starts.
func applyTrackVisible(_ state: NowPlaying, discDrawing: Bool, fade: CGFloat = 1,
                       discFade: CGFloat? = nil) {
    // Measured against the room the pill really has (mediafit.swift), and the
    // character budget only when the layout cannot be read.
    syncCallTicker(state)
    if state.source == .silence {
        applySilenceVisible(state, discDrawing: discDrawing, fade: discFade ?? fade)
        return
    }
    let parts = fittedParts(state)
    let titleColor = fadedColor(titleShade(state), fade)
    let subColor = fadedColor(state.playing ? artistColor : artistPausedColor, fade)
    let sepShade = fadedColor(state.playing ? sepColor : sepPausedColor, fade)
    // Property ownership matters here, because menubar_reveal.sh runs
    // concurrently and neither side knows about the other. The reveal owns the
    // *drawing* flags (label.drawing, icon.drawing, background.drawing,
    // background.image.drawing); this watcher owns *values* (icon, label,
    // colours, padding, background.image) plus the item's own top-level drawing.
    // If the watcher touched a drawing flag, a track change during a menu bar
    // hover would light that slot back up on top of the frosted pane.
    //
    // Within the watcher there is a second ownership line: this function never
    // touches background.image. setFrameImage is the only writer. It used to set
    // the image here too, and since media-control streams the full payload
    // roughly ten times a second that meant an image swap landing on top of a
    // spin timer that replaces the same image every 41ms. The two fought over one
    // property and the disc jittered.
    // A track with no artist hides that item outright rather than leaving an
    // empty label holding its padding. Top-level `drawing` is watcher-owned, so
    // this does not collide with the reveal's label.drawing.
    //
    // The `~` goes with it. A separator hanging off the end of a title with
    // nothing after it is worse than no separator, and it would leave 14pt of
    // padding sitting inside the pill for no reason.
    let artistArgs: [String] =
        parts.artist.isEmpty
        ? ["--set", "media_sep", "drawing=off", "--set", "media_artist", "drawing=off"]
        : [
            "--set", "media_sep", "drawing=on", "label.color=\(sepShade)", "label.y_offset=0",
            "--set", "media_artist", "drawing=on", "label=\(parts.artist)", "label.y_offset=0",
        ]
    // The title's trailing padding moves with them, and it has to, because the
    // pill's closing gap is `media_artist`'s `label.padding_right` and that
    // leaves with the item. With the artist drawn this is 0, since the separator
    // supplies the gap from its own left side. See pillTextPad.
    let titlePadRight = parts.artist.isEmpty ? pillTextPad : 0

    // Sized from `fade` in the same message that reveals it, so a disc shown at
    // the start of a fade-in starts collapsed instead of appearing at full size
    // for the one frame before the tween's first step lands on it.
    //
    // The shape rides along in the same message for the same reason. Sending it
    // separately would let a track change from a song to a video land the banner
    // image in a 28pt round slot for one frame, which is a visible clip and a
    // visible width jump.
    let discArgs = [
        "--set", "media_disc", "drawing=\(discDrawing ? "on" : "off")",
        "padding_left=\(trackDiscPadLeft)", "padding_right=\(trackDiscPad)",
        "background.image.scale=\(discScaleArg(discFade ?? fade, state: state))",
    ] + discShapeArgs(state.source)

    runSketchybar(
        ["--set", "media_wave", "drawing=off"]
            + [
                // Offset back to rest on every draw, so a swap cut short by a
                // hide can never leave the words a couple of points high.
                "--set", "media", "drawing=on", "icon=\(parts.title)",
                "icon.color=\(titleColor)", "icon.padding_right=\(titlePadRight)",
                "icon.y_offset=0",
                // What the silence transitions borrow, put back on every draw.
                "icon.padding_left=\(titlePadLeft)", "width=\(titleItemWidth(parts))",
            ]
            + artistArgs + ["label.color=\(subColor)"]
            + discArgs)
    playerDrawn = true
}

/// The title and artist as they will be drawn: fitted to the room the pill has
/// (mediafit.swift), or to the character budget when the layout cannot be read.
func fittedParts(_ state: NowPlaying) -> (title: String, artist: String) {
    if state.source == .call { return (callClock(), callAppName(state.bundleID)) }
    return titleRoom().map { fitParts(title: state.title, artist: state.artist, room: $0) }
        ?? composeParts(title: state.title, artist: state.artist, budget: labelBudget(for: state.source))
}

// MARK: Calls
//
// In a call the pill is a meeting clock rather than whatever the call app calls
// its media session: the call mark, how long the call has run, and the app,
// `12:04 ~ Teams`. The clock starts when the call first shows and ticks once a
// second; Avenir Next's figures are all one width (8.85pt each at the bar's
// size), so it does not shuffle the pill as it counts. A bar reload during a
// meeting keeps counting: the start is kept on disk, and trusted if the call
// was still showing in the last two minutes.

let callStartFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".cache/sketchybar/call-start")
var callStartedAt: Date?
var callTicker: DispatchSourceTimer?

func callClock() -> String {
    let now = Date()
    if callStartedAt == nil {
        let saved = (try? String(contentsOf: callStartFile, encoding: .utf8))?
            .split(separator: " ").compactMap { Double($0) } ?? []
        if saved.count == 2, now.timeIntervalSince1970 - saved[1] < 120 {
            callStartedAt = Date(timeIntervalSince1970: saved[0])
        } else {
            callStartedAt = now
        }
    }
    let start = callStartedAt ?? now
    try? "\(start.timeIntervalSince1970) \(now.timeIntervalSince1970)\n"
        .write(to: callStartFile, atomically: true, encoding: .utf8)
    let total = max(0, Int(now.timeIntervalSince(start)))
    let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}

func callAppName(_ bundleID: String) -> String {
    let id = bundleID.lowercased()
    if id.hasPrefix("com.microsoft.teams") || id == "com.microsoft.vcxpc" { return "Teams" }
    if id.hasPrefix("us.zoom") { return "Zoom" }
    if id.hasPrefix("com.apple.facetime") { return "FaceTime" }
    if id.hasPrefix("com.cisco.webex") { return "Webex" }
    if id.hasPrefix("com.tinyspeck.slackmacgap") { return "Slack" }
    return "Call"
}

/// Keeps the clock going while a call is on the pill, and stops it the moment
/// anything else is. A tick inside a transition waits for the next one, so the
/// clock never writes over a swap.
func syncCallTicker(_ state: NowPlaying) {
    guard state.source == .call else {
        callTicker?.cancel()
        callTicker = nil
        callStartedAt = nil
        return
    }
    guard callTicker == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: applyQueue)
    timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(50))
    timer.setEventHandler {
        guard callTicker === timer, let shown = lastApplied, shown.source == .call else { return }
        guard transitionTimer == nil, playerDrawn else { return }
        applyTrackVisible(shown, discDrawing: true)
    }
    timer.resume()
    callTicker = timer
}

// MARK: Silence
//
// Silence is the note alone: the disc slot and nothing after it, in a capsule
// just big enough to hold them. Getting there from a track, and back, is the
// one change on this pill that also changes its size a great deal, from 200pt
// or more down to 44, and SketchyBar has no animation of its own for an item's
// width. So the pill is walked there. Measured on the bar:
//
// - A drawn text item's rect includes its text wherever that text runs, even at
//   zero alpha, so a title cannot be shrunk while it is still set. The walk
//   happens with the title emptied, once it has faded.
// - With an empty title, no icon padding and an explicit `width` W, the pill is
//   30 + W wide, and never less than the disc's own 44 with its padding at 8.
//   So W from the pill's width less 32 down to silenceSeam lands exactly on the
//   note's capsule, and hiding the item then changes nothing on screen.
// - With a title, SketchyBar sizes each text by its glyph-path bounds rounded
//   up, and the pill comes to ceil(title) + 49 alone or ceil(title) +
//   ceil(artist) + 78 with an artist: the disc, the paddings and the separator
//   are the constants. Measured against seven real layouts, six exactly and one
//   a point out, so the walk back lands where the words will, and the capsule
//   does not move when they arrive. Re-measure these if a padding changes.
// - The title item carries that width explicitly, always: ceil(title) + 19
//   alone, or + 12 with an artist after it (titleItemWidth). Left to
//   `width=dynamic`, SketchyBar resolves the width a frame after the rest of a
//   change, and the capsule showed that frame: 437pt for a pill settling at 332
//   when the artist appeared in the same message, 2pt out on a plain redraw.
// - Below W = 14 the empty item stops following W, so the walk turns there: the
//   capsule is the note's 44 at that point either way, and hiding the item then
//   is invisible.
// The slot's paddings, a track's and the silence's. The silence's are not
// symmetric numbers because the slot is not symmetric: SketchyBar slides the
// image of an explicit-width item by its paddings rather than growing it, and
// 10 and 6 are what put the slot's mark 11.5pt from both ends of the capsule, measured
// off a capture (8 and 8 left them 9.5 from one end and 13.5 from the other).
// With the title item drawn the paddings do not touch the capsule's width at
// all, so they are only ever changed while the slot is empty, at scale 0.
let trackDiscPadLeft = 10
let trackDiscPad = 3
let silenceDiscPadLeft = 10
let silenceDiscPad = 6
let titlePadLeft = 9
let silenceSeam: CGFloat = 14
let explicitPillBase: CGFloat = 30
let silenceLeaveDuration: TimeInterval = 0.2
let silenceWalkDuration: TimeInterval = 0.46

func easeInOut(_ t: CGFloat) -> CGFloat {
    let c = min(1, max(0, t))
    return c < 0.5 ? 4 * c * c * c : 1 - pow(-2 * c + 2, 3) / 2
}

func glyphWidth(_ text: String) -> CGFloat {
    let attributed = NSAttributedString(
        string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): fitFont])
    return CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(attributed), .useGlyphPathBounds).width
}

func titleItemWidth(_ parts: (title: String, artist: String)) -> Int {
    Int(ceil(glyphWidth(steadyClock(parts.title)))) + (parts.artist.isEmpty ? 19 : 12)
}

/// A running clock measured as if every digit were 0, so its width only steps
/// when it grows a digit. The figures are all one advance, but their ink is not:
/// a 1 measures narrower than a 0, and the width would wobble every second.
func steadyClock(_ text: String) -> String {
    guard text.range(of: #"^\d{1,2}(:\d\d){1,2}$"#, options: .regularExpression) != nil else { return text }
    return String(text.map { $0.isNumber ? "0" : $0 })
}

func predictedPillWidth(_ parts: (title: String, artist: String)) -> CGFloat {
    let title = ceil(glyphWidth(steadyClock(parts.title)))
    return parts.artist.isEmpty ? title + 49 : title + ceil(glyphWidth(parts.artist)) + 78
}

/// The resting layout: the note in its slot, centred in a capsule of its own.
func applySilenceVisible(_ state: NowPlaying, discDrawing: Bool, fade: CGFloat) {
    runSketchybar(
        ["--set", "media_wave", "drawing=off",
         "--set", "media", "drawing=off",
         "--set", "media_sep", "drawing=off",
         "--set", "media_artist", "drawing=off",
         "--set", "media_disc", "drawing=\(discDrawing ? "on" : "off")",
         "padding_left=\(silenceDiscPadLeft)", "padding_right=\(silenceDiscPad)",
         "background.image.scale=\(discScaleArg(fade, state: state))"]
            + discShapeArgs(state.source))
    playerDrawn = true
}

/// The empty title item at width `w`, which is what the capsule's width follows
/// while it walks.
func walkArgs(_ w: CGFloat) -> [String] {
    ["--set", "media", "width=\(Int(w.rounded()))"]
}

/// When in a walk the slot changes hands: the leaving shape is gone by here,
/// the arriving one grows from here to the end, so the capsule is never empty.
let slotHandover: CGFloat = 0.32

/// The slot's image and shape switched while it is at scale 0, which is the only
/// moment its paddings may move (see trackDiscPad).
func handOverSlot(to state: NowPlaying, frames: [URL], left: Int, right: Int) -> [String] {
    framePaths = frames
    frameIndex = 0
    renderedArtworkKey = state.artworkKey
    lastApplied = state
    syncSpectrumTap(state)
    // setFrameImage leaves the scale alone when it thinks it is already right,
    // which keeps the new image at 0 until the walk brings it up.
    lastDiscScale = scaleArg(restingDiscScale(state))
    setFrameImage()
    return ["--set", "media_disc", "padding_left=\(left)", "padding_right=\(right)",
            "background.image.scale=0"] + discShapeArgs(state.source)
}

/// A track, or a pause that outlasted pauseHideAfter, settling into silence: the
/// words lift away as the cover shrinks, the capsule closes in around the slot,
/// and half way there the cover has gone and the note springs up in its place.
func settleIntoSilence(from previous: NowPlaying) {
    stopSpin()
    cancelDrain()
    // Rendered first, so no render can stall the walk once it is moving.
    let note: [URL]
    do {
        note = try renderDiscFrames(image: nil, key: silenceState.artworkKey, source: .silence)
    } catch {
        logErr("cannot render silence: \(error)")
        hidePlayer()
        return
    }
    let startPill = queryPillWidth() ?? (explicitPillBase + silenceSeam)
    let coverRest = restingDiscScale(previous)
    let noteRest = restingDiscScale(silenceState)
    let coverAtWalk: CGFloat = 0.6
    // Claimed now, so a repeated end of playback is a no-op rather than a restart.
    lastApplied = silenceState
    syncSpectrumTap(silenceState)
    runTween(
        curve: .leaving, duration: silenceLeaveDuration,
        step: { progress, _ in
            runSketchybar(trackSwapArgs(
                text: 1 - progress, lift: trackLift * progress,
                cover: 1 - (1 - coverAtWalk) * progress, state: previous))
        },
        completion: {
            let from = max(silenceSeam, startPill - explicitPillBase)
            // The words are clear, so the title can go blank at the width it
            // has, and nothing moves yet.
            runSketchybar(
                ["--set", "media_sep", "drawing=off", "--set", "media_artist", "drawing=off",
                 "--set", "media", "icon=", "icon.padding_left=0", "icon.padding_right=0",
                 "icon.y_offset=0", "width=\(Int(from.rounded()))"])
            var handed = false
            runTween(
                curve: .linear, duration: silenceWalkDuration,
                step: { raw, _ in
                    var args = walkArgs(from + (silenceSeam - from) * easeInOut(raw))
                    if raw < slotHandover {
                        let shrink = 1 - TweenCurve.leaving.apply(raw / slotHandover)
                        args += ["--set", "media_disc",
                                 "background.image.scale=\(scaleArg(coverRest * coverAtWalk * shrink))"]
                    } else {
                        if !handed {
                            handed = true
                            args += handOverSlot(to: silenceState, frames: note,
                                                 left: silenceDiscPadLeft, right: silenceDiscPad)
                        }
                        let grow = springProgress((raw - slotHandover) / (1 - slotHandover))
                        args += ["--set", "media_disc", "background.image.scale=\(scaleArg(noteRest * grow))"]
                    }
                    runSketchybar(args)
                },
                completion: {
                    applySilenceVisible(silenceState, discDrawing: true, fade: 1)
                    runSketchybar(["--set", "media", "icon.padding_left=\(titlePadLeft)"])
                    lastDiscScale = nil
                    startSpin()
                })
        })
}

/// Silence waking into a track, the settle backwards: the note sinks as the
/// capsule starts to open, the cover springs up in the slot while it is still
/// opening, and the capsule arrives at exactly the width the title takes, which
/// then rises into it.
func wakeFromSilence(to state: NowPlaying) {
    stopSpin()
    let cover: [URL]
    do {
        cover = try renderDiscFrames(image: currentArtwork, key: state.artworkKey, source: state.source)
    } catch {
        logErr("cannot render disc: \(error)")
        hidePlayer()
        return
    }
    let parts = fittedParts(state)
    let target = max(silenceSeam, predictedPillWidth(parts) - explicitPillBase)
    let startPill = queryPillWidth() ?? (explicitPillBase + silenceSeam)
    let from = max(silenceSeam, startPill - explicitPillBase)
    let noteRest = restingDiscScale(silenceState)
    let coverRest = restingDiscScale(state)
    runSketchybar(
        ["--set", "media", "drawing=on", "icon=", "icon.padding_left=0", "icon.padding_right=0",
         "icon.y_offset=0", "width=\(Int(from.rounded()))",
         "--set", "media_sep", "drawing=off", "--set", "media_artist", "drawing=off"])
    var handed = false
    runTween(
        curve: .linear, duration: silenceWalkDuration,
        step: { raw, _ in
            var args = walkArgs(from + (target - from) * easeInOut(raw))
            if raw < slotHandover {
                let sink = 1 - TweenCurve.leaving.apply(raw / slotHandover)
                args += ["--set", "media_disc", "background.image.scale=\(scaleArg(noteRest * sink))"]
            } else {
                if !handed {
                    handed = true
                    args += handOverSlot(to: state, frames: cover,
                                         left: trackDiscPadLeft, right: trackDiscPad)
                }
                let grow = springProgress((raw - slotHandover) / (1 - slotHandover))
                args += ["--set", "media_disc", "background.image.scale=\(scaleArg(coverRest * grow))"]
            }
            runSketchybar(args)
        },
        completion: {
            // The words go in clear at their own width, which is where the walk
            // just arrived, so the capsule does not move as they land; then
            // they rise into place.
            var landing = [
                "--set", "media", "icon=\(parts.title)",
                "icon.color=\(fadedColor(titleShade(state), 0))",
                "icon.padding_left=\(titlePadLeft)",
                "icon.padding_right=\(parts.artist.isEmpty ? pillTextPad : 0)",
                "icon.y_offset=\(Int(-trackLift))",
                "width=\(titleItemWidth(parts))",
            ]
            if !parts.artist.isEmpty {
                landing += [
                    "--set", "media_sep", "drawing=on", "label.color=\(fadedColor(sepColor, 0))",
                    "--set", "media_artist", "drawing=on", "label=\(parts.artist)",
                    "label.color=\(fadedColor(artistColor, 0))",
                ]
            }
            runSketchybar(landing)
            runTween(
                curve: .arriving, duration: trackArriveDuration,
                step: { settle, _ in
                    runSketchybar(trackSwapArgs(
                        text: settle, lift: -trackLift * (1 - settle), cover: 1, state: state))
                },
                completion: {
                    applyTrackVisible(state, discDrawing: true)
                    lastDiscScale = nil
                    if state.playing {
                        startSpin()
                    } else {
                        stopSpin()
                        parkDiscFrame(for: state.source)
                    }
                })
        })
}

func applyDJVisible() {
    let hideTrack = djHiddenItems.flatMap { ["--set", $0, "drawing=off"] }
    runSketchybar(hideTrack + ["--set", "media_wave", "drawing=on"])
    playerDrawn = true
}

// The only writer of background.image, and deliberately un-animated: the image
// is a discrete swap in a 24fps sequence, so asking SketchyBar to interpolate
// towards it just smears one frame into the next.
// The cached sequences keep their own cadence while the tick runs faster for the
// live waveform. Returns whether the index actually moved, which is the caller's
// cue that there is a new cached frame worth pushing; a tick that moves neither
// the index nor a level has nothing to say.
//
// The remainder is carried rather than reset, so 24fps stays 24fps on average
// instead of drifting down to the nearest multiple of the tick.
func advanceCanned(
    _ index: inout Int, count: Int, clock: inout TimeInterval,
    interval: TimeInterval, tick: TimeInterval = liveInterval
) -> Bool {
    guard count > 0 else { return false }
    clock += tick
    guard clock >= interval else { return false }
    clock -= interval
    index = (index + 1) % count
    return true
}

func setFrameImage(cannedAdvanced: Bool = true) {
    guard let canned = framePaths[safe: frameIndex] else { return }
    // A podcast's six bars are the one shape in this slot that can be driven by
    // real audio. A cover has nothing to react with and a dot is not a level.
    // Amplitude stays at 1 here, unlike the canned version's 1.3: that lift only
    // existed to rescue a synthetic envelope that sat too low, and applying it to
    // a measured level would just saturate every loud bar against the cap.
    var path = canned
    var drewLive = false
    if lastApplied?.source == .podcast,
       let levels = smoothedAudioLevels(
           bars: waveformBars(forWidth: slotPixelSize, sideMargin: discWaveSideMargin)),
       let live = liveWaveURL(
           width: slotPixelSize, levels: levels, amplitude: 1, opacity: 1,
           sideMargin: discWaveSideMargin, envelopeFloor: discWaveEnvelopeFloor)
    {
        path = live
        drewLive = true
    }
    // Falling back to the cached sequence on a tick that did not advance it means
    // re-sending the path it already has. Every set redraws the bar, so the whole
    // point of the faster tick is lost if the cached path pays for it too.
    guard drewLive || cannedAdvanced else { return }
    var args = ["--set", "media_disc", "background.image=\(path.path)"]
    let scale = lastApplied.map { scaleArg(restingDiscScale($0)) }
        ?? ((lastApplied?.playing ?? true) ? playingScale : pausedScale)
    if lastDiscScale != scale {
        args.append("background.image.scale=\(scale)")
        lastDiscScale = scale
    }
    runSketchybar(args)
}

func stopSpin() {
    spinTimer?.cancel()
    spinTimer = nil
}

func setWaveformFrame(cannedAdvanced: Bool = true) {
    guard let canned = waveformPaths[safe: waveformIndex] else { return }
    var path = canned
    var drewLive = false
    if let levels = smoothedAudioLevels(bars: waveformBars(forWidth: waveformRenderedWidth)),
       let live = liveWaveURL(
           width: waveformRenderedWidth, levels: levels, amplitude: 1, opacity: 1,
           sideMargin: waveformSideMargin, envelopeFloor: waveformEnvelopeFloor)
    {
        path = live
        drewLive = true
    }
    guard drewLive || cannedAdvanced else { return }
    var args = [
        "--set", "media_wave",
        "background.image=\(path.path)",
        "background.image.scale=1.0",
    ]
    if lastWaveWidth != waveformRenderedWidth {
        args.append("width=\(waveformRenderedWidth)")
        lastWaveWidth = waveformRenderedWidth
    }
    runSketchybar(args)
}

// Walks the handoff frames. `progress` is 0 for silent and invisible, 1 for the
// running waveform, so the exit passes 1 - progress and plays them backwards.
// Only ever driven by a tween, and the loop timer is stopped while one runs, so
// this does not break the single-writer rule on background.image.
func setWaveformEntryFrame(_ progress: CGFloat) {
    let span = CGFloat(waveformEntryCount - 1)
    let index = Int((min(1, max(0, progress)) * span).rounded())
    guard let path = waveformEntryPaths[safe: index] else { return }
    var args = [
        "--set", "media_wave",
        "background.image=\(path.path)",
        "background.image.scale=1.0",
    ]
    if lastWaveWidth != waveformRenderedWidth {
        args.append("width=\(waveformRenderedWidth)")
        lastWaveWidth = waveformRenderedWidth
    }
    runSketchybar(args)
}

func stopWaveform() {
    waveformTimer?.cancel()
    waveformTimer = nil
}

func startWaveform() {
    stopWaveform()
    guard waveformPaths.count == waveformFrameCount else { return }
    waveClock = 0
    let timer = DispatchSource.makeTimerSource(queue: applyQueue)
    timer.schedule(deadline: .now() + liveInterval, repeating: liveInterval, leeway: .milliseconds(2))
    timer.setEventHandler {
        guard waveformTimer === timer else { return }
        let advanced = advanceCanned(
            &waveformIndex, count: waveformFrameCount, clock: &waveClock,
            interval: waveformInterval)
        setWaveformFrame(cannedAdvanced: advanced)
    }
    timer.resume()
    waveformTimer = timer
}

// Drives whichever sequence is in framePaths: 60 frames of a rotating cover, 72
// of a waveform, or the banner's single frame, which needs no timer at all. The
// count comes off the array rather than the disc's own constant, because those
// are three different numbers now and pinning it to one meant the other two
// sequences silently never animated.
//
// The cadence is shared deliberately. The cover turns once in 2.5s and the
// waveform loops in 3s, both at 24fps, so neither reads as faster than the other.
// The timer itself ticks at 60 for the live waveform's benefit; the cached
// sequences step off an accumulator, so their timing is unchanged.
// How fast the disc turns relative to normal. 1 except while playback is
// starting or stopping, when the disc winds up or runs down instead of starting
// and stopping dead, the way a platter would.
var spinRate: Double = 1

func startSpin(rate: Double = 1) {
    spinRate = rate
    stopSpin()
    cancelDrain()
    let count = framePaths.count
    guard count > 1 else { return }
    spinClock = 0
    let timer = DispatchSource.makeTimerSource(queue: applyQueue)
    timer.schedule(deadline: .now() + liveInterval, repeating: liveInterval, leeway: .milliseconds(2))
    timer.setEventHandler {
        guard spinTimer === timer else { return }
        let advanced = advanceCanned(
            &frameIndex, count: count, clock: &spinClock,
            interval: slotInterval(for: lastApplied?.source) / max(0.04, spinRate))
        setFrameImage(cannedAdvanced: advanced)
    }
    timer.resume()
    spinTimer = timer
}

// Artwork rides along with the state instead of sitting in a global that the
// stream thread writes and applyQueue reads. Same reason as the spin: the
// decoded image was being swapped out from under whoever was rendering with it.
func scheduleApply(_ state: NowPlaying?, artwork: CGImage?) {
    applyQueue.async {
        // A pause is the one edge where the debounce below is visible: the disc
        // keeps turning through it, measured at 3 more frames and ~270ms from
        // the keypress, which reads as the cover not noticing the pause. Stopped
        // here, ahead of the debounce, because stopping a spin needs none of the
        // state the debounce exists to settle. Everything else about a paused
        // pill, the dimmed text and the parked frame, still goes through commit
        // a moment later, and `stopSpin` is idempotent so doing it twice costs
        // nothing.
        // Only while that track is what the slot shows. Resting in silence,
        // the paused track keeps sending heartbeats every few seconds, and
        // this used to answer each one by stopping the silence's glow and
        // draining its note into a flat grey disc, the cover's pause treatment
        // applied to a frame that was never a cover.
        if let state, !state.playing, spinTimer != nil, lastApplied?.source != .silence {
            stopSpin()
            parkDiscFrame(for: state.source)
        }
        pendingWorkItem?.cancel()
        let work = DispatchWorkItem {
            // A call owns the pill for its length; what Now Playing says
            // meanwhile is kept for when it ends (mediacall.swift).
            if activeCall != nil {
                heldPayload = (state, artwork)
                return
            }
            currentArtwork = artwork
            commit(state)
        }
        pendingWorkItem = work
        applyQueue.asyncAfter(deadline: .now() + 0.08, execute: work)
    }
}

func commit(_ state: NowPlaying?) {
    guard let state else {
        // With nothing on screen there is nothing to protect, so an empty
        // payload can be taken at face value. With the pill up it is a gap
        // between two tracks until proven otherwise.
        guard lastApplied != nil else {
            enterSilence()
            return
        }
        if gapTimer == nil { armGapHide() }
        return
    }
    cancelGapHide()
    syncTransportGlyph(playing: state.playing)

    // Playing clears everything a pause set up, and falls through to the normal
    // path, which fades the pill back in from wherever it is.
    tracePause("commit playing=\(state.playing) hiddenForPause=\(hiddenForPause) timer=\(pauseTimer != nil)")
    if state.playing {
        cancelPauseHide()
        hiddenForPause = false
    } else {
        // Already taken away by an earlier pause: the heartbeat is news of
        // nothing, and drawing it would undo the hide it is repeating.
        if hiddenForPause { return }
        armPauseHide()
    }

    if state.displayMode == .spotifyDJ {
        // Nothing is left spinning once the cover goes, and the tween owns the
        // disc's scale on the way out.
        stopSpin()
        // The wave is rendered at the width of the pill it is taking over, so the
        // pill keeps its size when the DJ starts. Measured only when a fresh
        // segment starts, while the track is still up and still defining that
        // width; a repeat payload mid-segment must not re-measure, because by
        // then the wave itself is what the pill is sized to and feeding that
        // back through would shrink it by 2pt per payload.
        if lastApplied?.displayMode != .spotifyDJ {
            let measured = queryPillWidth().map { Int(waveWidth(forPill: $0).rounded()) }
            waveformRenderedWidth = max(waveformMinWidth, measured ?? waveformFallbackWidth)
        }
        if waveformPaths.isEmpty || waveformEntryPaths.isEmpty
            || waveformCachedWidth != waveformRenderedWidth
        {
            do {
                waveformPaths = try renderWaveformFrames(width: waveformRenderedWidth)
                waveformEntryPaths = try renderWaveformEntryFrames(
                    width: waveformRenderedWidth)
                waveformCachedWidth = waveformRenderedWidth
                waveformIndex = 0
                pruneStaleWaveformVersions()
                pruneWaveformWidths()
            } catch {
                logErr("cannot render DJ waveform: \(error)")
                hidePlayer()
                return
            }
        }
        // A tween owns the wave until it hands over, so a heartbeat landing
        // mid-fade must not start the animation as a second writer.
        if state == lastApplied {
            // An exit fade heading for a track, while DJ is still the current
            // state, has to be abandoned rather than allowed to land. Otherwise
            // a DJ payload arriving inside that window is swallowed by this
            // equality check and the fade completes into a track that Spotify
            // is not playing.
            if pendingTrack != nil {
                cancelTransition()
                setWaveformFrame()
            }
            if transitionTimer == nil {
                if state.playing, waveformTimer == nil { startWaveform() }
                if !state.playing { stopWaveform() }
            }
            return
        }
        let previous = lastApplied
        lastApplied = state
        if previous?.displayMode == .spotifyDJ {
            // Already in DJ mode and only playback changed. Nothing enters or
            // leaves, so there is nothing to transition. applyDJVisible is still
            // sent because a fade may have left the item faint underneath us.
            cancelTransition()
            applyDJVisible()
            // An entry tween interrupted here by a pause leaves a half-risen
            // frame on screen, and a paused DJ starts no timer to replace it.
            setWaveformFrame()
            if state.playing { startWaveform() } else { stopWaveform() }
            return
        }
        enterDJ(state, from: previous)
        return
    }

    showTrack(state)
}

// The track half of commit, from a state that is not a DJ segment: whether it
// is a repaint, a pause, a swap or an entrance. enterSilence comes in here too.
func showTrack(_ state: NowPlaying) {
    stopWaveform()

    // media-control runs with --no-diff, so it re-sends the whole payload on
    // every update, including ones where only elapsed time moved. Without this
    // guard each of those repainted the item ~10x a second for no visible
    // benefit, and that traffic is what the spin had to compete with.
    if state == lastApplied, !framePaths.isEmpty {
        // The old track came back while a swap was leaving it, which happens
        // when a player flickers between two payloads. Abandon the swap and put
        // the old track back up, or it would complete into something that is no
        // longer playing.
        if pendingTrack != nil {
            cancelTransition()
            runSketchybar(trackSwapArgs(text: 1, lift: 0, cover: 1, state: state))
        }
        // The disc's scale belongs to the tween until it finishes, and startSpin
        // writes that property too.
        if state.playing, spinTimer == nil, transitionTimer == nil { startSpin() }
        return
    }

    if lastApplied?.displayMode == .spotifyDJ {
        // Shrink the wave away before drawing the track, rather than swapping
        // both in one message. Deferring the draw is also what keeps the pill's
        // width change hidden: it happens while neither side is legible.
        //
        // Deferring it is also why the tween has to be retargeted rather than
        // restarted. lastApplied still says DJ for the length of the fade, and
        // media-control debounces at 100ms, so a second payload lands inside the
        // window as a matter of course. Starting a fresh tween for each one
        // cancels the previous before it can hand over and the pill sits in DJ
        // mode pulsing forever. Measured: it never escaped.
        let alreadyLeaving = pendingTrack != nil
        pendingTrack = state
        if alreadyLeaving { return }
        runTween(
            curve: .leaving,
            step: { progress, _ in setWaveformEntryFrame(1 - progress) },
            completion: {
                // Whatever is pending now, not whatever was playing when the
                // fade started.
                guard let target = pendingTrack else { return }
                pendingTrack = nil
                drawTrack(target, fadeIn: true)
            })
        return
    }
    // Into and out of silence, which changes the capsule's size, so it walks.
    if let previous = lastApplied, previous.displayMode == .track, playerDrawn, playerPresence >= 1 {
        if state.source == .silence, previous.source != .silence {
            pendingTrack = nil
            settleIntoSilence(from: previous)
            return
        }
        if previous.source == .silence, state.source != .silence {
            pendingTrack = nil
            wakeFromSilence(to: state)
            return
        }
    }
    // Same thing playing, only paused or resumed, with the pill up and nothing
    // else animating it: ease between the two rather than cutting.
    if let previous = lastApplied, previous.displayMode == .track,
        !isDifferentTrack(previous, state), previous.playing != state.playing,
        playerDrawn, playerPresence >= 1, pendingTrack == nil,
        transitionTimer == nil || playbackToggling,
        !framePaths.isEmpty
    {
        togglePlayback(from: previous, to: state)
        return
    }
    // Something else is playing and the pill is fully up: swap rather than cut.
    // A second payload inside the out half only retargets it.
    if let previous = lastApplied, previous.displayMode == .track,
        playerDrawn, playerPresence >= 1,
        pendingTrack != nil || isDifferentTrack(previous, state)
    {
        let alreadyLeaving = pendingTrack != nil
        pendingTrack = state
        if alreadyLeaving { return }
        swapMovesText = textChanged(previous, state)
        leaveTrack(previous)
        return
    }
    drawTrack(state, fadeIn: false)
}

// `fadeIn` asks for the contents to arrive, which is handing back from a DJ
// segment: the capsule is already on screen and stays. Whether the capsule
// itself has to arrive is not the caller's business, it is a question about what
// is on screen, so it is decided here.
func drawTrack(_ state: NowPlaying, fadeIn: Bool, swap: Bool = false) {
    // A fade-in already in flight has to go before this draws anything. It
    // writes the disc's scale and the text colours on a 60fps timer, so leaving
    // it running would put two writers on those properties, and its completion
    // would then restore the playback state of the track it started with. Landing
    // here from a tween completion this is already a no-op: runTween cancels
    // before it hands over.
    cancelTransition()
    // Nothing on screen, or a fade-out interrupted part way through, and the
    // capsule comes up with its contents. Interrupted counts because five
    // minutes paused and then a keypress is the normal way this pill comes back,
    // and landing on it mid-fade would otherwise snap the contents to full
    // inside a still-transparent capsule.
    let pillArriving = !playerDrawn || playerPresence < 1
    // A swap only counts as one while the pill is up; one interrupted by a hide
    // lands as an ordinary entrance.
    let swapping = swap && !pillArriving
    let movesText = swapMovesText
    let entryFade: CGFloat =
        pillArriving ? (playerDrawn ? playerPresence : 0)
        : (fadeIn || (swapping && movesText) ? 0 : 1)
    if pillArriving {
        // Chrome first, while no member is drawn and the bracket therefore draws
        // nothing at all. Items first would show one frame of an opaque empty
        // capsule before the tween's first step could take it down.
        playerPresence = entryFade
        runSketchybar(pillChromeArgs(entryFade))
    }
    let needsFrames = renderedArtworkKey != state.artworkKey || framePaths.isEmpty
    if lastApplied?.displayMode == .spotifyDJ, needsFrames {
        // The title can appear immediately, but keep the disc hidden until its
        // new image has landed. Otherwise DJ chrome freezes throughout the
        // synchronous render and the old cover flashes for one IPC message.
        applyTrackVisible(state, discDrawing: false, fade: entryFade)
    }
    if needsFrames {
        do {
            framePaths = try renderDiscFrames(
                image: currentArtwork, key: state.artworkKey, source: state.source)
            frameIndex = 0
            renderedArtworkKey = state.artworkKey
        } catch {
            logErr("cannot render disc: \(error)")
            hidePlayer()
            return
        }
    }
    lastApplied = state
    // Before the first setFrameImage, so a podcast's opening frame can already
    // be a real level rather than one canned frame followed by live ones.
    syncSpectrumTap(state)
    // After lastApplied, because setFrameImage reads it to decide the scale.
    // Image first, drawing second: a newly shown disc can never flash the cover
    // from the track before the DJ segment.
    //
    // Mid-swap the disc is dipped, and setFrameImage would put the resting
    // scale back with the new image: one frame of the new cover at full size
    // before the spring starts. Telling it the scale is already right keeps the
    // dip; applyTrackVisible sets the real value in the next message.
    if swapping { lastDiscScale = scaleArg(restingDiscScale(state)) }
    setFrameImage()
    applyTrackVisible(
        state, discDrawing: true, fade: entryFade,
        discFade: swapping ? trackCoverDip : nil)
    // The spin stays parked for the length of any fade. Unlike the wave, the
    // disc's image and its scale are written by two different functions, so
    // running both would put two writers on background.image.scale, which is the
    // jitter this file already learned about once.
    let resumeSpin = {
        if state.playing {
            startSpin()
        } else {
            stopSpin()
            parkDiscFrame(for: state.source)
        }
    }
    if swapping {
        runTween(
            curve: .linear, duration: trackArriveDuration,
            step: { raw, _ in
                let settle = TweenCurve.arriving.apply(raw)
                runSketchybar(trackSwapArgs(
                    text: movesText ? settle : 1,
                    lift: movesText ? -trackLift * (1 - settle) : 0,
                    cover: trackCoverDip + (1 - trackCoverDip) * springProgress(raw),
                    state: state))
            },
            completion: {
                runSketchybar(trackSwapArgs(text: 1, lift: 0, cover: 1, state: state))
                resumeSpin()
            })
        return
    }
    guard pillArriving || fadeIn else {
        resumeSpin()
        return
    }
    if pillArriving {
        fadePlayerIn(state, then: resumeSpin)
        return
    }
    runTween(
        curve: .arriving,
        step: { progress, _ in setTrackChrome(progress, state: state) },
        completion: {
            setTrackChrome(1, state: state)
            resumeSpin()
        })
}

func enterDJ(_ state: NowPlaying, from previous: NowPlaying?) {
    let reveal = {
        applyDJVisible()
        setWaveformEntryFrame(0)
        runTween(
            curve: .arriving,
            step: { progress, _ in setWaveformEntryFrame(progress) },
            completion: {
                // Hand over to the loop, whose frame 0 the last entry frame
                // already matches in amplitude and opacity.
                waveformIndex = 0
                setWaveformFrame()
                if state.playing { startWaveform() }
            })
    }
    // No track to fade out. Either the pill is already up, which is a repaint
    // and not an entrance, or there is nothing on screen and the capsule has to
    // arrive the same way it does for a track.
    guard let previous, previous.displayMode == .track else {
        guard !playerDrawn || playerPresence < 1 else {
            applyDJVisible()
            setWaveformFrame()
            if state.playing { startWaveform() }
            return
        }
        playerPresence = playerDrawn ? playerPresence : 0
        runSketchybar(pillChromeArgs(playerPresence))
        applyDJVisible()
        setWaveformEntryFrame(playerPresence)
        fadePlayerIn(state) {
            waveformIndex = 0
            setWaveformFrame()
            if state.playing { startWaveform() }
        }
        return
    }
    runTween(
        curve: .leaving,
        step: { progress, _ in setTrackChrome(1 - progress, state: previous) },
        completion: reveal)
}

var currentArtwork: CGImage?

// Asks Spotify what it is actually playing. Returns nil for "no answer", which
// is a different thing from "not an episode" and has to stay that way: nil
// leaves the metadata heuristic in charge, false overrules it.
//
// Automation permission is per-caller, and the caller here is whatever spawned
// this binary, which is SketchyBar. macOS therefore prompts once, for
// SketchyBar, not for this file. Refuse it and osascript exits non-zero, this
// returns nil, and nothing else changes.
func spotifyCurrentTrackIsEpisode() -> Bool? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    proc.arguments = ["-e", "tell application \"Spotify\" to get id of current track"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do { try proc.run() } catch { return nil }
    // A wedged Spotify would otherwise hold this thread for as long as it likes.
    // The read below cannot be interrupted, so the watchdog closes the process
    // rather than the pipe.
    let watchdog = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: watchdog)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    watchdog.cancel()
    guard proc.terminationStatus == 0 else { return nil }
    return spotifyURIIsEpisode(String(decoding: data, as: UTF8.self))
}

// Split out from the subprocess so the part with the actual decision in it can
// be tested without Spotify running.
func spotifyURIIsEpisode(_ raw: String) -> Bool? {
    let uri = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if uri.hasPrefix("spotify:episode:") { return true }
    if uri.hasPrefix("spotify:track:") { return false }
    // Ads and local files land here. Neither is a podcast, so neither may be
    // drawn as one. An empty or unrecognised answer is no answer at all, and has
    // to stay distinct from "not an episode": nil leaves the metadata heuristic
    // holding the decision, false overrules it.
    return uri.isEmpty ? nil : false
}

// The subprocess runs off both the stream thread and applyQueue, so a wedged
// Spotify cannot stall metadata updates or the spin. `finish` is handed back on
// applyQueue, because everything it goes on to touch lives there.
func probeSpotifyKind(id: String, then finish: @escaping (Bool) -> Void) {
    guard claimSpotifyProbe(id) else { return }
    DispatchQueue.global(qos: .utility).async {
        let episode = spotifyCurrentTrackIsEpisode()
        finishSpotifyProbe(id, episode: episode)
        guard let episode else { return }
        applyQueue.async { finish(episode) }
    }
}

// A podcast pill shows the show, not the episode. The episode title is a
// sentence, and the show is what answers "what am I listening to" at a glance.
//
// Which field holds the show is not consistent, and on Spotify it is the mirror
// image of a song: measured 2026-09-09 on Diggnation, `artist` is empty and
// `album` carries the show, where a song fills artist and puts the record in
// album. So both are tried, artist first, which is also the right order for a
// podcast client that names the show there. The episode title is the last
// resort, because an over-long label still beats an empty pill.
func podcastShowName(title: String, artist: String, album: String) -> String {
    [artist, album]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? title
}

// A YouTube title usually carries the channel already, so the pill was reading
// "Rick Astley - Never Gonna Give You Up (Official Video) ~ Rick Astley". The
// trailing copy is width spent saying it twice. Only a title that genuinely
// opens with the channel name loses it, so a channel that is not in the title
// still shows.
func dropRedundantArtist(title: String, artist: String) -> String {
    let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          title.lowercased().hasPrefix(trimmed.lowercased())
    else { return artist }
    return ""
}

// Browsers publish a media session per tab and none of them say which site it
// came from: the payload carries the title, the channel as `artist`, a thumbnail
// and the browser's own bundle id, but no URL. Asking the browser for its active
// tab over AppleScript would settle it, at the price of an Automation prompt and
// a round trip on every track, and the active tab is not reliably the one that
// is playing anyway. So a wide thumbnail from a browser is called YouTube, which
// is right for every video this machine actually plays and wrong for the odd
// Vimeo embed.
let browserBundleIDs: Set<String> = [
    "company.thebrowser.dia",
    "company.thebrowser.browser",
    "com.apple.safari",
    "com.google.chrome",
    "com.brave.browser",
    "org.mozilla.firefox",
    "com.microsoft.edgemac",
    "com.vivaldi.vivaldi",
    "com.operasoftware.opera",
]

let callBundleIDs: Set<String> = [
    "com.microsoft.teams2",
    "com.microsoft.teams",
    "us.zoom.xos",
    "com.apple.facetime",
    "com.cisco.webexmeetingsapp",
    "com.tinyspeck.slackmacgap",
]

/// A call app, or any of its helpers. A Teams meeting's media session comes
/// from `com.microsoft.teams2.modulehost`, not the app's own id, and matching
/// only the exact id let it through as music: a meeting showed as a spinning
/// record (2026-10-06).
func isCallApp(_ bundleID: String) -> Bool {
    callBundleIDs.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") } || bundleID == "com.microsoft.vcxpc"
}

func classifySource(_ payload: [String: Any], artwork: CGImage?) -> MediaSource {
    let bundleID = (payload["bundleIdentifier"] as? String ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    // A dedicated client is the one case that needs no inference at all, so it
    // is settled before anything starts measuring pixels. Podcast art is square,
    // so the aspect test below would never have caught it anyway.
    if isPodcastApp(bundleID) { return .podcast }
    if bundleID == spotifyBundleID {
        if let id = payload["contentItemIdentifier"] as? String, let known = knownSpotifyKind(id) {
            return known ? .podcast : .music
        }
        return spotifyMetadataLooksLikeEpisode(payload) ? .podcast : .music
    }
    if isCallApp(bundleID) { return .call }
    let wide = (artworkAspect(artwork) ?? 0) >= videoAspectThreshold
    if browserBundleIDs.contains(bundleID) {
        // What the browser said the tab is, once it has been asked (see
        // confirmWebSource); until then the thumbnail's shape decides.
        let title = payload["title"] as? String ?? ""
        if case .some(.some(let service)) = knownService(bundleID: bundleID, title: title) {
            return .service(service)
        }
        return wide ? .youtube : .browser
    }
    if wide { return hasAppIcon(bundleID) ? .videoApp(bundleID) : .video }
    return .music
}

// Whether a bundle id belongs to an installed app, asked once per id: a video
// app gets its own icon, and an unknown one keeps the record dot.
var appIconKnown: [String: Bool] = [:]
let appIconLock = NSLock()
func hasAppIcon(_ bundleID: String) -> Bool {
    guard !bundleID.isEmpty else { return false }
    appIconLock.lock()
    defer { appIconLock.unlock() }
    if let known = appIconKnown[bundleID] { return known }
    let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    appIconKnown[bundleID] = found
    return found
}

/// Marks drawn by mediaservice.swift rather than as an SF Symbol, which rest on
/// the same frame and show at the same scale as the symbol icons.
func drawnAsMark(_ source: MediaSource) -> Bool {
    switch source {
    case .service(let service): return glyphMark(for: service) != nil || standInApp(for: service) != nil
    case .videoApp, .silence: return true
    default: return false
    }
}

func parsePayload(_ payload: [String: Any]) -> (NowPlaying, CGImage?)? {
    if payload.isEmpty { return nil }
    // Cleaned here rather than at draw time, so the cleaned pair is what lands in
    // NowPlaying. Everything downstream compares on it: two payloads that differ
    // only in some remaster tag now count as the same track and skip a repaint.
    let title = cleanTitle(sanitizeLabel(payload["title"] as? String ?? ""))
    let artist = cleanArtist(sanitizeLabel(payload["artist"] as? String ?? ""))
    guard !title.isEmpty || !artist.isEmpty else { return nil }
    // Lowercased to match how classifySource compares it, so the two can never
    // disagree about whether this is Spotify.
    let bundleID = (payload["bundleIdentifier"] as? String ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    let playing: Bool
    if let b = payload["playing"] as? Bool {
        playing = b
    } else if let n = payload["playing"] as? NSNumber {
        playing = n.boolValue
    } else {
        playing = false
    }
    var image: CGImage?
    var key = cachePrefix + "fallback"
    if let mime = payload["artworkMimeType"] as? String,
       let data = payload["artworkData"] as? String,
       let decoded = decodeArtwork(data, mime: mime)
    {
        image = decoded
        key = artworkKey(from: data)
    }
    let displayMode: MediaDisplayMode = isSpotifyDJ(payload) ? .spotifyDJ : .track
    let source = classifySource(payload, artwork: image)
    // Substituted here rather than at draw time for the same reason the cleaning
    // is: what lands in NowPlaying is what everything downstream compares on, so
    // the label budget and the artist-dropping both reason about the text that
    // is actually on screen.
    let shown: (title: String, artist: String)
    switch source {
    case .podcast:
        let album = sanitizeLabel(payload["album"] as? String ?? "")
        // Artist is emptied so applyTrackVisible drops the separator and the
        // artist item outright, rather than leaving a `~` with nothing after it.
        shown = (podcastShowName(title: title, artist: artist, album: album), "")
    case .video, .youtube, .videoApp:
        shown = (title, dropRedundantArtist(title: title, artist: artist))
    case .service(let service) where service.isVideo:
        shown = (title, dropRedundantArtist(title: title, artist: artist))
    case .music, .browser, .call, .service, .silence:
        shown = (title, artist)
    }
    // The shape is folded into the key rather than kept alongside it, and that is
    // what makes a re-classification take effect: `drawTrack` decides whether to
    // re-render by comparing this key, so the Spotify probe correcting a track
    // from music to podcast has to change it or the correction is skipped as an
    // artwork already on disk.
    return (
        NowPlaying(
            title: shown.title,
            artist: shown.artist,
            playing: playing,
            artworkKey: discCacheKey(artworkHash: key, source: source),
            displayMode: displayMode,
            source: source,
            bundleID: bundleID
        ),
        image
    )
}

func handleLine(_ line: String) {
    guard let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return }
    let payload = obj["payload"] as? [String: Any] ?? [:]
    guard let parsed = parsePayload(payload) else {
        scheduleApply(nil, artwork: nil)
        return
    }
    scheduleApply(parsed.0, artwork: parsed.1)
    confirmSpotifySource(payload, drawn: parsed.0)
    confirmWebSource(payload, drawn: parsed.0)
}

// The browser twin of confirmSpotifySource: the pill goes up with the guess,
// the browser is asked which tab is playing, and a different answer re-parses
// and re-commits, so the mark, the cache key and the frames move together.
func confirmWebSource(_ payload: [String: Any], drawn: NowPlaying) {
    let bundleID = (payload["bundleIdentifier"] as? String ?? "").lowercased()
    let title = payload["title"] as? String ?? ""
    guard browserBundleIDs.contains(bundleID), !title.isEmpty,
          knownService(bundleID: bundleID, title: title) == nil
    else { return }
    lookUpService(bundleID: bundleID, title: title) { _ in
        guard let corrected = parsePayload(payload), corrected.0.source != drawn.source,
              lastApplied?.title == drawn.title, lastApplied?.artist == drawn.artist
        else { return }
        scheduleApply(corrected.0, artwork: corrected.1)
    }
}

// Runs after the frame is already on its way to the screen, so the 144ms this
// costs is spent behind a pill that is already correct in the common case rather
// than in front of one that is not there yet.
//
// A correction only re-commits when the answer disagrees with what the metadata
// heuristic picked, and it re-parses instead of patching `source` by hand so the
// cache key, the shape and the frames all move together. The payload is captured
// rather than re-read: by the time the answer lands the stream may have moved on,
// and the check guards against applying it to a different track.
func confirmSpotifySource(_ payload: [String: Any], drawn: NowPlaying) {
    guard (payload["bundleIdentifier"] as? String)?.lowercased() == spotifyBundleID,
          drawn.displayMode != .spotifyDJ,
          let id = payload["contentItemIdentifier"] as? String
    else { return }
    probeSpotifyKind(id: id) { _ in
        guard let corrected = parsePayload(payload), corrected.0.source != drawn.source,
              lastApplied?.title == drawn.title, lastApplied?.artist == drawn.artist
        else { return }
        scheduleApply(corrected.0, artwork: corrected.1)
    }
}

func startStream() {
    var backoff: TimeInterval = 0.4
    while true {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: mediaControlBin)
        // The debounce stays at 100. Lowering it to 30 was tried for the pause
        // latency and measured identical: a pause reaches this stream 93ms after
        // the keypress either way, so the window is not what the pill was waiting
        // on. That 93ms is Spotify and MediaRemote, and it is the floor.
        task.arguments = ["stream", "--no-diff", "--debounce=100"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            logErr("cannot start media-control: \(error)")
            Thread.sleep(forTimeInterval: backoff)
            backoff = min(backoff * 2, 8)
            continue
        }
        backoff = 0.4
        let handle = pipe.fileHandleForReading
        var buffer = Data()
        while task.isRunning {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let range = buffer.range(of: Data([0x0A])) {
                let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex...range.lowerBound)
                if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                    handleLine(line)
                }
            }
        }
        task.waitUntilExit()
        logErr("media-control stream exited (\(task.terminationStatus)), retrying")
        Thread.sleep(forTimeInterval: backoff)
        backoff = min(backoff * 2, 8)
    }
}

// Self-test only: a plain opaque bitmap of a given shape, so the crop maths can
// be checked without shipping a fixture image.
func solidImage(width: Int, height: Int) -> CGImage? {
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.setFillColor(CGColor(red: 0.5, green: 0.2, blue: 0.7, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()
}

func selfTest() -> Int {
    var failures = 0
    func expect(_ ok: Bool, _ name: String) {
        if !ok {
            logErr("self-test failed: \(name)")
            failures += 1
        }
    }
    expect(decodeArtwork("@@@@", mime: "image/jpeg") == nil, "rejects malformed base64")
    fitSelfTest(expect)
    serviceSelfTest(expect)
    expect(decodeArtwork("aaaa", mime: "image/svg+xml") == nil, "rejects svg mime")
    expect(decodeArtwork("aaaa", mime: "text/plain") == nil, "rejects text mime")
    let huge = String(repeating: "A", count: (maxArtworkBytes + 16) * 2)
    expect(decodeArtwork(huge, mime: "image/jpeg") == nil, "rejects oversized artwork")
    // Every teardown path sends this one message, so an item missing from it is
    // an item that stays on screen alone.
    expect(mediaItems.contains("media_wave"), "mediaItems includes the DJ waveform")
    for item in mediaItems {
        expect(hideAll.contains(item), "hideAll covers \(item)")
    }
    expect(hideAll.count == mediaItems.count * 3, "hideAll is three tokens per item")

    // Transitions. A fade that does not land exactly on the resting colour
    // leaves the pill permanently a shade off, and one that does not land on
    // 1.000 leaves the disc permanently resampled.
    expect(fadedColor(playingColor, 1) == playingColor, "full fade is the original colour")
    expect(fadedColor(playingColor, 0).hasPrefix("0x00"), "empty fade is fully transparent")
    expect(
        fadedColor(playingColor, 0).dropFirst(4) == playingColor.dropFirst(4),
        "fading keeps the rgb and only moves alpha")
    expect(fadedColor(pausedColor, 2) == pausedColor, "fade amount is clamped at one")
    expect(fadedColor("nonsense", 0.5) == "nonsense", "a colour it cannot parse is left alone")
    // Every waveform assertion below reasons about the fallback width, since
    // the real width now depends on whatever title happens to be playing.
    let bars = waveformBars(forWidth: waveformFallbackWidth)

    // The handoff frames. The two endpoints are load-bearing: index 0 has to be
    // a silent invisible row for the entrance to start from nothing, and the
    // last index has to match the running loop or the handover is a visible step.
    let silent = waveformHeights(frame: 0, barCount: bars, amplitude: 0)
    expect(silent.allSatisfy { $0 == 2 }, "entry frame 0 is a flat line")
    expect(
        silent.count == bars,
        "a flat line still has every bar")
    expect(
        waveformHeights(frame: 0, barCount: bars, amplitude: 1) == waveformHeights(frame: 0, barCount: bars),
        "full amplitude is the unmodified loop frame")
    expect(
        waveformHeights(frame: 5, barCount: bars, amplitude: 0.5).enumerated().allSatisfy { i, h in
            h <= waveformHeights(frame: 5, barCount: bars)[i]
        },
        "amplitude only ever reduces a bar")
    expect(waveformEntryCount > 1, "the entry set has a span to interpolate over")
    // The pill is never allowed to be empty, so the frame the text hands over to
    // has to be a line you can see rather than a blank plate.
    expect(
        waveformEntryOpacityFloor > 0.2 && waveformEntryOpacityFloor < 1,
        "the entry set starts visible and still has somewhere to rise to")
    expect(
        waveformHeights(frame: 0, barCount: 43, amplitude: 0).allSatisfy { $0 == 2 },
        "the entry set's first frame is the flat row, not nothing")

    // Pill measurement. Feeding a measured pill back through the formula has to
    // give a wave that reproduces that same pill, or the DJ handoff resizes it.
    expect(
        waveWidth(forPill: 203) + waveformPaddingTotal == 203,
        "a pill is taken over at exactly its own width")
    expect(waveWidth(forPill: 0) >= 1, "an absurd pill still yields a legal width")
    expect(
        itemRect(fromQuery: [
            "bounding_rects": [
                "display-1": ["origin": [1644.0, 6.0], "size": [104.0, 34.0]]
            ]
        ])?.width == 104,
        "an item rect is read out of bounding_rects")
    expect(
        itemRect(fromQuery: [
            "bounding_rects": [
                "display-1": ["origin": [1644.0, 6.0], "size": [104.0, 34.0]],
                "display-2": ["origin": [-796.0, -927.0], "size": [104.0, 34.0]],
            ]
        ])?.origin == 1644,
        "the on-screen display wins over one parked at a negative origin")
    expect(itemRect(fromQuery: [:]) == nil, "a query with no rects measures nothing")

    // The capsule's fade. Full presence has to reproduce the configured colours
    // byte for byte, or the pill drifts a shade every time it is hidden and shown.
    expect(
        fadedColor(pillColor, 1) == pillColor && fadedColor(pillBorderColor, 1)
            == pillBorderColor && fadedColor(pillShadowColor, 1) == pillShadowColor,
        "full presence hands the pill's own colours back unchanged")
    expect(
        pillChromeArgs(1).contains("background.color=\(pillColor)"),
        "the chrome message carries the configured fill at full presence")
    expect(
        pillChromeArgs(0).filter { $0.contains("=0x") }.allSatisfy { $0.contains("=0x00") },
        "zero presence leaves fill, border and shadow all fully transparent")
    expect(
        pillChromeArgs(0.5).count == pillChromeArgs(1).count
            && pillChromeArgs(1).first == "--set",
        "the chrome message shape does not depend on how faded it is")

    // The entry bug, twice over. A track ending emits metadata-less payload,
    // which has to keep parsing as no state at all (there is nothing to draw),
    // while `commit` holds the pill up across it instead of taking that nil as
    // "playback is over". Getting either half wrong puts the DJ back on an empty
    // bar with no state to fade from.
    expect(
        parsePayload(["title": "", "artist": "", "playing": true]) == nil,
        "a track ending parses as no state at all")
    expect(
        emptyPayloadGrace > transitionDuration * 2,
        "the gap outlasts a handoff, so the fade is never cut short by a hide")
    let present = NowPlaying(
        title: "t", artist: "a", playing: true, artworkKey: "k", displayMode: .track,
        source: .music, bundleID: spotifyBundleID)
    expect(
        discScaleArg(1, state: present) == scaleArg(restingDiscScale(present)),
        "a present cover sits at its resting scale")
    expect(discScaleArg(0, state: present) == "0.000", "a gone cover scales all the way out")
    expect(
        discScaleArg(-1, state: present) == "0.000" && discScaleArg(2, state: present)
            == scaleArg(restingDiscScale(present)),
        "an out-of-range tween value cannot oversize the cover")
    // Source classification. The measurements these assert against are the ones
    // taken off the real payloads on 2026-09-09: Spotify sends a 600x600 cover
    // with an album and a track number, a YouTube tab in Dia sends a 150x83
    // thumbnail with neither and no mediaType at all.
    // Both payloads below are the real measured ones, 2026-09-09.
    let spotifySong: [String: Any] = [
        "bundleIdentifier": "com.spotify.client",
        "title": "Make Them Remember",
        "artist": "Drake",
        "album": "ICEMAN",
        "trackNumber": 14,
        "contentItemIdentifier": "song-1",
    ]
    let spotifyEpisode: [String: Any] = [
        "bundleIdentifier": "com.spotify.client",
        "title": "Is College Still Worth It When Entry-Level Jobs Are Disappearing?",
        "artist": "",
        "album": "Diggnation (Rebooted)",
        "trackNumber": 0,
        "contentItemIdentifier": "episode-1",
    ]
    expect(classifySource(spotifySong, artwork: nil) == .music, "a Spotify song is music")
    expect(
        !spotifyMetadataLooksLikeEpisode(spotifySong),
        "an artist and a track number rule out an episode")
    // The regression that mattered: the first heuristic tested for a missing
    // album and a missing track number, and a real episode has both. Keying on
    // the album would send every episode down the music path.
    expect(
        spotifyMetadataLooksLikeEpisode(spotifyEpisode),
        "an episode has no artist and track number 0, and its album is the show")
    expect(
        !(spotifyEpisode["album"] as? String ?? "").isEmpty
            && spotifyEpisode["trackNumber"] != nil,
        "the episode fixture really does carry an album and a track number")
    expect(classifySource(spotifyEpisode, artwork: nil) == .podcast, "so it classifies as one")
    // A single is one track but still has an artist and a track number, so it
    // must not fall down the podcast path.
    expect(
        classifySource(
            [
                "bundleIdentifier": "com.spotify.client", "artist": "Someone",
                "album": "Single", "trackNumber": 1,
            ], artwork: nil) == .music,
        "a one-track single is still music")
    expect(
        classifySource(["bundleIdentifier": "com.apple.podcasts"], artwork: nil) == .podcast,
        "a dedicated podcast client needs no inference")
    expect(
        isPodcastApp("au.com.shiftyjelly.pocketcasts.osx") && isPodcastApp("fm.overcast.mac"),
        "the substrings carry the clients that are not named outright")
    expect(!isPodcastApp("") && !isPodcastApp("com.spotify.client"), "no false podcast matches")
    // Podcast art is square, so a podcast client must win before the aspect test
    // rather than after it, and square art must never read as video.
    guard let squareArt = solidImage(width: 600, height: 600),
          let wideArt = solidImage(width: 150, height: 83)
    else { return failures + 1 }
    // A browser is recognised before the aspect test, so a wide thumbnail from
    // one is YouTube and square art from one is a browser tab, never music or a
    // generic video. The aspect still decides for everything that is not a
    // browser, which the IINA case covers.
    expect(
        classifySource(["bundleIdentifier": "company.thebrowser.dia"], artwork: wideArt)
            == .youtube,
        "a 150x83 thumbnail from a browser is a YouTube video")
    expect(
        classifySource(["bundleIdentifier": "company.thebrowser.dia"], artwork: squareArt)
            == .browser,
        "square art from a browser is a browser tab, not a cover")
    expect(
        classifySource(["bundleIdentifier": "com.colliderli.iina"], artwork: wideArt)
            == .video,
        "a wide thumbnail from a native player is still a video frame")
    expect(
        classifySource(["bundleIdentifier": "com.microsoft.teams2"], artwork: squareArt)
            == .call,
        "Teams is a call whatever art it sends")
    expect(
        classifySource(["bundleIdentifier": "com.microsoft.teams2.modulehost"], artwork: squareArt) == .call,
        "a Teams meeting's helper is a call, not a record")
    expect(callAppName("com.microsoft.teams2.modulehost") == "Teams", "the call is named after its app")
    expect(steadyClock("11:11") == "00:00" && steadyClock("1:08:47") == "0:00:00" && steadyClock("Meeting") == "Meeting",
           "a running clock is measured on zeros, words are left alone")
    expect(
        slotIcon(for: .youtube) != nil && slotIcon(for: .browser) != nil
            && slotIcon(for: .call) != nil && slotIcon(for: .music) == nil,
        "every icon source has an icon and the drawn shapes do not")
    expect(
        classifySource(["bundleIdentifier": "com.apple.podcasts"], artwork: squareArt)
            == .podcast,
        "a podcast client is settled before anything measures the artwork")
    expect(artworkAspect(nil) == nil, "no artwork has no aspect to test")
    // Cache keys. Music has to keep the bare hash or every cover already on disk
    // re-renders, and the other two have to differ from it or a banner and a
    // disc of the same cover overwrite each other frame for frame.
    expect(discCacheKey(artworkHash: "abc", source: .music) == "abc", "music keeps the bare hash")
    expect(
        discCacheKey(artworkHash: "abc", source: .video) != "abc"
            && discCacheKey(artworkHash: "abc", source: .podcast) != "abc",
        "the other two shapes cache somewhere else")
    expect(
        discCacheKey(artworkHash: "abc", source: .podcast)
            == discCacheKey(artworkHash: "xyz", source: .podcast),
        "the waveform is artwork-independent, so every episode shares one render")

    // Shapes. All three share the slot, so no source change moves the pill's
    // width, and only music wants a radius.
    expect(
        discShapeArgs(.music).contains("background.image.corner_radius=\(discCornerRadius)")
            && discShapeArgs(.music).contains("width=\(discItemWidth)"),
        "music is a round cover in the narrow slot")
    expect(
        discShapeArgs(.podcast).contains("background.image.corner_radius=0"),
        "rounding a row of bars would clip the outer two")
    expect(
        discShapeArgs(.video).contains("width=\(discItemWidth)")
            && discShapeArgs(.video).contains("background.image.corner_radius=0"),
        "a video dot sits in the disc's own slot, with no edge to round")
    expect(dotDiameter <= CGFloat(dotPixelSize), "the dot cannot be clipped by its canvas")

    // The blink. Brightest at frame 0, dimmest half way, never off, and never
    // over: an alpha above 1 is a silent clamp that would flatten the top of the
    // curve into a hold.
    expect(dotAlpha(frame: 0, count: dotFrameCount) == 1, "a fresh dot starts bright")
    expect(
        abs(dotAlpha(frame: dotRestFrame, count: dotFrameCount) - dotAlphaFloor) < 0.001,
        "the dimmest frame is the floor, and it is where a paused dot rests")
    let alphas = (0..<dotFrameCount).map { dotAlpha(frame: $0, count: dotFrameCount) }
    expect(
        alphas.allSatisfy { $0 >= dotAlphaFloor - 0.001 && $0 <= 1.001 },
        "every frame of the blink stays inside its own range")
    expect(
        dotAlpha(frame: dotFrameCount, count: dotFrameCount) == alphas[0],
        "the cycle closes, so the loop has no seam")
    // The pull towards bright is the whole difference between a blink and a
    // strobe, so assert it rather than trusting the exponent.
    expect(
        alphas.filter({ $0 > (1 + dotAlphaFloor) / 2 }).count > dotFrameCount / 2,
        "the dot spends more of the cycle bright than dim")

    // The small waveform. Six bars is what fits; fewer than four stops reading as
    // a waveform at all, and the DJ row's own margin would leave room for none.
    let discBars = waveformBars(forWidth: slotPixelSize, sideMargin: discWaveSideMargin)
    expect(discBars >= 4, "the disc-sized waveform still has bars to draw")
    expect(
        CGFloat(discBars) * waveformBarWidth + CGFloat(discBars - 1) * waveformBarGap
            <= CGFloat(slotPixelSize),
        "the bars fit inside the slot they are drawn in")
    expect(
        waveformBars(forWidth: waveformFallbackWidth) == bars,
        "the DJ row's bar count is unchanged by the margin becoming a parameter")

    // The Spotify URI, which is the authoritative half. Only the two prefixes
    // mean anything, and an empty answer has to stay "no answer" so a refused
    // Automation prompt leaves the metadata heuristic in charge rather than
    // reporting every episode as a song.
    expect(
        spotifyURIIsEpisode("spotify:episode:5abc") == true,
        "an episode URI is an episode")
    expect(
        spotifyURIIsEpisode("spotify:track:4DMKwE2E2iYDKY01C335Uw") == false,
        "a track URI is not")
    expect(
        spotifyURIIsEpisode("  SPOTIFY:EPISODE:5abc\n") == true,
        "the answer arrives off a pipe, so it is trimmed and case-folded")
    expect(spotifyURIIsEpisode("") == nil, "no answer is not the same as a no")
    expect(spotifyURIIsEpisode("spotify:ad:1") == false, "an ad is not a podcast")

    // Labels. The complaint that produced these was that a podcast and a YouTube
    // video both pushed the pill to most of the screen width, and the episode
    // titles measured below are why: the one global budget of 86 characters was
    // never anywhere near being reached.
    let episodeTitle = "Is College Still Worth It When Entry-Level Jobs Are Disappearing?"
    let ytTitle = "Rick Astley - Never Gonna Give You Up (Official Video)"
    expect(
        episodeTitle.count < labelMaxChars && ytTitle.count < labelMaxChars,
        "both real titles fitted the old budget, which is why neither ever clipped")
    expect(
        videoLabelMaxChars < episodeTitle.count && videoLabelMaxChars < ytTitle.count,
        "and both exceed the tighter one, so both actually shorten")
    // A podcast shows the show. On Spotify that is the album, because artist is
    // empty; on a client that names the show in artist, that wins.
    expect(
        podcastShowName(title: episodeTitle, artist: "", album: "Diggnation (Rebooted)")
            == "Diggnation (Rebooted)",
        "an empty artist falls through to the album, which is where Spotify puts the show")
    expect(
        podcastShowName(title: episodeTitle, artist: "Techlore", album: "") == "Techlore",
        "an artist that is set is the show name")
    expect(
        podcastShowName(title: episodeTitle, artist: "  ", album: " ") == episodeTitle,
        "with no show name at all the episode title beats an empty pill")
    guard let parsedEpisode = parsePayload(spotifyEpisode) else { return failures + 1 }
    expect(
        parsedEpisode.0.title == "Diggnation (Rebooted)" && parsedEpisode.0.artist.isEmpty,
        "a parsed episode carries the show alone, so the separator and artist drop out")
    // The channel is already in a YouTube title, so repeating it is spent width.
    expect(
        dropRedundantArtist(title: ytTitle, artist: "Rick Astley").isEmpty,
        "a title that opens with the channel does not also end with it")
    expect(
        dropRedundantArtist(title: ytTitle, artist: "Some Other Channel") == "Some Other Channel",
        "a channel the title does not name is kept")
    expect(
        dropRedundantArtist(title: "anything", artist: "") == "",
        "no channel stays no channel")
    // Clipping. The mark has to come out of the budget, or a shortened label is
    // wider than one that fitted, which defeats the point.
    let clippedYT = clipLabel(ytTitle, to: videoLabelMaxChars)
    expect(
        clippedYT.count <= videoLabelMaxChars && clippedYT.hasSuffix("\u{2026}"),
        "a clipped label stays inside the budget and says it was clipped")
    expect(
        clippedYT == "Rick Astley - Never Gonna Give You Up\u{2026}",
        "it breaks on the word boundary instead of leaving \"(Of\" hanging")
    expect(clipLabel("Short", to: 42) == "Short", "a label inside the budget is untouched")
    expect(
        !clipLabel("Some Title That Runs On Quite A Way", to: 20).contains(" \u{2026}"),
        "the ellipsis never hangs off a space or a dangling bracket")
    // A single long word has no boundary worth finding, so a mid-word cut is
    // right there and the floor is what allows it.
    let oneWord = String(repeating: "W", count: 60)
    expect(
        clipLabel(oneWord, to: 20).count == 20,
        "an unbreakable word still fills the budget rather than collapsing")
    expect(
        composeParts(title: ytTitle, artist: "Rick Astley", budget: videoLabelMaxChars)
            .title.count <= videoLabelMaxChars,
        "the budget the pill is drawn with is the one composeParts honours")
    expect(
        composeParts(title: "Kick Push", artist: "Lupe Fiasco", budget: labelMaxChars)
            == ("Kick Push", "Lupe Fiasco"),
        "music is unaffected by any of this")
    // The pill's closing gap. Without this the title sits flush against the
    // capsule's border whenever the artist is hidden, while the disc keeps its
    // 8pt on the other side, which is what "gaps on the end are bugged" was.
    expect(pillTextPad > 0, "there is a trailing pad to hand over in the first place")

    // The two new renderers, run for real. Dimensions matter because SketchyBar
    // clips an image to the item's slot, and "not blank" matters because a
    // context that fails halfway still produces a writable PNG: the earlier
    // waveform entry ramp shipped an invisible first frame exactly that way.
    func opaquePixelCount(_ url: URL) -> Int {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let data = image.dataProvider?.data as Data?
        else { return 0 }
        return stride(from: 3, to: data.count, by: 4).reduce(0) {
            data[$1] > 0 ? $0 + 1 : $0
        }
    }

    // Coverage and brightness are different questions, and the blink only
    // changes the second one: the dot's geometry is identical in every frame, so
    // opaquePixelCount is the same for the bright frame and the dim one. This
    // sums the alpha channel instead.
    func inkWeight(_ url: URL) -> Int {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let data = image.dataProvider?.data as Data?
        else { return 0 }
        return stride(from: 3, to: data.count, by: 4).reduce(0) { $0 + Int(data[$1]) }
    }

    if let waveFrames = try? renderDiscWaveFrames(key: cachePrefix + "selftest-wave") {
        expect(
            waveFrames.count == waveformFrameCount,
            "the disc waveform is a full loop, not a single frame")
        let sizes = waveFrames.prefix(3).compactMap { url -> (Int, Int)? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
            else { return nil }
            return (image.width, image.height)
        }
        expect(
            sizes.count == 3 && sizes.allSatisfy { $0 == (slotPixelSize, slotPixelSize) },
            "every waveform frame is exactly the disc's slot")
        expect(
            waveFrames.allSatisfy { opaquePixelCount($0) > 0 },
            "no waveform frame is blank, including the first")
        try? FileManager.default.removeItem(
            at: waveFrames[0].deletingLastPathComponent())
    } else {
        expect(false, "the disc waveform renders at all")
    }

    if let dots = try? renderRecordDotFrames(key: cachePrefix + "selftest-recdot") {
        expect(dots.count == dotFrameCount, "the dot renders a full cycle")
        if let src = CGImageSourceCreateWithURL(dots[0] as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        {
            expect(
                image.width == dotPixelSize && image.height == slotPixelSize,
                "the dot's canvas is the disc's slot")
        } else {
            expect(false, "the dot is a readable image")
        }
        // Every frame has ink, or the blink has a hole in it. The bright frame
        // weighs more than the dim one, which is the only proof the alpha curve
        // actually reaches the pixels rather than just the numbers.
        expect(
            dots.allSatisfy { opaquePixelCount($0) > 0 },
            "no frame of the blink is empty, so the dot never disappears")
        expect(
            inkWeight(dots[0]) > inkWeight(dots[dotRestFrame]),
            "the bright frame carries more ink than the resting one")
        expect(
            Double(inkWeight(dots[dotRestFrame])) / Double(max(1, inkWeight(dots[0]))) > 0.2,
            "the resting dot is dimmer but still plainly there")
        // A dot, not a plate: it must not fill the canvas it is drawn on.
        let canvas = dotPixelSize * slotPixelSize
        expect(
            opaquePixelCount(dots[0]) < canvas / 2,
            "the dot leaves most of its slot empty, which is what makes it a dot")
        try? FileManager.default.removeItem(at: dots[0].deletingLastPathComponent())
    } else {
        expect(false, "the record dot renders at all")
    }
    // The dot needs no artwork, which is the point: a web video with no artwork
    // used to be a pill that vanished, because a failed render calls hidePlayer.
    expect(
        discCacheKey(artworkHash: "abc", source: .video)
            == discCacheKey(artworkHash: "", source: .video),
        "the dot does not depend on artwork, so a video without any still draws")

    // MARK: live audio levels
    //
    // The tap itself needs a TCC grant and a running Spotify, so none of this
    // touches one. The transform and the band mapping are pure, and they are
    // where the bugs actually are: an FFT with the packing or the scaling wrong
    // still draws a plausible-looking waveform, which is the worst kind of wrong.
    let fftRate: Double = 48000
    if let fft = vDSP_create_fftsetup(tapLog2n, FFTRadix(kFFTRadix2)) {
        let hann = tapHannWindow(tapWindowSize)
        func tone(_ hz: Double, _ amplitude: Float = 1) -> [CGFloat] {
            let samples = (0..<tapWindowSize).map { i in
                amplitude * sinf(Float(2 * Double.pi * hz * Double(i) / fftRate))
            }
            return tapBands(
                magnitudes: tapBinMagnitudes(samples: samples, window: hann, setup: fft),
                sampleRate: fftRate, bands: 6)
        }
        expect(1 << Int(tapLog2n) == tapWindowSize, "log2n and the window size agree")
        expect(
            hann[0] < 0.01 && hann[tapWindowSize / 2] > 0.99,
            "the window is a Hann shape, which is what keeps one tone off every bar")
        expect(
            tone(0, 0).allSatisfy { $0 == 0 },
            "silence puts every band on the floor")
        // Six bands log-spaced over 60Hz..6kHz step by 100^(1/6), so the edges are
        // 60, 129, 278, 600, 1292, 2783, 6000. Worth writing out: the first
        // version of this expected 1kHz in band 2, a full octave off.
        for (hz, band) in [(100.0, 0), (200.0, 1), (1000.0, 3), (4000.0, 5)] {
            let measured = tone(hz)
            let loudest = measured.enumerated().max(by: { $0.element < $1.element })?.offset
            expect(loudest == band, "\(Int(hz))Hz is loudest in band \(band)")
        }
        // The top edge is a display range, so content above it is not drawn at all
        // rather than folded into the last bar. Asserted because the alternative
        // reads identically on music and would quietly pin the last bar again.
        expect(
            (tone(11000).max() ?? 1) < 0.1,
            "a tone above the top edge does not light a bar")
        let full = tone(1000)
        expect(full.max() ?? 0 > 0.95, "a full-scale tone nearly fills its bar")
        expect(full.max() ?? 2 <= 1, "and never overflows it, which would clip silently")
        expect(
            (tone(1000, 0.1).max() ?? 0) < (full.max() ?? 0),
            "quieter audio draws a shorter bar")
        expect((tone(1000, 0.1).max() ?? 0) > 0, "but -20dB is not silence")
        if let peak = full.enumerated().max(by: { $0.element < $1.element })?.offset {
            expect(
                full.enumerated().filter({ $0.offset != peak })
                    .allSatisfy { $0.element < full[peak] * 0.8 },
                "one tone does not lift every bar together")
        }
        vDSP_destroy_fftsetup(fft)
    } else {
        expect(false, "the FFT setup can be created at all")
    }
    expect(
        tapBands(magnitudes: [], sampleRate: fftRate, bands: 6).count == 6
            && tapBands(magnitudes: [1, 1], sampleRate: 0, bands: 6).count == 6,
        "degenerate spectra still return one value per bar rather than crashing")

    // Measured levels replace the texture and the envelope, not the geometry.
    let liveHeights = waveformHeights(frame: 0, barCount: 4, levels: [0, 1, 0, 1])
    expect(
        liveHeights[0] == 2 && liveHeights[1] > liveHeights[0],
        "a silent band sits on the 2px floor and a loud one stands up")
    expect(
        liveHeights.allSatisfy { $0 <= CGFloat(waveformPixelHeight - 2) },
        "no measured level can draw outside the slot")
    expect(
        waveformHeights(frame: 0, barCount: 4, amplitude: 0, levels: [1, 1, 1, 1])
            .allSatisfy { $0 == 2 },
        "amplitude 0 collapses a live row too, which is what the DJ handoff rides on")
    expect(
        waveformHeights(frame: 0, barCount: 6, levels: [0.5]).count == 6,
        "a level count that does not match the bar count is resampled, not indexed off the end")
    expect(
        waveformHeights(frame: 3, barCount: 6, levels: nil)
            == waveformHeights(frame: 3, barCount: 6),
        "no levels means the drawn waveform, unchanged")

    // Smoothing is expressed in time, so the same tuning has to survive a change
    // of tick rate. A one-pole filter closes ~63% of the gap in one time constant.
    expect(
        abs(levelCoefficient(dt: levelAttackTau, tau: levelAttackTau) - 0.6321) < 0.001,
        "one time constant of elapsed time closes 63% of the gap")
    expect(
        levelCoefficient(dt: 1.0 / 60.0, tau: levelAttackTau)
            < levelCoefficient(dt: 1.0 / 24.0, tau: levelAttackTau),
        "a shorter frame smooths harder, which is what keeps 60fps from being twitchier than 24")
    expect(
        levelCoefficient(dt: 10, tau: levelAttackTau) == 1
            && levelCoefficient(dt: 0, tau: levelAttackTau) == 1
            && levelCoefficient(dt: 0.02, tau: 0) == 1,
        "a long stall lands on the target instead of overshooting, and zero values do not divide")
    expect(
        levelCoefficient(dt: 1.0 / 60.0, tau: levelReleaseTau)
            < levelCoefficient(dt: 1.0 / 60.0, tau: levelAttackTau),
        "release is the slower of the two, so bars fall away rather than snap down")

    // Music and podcasts step at 60fps on the 60fps tick; the rest keep 24.
    var probeIndex = 0
    var probeClock: TimeInterval = 0
    var advances = 0
    for _ in 0..<60 {
        if advanceCanned(
            &probeIndex, count: 1000, clock: &probeClock, interval: slotRestInterval)
        {
            advances += 1
        }
    }
    expect(
        advances == 24 && probeIndex == 24,
        "one second of 60fps ticks steps a 24fps sequence exactly 24 times, got \(advances)")
    expect(slotInterval(for: .music) == spinInterval && slotInterval(for: .podcast) == waveformInterval
            && slotInterval(for: .video) == slotRestInterval,
           "the cover and the bars run at 60, the rest at 24")
    var driftIndex = 0
    var driftClock: TimeInterval = 0
    var driftAdvances = 0
    for _ in 0..<600 {
        if advanceCanned(
            &driftIndex, count: 1000, clock: &driftClock, interval: spinInterval)
        {
            driftAdvances += 1
        }
    }
    expect(
        driftAdvances == 600,
        "carrying the remainder keeps the cover at 2.5s per turn over ten seconds, got \(driftAdvances)")
    var emptyIndex = 0
    var emptyClock: TimeInterval = 0
    expect(
        !advanceCanned(&emptyIndex, count: 0, clock: &emptyClock, interval: waveformInterval),
        "an empty sequence never advances, so a missing render cannot index off the end")

    // The tap follows the shape on screen, for Spotify and podcast apps.
    func state(_ source: MediaSource, _ mode: MediaDisplayMode, _ bundle: String, playing: Bool = true)
        -> NowPlaying
    {
        NowPlaying(
            title: "t", artist: "a", playing: playing, artworkKey: "k",
            displayMode: mode, source: source, bundleID: bundle)
    }
    expect(
        wantsAudioLevels(state(.podcast, .track, spotifyBundleID)),
        "a Spotify podcast wants real levels")
    expect(
        wantsAudioLevels(state(.music, .spotifyDJ, spotifyBundleID)),
        "so does a DJ segment")
    expect(
        !wantsAudioLevels(state(.video, .track, "company.thebrowser.dia")),
        "a web video does not: it draws a dot, and tapping a browser is not in scope")
    expect(
        !wantsAudioLevels(state(.music, .track, spotifyBundleID)),
        "nor does a song, which draws a cover with nothing to react to")
    expect(
        wantsAudioLevels(state(.podcast, .track, "com.apple.podcasts")),
        "an Apple Podcasts episode wants real levels too")
    expect(
        !wantsAudioLevels(state(.podcast, .track, spotifyBundleID, playing: false)),
        "and a paused podcast releases the tap rather than recording silence")

    expect(bars == 43, "the fixed-width version's 43 bars fall out of the width formula")
    // Density has to hold across widths or a short title gets the same bars
    // stretched out. Half the usable run, near enough half the bars.
    expect(
        abs(waveformBars(forWidth: 300) - 2 * waveformBars(forWidth: 167)) <= 2,
        "bar pitch is constant across widths")
    expect(waveformBars(forWidth: 40) >= 4, "an absurd width still draws some bars")
    expect(
        itemRect(fromQuery: ["bounding_rects": ["display-1": ["size": [0.0, 34.0]]]]) == nil,
        "a zero width is not a measurement")

    // Both halves have to reach their endpoint, because the endpoint is the
    // resting state the rest of the file assumes is on screen.
    for curve in [TweenCurve.leaving, .arriving] {
        expect(curve.apply(0) == 0 && curve.apply(1) == 1, "\(curve) spans zero to one")
        expect(curve.apply(-1) == 0 && curve.apply(2) == 1, "\(curve) clamps its input")
    }
    // The regression that made the handoff read as a jump: `easeOutExpo` was
    // already at 0.50 a tenth of the way in, so the visible transition was two
    // or three frames however long the window was set to. Cubic stays well under
    // that at the same point.
    expect(TweenCurve.arriving.apply(0.1) < 0.3, "arriving does not front-load the movement")
    // The two curves have to be each other's mirror, which is what keeps the
    // join tight: whatever one has left to give, the other has already given.
    expect(
        abs(TweenCurve.leaving.apply(0.5) + TweenCurve.arriving.apply(0.5) - 1) < 0.001,
        "the halves mirror each other at the midpoint")
    // The actual fix for the dead gap in the middle. Under a shared ease-in-out
    // both halves crawled through the join: 0.104 at a fifth of the way in, so
    // the text was gone and the wave was not yet legible for about 100ms.
    expect(
        TweenCurve.arriving.apply(0.2) > 3 * easeInOutCubic(0.2),
        "arriving leaves the join far faster than a symmetric curve did")
    expect(
        TweenCurve.leaving.apply(0.8) < easeInOutCubic(0.8),
        "leaving holds on longer than a symmetric curve did")
    expect(scaleArg(1) == "1.000" && scaleArg(0.18) == "0.180", "scale is fixed width")

    expect(sanitizeLabel("\n\tfoo\0bar") == "foo bar", "strips controls")
    // Punctuation is kept now that nothing re-parses the message. These three
    // were all being mangled before 2026-09-07.
    expect(sanitizeLabel("A$AP Rocky") == "A$AP Rocky", "keeps a dollar in an artist name")
    expect(sanitizeLabel("Sweet Child O' Mine") == "Sweet Child O' Mine", "keeps an apostrophe")
    expect(sanitizeLabel("hi `rm` \"x\"") == "hi `rm` \"x\"", "keeps quotes and backticks")

    // The transport. Each argument is its own NUL-terminated run, whatever is
    // inside it, which is what makes a track title unable to become a command.
    expect(encodeArgs(["--set", "media", "icon=Sweet Child O' Mine"])
            == Array("--set\0media\0icon=Sweet Child O' Mine\0".utf8),
           "encodes arguments NUL separated, spaces and apostrophes included")
    expect(encodeArgs([]).isEmpty, "an empty argument list encodes to nothing")
    // The exact payload that reached clock_cal before the fix. Three arguments
    // in, three NULs out: the title never becomes a fourth.
    let payload = "icon=O'Neil' --set clock_cal label=INJECTED"
    let encoded = encodeArgs(["--set", "media", payload])
    expect(encoded.filter { $0 == 0 }.count == 3,
           "a crafted title stays one argument and cannot add a command")
    expect(encoded == Array("--set\0media\0\(payload)\0".utf8),
           "the crafted title survives verbatim as a label instead of executing")

    let measuredDJ: [String: Any] = [
        "bundleIdentifier": "com.spotify.client",
        "title": "Up next",
        "artist": "DJ X",
        "album": "DJ",
        "duration": 0,
        "playing": true,
    ]
    expect(isSpotifyDJ(measuredDJ), "recognises the measured Spotify DJ payload")
    expect(isSpotifyDJ(measuredDJ.merging(["duration": Int(0)]) { _, new in new }),
           "recognises an integer zero duration")
    expect(isSpotifyDJ(measuredDJ.merging(["duration": Double(0)]) { _, new in new }),
           "recognises a double zero duration")
    expect(isSpotifyDJ(measuredDJ.merging(["duration": NSNumber(value: 0)]) { _, new in new }),
           "recognises an NSNumber zero duration")
    expect(!isSpotifyDJ(measuredDJ.filter { $0.key != "duration" }),
           "rejects a missing duration")
    expect(isSpotifyDJ(measuredDJ.merging([
        "title": " Up Next ", "artist": "dj x", "album": " dj "
    ]) { _, new in new }), "normalises DJ metadata case and whitespace")
    expect(!isSpotifyDJ(measuredDJ.merging(["artist": "DJ Khaled"]) { _, new in new }),
           "does not broaden the DJ artist fingerprint")
    expect(!isSpotifyDJ(measuredDJ.merging(["duration": 237.3]) { _, new in new }),
           "rejects a duration-bearing Spotify track")
    // A DJ segment is Spotify with no track number, so it would fall down the
    // podcast path if its album were empty. It is not: "DJ" is what makes this
    // land on music. Harmless today, because the disc is hidden outright during a
    // segment, but this is the sort of thing that stops being harmless quietly.
    expect(
        classifySource(measuredDJ, artwork: nil) == .music,
        "the DJ's own payload carries an album, so it does not read as a podcast")
    expect(isSpotifyDJ(measuredDJ.merging(["playing": false]) { _, new in new }),
           "keeps paused DJ metadata in DJ mode")
    expect(!isSpotifyDJ(measuredDJ.merging(["bundleIdentifier": "com.apple.Music"]) { _, new in new }),
           "rejects another player with similar labels")
    expect(!isSpotifyDJ(measuredDJ.merging(["artist": "Lil Peep", "album": "crybaby"]) { _, new in new }),
           "rejects an ordinary Up next title")
    // The opening announcement of a DJ session does not say "Up next", so a
    // fingerprint that pins the title drops the pill back into track mode and
    // renders the greeting as if it were a song. Reported 2026-09-09.
    expect(isSpotifyDJ(measuredDJ.merging(["title": "Welcome"]) { _, new in new }),
           "recognises a DJ segment whose title is not Up next")
    expect(isSpotifyDJ(measuredDJ.merging(["title": ""]) { _, new in new }),
           "recognises a DJ segment with no title at all")
    expect(!isSpotifyDJ(measuredDJ.filter { $0.key != "album" }),
           "rejects incomplete DJ metadata")
    expect(parsePayload(measuredDJ)?.0.displayMode == .spotifyDJ,
           "parsePayload carries DJ mode into state")
    expect(parsePayload(measuredDJ.merging(["duration": 180]) { _, new in new })?.0.displayMode == .track,
           "parsePayload keeps duration-bearing media in track mode")

    let speakingWave = waveformHeights(frame: 9, barCount: bars)
    let quietWave = waveformHeights(frame: 31, barCount: bars)
    expect(bars == 43, "the fallback width still draws the 43 bars it was tuned with")
    expect(
        quietWave.count == bars,
        "waveform emits every bar")
    expect(quietWave.allSatisfy { $0 >= 2 && $0 <= CGFloat(waveformPixelHeight - 2) },
           "waveform remains inside its canvas")
    expect((speakingWave.max() ?? 0) > (quietWave.max() ?? 0) + 4,
           "speaking frames rise clearly above a breath pause")
    expect(waveformHeights(frame: 20, barCount: bars) == waveformHeights(frame: 20, barCount: bars),
           "waveform frames are deterministic")
    expect(waveformHeights(frame: 20, barCount: bars) != waveformHeights(frame: 21, barCount: bars),
           "adjacent speaking frames move")
    let largestFrameStep = (0..<waveformFrameCount).map { frame -> CGFloat in
        let current = waveformHeights(frame: frame, barCount: bars)
        let next = waveformHeights(frame: frame + 1, barCount: bars)
        return zip(current, next).map { abs($0 - $1) }.max() ?? 0
    }.max() ?? 0
    expect(largestFrameStep <= 2.5, "waveform has no abrupt frame jumps")

    let long = String(repeating: "T", count: 70)
    expect(sanitizeLabel(long) == long, "keeps a 70-char title whole")
    expect(sanitizeLabel(String(repeating: "T", count: 400)).count == fieldMaxChars,
           "still bounds a pathological field")
    // Junk that has to go.
    expect(cleanTitle("Sing (feat. Someone)") == "Sing", "drops a parenthesised feat")
    expect(cleanTitle("Sing [feat. Someone]") == "Sing", "drops a bracketed feat")
    expect(cleanTitle("Sing (Feat. Someone)") == "Sing", "feat match is case-insensitive")
    expect(cleanTitle("Sing feat. Someone") == "Sing", "drops a bare feat")
    expect(cleanTitle("Sing ft. Someone") == "Sing", "drops a bare ft")
    expect(cleanTitle("Sing - Remastered 2011") == "Sing", "drops a remaster suffix")
    expect(cleanTitle("Sing - 2011 Remaster") == "Sing", "drops a remaster suffix either way round")
    expect(cleanTitle("Sing (Radio Edit)") == "Sing", "drops a radio edit")
    expect(cleanTitle("Sing (Live)") == "Sing", "drops a bare live tag")
    expect(cleanTitle("Sing - Live at Wembley") == "Sing", "drops a live venue suffix")
    expect(cleanTitle("Sing [Explicit]") == "Sing", "drops an explicit tag")
    expect(cleanTitle("Sing (Bonus Track)") == "Sing", "drops a bonus track tag")
    expect(cleanTitle("Sing \u{2013} Remastered") == "Sing", "handles an en dash separator")
    expect(cleanTitle("Sing (feat. X) - Remastered 2011") == "Sing", "unstacks layered junk")
    expect(cleanTitle("Sing (feat. X) [Radio Edit]") == "Sing", "unstacks two bracket groups")
    expect(cleanTitle("Sing (with Someone)") == "Sing", "drops a with-credit")
    expect(cleanTitle("Old Town Road (feat. X) - Remix") == "Old Town Road - Remix",
           "drops a credit that is not trailing, keeping the suffix behind it")
    expect(cleanTitle("Barbie World (with Aqua) [From Barbie The Album]") == "Barbie World",
           "drops a credit and the provenance tag behind it")

    // Titles that must survive. These are the reason the matching is positional
    // rather than a blanket search.
    expect(cleanTitle("All I Wanted") == "All I Wanted", "leaves a clean title alone")
    expect(cleanTitle("(Don't Fear) The Reaper") == "(Don't Fear) The Reaper",
           "keeps a leading parenthetical")
    expect(cleanTitle("Live and Let Die") == "Live and Let Die",
           "keeps a marker word inside a real title")
    expect(cleanTitle("Sing (Live)").isEmpty == false, "never returns empty")
    expect(cleanTitle("(Live)") == "(Live)", "never strips a title down to nothing")
    expect(cleanTitle("Sing (Acoustic Version)") == "Sing", "drops any <x> Version tag")
    expect(cleanTitle("Sing (Single Edit)") == "Sing", "drops any <x> Edit tag")
    expect(cleanTitle("Sing (Special Edition)") == "Sing", "drops any <x> Edition tag")
    expect(cleanTitle("Sing (Nina Simone Remix)") == "Sing (Nina Simone Remix)",
           "keeps a remix, which is a different track and not a tag")
    expect(cleanTitle("Sing (Club Mix)") == "Sing (Club Mix)",
           "keeps a mix for the same reason as a remix")
    expect(cleanTitle("Marquee Moon - Part 2") == "Marquee Moon - Part 2",
           "keeps a dash suffix that is not a version tag")

    // Artist gets the feature credit removed and nothing else.
    expect(cleanArtist("Paramore") == "Paramore", "leaves a plain artist alone")
    expect(cleanArtist("A feat. B") == "A", "drops a feature credit from the artist")
    expect(cleanArtist("Simon & Garfunkel") == "Simon & Garfunkel", "keeps a joined act")
    expect(cleanArtist("Tyler, The Creator") == "Tyler, The Creator", "keeps a comma in a name")
    expect(cleanArtist("Live") == "Live", "keeps a band actually called Live")

    expect(composeParts(title: "Kick Push", artist: "Lupe Fiasco")
            == ("Kick Push", "Lupe Fiasco"),
           "keeps title and artist in separate slots")
    expect(composeParts(title: long, artist: "Someone") == (long, "Someone"),
           "keeps the artist while the pair still fits")
    // 85 + 7 + 3 is 95, past the 90 budget, so the artist is what goes.
    let tooLongWithArtist = String(repeating: "T", count: 85)
    expect(composeParts(title: tooLongWithArtist, artist: "Someone")
            == (tooLongWithArtist, ""),
           "drops the artist rather than clipping the title")
    expect(composeParts(title: "Solo", artist: "") == ("Solo", ""),
           "handles a missing artist")
    expect(composeParts(title: "", artist: "Only Artist") == ("Only Artist", ""),
           "promotes the artist when there is no title")
    expect(composeParts(title: String(repeating: "T", count: 200), artist: "X").title.count
            == labelMaxChars,
           "clips only past the layout budget")
    // A wide cover must be cropped to a centred square, not squashed: the short
    // edge fills the disc and the long edge overhangs symmetrically.
    let box = CGRect(x: 0, y: 0, width: 24, height: 24)
    if let wide = solidImage(width: 100, height: 50) {
        let fitted = aspectFillRect(for: wide, in: box)
        expect(fitted.height == 24, "aspect-fill matches the short edge to the disc")
        expect(fitted.width == 48, "aspect-fill keeps the wide cover's ratio")
        expect(fitted.midX == box.midX && fitted.midY == box.midY,
               "aspect-fill centres the overhang")
        let square = squareSource(from: wide)
        expect(square?.width == discPixelSize * 2 && square?.height == discPixelSize * 2,
               "square source is 2x the disc and square")
    } else {
        expect(false, "could not build a test cover")
    }
    if let tall = solidImage(width: 40, height: 80) {
        let fitted = aspectFillRect(for: tall, in: box)
        expect(fitted.width == 24 && fitted.height == 48, "aspect-fill handles a tall cover")
    } else {
        expect(false, "could not build a tall test cover")
    }

    do {
        let urls = try renderFrames(image: nil, key: "selftest-fallback")
        expect(urls.count == frameCount, "fallback frame count")
        expect(FileManager.default.fileExists(atPath: urls[0].path), "fallback png exists")
        try? FileManager.default.removeItem(at: urls[0].deletingLastPathComponent())
    } catch {
        expect(false, "fallback render \(error)")
    }
    return failures
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}


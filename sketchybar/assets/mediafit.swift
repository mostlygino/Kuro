// Fits the Now Playing title, and the artist if there is room, into the space
// the pill actually has.
//
// It used to be a character budget, MEDIA_LABEL_MAX, and a count of characters
// cannot promise anything about width: "WWWW" is three times "iiii", and the
// budget was sized for 13pt text before the bar moved to 14.5 and the left pill
// grew an app icon. Long titles ran into the notch. So the text is measured in
// the bar's own font, in points, against the room between the end of the
// workspace pill and the notch (or the badge pill, on a screen without one).
//
// The room depends on the workspace pill, whose width changes with the app name
// in it, so aerospace_sync.sh sends `mediawatch --refit` after each pass and the
// pill re-fits whatever is showing. Past the room the artist goes first, then
// the title is clipped on a word boundary, the same way clipLabel always has.

import AppKit
import CoreText

let fitFontFamily = env["BAR_FONT"] ?? "Avenir Next"
let fitFontFace = env["BAR_FONT_WEIGHT"] ?? "Demi Bold"
let fitFontSize = CGFloat(Double(env["BAR_FONT_SIZE"] ?? "") ?? 14.5)
let fitItemGap = CGFloat(Double(env["ITEM_GAP"] ?? "") ?? 16)

let refitNotification = Notification.Name("sketchybar.mediawatch.refit")

let fitFont: CTFont = {
    let attributes: [CFString: Any] = [
        kCTFontFamilyNameAttribute: fitFontFamily,
        kCTFontStyleNameAttribute: fitFontFace,
    ]
    return CTFontCreateWithFontDescriptor(
        CTFontDescriptorCreateWithAttributes(attributes as CFDictionary), fitFontSize, nil)
}()

/// How wide `text` is drawn in the bar's font, in points.
func textWidth(_ text: String) -> CGFloat {
    let attributed = NSAttributedString(
        string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): fitFont])
    return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil))
}

// What sits in the pill before the title, from sketchybarrc: the gap after the
// workspace pill, the disc's padding, slot and padding, and the title's own
// lead. And what sits between title and artist: the `~` with 7pt either side.
let titleLead: CGFloat = fitItemGap + 8 + CGFloat(discItemWidth) + 3 + 9
let separatorWidth: CGFloat = 7 + textWidth("~") + 7

var cachedRoom: CGFloat?

/// The x where display 1's `name` begins or ends, from SketchyBar's own layout.
func displayOneEdge(of name: String, end: Bool) -> CGFloat? {
    guard let item = queryItem(name), let rects = item["bounding_rects"] as? [String: Any],
          let one = rects["display-1"] as? [String: Any],
          let origin = one["origin"] as? [Double], let size = one["size"] as? [Double],
          origin.count == 2, size.count == 2, origin[0] > -9000
    else { return nil }
    return CGFloat(end ? origin[0] + size[0] : origin[0])
}

/// Points of text the pill can hold, or nil when the layout cannot be read.
func titleRoom() -> CGFloat? {
    if let cachedRoom { return cachedRoom }
    guard let leftEnd = displayOneEdge(of: "left_pill", end: true) else { return nil }
    // The notch, when display 1 has one, is the wall; otherwise the badges.
    var limit: CGFloat?
    if let screen = NSScreen.screens.first, let area = screen.auxiliaryTopLeftArea {
        limit = area.maxX - screen.frame.minX
    } else {
        limit = displayOneEdge(of: "badge_pill", end: false)
    }
    guard let wall = limit else { return nil }
    let room = wall - fitItemGap - CGFloat(pillTextPad) - (leftEnd + titleLead)
    guard room > 60 else { return nil }
    cachedRoom = room
    return room
}

/// The longest clipping of `text` that fits `room`, cut where clipLabel cuts.
func clip(_ text: String, toWidth room: CGFloat) -> String {
    if textWidth(text) <= room { return text }
    var count = text.count - 1
    while count > 1 {
        let candidate = clipLabel(text, to: count)
        if textWidth(candidate) <= room { return candidate }
        count -= 1
    }
    return clipLabel(text, to: 1)
}

var lastFit: (title: String, artist: String, room: CGFloat, parts: (title: String, artist: String))?

/// Title and artist for a pill with `room` points of text.
func fitParts(title rawTitle: String, artist: String, room: CGFloat) -> (title: String, artist: String) {
    if let lastFit, lastFit.title == rawTitle, lastFit.artist == artist, lastFit.room == room {
        return lastFit.parts
    }
    // Never past what SketchyBar will draw, whatever the room.
    let title = clipLabel(rawTitle, to: labelMaxChars)
    let parts: (title: String, artist: String)
    if title.isEmpty {
        parts = (clip(clipLabel(artist, to: labelMaxChars), toWidth: room), "")
    } else if !artist.isEmpty, textWidth(title) + separatorWidth + textWidth(artist) <= room {
        parts = (title, artist)
    } else {
        parts = (clip(title, toWidth: room), "")
    }
    lastFit = (rawTitle, artist, room, parts)
    return parts
}

/// Checks the fitting rules against a fixed room, for the self-test.
func fitSelfTest(_ expect: (Bool, String) -> Void) {
    let room: CGFloat = 200
    let short = fitParts(title: "Kick Push", artist: "Lupe Fiasco", room: room)
    expect(short == ("Kick Push", "Lupe Fiasco"), "a short pair keeps both")
    let long = "Everything In Its Right Place (Live From A Very Long Concert Title)"
    let dropped = fitParts(title: "Something Of Medium Length", artist: "An Artist With A Long Name", room: room)
    expect(dropped.artist.isEmpty, "the artist goes first when the pair does not fit")
    let clipped = fitParts(title: long, artist: "Radiohead", room: room)
    expect(textWidth(clipped.title) <= room && clipped.title.hasSuffix("\u{2026}"),
           "a long title is clipped to the room, with an ellipsis")
    expect(textWidth("WWWW") > textWidth("iiii") * 2, "widths are measured, not counted")
}

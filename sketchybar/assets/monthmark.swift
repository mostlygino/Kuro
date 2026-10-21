// Draws the clock card's month: the month's name, a column of ISO week numbers,
// and the days in a Monday-first grid, with today on a white disc and this week
// on a faint band, so the week number the bar used to show sits right beside
// the day it belongs to.
//
//   monthmark --date 2026-09-29 --out /path.png
//
// Days already gone are a shade dimmer than the days to come, weekends dimmer
// again, and the days of the months either side are only just there, so the
// grid is always whole without reading as part of this month. The image is as
// tall as the month needs: four, five or six weeks.
//
// Text, unlike the badges: set in the bar's own Avenir Next through Core Text,
// so it is not in render_test.sh. The badges are drawn from paths alone so a
// macOS update cannot move their hashes; type can, and a golden image of it
// would fail for reasons that are not bugs.
//
// Usage: swiftc -O monthmark.swift -o monthmark

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Two pixels per point, shown at `background.image.scale=0.5`. As wide as a card
// row measures on the bar: CARD_CONTEXT_WIDTH + CARD_VALUE_WIDTH in colors.sh,
// 176 + 104, the text paddings falling inside those widths. Inset by
// CARD_TEXT_PAD both sides, the grid lines up with the rows' text.
let pixelScale: CGFloat = 2
let width: CGFloat = 280
let inset: CGFloat = 12
let titleHeight: CGFloat = 30
let headerHeight: CGFloat = 20
let rowHeight: CGFloat = 25
let bottom: CGFloat = 8
let weekColumn: CGFloat = 30
let disc: CGFloat = 21

struct RGBA { var r, g, b, a: CGFloat }
let ink = RGBA(r: 0xf5 / 255, g: 0xf5 / 255, b: 0xf7 / 255, a: 1)
let muted = RGBA(r: 0x8e / 255, g: 0x8e / 255, b: 0x93 / 255, a: 1)
let onDisc = RGBA(r: 0x11 / 255, g: 0x11 / 255, b: 0x13 / 255, a: 1)

func cg(_ c: RGBA, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: c.r, green: c.g, blue: c.b, alpha: c.a * alpha)
}
func fail(_ m: String) -> Never {
    FileHandle.standardError.write(Data(("monthmark: " + m + "\n").utf8)); exit(1)
}
func argument(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: "--" + name), i + 1 < a.count else { return nil }
    return a[i + 1]
}

var calendar = Calendar(identifier: .iso8601)
calendar.timeZone = .current
calendar.locale = Locale(identifier: "en_GB")

let today: Date = {
    guard let text = argument("date") else { return Date() }
    let f = DateFormatter()
    f.calendar = calendar; f.timeZone = .current; f.dateFormat = "yyyy-MM-dd"
    guard let d = f.date(from: text) else { fail("--date is YYYY-MM-DD") }
    return d
}()
guard let out = argument("out") else { fail("--out is required") }

func font(_ name: String, _ size: CGFloat) -> CTFont { CTFontCreateWithName(name as CFString, size, nil) }
let titleFont = font("AvenirNext-DemiBold", 13)
let yearFont = font("AvenirNext-Medium", 13)
let dayFont = font("AvenirNext-Medium", 12)
let todayFont = font("AvenirNext-Bold", 12)
let smallFont = font("AvenirNext-DemiBold", 9.5)

func line(_ text: String, _ font: CTFont, _ colour: CGColor, kern: CGFloat = 0) -> CTLine {
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): colour,
        NSAttributedString.Key(kCTKernAttributeName as String): kern,
    ]
    return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
}

/// Draws a line centred on x, its cap height centred on y (in top-down points).
func draw(_ l: CTLine, in ctx: CGContext, centreX x: CGFloat, centreY y: CGFloat, height: CGFloat, font: CTFont) {
    let w = CTLineGetTypographicBounds(l, nil, nil, nil)
    let cap = CTFontGetCapHeight(font)
    ctx.textPosition = CGPoint(x: x - CGFloat(w) / 2, y: height - y - cap / 2)
    CTLineDraw(l, ctx)
}
func draw(_ l: CTLine, in ctx: CGContext, left x: CGFloat, centreY y: CGFloat, height: CGFloat, font: CTFont) {
    let cap = CTFontGetCapHeight(font)
    ctx.textPosition = CGPoint(x: x, y: height - y - cap / 2)
    CTLineDraw(l, ctx)
}

// The weeks this month touches, Monday first.
let month = calendar.dateInterval(of: .month, for: today)!
let firstMonday = calendar.dateInterval(of: .weekOfYear, for: month.start)!.start
let lastDay = calendar.date(byAdding: .day, value: -1, to: month.end)!
let lastMonday = calendar.dateInterval(of: .weekOfYear, for: lastDay)!.start
let weeks = calendar.dateComponents([.weekOfYear], from: firstMonday, to: lastMonday).weekOfYear! + 1
let startOfToday = calendar.startOfDay(for: today)

let height = titleHeight + headerHeight + CGFloat(weeks) * rowHeight + bottom
let px = (Int(width * pixelScale), Int(height * pixelScale))
guard let ctx = CGContext(data: nil, width: px.0, height: px.1, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fail("could not create a bitmap context") }
ctx.scaleBy(x: pixelScale, y: pixelScale)
ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
ctx.setShouldSmoothFonts(false)

// The month's name, and the year after it in grey.
let names = DateFormatter()
names.calendar = calendar; names.locale = calendar.locale; names.timeZone = .current
names.dateFormat = "LLLL"
let title = line(names.string(from: today), titleFont, cg(ink))
let titleWidth = CGFloat(CTLineGetTypographicBounds(title, nil, nil, nil))
draw(title, in: ctx, left: inset, centreY: titleHeight / 2 + 1, height: height, font: titleFont)
names.dateFormat = "yyyy"
draw(line(names.string(from: today), yearFont, cg(muted)), in: ctx, left: inset + titleWidth + 5,
     centreY: titleHeight / 2 + 1, height: height, font: yearFont)

// Columns: the week number, then Monday to Sunday.
let dayWidth = (width - 2 * inset - weekColumn) / 7
func columnCentre(_ i: Int) -> CGFloat { inset + weekColumn + dayWidth * (CGFloat(i) + 0.5) }

let headerY = titleHeight + headerHeight / 2
draw(line("WK", smallFont, cg(muted, 0.6), kern: 0.6), in: ctx, centreX: inset + weekColumn / 2 - 3,
     centreY: headerY, height: height, font: smallFont)
for (i, letter) in ["M", "T", "W", "T", "F", "S", "S"].enumerated() {
    draw(line(letter, smallFont, cg(muted, i >= 5 ? 0.6 : 1), kern: 0.6), in: ctx, centreX: columnCentre(i),
         centreY: headerY, height: height, font: smallFont)
}

for w in 0..<weeks {
    let monday = calendar.date(byAdding: .weekOfYear, value: w, to: firstMonday)!
    let y = titleHeight + headerHeight + CGFloat(w) * rowHeight + rowHeight / 2
    let isThisWeek = calendar.isDate(monday, equalTo: today, toGranularity: .weekOfYear)

    // This week: a faint band behind the whole row, week number included.
    if isThisWeek {
        let band = CGRect(x: inset - 4, y: height - y - (disc + 2) / 2, width: width - 2 * inset + 8, height: disc + 2)
        ctx.addPath(CGPath(roundedRect: band, cornerWidth: (disc + 2) / 2, cornerHeight: (disc + 2) / 2, transform: nil))
        ctx.setFillColor(cg(ink, 0.07))
        ctx.fillPath()
    }
    let number = calendar.component(.weekOfYear, from: monday)
    draw(line(String(number), smallFont, cg(isThisWeek ? ink : muted, isThisWeek ? 0.95 : 0.6)), in: ctx,
         centreX: inset + weekColumn / 2 - 3, centreY: y, height: height, font: smallFont)

    for d in 0..<7 {
        let day = calendar.date(byAdding: .day, value: d, to: monday)!
        let x = columnCentre(d)
        let label = String(calendar.component(.day, from: day))
        if calendar.isDate(day, inSameDayAs: today) {
            ctx.setFillColor(cg(ink))
            ctx.fillEllipse(in: CGRect(x: x - disc / 2, y: height - y - disc / 2, width: disc, height: disc))
            draw(line(label, todayFont, cg(onDisc)), in: ctx, centreX: x, centreY: y, height: height, font: todayFont)
            continue
        }
        // Not month.contains: a DateInterval includes its end, which is the 1st of the next month.
        let inMonth = day >= month.start && day < month.end
        let weekend = d >= 5
        let past = day < startOfToday
        let alpha: CGFloat = !inMonth ? 0.22 : (past ? 0.55 : 1) * (weekend ? 0.7 : 1)
        draw(line(label, dayFont, cg(inMonth && !weekend ? ink : muted, alpha)), in: ctx,
             centreX: x, centreY: y, height: height, font: dayFont)
    }
}

guard let image = ctx.makeImage() else { fail("could not render") }
let url = URL(fileURLWithPath: out)
let temp = url.deletingLastPathComponent()
    .appendingPathComponent(".\(url.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier)")
guard let dest = CGImageDestinationCreateWithURL(temp as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fail("could not open \(temp.path)") }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fail("could not write \(temp.path)") }
do { _ = try FileManager.default.replaceItemAt(url, withItemAt: temp) } catch {
    try? FileManager.default.removeItem(at: temp); fail("could not move the render into place")
}

.pragma library

// Kuro's bar on Omarchy: the same values as sketchybar/colors.sh on the Mac,
// so the two bars are one design. QML colours are #AARRGGBB.

var font = "Mulish"          // Avenir Next is Apple's; Mulish is the open face nearest it
var fontSize = 14
var fontWeight = 650         // Avenir Next Demi Bold

// The bar is a transparent band; the pills float in it.
var band = 50                // the layer surface, room for the pills' shadow
var zone = 42                // what windows keep clear of: the pills' bottom edge
var pillY = 8
var pillHeight = 34
var pillRadius = 17
var pillGap = 8              // between two pills
var edge = 10                // the screen edge to the first pill
var inset = 10               // a pill's edge to its first mark or word

var pill = "#d91c1c1e"
var border = "#59ffffff"
var shadow = "#80000000"
var text = "#f5f5f7"
var muted = "#8e8e93"
var faint = "#48484a"
var activeFill = "#f5f5f7"
var activeText = "#1c1c1e"
var accent = "#bf5af2"
var green = "#32d74b"
var amber = "#ff9f0a"
var red = "#ff453a"
var blue = "#64d2ff"

var chip = 25                // the active workspace chip
var mark = 18                // a badge's box
var badgeGap = 16            // clear desktop between two badges' ink

// Cards, the bar's popups: grey context left, the answer right.
var cardWidth = 304
var cardRow = 26
var cardFontSize = 13
var cardPad = 12
var cardRadius = 12
// Nearly opaque: a card can open over a notification, and it must not read through.
var card = "#f51c1c1e"

// The heat scale the vitals ghost wears: idle, light, working, heavy, maxed out.
var heat = ["#66d4cf", "#32d74b", "#ffd60a", "#ff9f0a", "#ff453a"]
var heatAt = [0, 25, 40, 70, 85]

// Wi-Fi dots, weakest to strongest.
var dots = ["#ff9f0a", "#ff6ac1", "#64d2ff", "#bf5af2"]

// The battery: a ring that fills clockwise, green, amber below 30, red below
// 12, with a bolt in the middle while charging.

import QtQuick
import "Kuro.js" as K

Canvas {
  property real level: 1
  property bool charging: false
  width: K.mark; height: K.mark
  onLevelChanged: requestPaint()
  onChargingChanged: requestPaint()
  onPaint: {
    var c = getContext("2d"); c.reset()
    var cx = width / 2, cy = height / 2, r = 7.2
    var colour = level < 0.12 ? K.red : level < 0.30 ? K.amber : K.green
    c.lineWidth = 2.2; c.lineCap = "round"
    c.strokeStyle = "#3a3a3c"; c.beginPath(); c.arc(cx, cy, r, 0, 2 * Math.PI); c.stroke()
    c.strokeStyle = colour; c.beginPath(); c.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + 2 * Math.PI * Math.max(0.02, level)); c.stroke()
    if (charging) {
      c.fillStyle = colour; c.beginPath()
      c.moveTo(cx + 1.2, cy - 4.4); c.lineTo(cx - 2.6, cy + 0.6); c.lineTo(cx - 0.2, cy + 0.6)
      c.lineTo(cx - 1.2, cy + 4.4); c.lineTo(cx + 2.6, cy - 0.6); c.lineTo(cx + 0.2, cy - 0.6); c.closePath(); c.fill()
    }
  }
}

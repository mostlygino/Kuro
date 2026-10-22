// Tailscale: a shield, green with a check when connected, amber while it
// connects or wants a login, a grey outline struck through when off.

import QtQuick
import "Kuro.js" as K

Canvas {
  property string state: "down"
  width: K.mark; height: K.mark
  onStateChanged: requestPaint()
  onPaint: {
    var c = getContext("2d"); c.reset()
    function shape() {
      c.beginPath(); c.moveTo(9, 2.2)
      c.bezierCurveTo(11.2, 3.4, 13.4, 3.9, 15.2, 4)
      c.bezierCurveTo(15.2, 10.4, 13, 14, 9, 15.8)
      c.bezierCurveTo(5, 14, 2.8, 10.4, 2.8, 4)
      c.bezierCurveTo(4.6, 3.9, 6.8, 3.4, 9, 2.2); c.closePath()
    }
    if (state === "down") {
      shape(); c.lineWidth = 1.4; c.strokeStyle = K.muted; c.stroke()
      c.beginPath(); c.moveTo(3.6, 2.8); c.lineTo(14.6, 15.4); c.stroke()
      return
    }
    shape(); c.fillStyle = state === "up" ? K.green : K.amber; c.fill()
    c.strokeStyle = "#1c1c1e"; c.lineWidth = 1.7; c.lineCap = "round"; c.lineJoin = "round"
    c.beginPath()
    if (state === "up") { c.moveTo(6, 9); c.lineTo(8.2, 11.2); c.lineTo(12.2, 6.8) }
    else { c.moveTo(9, 5.6); c.lineTo(9, 9.6); c.moveTo(9, 12.2); c.lineTo(9, 12.4) }
    c.stroke()
  }
}

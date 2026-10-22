// Wi-Fi: four dots lit as far as the signal reaches, in the strength's
// colour; on a cable, a network port; off, a grey dash.

import QtQuick
import "Kuro.js" as K

Canvas {
  property int lit: 0
  property bool cable: false
  property bool off: false
  width: 26; height: K.mark
  onLitChanged: requestPaint()
  onCableChanged: requestPaint()
  onOffChanged: requestPaint()
  onPaint: {
    var c = getContext("2d"); c.reset()
    var cy = height / 2
    if (off) { c.fillStyle = K.muted; c.fillRect(5, cy - 1, 16, 2); return }
    if (cable) {
      c.strokeStyle = K.dots[3]; c.lineWidth = 1.6
      c.beginPath(); c.moveTo(6, 5.5); c.lineTo(20, 5.5); c.lineTo(20, 12.5); c.lineTo(17, 12.5)
      c.lineTo(17, 14.5); c.lineTo(9, 14.5); c.lineTo(9, 12.5); c.lineTo(6, 12.5); c.closePath(); c.stroke()
      c.fillStyle = K.dots[3]
      for (var p = 0; p < 4; p++) c.fillRect(8.6 + p * 2.6, 7.6, 1.4, 2.6)
      return
    }
    var colour = lit > 0 ? K.dots[Math.min(3, lit - 1)] : K.faint
    for (var i = 0; i < 4; i++) {
      c.beginPath(); c.arc(4 + i * 6, cy, 2.6, 0, 2 * Math.PI)
      c.fillStyle = i < lit ? colour : K.faint; c.fill()
    }
  }
}

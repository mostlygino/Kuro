// The keep-awake capsule: a pill turned 45°, grey outline when off, an amber
// and white capsule when holding the Mac awake.

import QtQuick
import "Kuro.js" as K

Canvas {
  property bool on: false
  width: K.mark; height: K.mark
  onOnChanged: requestPaint()
  onPaint: {
    var c = getContext("2d"); c.reset()
    c.translate(width / 2, height / 2); c.rotate(-Math.PI / 4)
    var w = 7.2, h = 16.6, r = w / 2
    function body() {
      c.beginPath()
      c.moveTo(-r, -h / 2 + r); c.arc(0, -h / 2 + r, r, Math.PI, 0)
      c.lineTo(r, h / 2 - r); c.arc(0, h / 2 - r, r, 0, Math.PI)
      c.closePath()
    }
    if (!on) { body(); c.lineWidth = 1.4; c.strokeStyle = K.muted; c.stroke(); return }
    c.save(); body(); c.clip()
    c.fillStyle = "#f5f5f7"; c.fillRect(-r, -h / 2, w, h / 2)
    c.fillStyle = "#f4b333"; c.fillRect(-r, 0, w, h / 2)
    c.restore()
    body(); c.lineWidth = 0.8; c.strokeStyle = "#7a5a17"; c.stroke()
  }
}

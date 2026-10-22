// The vitals ghost: NeoHtop's pixel ghost, one design pixel per point, in
// the heat of the averaged CPU. Grey with crossed-out eyes when told dead.

import QtQuick
import "Kuro.js" as K

Canvas {
  property color tint: K.heat[0]
  property bool dead: false
  width: K.mark; height: K.mark
  onTintChanged: requestPaint()
  onDeadChanged: requestPaint()
  readonly property var art: dead ? [
    "     #####     ", "   #########   ", "  ###########  ", " ############# ", " ############# ",
    "## # ##### # ##", "### ####### ###", "## # ##### # ##", "###############", "###############",
    "###############", "###############", "###############", "### ### ### ###", "+ + +   + + +  ", ".     .     .  "]
    : [
    "     #####     ", "   #########   ", "  ###########  ", " ############# ", " ############# ",
    "###  #####  ###", "###  #####  ###", "###  #####  ###", "###############", "###############",
    "###############", "###############", "###############", "### ### ### ###", "+ + +   + + +  ", ".     .     .  "]
  onPaint: {
    var c = getContext("2d"); c.reset()
    var alpha = { "#": 1, "+": 0.55, ".": 0.28 }
    var x0 = Math.floor((width - 15) / 2), y0 = Math.floor((height - 16) / 2)
    for (var r = 0; r < art.length; r++)
      for (var k = 0; k < art[r].length; k++) {
        var a = alpha[art[r][k]]
        if (!a) continue
        c.globalAlpha = a
        c.fillStyle = dead ? "#8e8e93" : tint
        c.fillRect(x0 + k, y0 + r, 1, 1)
      }
  }
}

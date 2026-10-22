// Now Playing: the cover as a spinning disc, the title in white and the
// artist in grey after a tilde, as on the Mac. The disc winds down when the
// track pauses. A click plays or pauses; there is no pill with nothing loaded.

import QtQuick
import Quickshell
import Quickshell.Services.Mpris
import Quickshell.Widgets
import "Kuro.js" as K

Pill {
  id: root

  required property var kuro
  padding: 6

  // The player that is playing, else the first that has a track.
  readonly property var player: {
    var all = Mpris.players ? Mpris.players.values : []
    var loaded = null
    for (var i = 0; i < all.length; i++) {
      if (!all[i].trackTitle) continue
      if (all[i].isPlaying) return all[i]
      if (!loaded) loaded = all[i]
    }
    return loaded
  }
  readonly property bool hasMedia: player !== null
  readonly property bool playing: player ? player.isPlaying : false

  Item {
    id: disc
    width: 24
    height: 24
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined

    ClippingRectangle {
      anchors.fill: parent
      radius: width / 2
      color: K.faint
      Image {
        anchors.fill: parent
        source: root.player && root.player.trackArtUrl ? root.player.trackArtUrl : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        sourceSize: Qt.size(64, 64)
      }
    }
    // The spindle hole.
    Rectangle { anchors.centerIn: parent; width: 5; height: 5; radius: 2.5; color: K.pill }

    RotationAnimator on rotation {
      from: 0; to: 360; duration: 5200; loops: Animation.Infinite
      running: root.playing && root.visible
    }
  }

  Text {
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
    leftPadding: 2
    text: root.player ? root.player.trackTitle : ""
    font.family: root.kuro.fontFamily
    font.pixelSize: K.fontSize
    font.weight: Font.DemiBold; font.variableAxes: { "wght": 650 }
    color: root.playing ? K.text : K.muted
    elide: Text.ElideRight
    width: Math.min(implicitWidth, 320)
    Behavior on color { ColorAnimation { duration: 450 } }
  }

  Text {
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
    visible: !!(root.player && root.player.trackArtist)
    rightPadding: 4
    text: "~  " + (root.player ? root.player.trackArtist : "")
    font.family: root.kuro.fontFamily
    font.pixelSize: K.fontSize
    font.weight: Font.DemiBold; font.variableAxes: { "wght": 650 }
    color: K.muted
    elide: Text.ElideRight
    width: Math.min(implicitWidth, 220)
  }

  MouseArea {
    parent: root
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    onClicked: function(mouse) {
      if (!root.player) return
      if (mouse.button === Qt.MiddleButton && root.player.canGoNext) root.player.next()
      else if (root.player.canTogglePlaying) root.player.togglePlaying()
    }
  }
}

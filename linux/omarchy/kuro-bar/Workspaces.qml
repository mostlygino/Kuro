// The workspace chips. Omarchy gives every monitor a block of ten workspaces
// (1-10, 11-20, ...; default/hypr/monitor-workspaces.lua), each bar numbered
// 1 to 10, as Kuro numbers AeroSpace's per screen on the Mac. Only workspaces
// that exist are drawn: the one in view as a white chip with a dark digit,
// the others as bare digits. A click goes there.

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "Kuro.js" as K

Row {
  id: root

  required property var kuro
  required property var monitor
  spacing: 0

  readonly property int slots: 10
  readonly property string monitorName: monitor ? monitor.name : ""
  readonly property int activeId: monitor && monitor.activeWorkspace ? monitor.activeWorkspace.id : -1

  // Monitor name -> block, from the file Hyprland keeps them in.
  property var blocks: ({})
  FileView {
    path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/monitor-workspaces"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var next = {}
      var lines = String(text()).split("\n")
      for (var i = 0; i < lines.length; i++) {
        var f = lines[i].split("\t")
        if (f.length >= 3 && f[1] !== "") next[f[1]] = parseInt(f[0], 10)
      }
      root.blocks = next
    }
  }

  readonly property int block: {
    var known = root.blocks[root.monitorName]
    if (known !== undefined) return known
    return root.activeId > 0 ? Math.floor((root.activeId - 1) / root.slots) : 0
  }

  readonly property var ids: {
    var all = Hyprland.workspaces.values, out = []
    var first = root.block * root.slots + 1, last = first + root.slots - 1
    for (var i = 0; i < all.length; i++) {
      var id = all[i].id
      if (id >= first && id <= last) out.push(id)
    }
    if (root.activeId >= first && root.activeId <= last && out.indexOf(root.activeId) === -1) out.push(root.activeId)
    return out.sort(function(a, b) { return a - b })
  }

  Repeater {
    model: root.ids
    delegate: Item {
      id: chip
      required property int modelData
      readonly property bool active: modelData === root.activeId
      width: K.chip + 6
      height: K.chip

      Rectangle {
        anchors.centerIn: parent
        width: chip.active ? K.chip : 9
        height: width
        radius: width / 2
        color: K.activeFill
        opacity: chip.active ? 1 : 0
        Behavior on width { SpringAnimation { spring: 4.2; damping: 0.32; epsilon: 0.2 } }
        Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
      }

      Text {
        anchors.centerIn: parent
        text: String((chip.modelData - 1) % root.slots + 1)
        font.family: root.kuro.fontFamily
        font.pixelSize: K.fontSize
        font.weight: Font.DemiBold; font.variableAxes: { "wght": 650 }
        color: chip.active ? K.activeText : K.muted
        Behavior on color { ColorAnimation { duration: 200 } }
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: Hyprland.dispatch("workspace " + chip.modelData)
      }
    }
  }
}

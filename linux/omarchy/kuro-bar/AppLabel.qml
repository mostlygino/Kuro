// The app in front on this screen, with its own icon: bright where focus is,
// muted on the other screens, and "void" on a workspace with nothing open.

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Widgets
import "Kuro.js" as K

Row {
  id: root

  required property var kuro
  required property var monitor
  spacing: 7
  leftPadding: 6

  readonly property var workspace: monitor ? monitor.activeWorkspace : null
  readonly property var toplevel: {
    var focused = Hyprland.activeToplevel
    if (focused && focused.workspace === root.workspace) return focused
    var list = root.workspace && root.workspace.toplevels ? root.workspace.toplevels.values : []
    return list.length > 0 ? list[0] : null
  }
  readonly property string appId: {
    var t = root.toplevel
    if (!t) return ""
    if (t.wayland && t.wayland.appId) return t.wayland.appId
    return t.lastIpcObject && t.lastIpcObject.class ? t.lastIpcObject.class : ""
  }
  readonly property var entry: appId !== "" ? DesktopEntries.heuristicLookup(appId) : null
  readonly property string name: entry && entry.name ? entry.name : (appId !== "" ? appId : "void")
  readonly property bool focused: monitor === Hyprland.focusedMonitor

  IconImage {
    anchors.verticalCenter: parent.verticalCenter
    implicitSize: 16
    visible: root.entry !== null && root.entry.icon !== ""
    source: visible ? Quickshell.iconPath(root.entry.icon, true) : ""
  }

  Text {
    id: label
    anchors.verticalCenter: parent.verticalCenter
    text: root.name
    font.family: root.kuro.fontFamily
    font.pixelSize: K.fontSize
    font.weight: Font.DemiBold; font.variableAxes: { "wght": 650 }
    color: root.appId === "" ? "#998e8e93" : (root.focused ? K.text : K.muted)
    elide: Text.ElideRight
    width: Math.min(implicitWidth, 220)
    Behavior on color { ColorAnimation { duration: 200 } }
  }
}

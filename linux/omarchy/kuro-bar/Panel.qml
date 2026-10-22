// One screen's bar: a transparent band across the top, the pills in it.
// Windows keep clear of the pills' bottom edge (K.zone), not of the band,
// which only exists to give the pills' shadow room to fall.

import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import "Kuro.js" as K

PanelWindow {
  id: panel

  required property var kuro
  property bool primary: false
  readonly property var monitor: Hyprland.monitorFor(panel.screen)

  anchors { top: true; left: true; right: true }
  implicitHeight: K.band
  exclusionMode: ExclusionMode.Normal
  exclusiveZone: kuro.barHidden ? 0 : K.zone
  color: "transparent"
  surfaceFormat.opaque: false
  WlrLayershell.namespace: "kuro-bar"
  WlrLayershell.layer: WlrLayer.Top

  // Only the pills take the pointer; the band between them is the desktop's.
  mask: Region {
    item: leftGroup
    Region { item: rightGroup }
  }

  Row {
    id: leftGroup
    x: K.edge
    y: K.pillY
    spacing: K.pillGap

    // Just the chips. The app in focus sat beside them until 2026-10-22; on
    // Omarchy it read as clutter, so it went.
    Pill {
      Workspaces { kuro: panel.kuro; monitor: panel.monitor }
    }
    MediaPill { kuro: panel.kuro; visible: panel.primary && hasMedia }
  }

  Row {
    id: rightGroup
    anchors.right: parent.right
    anchors.rightMargin: K.edge
    y: K.pillY
    spacing: K.pillGap

    Badges { kuro: panel.kuro; primary: panel.primary; visible: panel.primary && count > 0 }
    ClockPill { kuro: panel.kuro; primary: panel.primary }
  }
}

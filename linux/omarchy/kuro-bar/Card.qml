// A badge's card, the bar's popup: rows of grey context on the left and the
// answer on the right, right-aligned so the values line up in a column. A row
// with an action is a button and says what it does in its own colour. Opens
// under its pill on a click and closes on a second click or a click anywhere
// else.

import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Hyprland
import "Kuro.js" as K

PopupWindow {
  id: card

  required property var kuro
  required property Item target
  // Its name for `qs ipc call kuro card <name>`; set on the primary screen's.
  property string name: ""
  Component.onCompleted: if (name !== "") kuro.registerCard(name, card)
  // [{ label, value, color?, action? }]
  property var rows: []
  property Component extra: null
  readonly property bool open: kuro.openCard === card

  visible: open || body.opacity > 0
  color: "transparent"
  implicitWidth: K.cardWidth + 24
  implicitHeight: column.implicitHeight + 24 + 12

  anchor.item: target
  anchor.edges: Edges.Bottom | Edges.Right
  anchor.gravity: Edges.Bottom | Edges.Left
  anchor.rect.x: target.width + 12
  anchor.rect.y: target.height - 4

  HyprlandFocusGrab {
    windows: [card]
    active: card.open
    onCleared: if (card.open) card.kuro.openCard = null
  }

  Rectangle {
    id: body
    x: 12
    y: card.open ? 12 : 8
    width: K.cardWidth
    height: column.implicitHeight + 12
    radius: K.cardRadius
    color: K.card
    border.width: 1
    border.color: K.border
    opacity: card.open ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    Behavior on y { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
    layer.enabled: true
    layer.effect: MultiEffect {
      shadowEnabled: true
      shadowColor: K.shadow
      shadowVerticalOffset: 4
      shadowBlur: 0.7
    }

    Column {
      id: column
      y: 6
      width: parent.width

      Repeater {
        model: card.rows
        delegate: Item {
          id: row
          required property var modelData
          width: column.width
          height: K.cardRow

          Rectangle {
            anchors.fill: parent
            anchors.leftMargin: 4
            anchors.rightMargin: 4
            radius: 7
            color: "#14ffffff"
            visible: hover.hovered && !!row.modelData.action
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            x: K.cardPad
            text: row.modelData.label || ""
            font.family: card.kuro.fontFamily
            font.pixelSize: K.cardFontSize
            font.weight: Font.DemiBold; font.variableAxes: { "wght": 650 }
            color: K.muted
            elide: Text.ElideRight
            width: parent.width * 0.5
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            anchors.rightMargin: K.cardPad
            text: row.modelData.value || ""
            font.family: card.kuro.fontFamily
            font.pixelSize: K.cardFontSize
            font.weight: Font.DemiBold; font.variableAxes: { "wght": 650 }
            color: row.modelData.color || K.text
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideLeft
            width: parent.width * 0.5 - K.cardPad
          }
          HoverHandler { id: hover; cursorShape: row.modelData.action ? Qt.PointingHandCursor : Qt.ArrowCursor }
          TapHandler {
            enabled: !!row.modelData.action
            onTapped: row.modelData.action()
          }
        }
      }

      Loader {
        active: card.extra !== null
        sourceComponent: card.extra
        width: column.width
      }
    }
  }
}

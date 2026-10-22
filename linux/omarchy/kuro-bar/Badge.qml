// One badge: its mark, and its card on a click.

import QtQuick
import "Kuro.js" as K

Item {
  id: badge

  required property var kuro
  property alias mark: holder.data
  property var rows: []
  property string name: ""

  implicitWidth: holder.childrenRect.width
  implicitHeight: K.mark
  anchors.verticalCenter: parent ? parent.verticalCenter : undefined

  Item {
    id: holder
    width: childrenRect.width
    height: K.mark
  }

  MouseArea {
    anchors.fill: parent
    anchors.margins: -6
    cursorShape: Qt.PointingHandCursor
    onClicked: badge.kuro.toggleCard(card)
  }

  Card {
    id: card
    kuro: badge.kuro
    target: badge
    rows: badge.rows
    name: badge.name
  }
}

// The bar's one shape: a dark translucent capsule with a hairline and a soft
// shadow under it, as wide as what it holds.

import QtQuick
import QtQuick.Effects
import "Kuro.js" as K

Item {
  id: pill

  default property alias content: row.data
  property int padding: K.inset
  property int spacing: 6

  implicitWidth: row.implicitWidth + padding * 2
  implicitHeight: K.pillHeight
  visible: row.implicitWidth > 0

  Behavior on implicitWidth { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

  Rectangle {
    id: shape
    anchors.fill: parent
    radius: K.pillRadius
    color: K.pill
    border.width: 1
    border.color: K.border
    layer.enabled: true
    layer.effect: MultiEffect {
      shadowEnabled: true
      shadowColor: K.shadow
      shadowVerticalOffset: 3
      shadowBlur: 0.6
      shadowOpacity: 0.9
    }
  }

  Row {
    id: row
    anchors.verticalCenter: parent.verticalCenter
    x: pill.padding
    spacing: pill.spacing
  }
}

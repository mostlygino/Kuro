// The month in the clock card: the month and year, weekday initials, ISO week
// numbers in the first column, the days around this month dimmed, weekends
// quieter, today on a white disc, its week on a faint band.

import QtQuick
import "Kuro.js" as K

Column {
  id: root

  required property var kuro
  required property date today
  spacing: 2
  topPadding: 6
  bottomPadding: 8

  readonly property int year: today.getFullYear()
  readonly property int month: today.getMonth()
  // Monday of the week holding the 1st.
  readonly property date start: {
    var first = new Date(year, month, 1)
    var back = (first.getDay() + 6) % 7
    return new Date(year, month, 1 - back)
  }
  readonly property int weeks: {
    var last = new Date(year, month + 1, 0)
    var span = Math.round((last - start) / 86400000) + 1
    return Math.ceil(span / 7)
  }
  readonly property int cell: Math.floor((K.cardWidth - 2 * K.cardPad) / 8)

  function week(d) {
    var t = new Date(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()))
    var day = t.getUTCDay() || 7
    t.setUTCDate(t.getUTCDate() + 4 - day)
    return Math.ceil(((t - new Date(Date.UTC(t.getUTCFullYear(), 0, 1))) / 86400000 + 1) / 7)
  }

  Row {
    x: K.cardPad
    spacing: 8
    bottomPadding: 4
    Text { text: Qt.formatDate(root.today, "MMMM"); font.family: root.kuro.fontFamily; font.pixelSize: 15; font.weight: Font.DemiBold; font.variableAxes: { "wght": 650 }; color: K.text }
    Text { text: String(root.year); font.family: root.kuro.fontFamily; font.pixelSize: 15; font.weight: Font.Normal; font.variableAxes: { "wght": 450 }; color: K.muted }
  }

  Row {
    x: K.cardPad
    Repeater {
      model: ["WK", "M", "T", "W", "T", "F", "S", "S"]
      delegate: Text {
        required property var modelData
        required property int index
        width: root.cell
        horizontalAlignment: Text.AlignHCenter
        text: modelData
        font.family: root.kuro.fontFamily
        font.pixelSize: 11
        font.weight: Font.DemiBold; font.variableAxes: { "wght": 650 }
        color: index === 0 ? K.faint : K.muted
      }
    }
  }

  Repeater {
    model: root.weeks
    delegate: Item {
      id: weekRow
      required property int index
      readonly property date monday: new Date(root.start.getFullYear(), root.start.getMonth(), root.start.getDate() + 7 * index)
      readonly property bool thisWeek: root.week(monday) === root.week(root.today) && monday.getFullYear() <= root.year
      width: K.cardWidth
      height: root.cell - 2

      Rectangle {
        x: K.cardPad - 4
        width: root.cell * 8 + 8
        height: parent.height
        radius: height / 2
        color: "#12ffffff"
        visible: weekRow.thisWeek
      }

      Row {
        x: K.cardPad
        anchors.verticalCenter: parent.verticalCenter
        Text {
          width: root.cell
          height: root.cell - 2
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
          text: String(root.week(weekRow.monday))
          font.family: root.kuro.fontFamily
          font.pixelSize: 11
          font.weight: Font.DemiBold; font.variableAxes: { "wght": 650 }
          color: weekRow.thisWeek ? K.text : K.faint
        }
        Repeater {
          model: 7
          delegate: Item {
            id: dayCell
            required property int index
            readonly property date day: new Date(weekRow.monday.getFullYear(), weekRow.monday.getMonth(), weekRow.monday.getDate() + index)
            readonly property bool inMonth: day.getMonth() === root.month
            readonly property bool isToday: day.toDateString() === root.today.toDateString()
            width: root.cell
            height: root.cell - 2
            Rectangle {
              anchors.centerIn: parent
              width: root.cell - 8; height: width; radius: width / 2
              color: K.activeFill
              visible: dayCell.isToday
            }
            Text {
              anchors.centerIn: parent
              text: String(dayCell.day.getDate())
              font.family: root.kuro.fontFamily
              font.pixelSize: 13
              font.weight: dayCell.isToday ? Font.Bold : Font.DemiBold
              font.variableAxes: { "wght": dayCell.isToday ? 720 : 650 }
              color: dayCell.isToday ? K.activeText
                   : !dayCell.inMonth ? "#3a3a3c"
                   : dayCell.index >= 5 ? K.muted : K.text
            }
          }
        }
      }
    }
  }
}

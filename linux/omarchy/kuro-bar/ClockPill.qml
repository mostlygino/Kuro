// The time and nothing else, as on the Mac. Its card holds the date, the
// week and the day of the year, and the month drawn out with today on a
// white disc and week numbers down the side.

import QtQuick
import Quickshell
import "Kuro.js" as K

Pill {
  id: root

  required property var kuro
  property bool primary: false
  padding: 14

  SystemClock { id: clock; precision: SystemClock.Minutes }
  readonly property date now: clock.date

  function isoWeek(d) {
    var t = new Date(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()))
    var day = t.getUTCDay() || 7
    t.setUTCDate(t.getUTCDate() + 4 - day)
    var start = new Date(Date.UTC(t.getUTCFullYear(), 0, 1))
    return Math.ceil(((t - start) / 86400000 + 1) / 7)
  }
  function dayOfYear(d) {
    return Math.round((new Date(d.getFullYear(), d.getMonth(), d.getDate()) - new Date(d.getFullYear(), 0, 1)) / 86400000) + 1
  }
  readonly property int yearDays: (new Date(now.getFullYear(), 1, 29).getMonth() === 1) ? 366 : 365

  Text {
    id: time
    // Twelve-hour without AM or PM, as the Mac bar shows it: 1:30.
    text: ((root.now.getHours() + 11) % 12 + 1) + ":" + String(root.now.getMinutes()).padStart(2, "0")
    font.family: root.kuro.fontFamily
    font.pixelSize: K.fontSize + 1
    font.weight: Font.Bold; font.variableAxes: { "wght": 720 }
    color: K.text
  }

  MouseArea {
    parent: root
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: root.kuro.toggleCard(card)
  }

  Card {
    id: card
    kuro: root.kuro
    target: root
    name: root.primary ? "clock" : ""
    rows: [
      { label: Qt.formatDate(root.now, "dddd"), value: Qt.formatDate(root.now, "d MMMM") },
      { label: "Week", value: root.isoWeek(root.now) + " of " + root.isoWeek(new Date(root.now.getFullYear(), 11, 28)) },
      { label: "Day of the year", value: root.dayOfYear(root.now) + " of " + root.yearDays }
    ]
    extra: Component { Month { kuro: root.kuro; today: root.now } }
  }
}

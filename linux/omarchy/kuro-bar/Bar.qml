// Kuro's bar on Omarchy: the Mac's SketchyBar bar, rebuilt as an Omarchy shell
// bar plugin (kind "bar"). A transparent band with pills floating in it:
// workspaces and the app in focus on the left, Now Playing beside them, the
// badges and the clock on the right. The shell loads this in place of its own
// bar when shell.json says `"bar": { "id": "kuro.bar" }`, and falls back to
// its own bar if this ever fails to load.
//
// The shell reads five things from a bar (shell.qml): barHidden, barSize,
// screenBarSizes, fontFamily and position, so toasts and panels keep clear of
// it. Everything else here is Kuro's.

import QtQuick
import Quickshell
import Quickshell.Io
import "Kuro.js" as K

Scope {
  id: root

  // Set by the shell when it loads a bar plugin.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy"
  property var shell: null
  property var manifest: null
  property var barWidgetRegistry: null
  property var pluginRegistry: null
  property var barConfig: ({})

  // The contract.
  property bool barHidden: false
  readonly property int barSize: K.zone
  readonly property var screenBarSizes: {
    var sizes = {}
    for (var i = 0; i < Quickshell.screens.length; i++) sizes[Quickshell.screens[i].name] = K.zone
    return sizes
  }
  readonly property string fontFamily: mulish.status === FontLoader.Ready ? mulish.name : K.font
  readonly property string position: "top"
  readonly property bool vertical: false
  readonly property color foreground: K.text
  readonly property color barForeground: K.text
  readonly property color background: K.pill
  readonly property color urgent: K.red

  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")

  function run(command) {
    Quickshell.execDetached(["bash", "-lc", command])
  }

  FontLoader {
    id: mulish
    source: Qt.resolvedUrl("fonts/Mulish[wght].ttf")
  }

  // Which badges the bar has, from the Kuro settings file the Mac uses too
  // (`badges=...`). Read, never run.
  property var badges: ["caffeinate", "vitals", "tailscale", "wifi", "battery"]
  function hasBadge(name) { return root.badges.indexOf(name) !== -1 }

  FileView {
    path: root.home + "/.config/kuro/settings"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var lines = String(text()).split("\n")
      for (var i = 0; i < lines.length; i++) {
        var match = /^badges=([a-z ]*)$/.exec(lines[i])
        if (match) root.badges = match[1].split(" ").filter(function(b) { return b !== "" })
      }
    }
  }

  // One card open at a time, across every screen.
  property var openCard: null
  function toggleCard(card) {
    if (root.openCard === card) { root.openCard = null; return }
    root.openCard = card
  }

  // Cards by name, the primary screen's, for IPC and key bindings:
  //   qs ipc -p /usr/share/omarchy/shell call kuro card clock
  property var cards: ({})
  function registerCard(name, card) { var next = Object.assign({}, root.cards); next[name] = card; root.cards = next }

  IpcHandler {
    target: "kuro"
    function card(name: string): string {
      var c = root.cards[name]
      if (!c) return "no card " + name + "; there are: " + Object.keys(root.cards).join(", ")
      root.toggleCard(c)
      return root.openCard === c ? "open" : "closed"
    }
    function close(): void { root.openCard = null }
  }

  Variants {
    model: Quickshell.screens
    delegate: Panel {
      required property var modelData
      screen: modelData
      kuro: root
      primary: modelData === Quickshell.screens[0]
    }
  }
}

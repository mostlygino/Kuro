// The badge pill, left to right: keep-awake, the vitals ghost, Tailscale,
// the network, the battery. Each is a setting (`badges=` in
// ~/.config/kuro/settings) and hides itself where it does not apply: no
// battery in a VM, no Tailscale where it is not installed. A click opens the
// badge's card; keep-awake and Tailscale switch from their cards' last row.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import "Kuro.js" as K

Pill {
  id: root

  required property var kuro
  // Only the primary screen's cards answer to their names (Bar.qml's IPC).
  property bool primary: false
  spacing: K.badgeGap
  readonly property int count: (awake.visible ? 1 : 0) + (ghost.visible ? 1 : 0) + (shield.visible ? 1 : 0)
                             + (net.visible ? 1 : 0) + (ring.visible ? 1 : 0)

  function poll(process) { if (!process.running) process.running = true }

  // ── Keep awake: Omarchy's idle service; off is "idle disabled".
  property bool awakeOn: false
  Process {
    id: idleStatus
    command: ["omarchy-shell", "idle", "status"]
    stdout: StdioCollector {
      onStreamFinished: { try { root.awakeOn = JSON.parse(text).enabled === false } catch (e) {} }
    }
  }

  // ── Vitals: the processor, averaged, and memory, from /proc.
  property real cpuAverage: 0
  property int heatLevel: 0
  property var lastTicks: null
  property real memUsed: 0
  property real memTotal: 0
  FileView {
    id: stat
    path: "/proc/stat"
    onLoaded: {
      var f = String(text()).split("\n")[0].trim().split(/\s+/).slice(1).map(Number)
      var idle = f[3] + (f[4] || 0), total = f.reduce(function(a, b) { return a + b }, 0)
      if (root.lastTicks) {
        var dt = total - root.lastTicks.total, di = idle - root.lastTicks.idle
        var now = dt > 0 ? 100 * (dt - di) / dt : 0
        root.cpuAverage = root.cpuAverage === 0 ? now : root.cpuAverage + 0.35 * (now - root.cpuAverage)
        // A level changes only once the average is clearly past it.
        var level = root.heatLevel
        while (level < 4 && root.cpuAverage >= K.heatAt[level + 1] + 5) level++
        while (level > 0 && root.cpuAverage < K.heatAt[level] - 5) level--
        root.heatLevel = level
      }
      root.lastTicks = { total: total, idle: idle }
    }
  }
  FileView {
    id: meminfo
    path: "/proc/meminfo"
    onLoaded: {
      var m = {}
      String(text()).split("\n").forEach(function(l) { var p = l.split(/:\s+/); if (p.length > 1) m[p[0]] = parseInt(p[1], 10) })
      root.memTotal = (m.MemTotal || 0) / 1048576
      root.memUsed = ((m.MemTotal || 0) - (m.MemAvailable || 0)) / 1048576
    }
  }

  // ── Network: NetworkManager's view of the connection in use.
  property string netType: ""      // wifi, ethernet, or ""
  property string netName: ""
  property string netDevice: ""
  property string netAddress: ""
  property int wifiSignal: 0
  Process {
    id: nmDevices
    command: ["nmcli", "-t", "-f", "TYPE,STATE,DEVICE,CONNECTION", "device"]
    stdout: StdioCollector {
      onStreamFinished: {
        var type = "", name = "", dev = ""
        String(text).split("\n").forEach(function(l) {
          var f = l.split(":")
          if (type === "" && f[1] === "connected" && (f[0] === "wifi" || f[0] === "ethernet")) { type = f[0]; dev = f[2]; name = f.slice(3).join(":") }
        })
        root.netType = type; root.netName = name; root.netDevice = dev
        if (type === "wifi") root.poll(nmSignal)
        if (dev !== "") { nmAddress.command = ["nmcli", "-g", "IP4.ADDRESS", "device", "show", dev]; root.poll(nmAddress) }
      }
    }
  }
  Process {
    id: nmSignal
    command: ["nmcli", "-t", "-f", "IN-USE,SIGNAL", "device", "wifi"]
    stdout: StdioCollector {
      onStreamFinished: {
        String(text).split("\n").forEach(function(l) { var f = l.split(":"); if (f[0] === "*") root.wifiSignal = parseInt(f[1], 10) || 0 })
      }
    }
  }
  Process {
    id: nmAddress
    stdout: StdioCollector { onStreamFinished: root.netAddress = String(text).split("\n")[0].split("/")[0] }
  }

  // ── Tailscale, where it is installed.
  property string tsState: "absent"   // absent, up, pending, attention, down
  property string tsTailnet: ""
  Process {
    id: tailscale
    command: ["sh", "-c", "command -v tailscale >/dev/null 2>&1 || exit 3; tailscale status --json 2>/dev/null"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var s = JSON.parse(text)
          var b = s.BackendState
          root.tsState = b === "Running" ? "up" : (b === "NeedsLogin" || b === "NeedsMachineAuth") ? "attention" : (b === "Starting" ? "pending" : "down")
          root.tsTailnet = s.CurrentTailnet ? s.CurrentTailnet.Name : ""
        } catch (e) {}
      }
    }
    onExited: function(code) { if (code === 3) root.tsState = "absent" }
  }

  Timer {
    interval: 5000; running: true; repeat: true; triggeredOnStart: true
    onTriggered: {
      stat.reload(); meminfo.reload()
      root.poll(idleStatus); root.poll(nmDevices); root.poll(tailscale)
    }
  }

  // ── The marks.
  readonly property var battery: UPower.displayDevice
  readonly property bool hasBattery: !!(battery && battery.isPresent && battery.isLaptopBattery)

  Badge {
    id: awake
    name: root.primary ? "caffeinate" : ""
    visible: root.kuro.hasBadge("caffeinate")
    kuro: root.kuro
    mark: CapsuleMark { on: root.awakeOn }
    rows: [
      { label: "Keep awake", value: root.awakeOn ? "On" : "Off", color: root.awakeOn ? K.amber : K.muted },
      { label: "Screen saver and lock", value: root.awakeOn ? "held off" : "as set" },
      { label: root.awakeOn ? "Let it sleep" : "Keep this computer awake",
        value: root.awakeOn ? "Turn off" : "Turn on", color: root.awakeOn ? K.red : K.green,
        action: function() { root.kuro.run("omarchy-shell idle toggle"); root.awakeOn = !root.awakeOn } }
    ]
  }

  Badge {
    id: ghost
    name: root.primary ? "vitals" : ""
    visible: root.kuro.hasBadge("vitals")
    kuro: root.kuro
    mark: GhostMark { tint: K.heat[root.heatLevel] }
    rows: [
      { label: "Processor", value: Math.round(root.cpuAverage) + "% busy", color: K.heat[root.heatLevel] },
      { label: "Memory", value: root.memUsed.toFixed(1) + " of " + Math.round(root.memTotal) + " GB" },
      { label: "Everything running", value: "Open btop", color: K.blue,
        action: function() { root.kuro.run("omarchy-launch-or-focus-tui btop") } }
    ]
  }

  Badge {
    id: shield
    name: root.primary ? "tailscale" : ""
    visible: root.kuro.hasBadge("tailscale") && root.tsState !== "absent"
    kuro: root.kuro
    mark: ShieldMark { state: root.tsState }
    rows: [
      { label: "Tailnet" + (root.tsTailnet ? "  ·  " + root.tsTailnet : ""),
        value: root.tsState === "up" ? "Connected" : root.tsState === "attention" ? "Needs login" : "Off" },
      { label: "Tunnel", value: root.tsState === "up" ? "Disconnect" : "Connect", color: root.tsState === "up" ? K.red : K.green,
        action: function() { root.kuro.run(root.tsState === "up" ? "tailscale down" : "tailscale up") } }
    ]
  }

  Badge {
    id: net
    name: root.primary ? "wifi" : ""
    visible: root.kuro.hasBadge("wifi")
    kuro: root.kuro
    mark: DotsMark {
      cable: root.netType === "ethernet"
      off: root.netType === ""
      lit: root.wifiSignal >= 75 ? 4 : root.wifiSignal >= 50 ? 3 : root.wifiSignal >= 25 ? 2 : (root.wifiSignal > 0 ? 1 : 0)
    }
    rows: [
      { label: root.netType === "ethernet" ? "Cable" : root.netType === "wifi" ? "Wi-Fi" : "Network",
        value: root.netName || "Not connected", color: root.netType === "" ? K.muted : K.text },
      { label: "This computer", value: root.netAddress || "none" },
      { label: "Network settings", value: "Open", color: K.blue, action: function() { root.kuro.run("omarchy-launch-or-focus-tui nmtui") } }
    ]
  }

  Badge {
    id: ring
    name: root.primary ? "battery" : ""
    visible: root.kuro.hasBadge("battery") && root.hasBattery
    kuro: root.kuro
    mark: RingMark {
      level: root.battery ? root.battery.percentage : 1
      charging: root.battery ? root.battery.state === UPowerDeviceState.Charging : false
    }
    rows: [
      { label: "Charge", value: Math.round((root.battery ? root.battery.percentage : 0) * 100) + "%" },
      { label: UPower.onBattery ? "On battery" : "On power", value: "" }
    ]
  }
}

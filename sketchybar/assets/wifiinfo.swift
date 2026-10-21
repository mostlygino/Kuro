// Everything the Wi-Fi badge needs to know, as one line of JSON, in a quarter of
// a second.
//
//   wifiinfo              print the current Wi-Fi state
//   wifiinfo --authorize  ask for the Location permission the network name needs
//
// Since macOS 14 the name of the network you are on is location data: without
// Location Services permission, CoreWLAN answers nil for it, `ipconfig`,
// `scutil` and `system_profiler` all print <redacted>, `networksetup` claims
// there is no network at all, and the old `airport` tool is gone. Signal,
// noise, rate, channel and security stay readable. So this lives in an app
// bundle with a usage description and a stable signature, like mediawatch,
// because that is what a permission needs to attach to; `--authorize` asks
// once, and every run after that can read the name.
//
// Usage: built by plugins/wifi.sh into wifiinfo.app.

import AppKit
import CoreLocation
import CoreWLAN
import Foundation

func emit(_ object: [String: Any]) {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func authorizationName(_ status: CLAuthorizationStatus) -> String {
    switch status {
    case .authorizedAlways, .authorized: return "authorized"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "undetermined"
    @unknown default: return "unknown"
    }
}

final class Authorizer: NSObject, CLLocationManagerDelegate {
    let manager = CLLocationManager()
    var done = false

    override init() {
        super.init()
        manager.delegate = self
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus != .notDetermined { done = true }
    }
}

if CommandLine.arguments.contains("--authorize") {
    let authorizer = Authorizer()
    if authorizer.manager.authorizationStatus == .notDetermined {
        // macOS only shows the prompt for an app that is frontmost and is
        // actually asking for a location: an agent app that merely requests
        // authorisation from the background is answered with silence.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)
        authorizer.manager.requestWhenInUseAuthorization()
        authorizer.manager.startUpdatingLocation()
        // The answer comes back on the run loop. A minute is plenty for
        // someone to read the prompt; after that, report what there is.
        let deadline = Date().addingTimeInterval(60)
        while !authorizer.done, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
    }
    emit(["authorization": authorizationName(authorizer.manager.authorizationStatus)])
    exit(0)
}

// The status arrives on the run loop, not with the manager: read straight
// away it is "undetermined" even when the app is authorised, and CoreWLAN
// hides the network name until this process's location client has been
// told. So wait for the first callback, briefly.
let probe = Authorizer()
let settle = Date().addingTimeInterval(1)
while !probe.done, Date() < settle {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
}
let authorization = authorizationName(probe.manager.authorizationStatus)

guard let wifi = CWWiFiClient.shared().interface() else {
    emit(["present": false, "authorization": authorization])
    exit(0)
}

var state: [String: Any] = [
    "present": true,
    "interface": wifi.interfaceName ?? "",
    "power": wifi.powerOn(),
    "authorization": authorization,
]

// Associated means there is a channel; the name alone would say nothing
// without the permission.
if wifi.powerOn(), let channel = wifi.wlanChannel() {
    state["associated"] = true
    state["ssid"] = wifi.ssid() ?? NSNull()
    state["rssi"] = wifi.rssiValue()
    state["noise"] = wifi.noiseMeasurement()
    state["rate"] = wifi.transmitRate()
    state["channel"] = channel.channelNumber
    state["band"] = [CWChannelBand.band2GHz: "2.4 GHz", .band5GHz: "5 GHz", .band6GHz: "6 GHz"][channel.channelBand] ?? "unknown"
    state["width"] = [CWChannelWidth.width20MHz: 20, .width40MHz: 40, .width80MHz: 80, .width160MHz: 160][channel.channelWidth] ?? 0
    let phy: [CWPHYMode: String] = [.mode11a: "802.11a", .mode11b: "802.11b", .mode11g: "802.11g",
                                    .mode11n: "Wi-Fi 4", .mode11ac: "Wi-Fi 5", .mode11ax: "Wi-Fi 6"]
    state["phy"] = phy[wifi.activePHYMode()] ?? "Wi-Fi 7"
    let security: [CWSecurity: String] = [
        .none: "Open", .WEP: "WEP", .wpaPersonal: "WPA Personal", .wpaPersonalMixed: "WPA/WPA2 Personal",
        .wpa2Personal: "WPA2 Personal", .personal: "WPA2/WPA3 Personal", .wpa3Personal: "WPA3 Personal",
        .wpa3Transition: "WPA2/WPA3 Personal", .wpaEnterprise: "WPA Enterprise",
        .wpaEnterpriseMixed: "WPA/WPA2 Enterprise", .wpa2Enterprise: "WPA2 Enterprise",
        .enterprise: "WPA2/WPA3 Enterprise", .wpa3Enterprise: "WPA3 Enterprise",
        .OWE: "Enhanced Open", .oweTransition: "Enhanced Open",
    ]
    state["security"] = security[wifi.security()] ?? "Secured"
} else {
    state["associated"] = false
}

emit(state)

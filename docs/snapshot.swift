// Renders a local HTML page to a PNG with WebKit, at 2x, after its scripts run.
//
//   swift docs/snapshot.swift <page.html> <out.png> <width> [javascript]
//
// For docs/make_keys.py, which snapshots docs/keys.html into docs/keys.png so
// the README shows the real page rather than a mock-up of it.

import AppKit
import WebKit
let args = CommandLine.arguments
let url = URL(fileURLWithPath: args[1]), out = args[2]
let width = CGFloat(Double(args[3]) ?? 1280)
let script = args.count > 4 ? args[4] : ""
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
final class Delegate: NSObject, WKNavigationDelegate {
    var view: WKWebView!
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(script) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                webView.evaluateJavaScript("document.body.scrollHeight") { h, _ in
                    let height = CGFloat((h as? NSNumber)?.doubleValue ?? 1600)
                    webView.setFrameSize(NSSize(width: width, height: height))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        let config = WKSnapshotConfiguration()
                        config.rect = CGRect(x: 0, y: 0, width: width, height: height)
                        // 2x whatever screen this runs on. The snapshot comes at the
                        // window's backing scale, so on a 1x display it came out half
                        // size and make_highlights.py cropped the wrong part of it.
                        config.snapshotWidth = NSNumber(value: Double(width * 2 / (window.backingScaleFactor)))
                        webView.takeSnapshot(with: config) { image, _ in
                            guard let image, let tiff = image.tiffRepresentation,
                                  let rep = NSBitmapImageRep(data: tiff),
                                  let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
                            try? png.write(to: URL(fileURLWithPath: out)); exit(0)
                        }
                    }
                }
            }
        }
    }
}
let d = Delegate()
let view = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 1400))
d.view = view
view.navigationDelegate = d
let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
window.contentView = view
view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
app.run()

// Says whether Notification Center is on screen: exit 0 when it is, 1 when not.
//
//   ncstate
//
// Open, Notification Center is a window owned by "Notification Center" that
// covers the screen; closed, it has none. It stays listed while it slides away,
// which is what the clock's click needs: a click that lands while the panel is
// open or still leaving is the click that closes it, and must not press the
// shortcut again. The window list needs no permission for owner names.
//
// Usage: swiftc -O ncstate.swift -o ncstate

import CoreGraphics

let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let open = windows.contains { ($0[kCGWindowOwnerName as String] as? String) == "Notification Center" }
exit(open ? 0 : 1)

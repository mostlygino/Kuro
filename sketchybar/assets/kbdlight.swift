// Steps the built-in keyboard's backlight, the way the brightness keys on a
// MacBook's own keyboard do, for keyboards and setups that have no such key.
//
//   kbdlight up | down      one step of 1/16, the system's own step
//   kbdlight off | max      all the way down or up
//   kbdlight                prints the level, 0 to 1
//
// Through CoreBrightness's KeyboardBrightnessClient, which is what Control
// Centre's keyboard slider uses. A private framework: if a macOS update takes
// the class away, this says so and changes nothing. With the lid closed the
// backlight is off and stays off, whatever is asked.
//
// Usage: swiftc -O kbdlight.swift -o kbdlight

import Foundation

let step: Float = 1.0 / 16

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("kbdlight: \(message)\n".utf8))
    exit(1)
}

guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW) != nil,
      let type = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type
else { fail("CoreBrightness has no KeyboardBrightnessClient on this macOS") }
let client = type.init()

let listSelector = NSSelectorFromString("copyKeyboardBacklightIDs")
guard client.responds(to: listSelector),
      let ids = client.perform(listSelector)?.takeRetainedValue() as? [NSNumber], let keyboard = ids.first
else { fail("no keyboard backlight on this Mac") }

typealias Get = @convention(c) (AnyObject, Selector, UInt64) -> Float
typealias Set = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
let getSelector = NSSelectorFromString("brightnessForKeyboard:")
let setSelector = NSSelectorFromString("setBrightness:forKeyboard:")
guard client.responds(to: getSelector), client.responds(to: setSelector) else { fail("KeyboardBrightnessClient changed") }
let get = unsafeBitCast(client.method(for: getSelector), to: Get.self)
let set = unsafeBitCast(client.method(for: setSelector), to: Set.self)

let id = keyboard.uint64Value
let now = get(client, getSelector, id)
let direction = CommandLine.arguments.dropFirst().first
guard let direction else { print(String(format: "%.3f", now)); exit(0) }
// Onto the next sixteenth, so a level set by the slider lands back on the grid.
let steps = (now / step).rounded()
let target: Float
switch direction {
case "up": target = min(1, (steps + 1) * step)
case "down": target = max(0, (steps - 1) * step)
case "off": target = 0
case "max": target = 1
default: fail("up, down, off or max")
}
guard set(client, setSelector, target, id) else { fail("the backlight refused the change") }

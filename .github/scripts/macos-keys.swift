// Post real keyboard events through the macOS HID event tap (TASK-48).
//
// Usage: swift macos-keys.swift <pid> plain|option
//
// `conduit-test key` injects into SDL's queue, which proves bindings but not
// what macOS's text system does with Option. This brings the process <pid> to
// the front and posts `x` through Quartz Event Services exactly as a keyboard
// would, either alone or with the left Option key held (a flags-changed press
// of keycode 58 first, so SDL sees left Alt, then `x` with the Option flags).
// Posting needs the runner's Accessibility grant; the line it prints says
// whether this process is trusted, so a run that injected nothing says why.
import Cocoa

let arguments = CommandLine.arguments
guard arguments.count == 3, let pid = pid_t(arguments[1]) else {
    FileHandle.standardError.write("usage: macos-keys.swift <pid> plain|option\n".data(using: .utf8)!)
    exit(2)
}
let mode = arguments[2]
guard let app = NSRunningApplication(processIdentifier: pid) else {
    FileHandle.standardError.write("no running application with pid \(pid)\n".data(using: .utf8)!)
    exit(1)
}
app.activate(options: [.activateIgnoringOtherApps])
usleep(700_000)

let source = CGEventSource(stateID: .hidSystemState)
func post(_ key: CGKeyCode, _ down: Bool, _ flags: CGEventFlags) {
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return }
    event.flags = flags
    event.post(tap: .cghidEventTap)
    usleep(80_000)
}

let leftOption = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20)
let keyX: CGKeyCode = 7
let keyLeftOption: CGKeyCode = 58
switch mode {
case "option":
    post(keyLeftOption, true, leftOption)
    post(keyX, true, leftOption)
    post(keyX, false, leftOption)
    post(keyLeftOption, false, [])
case "plain":
    post(keyX, true, [])
    post(keyX, false, [])
default:
    FileHandle.standardError.write("mode must be plain or option\n".data(using: .utf8)!)
    exit(2)
}
print("posted \(mode) x to pid \(pid) (active: \(app.isActive), accessibility trusted: \(AXIsProcessTrusted()))")

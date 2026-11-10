import Foundation
import AppKit
import CoreGraphics

/// Performs a MouseAction by posting synthetic events (all tagged with kOpenMouseFixMagic).
enum ActionRunner {
    static func run(_ action: MouseAction, button: Int64, location: CGPoint) {
        switch action {
        case .none:
            break
        case .passthrough:
            click(button: button, at: location)
        case .middleClick:
            click(button: 2, at: location)
        case .back:
            key(0x21, flags: .maskCommand)          // ⌘[
        case .forward:
            key(0x1E, flags: .maskCommand)          // ⌘]
        case .missionControl:
            dock("com.apple.expose.awake") { key(0x7E, flags: arrowFlags) }       // ⌃↑
        case .appExpose:
            dock("com.apple.expose.front.awake") { key(0x7D, flags: arrowFlags) } // ⌃↓
        case .showDesktop:
            dock("com.apple.showdesktop.awake") { key(0x67, flags: []) }          // F11
        case .launchpad:
            dock("com.apple.launchpad.toggle") { openLaunchpad() }
        case .spaceLeft:
            key(0x7B, flags: arrowFlags)            // ⌃←
        case .spaceRight:
            key(0x7C, flags: arrowFlags)            // ⌃→
        }
    }

    /// Arrow-key shortcuts only register with the fn and numeric-pad flags, like a real keyboard.
    private static let arrowFlags: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad]

    // MARK: - Synthetic events

    private static func click(button: Int64, at location: CGPoint) {
        let cgButton = CGMouseButton(rawValue: UInt32(button)) ?? .center
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            guard let e = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: location, mouseButton: cgButton) else { continue }
            e.setIntegerValueField(.mouseEventButtonNumber, value: button)
            e.setIntegerValueField(.mouseEventClickState, value: 1)
            e.setIntegerValueField(.eventSourceUserData, value: kOpenMouseFixMagic)
            e.post(tap: .cghidEventTap)
        }
    }

    private static func key(_ code: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: kOpenMouseFixMagic)
            e.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Dock / system actions

    private typealias DockSend = @convention(c) (CFString, Int32) -> Int32

    /// Sends a Dock notification through the private CoreDockSendNotification, or runs `fallback` if unavailable.
    private static func dock(_ name: String, fallback: () -> Void) {
        // RTLD_DEFAULT is (void *)-2.
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CoreDockSendNotification") else {
            fallback()
            return
        }
        let fn = unsafeBitCast(sym, to: DockSend.self)
        _ = fn(name as CFString, 0)
    }

    private static func openLaunchpad() {
        let fm = FileManager.default
        let path = fm.fileExists(atPath: "/System/Applications/Apps.app")
            ? "/System/Applications/Apps.app" : "/System/Applications/Launchpad.app"
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

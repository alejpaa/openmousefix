import AppKit
import CoreGraphics
import Foundation

/// Simulates trackpad "dock swipe" gestures (the 3/4-finger swipes that switch Spaces or
/// open Mission Control / App Exposé), so the system animation follows the mouse.
/// Uses an embedded IOHIDEvent via SkyLight on macOS 27+, falling back to legacy CGEvent
/// fields on earlier macOS releases. Main-thread only.
enum DockSwipe {
    enum Axis: Int64 {
        case horizontal = 1   // switch Spaces
        case vertical = 2     // Mission Control / App Exposé
    }

    private enum Phase: UInt32 {
        case began = 1
        case changed = 2
        case ended = 4
        case cancelled = 8
    }

    // Constants from IOKit/hid/IOHIDEventTypes.h & IOHIDEventFieldDefs.h.
    private static let kIOHIDEventTypeVelocity: UInt32 = 9
    private static let kIOHIDEventTypeDockSwipe: UInt32 = 23
    private static let kIOHIDEventOptionPhaseShift: UInt32 = 24
    private static let kIOHIDGestureFlavorDockPrimary: CFIndex = 3

    private static let kFieldDockSwipeMotion: UInt32 = (kIOHIDEventTypeDockSwipe << 16) | 1
    private static let kFieldDockSwipeProgress: UInt32 = (kIOHIDEventTypeDockSwipe << 16) | 2
    private static let kFieldDockSwipeFlavor: UInt32 = (kIOHIDEventTypeDockSwipe << 16) | 5

    private static let kFieldVelocityX: UInt32 = (kIOHIDEventTypeVelocity << 16) | 0
    private static let kFieldVelocityY: UInt32 = (kIOHIDEventTypeVelocity << 16) | 1
    private static let kFieldVelocityZ: UInt32 = (kIOHIDEventTypeVelocity << 16) | 2

    private static var offset = 0.0
    private static var lastDelta = 0.0
    private static var axis: Axis = .horizontal
    private static var invertedFromDevice = true
    private static var endRetryItems: [DispatchWorkItem] = []

    /// Reads macOS's "Natural scrolling" trackpad preference (defaults to true when unset).
    static var systemNaturalDirection: Bool {
        (UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool) ?? true
    }

    /// Computes gesture-units-per-point scaling for the main display using MMF's Space-count formula.
    static func scale(for axis: Axis) -> Double {
        let (size, spaces) = displayMetrics()
        switch axis {
        case .horizontal:
            let oneSpaceOffset = spaces <= 1 ? 2.0 : 1.0 + 1.0 / Double(spaces - 1)
            let spaceSeparatorWidth = 63.0
            return oneSpaceOffset / (max(size.width, 1) + spaceSeparatorWidth)
        case .vertical:
            return 1.0 / max(size.height, 1)
        }
    }

    static func begin(_ a: Axis, delta: Double = 0, invertedFromDevice inverted: Bool = true) {
        cancelEndRetries()
        axis = a
        invertedFromDevice = inverted
        offset = delta
        _ = post(.began)
        lastDelta = delta
    }

    /// `delta` is in gesture units (1.0 ≈ one full Space / Mission Control transition).
    static func change(_ delta: Double) {
        guard delta != 0 else { return }
        offset += delta
        _ = post(.changed)
        lastDelta = delta
    }

    static func end(cancel: Bool = false) {
        cancelEndRetries()
        var phase: Phase = cancel ? .cancelled : .ended
        // Cancel the swipe if the final movement reversed direction relative to the net offset.
        if phase == .ended && sign(lastDelta) != sign(offset) {
            phase = .cancelled
        }
        let events = post(phase)
        lastDelta = 0
        guard !events.isEmpty else { return }

        // The Dock occasionally misses the first end event under load; re-post at 0.2s and 0.5s.
        for delay in [0.2, 0.5] {
            let item = DispatchWorkItem {
                for event in events { event.post(tap: .cgSessionEventTap) }
            }
            endRetryItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    // MARK: - Event construction & posting

    private static func post(_ phase: Phase) -> [CGEvent] {
        let exitSpeed = (phase == .ended || phase == .cancelled) ? lastDelta * 100.0 : 0.0

        let events: [CGEvent]
        if #available(macOS 27.0, *), let hidEvent = makeHIDDockSwipeEvent(phase: phase, exitSpeed: exitSpeed) {
            events = [hidEvent]
        } else {
            events = makeLegacyDockSwipeEvents(phase: phase, exitSpeed: exitSpeed)
        }

        for event in events { event.post(tap: .cgSessionEventTap) }
        return events
    }

    private static func makeHIDDockSwipeEvent(phase: Phase, exitSpeed: Double) -> CGEvent? {
        guard let setIOHID = PrivateSPI.slEventSetIOHIDEvent,
              let create = PrivateSPI.hidEventCreate,
              let setInt = PrivateSPI.hidEventSetInteger,
              let setDouble = PrivateSPI.hidEventSetDouble,
              let append = PrivateSPI.hidEventAppend,
              let type30 = CGEventType(rawValue: 30),
              let cgEvent = CGEvent(source: nil) else { return nil }

        let options = phase.rawValue << kIOHIDEventOptionPhaseShift
        guard let hidEvent = create(nil, kIOHIDEventTypeDockSwipe, 0, options) else { return nil }
        defer { Unmanaged<AnyObject>.fromOpaque(hidEvent).release() }

        // On macOS 27+, Dock applies natural-scrolling inversion itself when reading DockSwipeProgress,
        // so undo the pre-flip used for the legacy CGEvent field 136 path.
        let progress = invertedFromDevice ? -offset : offset
        setInt(hidEvent, kFieldDockSwipeMotion, CFIndex(axis.rawValue))
        setInt(hidEvent, kFieldDockSwipeFlavor, kIOHIDGestureFlavorDockPrimary)
        setDouble(hidEvent, kFieldDockSwipeProgress, progress)

        if phase == .ended || phase == .cancelled {
            if let child = create(nil, kIOHIDEventTypeVelocity, 0, 0) {
                setDouble(child, kFieldVelocityX, exitSpeed)
                setDouble(child, kFieldVelocityY, exitSpeed)
                setDouble(child, kFieldVelocityZ, 0.0)
                append(hidEvent, child, false)
                Unmanaged<AnyObject>.fromOpaque(child).release()
            }
        }

        cgEvent.type = type30
        cgEvent.setIntegerValueField(.eventSourceUserData, value: kOpenMouseFixMagic)
        setIOHID(cgEvent, hidEvent)
        return cgEvent
    }

    private static func makeLegacyDockSwipeEvents(phase: Phase, exitSpeed: Double) -> [CGEvent] {
        guard let gesture = CGEvent(source: nil), let dock = CGEvent(source: nil) else { return [] }

        let val41: Int64 = 33231
        gesture.setIntegerValueField(field(55), value: 29)          // NSEventTypeGesture
        gesture.setIntegerValueField(field(41), value: val41)
        gesture.setIntegerValueField(.eventSourceUserData, value: kOpenMouseFixMagic)

        let phaseVal = Int64(phase.rawValue)
        dock.setIntegerValueField(field(55), value: 30)             // gesture subtype event
        dock.setIntegerValueField(field(110), value: Int64(kIOHIDEventTypeDockSwipe))
        dock.setIntegerValueField(field(132), value: phaseVal)
        dock.setIntegerValueField(field(134), value: phaseVal)
        dock.setDoubleValueField(field(124), value: offset)
        dock.setIntegerValueField(field(135), value: Int64(Float32(offset).bitPattern))
        dock.setIntegerValueField(field(41), value: val41)

        let encodedType = Double(Float32(bitPattern: UInt32(axis.rawValue)))
        dock.setDoubleValueField(field(119), value: encodedType)
        dock.setDoubleValueField(field(139), value: encodedType)
        dock.setIntegerValueField(field(123), value: axis.rawValue)
        dock.setIntegerValueField(field(165), value: axis.rawValue)
        dock.setIntegerValueField(field(136), value: invertedFromDevice ? 1 : 0)

        if phase == .ended || phase == .cancelled {
            dock.setDoubleValueField(field(129), value: exitSpeed)
            dock.setDoubleValueField(field(130), value: exitSpeed)
        }
        dock.setIntegerValueField(.eventSourceUserData, value: kOpenMouseFixMagic)

        return [dock, gesture]
    }

    // MARK: - Helpers

    private static func field(_ raw: UInt32) -> CGEventField { CGEventField(rawValue: raw)! }

    private static func sign(_ x: Double) -> Int {
        x > 0 ? 1 : (x < 0 ? -1 : 0)
    }

    private static func cancelEndRetries() {
        for item in endRetryItems { item.cancel() }
        endRetryItems.removeAll()
    }

    private static func displayMetrics() -> (size: CGSize, spaces: Int) {
        guard let screen = NSScreen.main else { return (CGSize(width: 1440, height: 900), 1) }
        let size = screen.frame.size
        var spaceCount = 1
        if let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
           let uuidRef = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
           let cgsMain = PrivateSPI.cgsMainConnectionID,
           let cgsSpaces = PrivateSPI.cgsCopyManagedDisplaySpaces,
           let list = cgsSpaces(cgsMain())?.takeRetainedValue() as? [[String: Any]] {
            let uuid = CFUUIDCreateString(kCFAllocatorDefault, uuidRef) as String
            if let entry = list.first(where: { ($0["Display Identifier"] as? String) == uuid }),
               let spaces = entry["Spaces"] as? [Any] {
                spaceCount = max(spaces.count, 1)
            }
        }
        return (size, spaceCount)
    }
}

private enum PrivateSPI {
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)

    private static func sym<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as type: T.Type) -> T? {
        guard let handle, let ptr = dlsym(handle, name) else { return nil }
        return unsafeBitCast(ptr, to: type)
    }

    typealias SLEventSetIOHIDEventFn = @convention(c) (CGEvent, UnsafeRawPointer) -> Void
    typealias CGSMainConnectionIDFn = @convention(c) () -> Int32
    typealias CGSCopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?

    typealias IOHIDEventCreateFn = @convention(c) (CFAllocator?, UInt32, UInt64, UInt32) -> UnsafeMutableRawPointer?
    typealias IOHIDEventSetIntegerValueFn = @convention(c) (UnsafeMutableRawPointer, UInt32, CFIndex) -> Void
    typealias IOHIDEventSetDoubleValueFn = @convention(c) (UnsafeMutableRawPointer, UInt32, Double) -> Void
    typealias IOHIDEventAppendEventFn = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, Bool) -> Void

    static let slEventSetIOHIDEvent = sym(skyLight, "SLEventSetIOHIDEvent", as: SLEventSetIOHIDEventFn.self)
    static let cgsMainConnectionID = sym(skyLight, "CGSMainConnectionID", as: CGSMainConnectionIDFn.self)
    static let cgsCopyManagedDisplaySpaces = sym(skyLight, "CGSCopyManagedDisplaySpaces", as: CGSCopyManagedDisplaySpacesFn.self)

    static let hidEventCreate = sym(ioKit, "IOHIDEventCreate", as: IOHIDEventCreateFn.self)
    static let hidEventSetInteger = sym(ioKit, "IOHIDEventSetIntegerValue", as: IOHIDEventSetIntegerValueFn.self)
    static let hidEventSetDouble = sym(ioKit, "IOHIDEventSetDoubleValue", as: IOHIDEventSetDoubleValueFn.self)
    static let hidEventAppend = sym(ioKit, "IOHIDEventAppendEvent", as: IOHIDEventAppendEventFn.self)
}

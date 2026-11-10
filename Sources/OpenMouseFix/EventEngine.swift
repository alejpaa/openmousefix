import Foundation
import CoreGraphics

/// Owns the global CGEvent tap: reverses scroll direction, feeds the smooth scroller,
/// and turns extra mouse buttons into clicks/gestures.
/// All callbacks run on the main run loop, so access to Settings is main-thread only.
final class EventEngine {
    static let shared = EventEngine()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let scroller = SmoothScroller()

    /// State of the single button currently being tracked (swallowed down event).
    private struct ActiveButton {
        let number: Int64
        let config: ButtonConfig
        var dx: Double = 0
        var dy: Double = 0
        var fired = false
    }
    private var active: ActiveButton?

    var isRunning: Bool {
        guard let tap = tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    private init() {}

    /// Installs the tap. Returns false when creation fails (no Accessibility permission).
    func start() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.scrollWheel, .otherMouseDown, .otherMouseUp, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }

        let callback: CGEventTapCallBack = { _, type, event, _ in
            EventEngine.shared.handle(type: type, event: event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: callback, userInfo: nil) else { return false }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        source = src
        return true
    }

    func stop() {
        if let src = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        if let port = tap {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        tap = nil
        source = nil
        active = nil
    }

    // MARK: - Dispatch

    /// Returns the event to pass on, or nil to swallow it.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        // Our own synthetic events must never be processed again.
        if event.getIntegerValueField(.eventSourceUserData) == kOpenMouseFixMagic { return pass }
        guard Settings.shared.enabled else { return pass }

        switch type {
        case .scrollWheel:
            return handleScroll(event) ? pass : nil
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            return handleButton(type: type, event: event) ? pass : nil
        default:
            return pass
        }
    }

    // MARK: - Scroll

    /// Returns true if the event should pass (possibly modified), false to swallow.
    private func handleScroll(_ event: CGEvent) -> Bool {
        let s = Settings.shared
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0

        if continuous { // trackpad / Magic Mouse
            if s.reverseTrackpad { negateDeltas(event) }
            return true
        }

        // Regular mouse wheel.
        let flags = event.flags
        let modifierHeld = !flags.isDisjoint(with: [.maskCommand, .maskAlternate, .maskControl])
        if !s.smoothScroll || modifierHeld {
            if s.reverseMouse { negateDeltas(event) }
            return true
        }

        var v = tickSign(event, .scrollWheelEventDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1)
        var h = tickSign(event, .scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2)
        if s.reverseMouse { v = -v; h = -h }
        // Shift + wheel scrolls horizontally.
        if flags.contains(.maskShift) && h == 0 { h = v; v = 0 }
        scroller.add(dx: h, dy: v)
        return false
    }

    /// Direction (-1, 0, 1) of a wheel tick; falls back to the fixed-point delta when the int delta is 0.
    private func tickSign(_ e: CGEvent, _ intField: CGEventField, _ fixedField: CGEventField) -> Double {
        let i = e.getIntegerValueField(intField)
        if i != 0 { return i > 0 ? 1 : -1 }
        let f = e.getDoubleValueField(fixedField)
        return f > 0 ? 1 : (f < 0 ? -1 : 0)
    }

    private func negateDeltas(_ e: CGEvent) {
        let ints: [CGEventField] = [.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2,
                                    .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2]
        for f in ints { e.setIntegerValueField(f, value: -e.getIntegerValueField(f)) }
        let doubles: [CGEventField] = [.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2]
        for f in doubles { e.setDoubleValueField(f, value: -e.getDoubleValueField(f)) }
    }

    // MARK: - Buttons

    /// Returns true if the event should pass, false to swallow.
    private func handleButton(type: CGEventType, event: CGEvent) -> Bool {
        let number = event.getIntegerValueField(.mouseEventButtonNumber)

        switch type {
        case .otherMouseDown:
            // A new press replaces any tracked button, so a lost mouse-up (e.g. tap disabled)
            // can never leave the engine stuck.
            guard let config = Settings.shared.config(forButton: number) else { return true }
            if config.click == .passthrough && !config.dragEnabled { return true }
            active = ActiveButton(number: number, config: config)
            return false

        case .otherMouseDragged:
            guard var a = active, a.number == number else { return true }
            if a.config.dragEnabled && !a.fired {
                a.dx += event.getDoubleValueField(.mouseEventDeltaX)
                a.dy += event.getDoubleValueField(.mouseEventDeltaY)
                if hypot(a.dx, a.dy) >= Settings.shared.dragThreshold {
                    let action: MouseAction
                    if abs(a.dx) > abs(a.dy) {
                        action = a.dx < 0 ? a.config.dragLeft : a.config.dragRight
                    } else {
                        action = a.dy < 0 ? a.config.dragUp : a.config.dragDown
                    }
                    a.fired = true
                    dispatch(action, button: number, location: event.location)
                }
            }
            active = a
            return false

        case .otherMouseUp:
            guard let a = active, a.number == number else { return true }
            active = nil
            if !a.fired { dispatch(a.config.click, button: number, location: event.location) }
            return false

        default:
            return true
        }
    }

    /// Actions post synthetic events, which must not happen inside the tap callback.
    private func dispatch(_ action: MouseAction, button: Int64, location: CGPoint) {
        DispatchQueue.main.async { ActionRunner.run(action, button: button, location: location) }
    }
}

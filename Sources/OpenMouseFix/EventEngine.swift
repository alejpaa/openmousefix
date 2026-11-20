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
        /// Set once the drag moved far enough to be considered a gesture.
        var locked = false
        /// Non-nil while an interactive (trackpad-like) swipe is in progress.
        var swipe: DockSwipe.Axis?
        /// +1/-1: maps raw mouse movement to DockSwipe delta direction.
        var swipeSign: Double = 1
        /// Gesture units per point of mouse movement for the active swipe axis.
        var swipeScale: Double = 1
    }

    /// Distance (pt) after which a drag counts as a gesture (and the cursor locks, if enabled).
    private let lockDistance = 6.0
    private var cursorFrozen = false
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
        endActiveGesture()
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
            endActiveGesture(cancel: true)
            guard let config = Settings.shared.config(forButton: number) else { return true }
            if config.click == .passthrough && !config.dragEnabled { return true }
            active = ActiveButton(number: number, config: config)
            return false

        case .otherMouseDragged:
            guard var a = active, a.number == number else { return true }
            guard a.config.dragEnabled else { return false }
            let ddx = event.getDoubleValueField(.mouseEventDeltaX)
            let ddy = event.getDoubleValueField(.mouseEventDeltaY)
            a.dx += ddx
            a.dy += ddy

            if !a.locked && hypot(a.dx, a.dy) >= lockDistance {
                a.locked = true
                if Settings.shared.lockCursorDuringGestures { freezeCursor(true) }
                let horizontal = abs(a.dx) > abs(a.dy)
                if let (axis, sign) = interactiveAxis(a.config, horizontal: horizontal) {
                    let natural = DockSwipe.systemNaturalDirection
                    let effectiveSign = sign * (natural ? 1.0 : -1.0)
                    let swipeScale = DockSwipe.scale(for: axis)
                    a.swipe = axis
                    a.swipeSign = effectiveSign
                    a.swipeScale = swipeScale
                    a.fired = true
                    let initial = (horizontal ? a.dx : a.dy) * effectiveSign * swipeScale
                    DispatchQueue.main.async {
                        DockSwipe.begin(axis, delta: initial, invertedFromDevice: natural)
                    }
                }
            } else if let axis = a.swipe {
                let d = (axis == .horizontal ? ddx : ddy) * a.swipeSign * a.swipeScale
                if d != 0 {
                    DispatchQueue.main.async { DockSwipe.change(d) }
                }
            }

            if a.swipe == nil && !a.fired && hypot(a.dx, a.dy) >= Settings.shared.dragThreshold {
                let action: MouseAction
                if abs(a.dx) > abs(a.dy) {
                    action = a.dx < 0 ? a.config.dragLeft : a.config.dragRight
                } else {
                    action = a.dy < 0 ? a.config.dragUp : a.config.dragDown
                }
                a.fired = true
                dispatch(action, button: number, location: event.location)
            }
            active = a
            return false

        case .otherMouseUp:
            guard let a = active, a.number == number else { return true }
            endActiveGesture(cancel: false)
            if !a.fired { dispatch(a.config.click, button: number, location: event.location) }
            return false

        default:
            return true
        }
    }

    /// If the configured actions for this axis are the ones a trackpad swipe performs,
    /// returns the dock-swipe axis and the sign that maps mouse movement onto it.
    private func interactiveAxis(_ c: ButtonConfig, horizontal: Bool) -> (DockSwipe.Axis, Double)? {
        // Default: the content follows the mouse (drag left → Space on the left).
        let invert = Settings.shared.invertGestures ? 1.0 : -1.0
        if horizontal {
            if c.dragLeft == .spaceLeft && c.dragRight == .spaceRight { return (.horizontal, -invert) }
            if c.dragLeft == .spaceRight && c.dragRight == .spaceLeft { return (.horizontal, invert) }
        } else {
            if c.dragUp == .missionControl && c.dragDown == .appExpose { return (.vertical, invert) }
            if c.dragUp == .appExpose && c.dragDown == .missionControl { return (.vertical, -invert) }
        }
        return nil
    }

    private func endActiveGesture(cancel: Bool = true) {
        if active?.swipe != nil {
            DispatchQueue.main.async { DockSwipe.end(cancel: cancel) }
        }
        active = nil
        freezeCursor(false)
    }

    /// Keeps the cursor still during a gesture (mouse deltas still arrive).
    private func freezeCursor(_ on: Bool) {
        guard on != cursorFrozen else { return }
        cursorFrozen = on
        CGAssociateMouseAndMouseCursorPosition(on ? 0 : 1)
    }

    /// Actions post synthetic events, which must not happen inside the tap callback.
    private func dispatch(_ action: MouseAction, button: Int64, location: CGPoint) {
        DispatchQueue.main.async { ActionRunner.run(action, button: button, location: location) }
    }
}

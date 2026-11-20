import Foundation
import CoreGraphics

/// Emits trackpad-like continuous scroll (type 22) and accompanying scroll-gesture
/// (type 29, subtype 6) CGEvents with explicit scroll and momentum phases.
/// Main-thread only.
enum GestureScroll {
    enum ScrollPhase: Int64 {
        case undefined = 0
        case began = 1
        case changed = 2
        case ended = 4
        case cancelled = 8
        case mayBegin = 128
    }

    /// Accumulates fractional line deltas per axis and locks rounding direction to the
    /// first non-zero sample after reset, so line deltas never flip sign and the first
    /// non-zero pixel delta produces at least 1 line unit when appropriate.
    private struct BiasedPixelator {
        private enum Direction { case up, down }
        private var direction: Direction?
        private var remainder = 0.0

        mutating func step(_ input: Double) -> Int64 {
            guard input != 0 else { return 0 }
            let dir: Direction
            if let existing = direction {
                dir = existing
            } else {
                dir = input > 0 ? .up : .down
                direction = dir
            }

            let precise = input + remainder
            let rounded = (dir == .up) ? ceil(precise) : floor(precise)
            remainder = precise - rounded
            return Int64(rounded)
        }

        mutating func reset() {
            direction = nil
            remainder = 0
        }
    }

    private static var linePixelatorX = BiasedPixelator()
    private static var linePixelatorY = BiasedPixelator()

    static func resetSubPixelator() {
        linePixelatorX.reset()
        linePixelatorY.reset()
    }

    static func resetSubPixelatorX() {
        linePixelatorX.reset()
    }

    static func resetSubPixelatorY() {
        linePixelatorY.reset()
    }

    static func postGesture(dx: Int32, dy: Int32, phase: ScrollPhase) {
        post(dx: dx, dy: dy, scrollPhase: phase, momentumPhase: .none)
    }

    static func postMomentum(dx: Int32, dy: Int32, phase: CGMomentumScrollPhase) {
        post(dx: dx, dy: dy, scrollPhase: .undefined, momentumPhase: phase)
    }

    private static func post(dx: Int32, dy: Int32, scrollPhase: ScrollPhase, momentumPhase: CGMomentumScrollPhase) {
        guard let e22 = CGEvent(source: nil) else { return }

        let ts = CGEventTimestamp(DispatchTime.now().uptimeNanoseconds)
        let lineX = linePixelatorX.step(Double(dx) / 10.0)
        let lineY = linePixelatorY.step(Double(dy) / 10.0)
        let inverted: Int64 = DockSwipe.systemNaturalDirection ? 1 : 0

        e22.setIntegerValueField(field(55), value: 22) // NSEventTypeScrollWheel
        e22.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e22.setIntegerValueField(field(137), value: inverted)

        e22.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: lineY)
        e22.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy))
        e22.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: lineY << 16)

        e22.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: lineX)
        e22.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
        e22.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: lineX << 16)

        e22.setIntegerValueField(.scrollWheelEventScrollPhase, value: scrollPhase.rawValue)
        e22.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentumPhase.rawValue))
        e22.setIntegerValueField(.eventSourceUserData, value: kOpenMouseFixMagic)
        e22.timestamp = ts
        e22.post(tap: .cgSessionEventTap)

        guard scrollPhase != .undefined, let e29 = CGEvent(source: nil) else { return }

        let gx = dx == 0 ? -0.0 : Double(dx) * 1.67
        let gy = dy == 0 ? -0.0 : Double(dy) * 1.67

        e29.setIntegerValueField(field(55), value: 29)  // NSEventTypeGesture
        e29.setIntegerValueField(field(110), value: 6)  // kIOHIDEventTypeScroll
        e29.setDoubleValueField(field(116), value: gx)
        e29.setDoubleValueField(field(119), value: gy)
        e29.setIntegerValueField(field(132), value: scrollPhase.rawValue)
        e29.setIntegerValueField(.eventSourceUserData, value: kOpenMouseFixMagic)
        e29.timestamp = ts
        e29.post(tap: .cgSessionEventTap)
    }

    private static func field(_ raw: UInt32) -> CGEventField { CGEventField(rawValue: raw)! }
}

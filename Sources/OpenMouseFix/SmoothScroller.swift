import Foundation
import CoreGraphics

/// Turns discrete wheel ticks into a stream of small pixel-based scroll events
/// with optional acceleration. Main-thread only.
final class SmoothScroller {
    private var pendingX = 0.0, pendingY = 0.0   // distance (px) still to emit
    private var remX = 0.0, remY = 0.0           // sub-pixel remainders carried between frames
    private var timer: Timer?

    // Acceleration state, per axis.
    private var streakX = 0, streakY = 0
    private var lastTickX = 0.0, lastTickY = 0.0
    private var lastDirX = 0.0, lastDirY = 0.0

    private let baseStep = 40.0
    private let streakWindow = 0.120
    private let maxStreak = 12

    /// dx/dy are tick directions (-1, 0, +1).
    func add(dx: Double, dy: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        let s = Settings.shared
        if dy != 0 {
            pendingY = push(dir: dy, pending: pendingY, now: now, accel: s.acceleration,
                            streak: &streakY, last: &lastTickY, lastDir: &lastDirY)
        }
        if dx != 0 {
            pendingX = push(dir: dx, pending: pendingX, now: now, accel: s.acceleration,
                            streak: &streakX, last: &lastTickX, lastDir: &lastDirX)
        }
        startTimerIfNeeded()
    }

    private func push(dir: Double, pending: Double, now: Double, accel: Bool,
                      streak: inout Int, last: inout Double, lastDir: inout Double) -> Double {
        var pending = pending
        // Direction reversal: discard what was still gliding the other way.
        if pending != 0 && (pending > 0) != (dir > 0) { pending = 0 }

        if now - last <= streakWindow && dir == lastDir {
            streak = min(streak + 1, maxStreak)
        } else {
            streak = 0
        }
        last = now
        lastDir = dir

        let mult = accel ? 1 + Double(streak) * 0.35 : 1
        return pending + dir * baseStep * Settings.shared.scrollSpeed * mult
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.frame() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func frame() {
        let f = 0.35 - Settings.shared.smoothness * 0.27
        let outX = step(&pendingX, &remX, fraction: f)
        let outY = step(&pendingY, &remY, fraction: f)
        if outX != 0 || outY != 0 { post(dx: outX, dy: outY) }
        if abs(pendingX) < 0.01 && abs(pendingY) < 0.01 {
            pendingX = 0; pendingY = 0; remX = 0; remY = 0
            stopTimer()
        }
    }

    /// Consumes a fraction of `pending` (at least ~1px) and returns whole pixels to emit.
    private func step(_ pending: inout Double, _ rem: inout Double, fraction: Double) -> Int32 {
        guard abs(pending) >= 0.01 else { pending = 0; return 0 }
        let mag = max(abs(pending) * fraction, min(1, abs(pending)))
        let amount = pending > 0 ? mag : -mag
        pending -= amount
        let total = amount + rem
        let whole = total.rounded(.towardZero)
        rem = total - whole
        return Int32(whole)
    }

    private func post(dx: Int32, dy: Int32) {
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                              wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.eventSourceUserData, value: kOpenMouseFixMagic)
        e.post(tap: .cgSessionEventTap)
    }
}

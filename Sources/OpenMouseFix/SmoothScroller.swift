import Foundation
import CoreGraphics

/// Turns discrete wheel ticks into a stream of trackpad-like pixel scroll events
/// with gesture/momentum phases and optional acceleration. Main-thread only.
final class SmoothScroller {
    private enum PhaseState {
        case idle
        case gesture(beganSent: Bool)
        case momentum
    }

    private var pendingX = 0.0, pendingY = 0.0   // distance (px) still to emit
    private var remX = 0.0, remY = 0.0           // sub-pixel remainders carried between frames
    private var timer: Timer?
    private var state: PhaseState = .idle
    private var lastTickTime = 0.0

    // Acceleration state, per axis.
    private var streakX = 0, streakY = 0
    private var lastTickX = 0.0, lastTickY = 0.0
    private var lastDirX = 0.0, lastDirY = 0.0

    private let baseStep = 40.0
    private let streakWindow = 0.120
    private let maxStreak = 12
    private let gestureHold = 0.040

    /// dx/dy are tick directions (-1, 0, +1).
    func add(dx: Double, dy: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        let s = Settings.shared

        switch state {
        case .idle:
            state = .gesture(beganSent: false)
        case .gesture:
            break
        case .momentum:
            // Cleanly end ongoing momentum before starting a new gesture.
            GestureScroll.postMomentum(dx: 0, dy: 0, phase: .end)
            state = .gesture(beganSent: false)
        }
        lastTickTime = now

        if dy != 0 {
            pendingY = push(dir: dy, pending: pendingY, rem: &remY, now: now, accel: s.acceleration,
                            streak: &streakY, last: &lastTickY, lastDir: &lastDirY,
                            onReverse: GestureScroll.resetSubPixelatorY)
        }
        if dx != 0 {
            pendingX = push(dir: dx, pending: pendingX, rem: &remX, now: now, accel: s.acceleration,
                            streak: &streakX, last: &lastTickX, lastDir: &lastDirX,
                            onReverse: GestureScroll.resetSubPixelatorX)
        }
        startTimerIfNeeded()
    }

    private func push(dir: Double, pending: Double, rem: inout Double, now: Double, accel: Bool,
                      streak: inout Int, last: inout Double, lastDir: inout Double,
                      onReverse: () -> Void) -> Double {
        var pending = pending
        // Direction reversal: discard what was still gliding the other way.
        if pending != 0 && (pending > 0) != (dir > 0) {
            pending = 0
            rem = 0
            onReverse()
        }

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
        let now = ProcessInfo.processInfo.systemUptime
        let f = 0.35 - Settings.shared.smoothness * 0.27
        let outX = step(&pendingX, &remX, fraction: f)
        let outY = step(&pendingY, &remY, fraction: f)

        if outX != 0 || outY != 0 {
            switch state {
            case .idle, .gesture(beganSent: false):
                GestureScroll.resetSubPixelator()
                GestureScroll.postGesture(dx: outX, dy: outY, phase: .began)
                state = .gesture(beganSent: true)
            case .gesture(beganSent: true):
                if now - lastTickTime >= gestureHold {
                    GestureScroll.postGesture(dx: 0, dy: 0, phase: .ended)
                    GestureScroll.resetSubPixelator()
                    GestureScroll.postMomentum(dx: outX, dy: outY, phase: .begin)
                    state = .momentum
                } else {
                    GestureScroll.postGesture(dx: outX, dy: outY, phase: .changed)
                }
            case .momentum:
                GestureScroll.postMomentum(dx: outX, dy: outY, phase: .continuous)
            }
            return
        }

        if abs(pendingX) < 0.01 && abs(pendingY) < 0.01 {
            pendingX = 0; pendingY = 0; remX = 0; remY = 0
            switch state {
            case .idle, .gesture(beganSent: false):
                break
            case .gesture(beganSent: true):
                GestureScroll.postGesture(dx: 0, dy: 0, phase: .ended)
            case .momentum:
                GestureScroll.postMomentum(dx: 0, dy: 0, phase: .end)
            }
            state = .idle
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
}

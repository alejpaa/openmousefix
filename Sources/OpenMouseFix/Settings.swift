import Foundation
import Combine

/// Marker stored in `CGEventField.eventSourceUserData` on every event this app synthesizes,
/// so the event tap can ignore its own events.
let kOpenMouseFixMagic: Int64 = 0x4F4D_4658 // "OMFX"

/// Actions that can be bound to a mouse button click or a click-and-drag gesture.
enum MouseAction: String, CaseIterable, Identifiable, Codable {
    case passthrough      // deliver the original button event unchanged (click only)
    case none             // do nothing
    case back             // ⌘[
    case forward          // ⌘]
    case missionControl
    case appExpose
    case showDesktop
    case launchpad        // Launchpad, or the "Apps" app on macOS 26+
    case spaceLeft        // ⌃←
    case spaceRight       // ⌃→
    case middleClick      // synthesize a middle-button click

    var id: String { rawValue }

    var title: String {
        switch self {
        case .passthrough: return "Normal (sin cambios)"
        case .none: return "Nada"
        case .back: return "Atrás"
        case .forward: return "Adelante"
        case .missionControl: return "Mission Control"
        case .appExpose: return "App Exposé"
        case .showDesktop: return "Mostrar escritorio"
        case .launchpad: return "Launchpad / Apps"
        case .spaceLeft: return "Escritorio a la izquierda"
        case .spaceRight: return "Escritorio a la derecha"
        case .middleClick: return "Clic central"
        }
    }

    /// Actions that make sense for a drag gesture (passthrough does not).
    static var dragActions: [MouseAction] { allCases.filter { $0 != .passthrough } }
}

/// Configuration for one mouse button.
struct ButtonConfig: Codable, Equatable {
    var click: MouseAction
    var dragEnabled: Bool
    var dragLeft: MouseAction
    var dragRight: MouseAction
    var dragUp: MouseAction
    var dragDown: MouseAction

    static func gestures(click: MouseAction) -> ButtonConfig {
        ButtonConfig(click: click, dragEnabled: true,
                     dragLeft: .spaceLeft, dragRight: .spaceRight,
                     dragUp: .missionControl, dragDown: .appExpose)
    }

    static let plain = ButtonConfig(click: .passthrough, dragEnabled: false,
                                    dragLeft: .none, dragRight: .none,
                                    dragUp: .none, dragDown: .none)
}

/// App-wide settings, persisted in UserDefaults. Accessed only from the main thread.
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    // General
    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "enabled") } }

    // Mouse wheel
    @Published var smoothScroll: Bool { didSet { d.set(smoothScroll, forKey: "smoothScroll") } }
    /// Multiplier for pixels per wheel tick. Range 0.3...3.0, default 1.0.
    @Published var scrollSpeed: Double { didSet { d.set(scrollSpeed, forKey: "scrollSpeed") } }
    /// 0 = snappy, 1 = very smooth/long glide. Default 0.5.
    @Published var smoothness: Double { didSet { d.set(smoothness, forKey: "smoothness") } }
    @Published var acceleration: Bool { didSet { d.set(acceleration, forKey: "acceleration") } }
    @Published var reverseMouse: Bool { didSet { d.set(reverseMouse, forKey: "reverseMouse") } }

    // Trackpad
    @Published var reverseTrackpad: Bool { didSet { d.set(reverseTrackpad, forKey: "reverseTrackpad") } }

    // Buttons (CGEvent button numbers: 2 = middle, 3 = back/side, 4 = forward/side)
    @Published var middleButton: ButtonConfig { didSet { save(middleButton, "middleButton") } }
    @Published var button4: ButtonConfig { didSet { save(button4, "button4") } }
    @Published var button5: ButtonConfig { didSet { save(button5, "button5") } }

    /// Minimum drag distance (points) to trigger a gesture. Default 60.
    @Published var dragThreshold: Double { didSet { d.set(dragThreshold, forKey: "dragThreshold") } }

    private init() {
        enabled = d.object(forKey: "enabled") as? Bool ?? true
        smoothScroll = d.object(forKey: "smoothScroll") as? Bool ?? true
        scrollSpeed = d.object(forKey: "scrollSpeed") as? Double ?? 1.0
        smoothness = d.object(forKey: "smoothness") as? Double ?? 0.5
        acceleration = d.object(forKey: "acceleration") as? Bool ?? true
        reverseMouse = d.object(forKey: "reverseMouse") as? Bool ?? true
        reverseTrackpad = d.object(forKey: "reverseTrackpad") as? Bool ?? false
        dragThreshold = d.object(forKey: "dragThreshold") as? Double ?? 60
        middleButton = Settings.load("middleButton") ?? .plain
        button4 = Settings.load("button4") ?? .gestures(click: .back)
        button5 = Settings.load("button5") ?? .gestures(click: .forward)
    }

    /// Returns the config for a CGEvent button number, or nil if the button is not handled.
    func config(forButton number: Int64) -> ButtonConfig? {
        switch number {
        case 2: return middleButton
        case 3: return button4
        case 4: return button5
        default: return nil
        }
    }

    private func save(_ c: ButtonConfig, _ key: String) {
        if let data = try? JSONEncoder().encode(c) { d.set(data, forKey: key) }
    }

    private static func load(_ key: String) -> ButtonConfig? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ButtonConfig.self, from: data)
    }
}

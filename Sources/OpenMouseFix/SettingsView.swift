import SwiftUI
import ServiceManagement
import Combine

private final class LocalState: ObservableObject {
    @Published var trusted = AXIsProcessTrusted()
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginError: String?
}

struct SettingsView: View {
    @ObservedObject private var settings = Settings.shared
    // Note: @State is a macro in the macOS 27 SDK and its plugin is missing from the
    // Command Line Tools, so local view state lives in an ObservableObject instead.
    @StateObject private var model = LocalState()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        Form {
            if !model.trusted {
                Section {
                    Text("OpenMouseFix necesita permiso de Accesibilidad para funcionar.")
                        .foregroundStyle(.orange)
                    Button("Abrir Ajustes del Sistema") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }

            Section("General") {
                Toggle("Activado", isOn: $settings.enabled)
                Toggle("Abrir al iniciar sesión", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { setLaunchAtLogin($0) }))
                if let loginError = model.loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Rueda del ratón") {
                Toggle("Desplazamiento suave", isOn: $settings.smoothScroll)
                LabeledContent("Velocidad") {
                    HStack {
                        Slider(value: $settings.scrollSpeed, in: 0.3...3)
                        Text(String(format: "%.1f×", settings.scrollSpeed))
                            .monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                .disabled(!settings.smoothScroll)
                LabeledContent("Suavidad") {
                    Slider(value: $settings.smoothness, in: 0...1)
                }
                .disabled(!settings.smoothScroll)
                Toggle("Aceleración", isOn: $settings.acceleration)
                    .disabled(!settings.smoothScroll)
                Toggle("Invertir dirección", isOn: $settings.reverseMouse)
                Text("La inversión se aplica solo al ratón, no al trackpad.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Trackpad") {
                Toggle("Invertir dirección", isOn: $settings.reverseTrackpad)
                Text("El «desplazamiento natural» de macOS afecta a ambos dispositivos; usa estos interruptores para invertir solo uno.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ButtonSection(title: "Botón 4 (lateral atrás)", config: $settings.button4)
            ButtonSection(title: "Botón 5 (lateral adelante)", config: $settings.button5)
            ButtonSection(title: "Botón central", config: $settings.middleButton)

            Section("Gestos") {
                LabeledContent("Distancia mínima") {
                    HStack {
                        Slider(value: $settings.dragThreshold, in: 20...200)
                        Text("\(Int(settings.dragThreshold)) pt")
                            .monospacedDigit().frame(width: 55, alignment: .trailing)
                    }
                }
            }

            Section {
                HStack {
                    Text("OpenMouseFix \(version)").foregroundStyle(.secondary)
                    Spacer()
                    if let url = URL(string: "https://github.com/alejpaa/openmousefix") {
                        Link("GitHub", destination: url)
                    }
                }
                .font(.caption)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 500, idealWidth: 520, maxWidth: 560, minHeight: 400, idealHeight: 680)
        .onReceive(timer) { _ in
            let now = AXIsProcessTrusted()
            if now != model.trusted { model.trusted = now }
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            model.loginError = nil
        } catch {
            model.loginError = "No se pudo cambiar el inicio de sesión: \(error.localizedDescription)"
        }
        model.launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

private struct ButtonSection: View {
    let title: String
    @Binding var config: ButtonConfig

    var body: some View {
        Section(title) {
            Picker("Clic", selection: $config.click) {
                ForEach(MouseAction.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Gestos al mantener y arrastrar", isOn: $config.dragEnabled)
            if config.dragEnabled {
                dragPicker("← Izquierda", $config.dragLeft)
                dragPicker("→ Derecha", $config.dragRight)
                dragPicker("↑ Arriba", $config.dragUp)
                dragPicker("↓ Abajo", $config.dragDown)
            }
        }
    }

    private func dragPicker(_ label: String, _ sel: Binding<MouseAction>) -> some View {
        Picker(label, selection: sel) {
            ForEach(MouseAction.dragActions) { Text($0.title).tag($0) }
        }
    }
}

import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var enabledItem: NSMenuItem!
    private var settingsWindow: NSWindow?
    private var pollTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        Settings.shared.$enabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.enabledItem?.state = value ? .on : .off }
            .store(in: &cancellables)

        let defaults = UserDefaults.standard
        var showSettings = false
        if !defaults.bool(forKey: "didShowFirstLaunch") {
            defaults.set(true, forKey: "didShowFirstLaunch")
            showSettings = true
        }

        if AXIsProcessTrusted() {
            if !EventEngine.shared.start() { startPolling() }
        } else {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            showSettings = true
            startPolling()
        }

        if showSettings { openSettings() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        EventEngine.shared.stop()
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "computermouse", accessibilityDescription: "OpenMouseFix")
            image?.isTemplate = true
            button.image = image
        }

        let menu = NSMenu()
        enabledItem = NSMenuItem(title: "Activado", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.state = Settings.shared.enabled ? .on : .off
        menu.addItem(enabledItem)

        let settingsItem = NSMenuItem(title: "Ajustes…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let about = NSMenuItem(title: "Acerca de OpenMouseFix",
                               action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func toggleEnabled() {
        Settings.shared.enabled.toggle()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    // MARK: - Engine start polling

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard AXIsProcessTrusted() else { return }
            if EventEngine.shared.start() {
                self?.pollTimer?.invalidate()
                self?.pollTimer = nil
            }
        }
    }

    // MARK: - Settings window

    @objc func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
                                  styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "OpenMouseFix"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView())
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

import SwiftUI
import ServiceManagement

// MARK: - Welcome Window Controller

@MainActor
final class WelcomeWindowController {
    static let shared = WelcomeWindowController()
    private var window: NSWindow?
    private var didCheck = false

    func showIfFirstLaunch() {
        guard !didCheck else { return }
        didCheck = true
        guard !SettingsManager.shared.hasLaunchedBefore else { return }
        show()
    }

    func show() {
        guard window == nil else {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let welcomeView = WelcomeView()

        let hostingView = NSHostingView(rootView: welcomeView)
        hostingView.sizingOptions = []
        let size = hostingView.fittingSize

        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.contentView = hostingView
        win.title = "Ekual"
        win.center()
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.makeKeyAndOrderFront(nil)
        NSApp.activate()

        self.window = win
    }

    func bringToFront() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close() {
        window?.close()
        window = nil
    }
}

// MARK: - First Launch Observer

private enum FirstLaunchObserver {
    nonisolated(unsafe) static var observer: Any?

    static func install() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                // Set up the status bar item and popover
                StatusBarController.shared.setup()

                WelcomeWindowController.shared.showIfFirstLaunch()

                // If auto-start is enabled but permission needs re-confirmation
                // (e.g. debug build with reset TCC), open the popover
                // so the user sees the permission banner immediately.
                // Delay slightly so the status item is fully laid out by AppKit.
                let settings = SettingsManager.shared
                if settings.autoStartProcessing &&
                   settings.hasGrantedAudioPermission &&
                   settings.hasLaunchedBefore &&
                   !AudioEngine.shared.permissionConfirmedThisSession {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        StatusBarController.shared.openPopover()
                    }
                }
            }
        }
    }
}

// MARK: - Status Bar Controller

/// Manages the NSStatusItem, NSPopover, and right-click menu.
/// Replaces SwiftUI's MenuBarExtra for full programmatic control.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    static let shared = StatusBarController()

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var eventMonitor: Any?
    private var shortcutMonitor: Any?

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform.path", accessibilityDescription: "Ekual")
            button.target = self
            button.action = #selector(statusBarButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.contentViewController = NSHostingController(rootView: ContentView())
        popover.behavior = .transient
        popover.delegate = self

        updateIcon()
        updateShortcutMonitor()
    }

    func updateIcon() {
        guard let button = statusItem?.button else { return }
        let running = AudioEngine.shared.isRunning
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        button.image = NSImage(systemSymbolName: "waveform.path", accessibilityDescription: "Ekual")?
            .withSymbolConfiguration(config)
        button.appearsDisabled = !running
    }

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent!

        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            openPopover()
        }
    }

    func openPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Ensure the popover's window is key so the UI appears active
        popover.contentViewController?.view.window?.makeKey()

        // Close popover when clicking outside
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
    }

    func closePopover() {
        popover.performClose(nil)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    // NSPopoverDelegate — clean up monitor when popover closes
    func popoverDidClose(_ notification: Notification) {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func showContextMenu() {
        let l10n = SettingsManager.shared.l10n
        let engine = AudioEngine.shared
        let menu = NSMenu()

        // Toggle on/off
        let toggleItem = NSMenuItem(
            title: engine.isRunning ? l10n.stopEkual : l10n.startEkual,
            action: #selector(toggleEngine),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        // Reset to Defaults
        let resetItem = NSMenuItem(
            title: l10n.resetToDefaults,
            action: #selector(resetDefaults),
            keyEquivalent: ""
        )
        resetItem.target = self
        menu.addItem(resetItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(
            title: l10n.quit,
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Reset menu so left-click works again
        statusItem.menu = nil
    }

    @objc private func toggleEngine() {
        let engine = AudioEngine.shared
        if engine.isRunning {
            engine.stop()
        } else {
            engine.start()
        }
        updateIcon()
    }

    @objc private func resetDefaults() {
        AudioEngine.shared.resetToDefaults()
    }

    @objc private func quitApp() {
        AudioEngine.shared.stop()
        NSApplication.shared.terminate(nil)
    }

    func updateShortcutMonitor() {
        if let monitor = shortcutMonitor {
            NSEvent.removeMonitor(monitor)
            shortcutMonitor = nil
        }

        guard SettingsManager.shared.globalShortcutEnabled else { return }

        let settings = SettingsManager.shared
        let expectedKeyCode = settings.shortcutKeyCode
        let expectedModifiers = NSEvent.ModifierFlags(rawValue: settings.shortcutModifiers)
            .intersection(.deviceIndependentFlagsMask)

        shortcutMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if flags == expectedModifiers && event.keyCode == expectedKeyCode {
                Task { @MainActor in
                    let engine = AudioEngine.shared
                    if engine.isRunning {
                        engine.stop()
                    } else {
                        engine.start()
                    }
                    StatusBarController.shared.updateIcon()
                }
            }
        }
    }
}

@main
struct EkualApp: App {
    @State private var settings = SettingsManager.shared

    init() {
        FirstLaunchObserver.install()
    }

    var body: some Scene {
        // Empty Settings scene — we use NSStatusItem directly instead of MenuBarExtra
        Settings {
            EmptyView()
        }
    }
}

// MARK: - Welcome View

struct WelcomeView: View {
    @State private var engine = AudioEngine.shared
    @State private var settings = SettingsManager.shared
    @State private var launchAtLogin = true
    @State private var autoStartOnLaunch = true
    @State private var globalShortcut = false
    @State private var permissionGranted = false
    @State private var requestingPermission = false

    private var l10n: L10n { settings.l10n }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.path")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Ekual")
                .font(.largeTitle.bold())

            Text(l10n.appDescription)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            // Audio Permission
            VStack(spacing: 8) {
                Text(l10n.permissionExplanation)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    if !engine.isRunning && !permissionGranted {
                        requestingPermission = true
                        // Start the engine to trigger the system permission dialog,
                        // then immediately stop it so the user can configure settings first.
                        // Use a short delay so the window is fully visible before the
                        // TCC dialog appears.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            engine.start()
                            requestingPermission = false
                            if engine.isRunning {
                                engine.stop()
                                permissionGranted = true
                                settings.hasGrantedAudioPermission = true
                            }
                            // Bring the welcome window back to front after the TCC dialog
                            WelcomeWindowController.shared.bringToFront()
                        }
                    }
                } label: {
                    if permissionGranted {
                        Label(l10n.permissionGranted, systemImage: "checkmark.circle.fill")
                            .font(.callout.bold())
                            .foregroundStyle(.green)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    } else if requestingPermission {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    } else {
                        Label(l10n.grantPermission, systemImage: "speaker.wave.3.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(permissionGranted || requestingPermission)
            }

            Divider()

            // Settings
            VStack(alignment: .leading, spacing: 8) {
                Toggle(l10n.launchAtLogin, isOn: $launchAtLogin)
                    .font(.callout)
                    .toggleStyle(.checkbox)

                Toggle(l10n.autoStart, isOn: $autoStartOnLaunch)
                    .font(.callout)
                    .toggleStyle(.checkbox)

                Toggle(l10n.globalShortcutToggle, isOn: $globalShortcut)
                    .font(.callout)
                    .toggleStyle(.checkbox)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                if engine.isRunning {
                    engine.stop()
                } else {
                    settings.globalShortcutEnabled = globalShortcut
                    settings.autoStartProcessing = autoStartOnLaunch
                    if launchAtLogin {
                        try? SMAppService.mainApp.register()
                    }
                    engine.start()
                    settings.hasLaunchedBefore = true
                }
            } label: {
                Label {
                    Text(engine.isRunning ? l10n.stopEkual : l10n.startEkual)
                        .font(.headline)
                } icon: {
                    Image(systemName: engine.isRunning ? "stop.fill" : "power")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(engine.isRunning ? .red : .green)
            .controlSize(.large)
            .disabled(!permissionGranted)

            Text(l10n.menuBarHint)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(width: 460)
    }
}

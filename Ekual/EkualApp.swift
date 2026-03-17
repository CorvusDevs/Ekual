import SwiftUI
import Carbon.HIToolbox
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
                WelcomeWindowController.shared.showIfFirstLaunch()
            }
        }
    }
}

@main
struct EkualApp: App {
    @State private var engine = AudioEngine.shared
    @State private var settings = SettingsManager.shared
    @State private var shortcutMonitor: Any?
    @State private var didSetup = false

    init() {
        FirstLaunchObserver.install()
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .onAppear {
                    guard !didSetup else { return }
                    didSetup = true

                    WelcomeWindowController.shared.showIfFirstLaunch()

                    if settings.hasLaunchedBefore {
                        handleAutoStart()
                    }
                    updateShortcutMonitor()
                }
                .onChange(of: settings.globalShortcutEnabled) { _, _ in
                    updateShortcutMonitor()
                }
        } label: {
            Image(systemName: "waveform.path")
                .symbolVariant(engine.isRunning ? .none : .slash)
        }
        .menuBarExtraStyle(.window)
    }

    private func handleAutoStart() {
        guard settings.autoStartProcessing && !engine.isRunning else { return }
        engine.start()
    }

    private func updateShortcutMonitor() {
        if let monitor = shortcutMonitor {
            NSEvent.removeMonitor(monitor)
            shortcutMonitor = nil
        }

        guard settings.globalShortcutEnabled else { return }

        shortcutMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isControlOption = flags == [.control, .option]
            let isE = event.keyCode == UInt16(kVK_ANSI_E)

            if isControlOption && isE {
                Task { @MainActor in
                    if engine.isRunning {
                        engine.stop()
                    } else {
                        engine.start()
                    }
                }
            }
        }
    }
}

// MARK: - Welcome View

struct WelcomeView: View {
    @State private var engine = AudioEngine.shared
    @State private var settings = SettingsManager.shared
    @State private var launchAtLogin = true
    @State private var autoStart = true
    @State private var globalShortcut = false
    @State private var permissionGranted = false

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
                    if !engine.isRunning {
                        // Start the engine to trigger the system permission dialog,
                        // then immediately stop it so the user can configure settings first
                        engine.start()
                        if engine.isRunning {
                            engine.stop()
                            permissionGranted = true
                        }
                    }
                } label: {
                    if permissionGranted {
                        Label(l10n.permissionGranted, systemImage: "checkmark.circle.fill")
                            .font(.callout.bold())
                            .foregroundStyle(.green)
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
                .disabled(permissionGranted)
            }

            Divider()

            // Settings
            VStack(alignment: .leading, spacing: 8) {
                Toggle(l10n.launchAtLogin, isOn: $launchAtLogin)
                    .font(.callout)
                    .toggleStyle(.checkbox)

                Toggle(l10n.autoStart, isOn: $autoStart)
                    .font(.callout)
                    .toggleStyle(.checkbox)

                Toggle(l10n.globalShortcut, isOn: $globalShortcut)
                    .font(.callout)
                    .toggleStyle(.checkbox)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                if engine.isRunning {
                    engine.stop()
                } else {
                    settings.autoStartProcessing = autoStart
                    settings.globalShortcutEnabled = globalShortcut
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

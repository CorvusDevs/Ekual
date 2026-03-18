import SwiftUI
import ServiceManagement

struct ContentView: View {
    @Bindable var engine = AudioEngine.shared
    @State private var settings = SettingsManager.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var showInfoPopover = false
    @State private var showLanguagePicker = false
    @State private var switchingPulse = false
    @State private var showMeters = false
    @State private var showSavePresetDialog = false
    @State private var showRenameDialog = false
    @State private var newPresetName = ""
    @State private var renameText = ""
    @State private var presetToRenameID: UUID?
    @State private var showExcludedApps = false
    @State private var runningApps: [RunningAudioApp] = []

    private var l10n: L10n { settings.l10n }

    /// Engine is active or in the middle of a device switch
    private var isEngineActive: Bool {
        engine.isRunning || engine.switchingToDevice != nil
    }

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "waveform.path")
                    .font(.title2)
                    .foregroundStyle(engine.isRunning ? .green : .secondary)
                Text("Ekual")
                    .font(.title2.bold())

                Button {
                    showInfoPopover.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Info")
                .popover(isPresented: $showInfoPopover, arrowEdge: .bottom) {
                    Text(l10n.appDescription)
                        .font(.caption)
                        .frame(width: 240)
                        .padding(12)
                }

                Spacer()

                // Power Button (hidden until permission granted)
                if settings.hasGrantedAudioPermission {
                    Button {
                        if engine.isRunning {
                            engine.stop()
                        } else {
                            engine.start()
                            engine.startMetering()
                        }
                    } label: {
                        Image(systemName: "power")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(engine.isRunning ? .green : .secondary)
                            .frame(width: 32, height: 32)
                            .background(
                                Circle()
                                    .fill(engine.isRunning ? Color.green.opacity(0.15) : Color.secondary.opacity(0.1))
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(engine.isRunning ? l10n.stopEkual : l10n.startEkual)
                }
            }

            // Permission prompt or status
            if !settings.hasGrantedAudioPermission {
                permissionPromptView
            } else {
                statusView
            }

            // Auto-start needs permission confirmation this session
            if settings.autoStartProcessing &&
               settings.hasGrantedAudioPermission &&
               !engine.permissionConfirmedThisSession &&
               !engine.isRunning {
                autoStartPermissionBanner
            }

            Divider()

            // Level Meters — hidden behind a disclosure to avoid rendering cost
            if isEngineActive {
                DisclosureGroup(l10n.meters, isExpanded: $showMeters) {
                    LevelMetersView(
                        inputLabel: l10n.input,
                        outputLabel: l10n.output,
                        inputLevelDb: engine.isRunning ? engine.inputLevelDb : -100,
                        outputLevelDb: engine.isRunning ? engine.outputLevelDb : -100
                    )
                    .opacity(engine.switchingToDevice != nil ? 0.4 : 1.0)
                }
                .font(.caption.bold())
                .onChange(of: showMeters) { _, expanded in
                    if expanded {
                        engine.startMetering()
                    } else {
                        engine.stopMetering()
                    }
                }
            }

            // Output Device Picker
            if isEngineActive {
                HStack {
                    Text(l10n.outputDevice)
                        .font(.caption.bold())
                    Spacer()
                    Picker("", selection: selectedDeviceBinding) {
                        Text(l10n.systemDefault).tag(nil as String?)
                        ForEach(engine.availableOutputDevices) { device in
                            Text(device.name).tag(device.uid as String?)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel(l10n.outputDevice)
                }
            }

            // Excluded Apps
            if isEngineActive {
                DisclosureGroup(l10n.excludedApps, isExpanded: $showExcludedApps) {
                    if runningApps.isEmpty {
                        Text(l10n.noAppsRunning)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 2)
                    } else {
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(runningApps) { app in
                                    HStack(spacing: 6) {
                                        if let icon = app.icon {
                                            Image(nsImage: icon)
                                                .resizable()
                                                .frame(width: 14, height: 14)
                                        }
                                        Text(app.name)
                                            .font(.caption2)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                        Spacer()
                                        Toggle("", isOn: exclusionBinding(for: app.bundleID))
                                            .toggleStyle(.switch)
                                            .controlSize(.mini)
                                            .labelsHidden()
                                    }
                                    .padding(.vertical, 2)
                                    .padding(.horizontal, 4)
                                }
                            }
                        }
                        .frame(maxHeight: 120)
                    }
                }
                .font(.caption.bold())
                .onAppear {
                    // Refresh every time the popover appears
                    runningApps = engine.getRunningAudioApps()
                }
                .onChange(of: showExcludedApps) { _, expanded in
                    if expanded {
                        runningApps = engine.getRunningAudioApps()
                    }
                }
                .task(id: showExcludedApps) {
                    // While the disclosure group is expanded, poll for new apps
                    guard showExcludedApps else { return }
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(3))
                        guard !Task.isCancelled else { break }
                        runningApps = engine.getRunningAudioApps()
                    }
                }
            }

            // Preset Picker
            VStack(spacing: 6) {
                HStack {
                    Text(l10n.preset)
                        .font(.caption.bold())
                    Spacer()
                    Picker("", selection: presetSelectionBinding) {
                        ForEach(BuiltInPreset.allCases) { preset in
                            Text(l10n.builtInPresetName(preset)).tag(PresetSelection.builtIn(preset))
                        }
                        if !settings.customPresets.isEmpty {
                            Divider()
                            ForEach(settings.customPresets) { preset in
                                Text(preset.name).tag(PresetSelection.custom(preset.id))
                            }
                        }
                        if settings.presetSelection == .modified {
                            Divider()
                            Text(l10n.customModified).tag(PresetSelection.modified)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel(l10n.preset)
                }

                // Preset action buttons row
                HStack(spacing: 8) {
                    Button {
                        dismissPresetNameEdit()
                        newPresetName = ""
                        showSavePresetDialog = true
                    } label: {
                        Label(l10n.savePreset, systemImage: "plus.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    if case .custom(let id) = settings.presetSelection {
                        Button {
                            dismissPresetNameEdit()
                            if let preset = settings.customPresets.first(where: { $0.id == id }) {
                                presetToRenameID = preset.id
                                renameText = preset.name
                                showRenameDialog = true
                            }
                        } label: {
                            Label(l10n.rename, systemImage: "pencil")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)

                        Button {
                            settings.deleteCustomPreset(id: id)
                        } label: {
                            Label(l10n.delete, systemImage: "trash")
                                .font(.caption)
                                .foregroundStyle(.red.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()
                }

                // Inline preset name editor (save or rename)
                if showSavePresetDialog || showRenameDialog {
                    HStack(spacing: 6) {
                        TextField(l10n.presetName_, text: showRenameDialog ? $renameText : $newPresetName)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                            .onSubmit {
                                commitPresetNameEdit()
                            }

                        Button(l10n.save) {
                            commitPresetNameEdit()
                        }
                        .font(.caption)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button(l10n.cancel) {
                            dismissPresetNameEdit()
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            // Controls
            VStack(spacing: 12) {
                SliderRow(
                    label: l10n.releaseTime,
                    value: $engine.releaseTime,
                    range: 0.1...3.0,
                    valueText: releaseTimeLabel,
                    tooltip: l10n.releaseTimeTooltip
                )

                SliderRow(
                    label: l10n.boost,
                    value: $engine.makeupGainDb,
                    range: 0...24,
                    valueText: String(format: "%.0f dB", engine.makeupGainDb),
                    tooltip: l10n.boostTooltip
                )

                SliderRow(
                    label: l10n.threshold,
                    value: $engine.targetLevelDb,
                    range: -48...(-6),
                    valueText: String(format: "%.0f dB", engine.targetLevelDb),
                    tooltip: l10n.thresholdTooltip
                )
            }
            .disabled(!engine.isRunning)
            .opacity(engine.isRunning ? 1.0 : 0.5)

            Divider()

            // Options
            VStack(alignment: .leading, spacing: 6) {
                Toggle(l10n.launchAtLogin, isOn: $launchAtLogin)
                    .font(.caption)
                    .toggleStyle(.checkbox)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }

                Toggle(l10n.autoStart, isOn: $settings.autoStartProcessing)
                    .font(.caption)
                    .toggleStyle(.checkbox)

                HStack {
                    Toggle(l10n.globalShortcutToggle, isOn: $settings.globalShortcutEnabled)
                        .font(.caption)
                        .toggleStyle(.checkbox)
                        .onChange(of: settings.globalShortcutEnabled) { _, _ in
                            StatusBarController.shared.updateShortcutMonitor()
                        }

                    Spacer()

                    ShortcutRecorderButton(
                        keyCode: $settings.shortcutKeyCode,
                        modifiers: $settings.shortcutModifiers,
                        displayString: settings.shortcutDisplayString,
                        pressKeysLabel: l10n.pressKeys
                    )
                    .onChange(of: settings.shortcutKeyCode) { _, _ in
                        StatusBarController.shared.updateShortcutMonitor()
                    }
                    .onChange(of: settings.shortcutModifiers) { _, _ in
                        StatusBarController.shared.updateShortcutMonitor()
                    }
                }
            }

            HStack {
                Button(l10n.resetToDefaults) {
                    engine.resetToDefaults()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)

                Button {
                    showLanguagePicker.toggle()
                } label: {
                    Image(systemName: "globe")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(l10n.language_)
                .popover(isPresented: $showLanguagePicker, arrowEdge: .bottom) {
                    LanguagePickerView(settings: settings, l10n: l10n) {
                        showLanguagePicker = false
                    }
                }

                Spacer()

                Button(l10n.quit) {
                    engine.stop()
                    NSApplication.shared.terminate(nil)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            // If auto-start is enabled and we've already confirmed TCC permission
            // in this session (engine ran at least once), start silently.
            if settings.autoStartProcessing &&
               engine.permissionConfirmedThisSession &&
               !engine.isRunning {
                engine.start()
            }
        }
        .onDisappear {
            showMeters = false
            engine.stopMetering()
        }
    }

    // MARK: - Status View

    @ViewBuilder
    private var permissionPromptView: some View {
        VStack(spacing: 8) {
            Text(l10n.permissionExplanation)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button {
                engine.start()
                if engine.isRunning {
                    settings.hasGrantedAudioPermission = true
                }
            } label: {
                Label(l10n.grantPermission, systemImage: "speaker.wave.3.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .controlSize(.regular)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        if let error = engine.errorMessage {
            VStack(spacing: 6) {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button {
                    engine.start()
                    engine.startMetering()
                } label: {
                    Label(l10n.tryAgain, systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(l10n.tryAgain)
            }
        } else {
            VStack(spacing: 2) {
                // Status text — crossfade between states
                Group {
                    if let device = engine.switchingToDevice {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(l10n.switchingTo(device))
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                        }
                        .opacity(switchingPulse ? 0.5 : 1.0)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                                switchingPulse = true
                            }
                        }
                        .onDisappear { switchingPulse = false }
                    } else {
                        Text(engine.isRunning ? l10n.statusActive : l10n.statusOff)
                            .font(.subheadline)
                            .foregroundStyle(engine.isRunning ? .green : .secondary)
                    }
                }
                .animation(.easeInOut(duration: 0.4), value: engine.switchingToDevice == nil)

                // Device name — always visible when active
                if isEngineActive {
                    let deviceName = engine.switchingToDevice ?? engine.currentDeviceName
                    if !deviceName.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.caption2)
                            Text(deviceName)
                                .font(.caption)
                                .contentTransition(.numericText())
                        }
                        .foregroundStyle(.secondary)
                        .animation(.easeInOut(duration: 0.3), value: deviceName)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var autoStartPermissionBanner: some View {
        VStack(spacing: 6) {
            Text(l10n.autoStartPermission)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            GlowingPermissionButton(l10n: l10n) {
                engine.start()
                if engine.isRunning {
                    engine.startMetering()
                }
            }
        }
    }

    // MARK: - Bindings

    private var selectedDeviceBinding: Binding<String?> {
        Binding<String?>(
            get: { engine.preferredDeviceUID },
            set: { newUID in
                if let uid = newUID {
                    let device = engine.availableOutputDevices.first { $0.uid == uid }
                    engine.switchToDevice(device)
                } else {
                    engine.switchToDevice(nil)
                }
            }
        )
    }

    private func commitPresetNameEdit() {
        if showSavePresetDialog {
            let name = newPresetName.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            settings.saveCurrentAsCustomPreset(name: name)
            newPresetName = ""
            showSavePresetDialog = false
        } else if showRenameDialog {
            let name = renameText.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, let id = presetToRenameID else { return }
            settings.renameCustomPreset(id: id, newName: name)
            presetToRenameID = nil
            renameText = ""
            showRenameDialog = false
        }
    }

    private func dismissPresetNameEdit() {
        newPresetName = ""
        renameText = ""
        presetToRenameID = nil
        showSavePresetDialog = false
        showRenameDialog = false
    }

    private var presetSelectionBinding: Binding<PresetSelection> {
        Binding<PresetSelection>(
            get: { settings.presetSelection },
            set: { newSelection in
                switch newSelection {
                case .builtIn(let preset):
                    engine.applyBuiltInPreset(preset)
                case .custom(let id):
                    if let preset = settings.customPresets.first(where: { $0.id == id }) {
                        engine.applyCustomPreset(preset)
                    }
                case .modified:
                    break
                }
            }
        )
    }

    private func exclusionBinding(for bundleID: String) -> Binding<Bool> {
        Binding<Bool>(
            get: { settings.excludedBundleIDs.contains(bundleID) },
            set: { excluded in
                if excluded {
                    settings.excludedBundleIDs.insert(bundleID)
                } else {
                    settings.excludedBundleIDs.remove(bundleID)
                }
                engine.applyExclusionListChange()
            }
        )
    }

    private var releaseTimeLabel: String {
        let ms = Int(engine.releaseTime * 1000)
        if ms < 1000 {
            return "\(ms) ms"
        } else {
            return String(format: "%.1f s", engine.releaseTime)
        }
    }

}

// MARK: - Glowing Permission Button

/// Isolated view so the repeating glow animation doesn't leak to parent.
private struct GlowingPermissionButton: View {
    let l10n: L10n
    let action: () -> Void
    @State private var glowing = false

    var body: some View {
        Button(action: action) {
            Label(l10n.grantPermission, systemImage: "speaker.wave.3.fill")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            LinearGradient(
                                colors: [.red, .orange],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                )
        }
        .buttonStyle(.plain)
        .shadow(color: .red.opacity(glowing ? 0.6 : 0.15), radius: glowing ? 10 : 4)
        .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: glowing)
        .onAppear { glowing = true }
    }
}

// MARK: - Shortcut Recorder Button

private struct ShortcutRecorderButton: View {
    @Binding var keyCode: UInt16
    @Binding var modifiers: UInt
    let displayString: String
    let pressKeysLabel: String

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            if isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        } label: {
            Text(isRecording ? pressKeysLabel : displayString)
                .font(.caption.monospaced())
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isRecording ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isRecording ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape cancels recording
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }

            // Require at least one modifier (control, option, command, or shift)
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let hasModifier = !flags.intersection([.control, .option, .command, .shift]).isEmpty

            if hasModifier {
                keyCode = event.keyCode
                modifiers = flags.rawValue
                stopRecording()
                return nil // consume the event
            }

            return nil // consume all key events while recording
        }
    }

    private func stopRecording() {
        isRecording = false
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }
}

// MARK: - Language Picker

struct LanguagePickerView: View {
    var settings: SettingsManager
    let l10n: L10n
    let onDismiss: () -> Void

    private let languages = Array(AppLanguage.allCases)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(l10n.language_)
                .font(.caption.bold())
                .padding(.bottom, 4)
            ForEach(languages) { lang in
                LanguageRow(
                    lang: lang,
                    isSelected: lang == settings.appLanguage
                ) {
                    settings.appLanguage = lang
                    onDismiss()
                }
            }
        }
        .padding(12)
        .frame(width: 180)
    }
}

private struct LanguageRow: View {
    let lang: AppLanguage
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(lang.displayName)
                    .font(.caption)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Slider Row with Tooltip

struct SliderRow: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let valueText: String
    let tooltip: String

    @State private var showTip = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption.bold())

                Button {
                    showTip.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showTip, arrowEdge: .top) {
                    Text(tooltip)
                        .font(.caption)
                        .frame(width: 200)
                        .padding(10)
                }

                Spacer()
                Text(valueText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
                .labelsHidden()
                .accessibilityLabel(label)
                .accessibilityValue(valueText)
        }
    }
}

// MARK: - Level Meters (isolated view to avoid re-evaluating ContentView.body)

/// Pure value-driven meter view — no @Observable engine reference,
/// so it only re-renders when the passed-in Float values actually change.
struct LevelMetersView: View, Equatable {
    let inputLabel: String
    let outputLabel: String
    let inputLevelDb: Float
    let outputLevelDb: Float

    var body: some View {
        VStack(spacing: 8) {
            LevelMeterRow(label: inputLabel, levelDb: inputLevelDb)
            LevelMeterRow(label: outputLabel, levelDb: outputLevelDb)
        }
    }
}

struct LevelMeterRow: View {
    let label: String
    let levelDb: Float

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .frame(width: 44, alignment: .trailing)

            // Meter bar — uses a simple proportional frame instead of GeometryReader
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.15))

                RoundedRectangle(cornerRadius: 3)
                    .fill(meterColor)
                    .frame(width: max(0, meterFraction * 150))
                    .animation(.linear(duration: 0.1), value: meterFraction)
            }
            .frame(width: 150, height: 8)

            Text(dbText)
                .font(.caption.monospacedDigit())
                .frame(width: 48, alignment: .trailing)
                .foregroundStyle(.secondary)
                .animation(nil, value: levelDb)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(dbText)
    }

    private var meterFraction: CGFloat {
        let clamped = max(-60, min(0, CGFloat(levelDb)))
        return (clamped + 60) / 60
    }

    private var meterColor: Color {
        if levelDb > -3 {
            return .red
        } else if levelDb > -12 {
            return .yellow
        } else {
            return .green
        }
    }

    private var dbText: String {
        String(format: "%3.0f dB", levelDb)
    }
}

#Preview {
    ContentView()
}

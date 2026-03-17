import SwiftUI
import ServiceManagement

struct ContentView: View {
    @Bindable var engine = AudioEngine.shared
    @State private var settings = SettingsManager.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var showInfoPopover = false
    @State private var showLanguagePicker = false

    private var l10n: L10n { settings.l10n }

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
                .popover(isPresented: $showInfoPopover, arrowEdge: .bottom) {
                    Text(l10n.appDescription)
                        .font(.caption)
                        .frame(width: 240)
                        .padding(12)
                }

                Spacer()

                // Power Button
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
            }

            // Status
            if let error = engine.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            } else {
                Text(engine.isRunning ? l10n.statusActive : l10n.statusOff)
                    .font(.subheadline)
                    .foregroundStyle(engine.isRunning ? .green : .secondary)
            }

            Divider()

            // Level Meters
            if engine.isRunning {
                VStack(spacing: 8) {
                    LevelMeterRow(label: l10n.input, levelDb: engine.inputLevelDb)
                    LevelMeterRow(label: l10n.output, levelDb: engine.outputLevelDb)
                }
                .transition(.opacity)
            }

            // Preset Picker
            HStack {
                Text(l10n.preset)
                    .font(.caption.bold())
                Spacer()
                Picker("", selection: $settings.selectedPreset) {
                    ForEach(Preset.allCases) { preset in
                        Text(l10n.presetName(preset)).tag(preset)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: settings.selectedPreset) { _, newPreset in
                    if newPreset != .custom {
                        engine.applyPreset(newPreset)
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

                Toggle(l10n.globalShortcut, isOn: $settings.globalShortcutEnabled)
                    .font(.caption)
                    .toggleStyle(.checkbox)
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
        .onAppear { engine.startMetering() }
        .onDisappear { engine.stopMetering() }
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
        }
    }
}

// MARK: - Level Meter

struct LevelMeterRow: View {
    let label: String
    let levelDb: Float

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .frame(width: 44, alignment: .trailing)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.15))

                    // Level bar
                    RoundedRectangle(cornerRadius: 3)
                        .fill(meterColor)
                        .frame(width: max(0, meterFraction * geo.size.width))
                }
            }
            .frame(height: 8)

            Text(String(format: "%3.0f dB", levelDb))
                .font(.caption.monospacedDigit())
                .frame(width: 48, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }

    private var meterFraction: CGFloat {
        // Map -60 dB to 0 dB → 0.0 to 1.0
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
}

#Preview {
    ContentView()
}

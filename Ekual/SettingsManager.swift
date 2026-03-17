import Foundation

enum Preset: String, CaseIterable, Identifiable {
    case light = "Light"
    case medium = "Medium"
    case heavy = "Heavy"
    case custom = "Custom"

    var id: String { rawValue }

    var releaseTime: Float {
        switch self {
        case .light: 0.5
        case .medium: 1.0
        case .heavy: 2.0
        case .custom: 1.0
        }
    }

    var makeupGainDb: Float {
        switch self {
        case .light: 6.0
        case .medium: 12.0
        case .heavy: 20.0
        case .custom: 12.0
        }
    }

    var targetLevelDb: Float {
        switch self {
        case .light: -18.0
        case .medium: -24.0
        case .heavy: -36.0
        case .custom: -24.0
        }
    }
}

@Observable
@MainActor
final class SettingsManager {

    static let shared = SettingsManager()

    // MARK: - Keys

    private enum Keys {
        static let releaseTime = "releaseTime"
        static let makeupGainDb = "makeupGainDb"
        static let targetLevelDb = "targetLevelDb"
        static let autoStart = "autoStartProcessing"
        static let selectedPreset = "selectedPreset"
        static let globalShortcutEnabled = "globalShortcutEnabled"
        static let appLanguage = "appLanguage"
        static let hasLaunchedBefore = "hasLaunchedBefore"
    }

    // MARK: - Defaults

    static let defaultReleaseTime: Float = 1.0
    static let defaultMakeupGainDb: Float = 12.0
    static let defaultTargetLevelDb: Float = -24.0

    // MARK: - Properties

    var releaseTime: Float {
        didSet {
            UserDefaults.standard.set(releaseTime, forKey: Keys.releaseTime)
            updatePresetIfNeeded()
        }
    }

    var makeupGainDb: Float {
        didSet {
            UserDefaults.standard.set(makeupGainDb, forKey: Keys.makeupGainDb)
            updatePresetIfNeeded()
        }
    }

    var targetLevelDb: Float {
        didSet {
            UserDefaults.standard.set(targetLevelDb, forKey: Keys.targetLevelDb)
            updatePresetIfNeeded()
        }
    }

    var autoStartProcessing: Bool {
        didSet {
            UserDefaults.standard.set(autoStartProcessing, forKey: Keys.autoStart)
        }
    }

    var selectedPreset: Preset {
        didSet {
            UserDefaults.standard.set(selectedPreset.rawValue, forKey: Keys.selectedPreset)
        }
    }

    var globalShortcutEnabled: Bool {
        didSet {
            UserDefaults.standard.set(globalShortcutEnabled, forKey: Keys.globalShortcutEnabled)
        }
    }

    var appLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(appLanguage.rawValue, forKey: Keys.appLanguage)
        }
    }

    var hasLaunchedBefore: Bool {
        didSet {
            UserDefaults.standard.set(hasLaunchedBefore, forKey: Keys.hasLaunchedBefore)
        }
    }

    var l10n: L10n { L10n(language: appLanguage) }

    // MARK: - Init

    private init() {
        let defaults = UserDefaults.standard

        // Load saved values or use defaults
        if defaults.object(forKey: Keys.releaseTime) != nil {
            self.releaseTime = defaults.float(forKey: Keys.releaseTime)
        } else {
            self.releaseTime = Self.defaultReleaseTime
        }

        if defaults.object(forKey: Keys.makeupGainDb) != nil {
            self.makeupGainDb = defaults.float(forKey: Keys.makeupGainDb)
        } else {
            self.makeupGainDb = Self.defaultMakeupGainDb
        }

        if defaults.object(forKey: Keys.targetLevelDb) != nil {
            self.targetLevelDb = defaults.float(forKey: Keys.targetLevelDb)
        } else {
            self.targetLevelDb = Self.defaultTargetLevelDb
        }

        self.autoStartProcessing = defaults.bool(forKey: Keys.autoStart)
        self.globalShortcutEnabled = defaults.bool(forKey: Keys.globalShortcutEnabled)
        self.hasLaunchedBefore = defaults.bool(forKey: Keys.hasLaunchedBefore)

        if let langRaw = defaults.string(forKey: Keys.appLanguage),
           let lang = AppLanguage(rawValue: langRaw) {
            self.appLanguage = lang
        } else {
            self.appLanguage = AppLanguage.detect()
        }

        if let presetRaw = defaults.string(forKey: Keys.selectedPreset),
           let preset = Preset(rawValue: presetRaw) {
            self.selectedPreset = preset
        } else {
            self.selectedPreset = .medium
        }
    }

    // MARK: - Preset Application

    func applyPreset(_ preset: Preset) {
        guard preset != .custom else { return }
        selectedPreset = preset
        releaseTime = preset.releaseTime
        makeupGainDb = preset.makeupGainDb
        targetLevelDb = preset.targetLevelDb
    }

    func resetToDefaults() {
        applyPreset(.medium)
    }

    private func updatePresetIfNeeded() {
        // Check if current values match any preset
        for preset in Preset.allCases where preset != .custom {
            if releaseTime == preset.releaseTime &&
               makeupGainDb == preset.makeupGainDb &&
               targetLevelDb == preset.targetLevelDb {
                if selectedPreset != preset {
                    selectedPreset = preset
                }
                return
            }
        }
        if selectedPreset != .custom {
            selectedPreset = .custom
        }
    }
}

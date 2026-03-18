import Foundation

// MARK: - Built-In Presets

enum BuiltInPreset: String, CaseIterable, Identifiable {
    case light = "Light"
    case medium = "Medium"
    case heavy = "Heavy"

    var id: String { rawValue }

    var releaseTime: Float {
        switch self {
        case .light: 0.5
        case .medium: 1.0
        case .heavy: 2.0
        }
    }

    var makeupGainDb: Float {
        switch self {
        case .light: 6.0
        case .medium: 12.0
        case .heavy: 20.0
        }
    }

    var targetLevelDb: Float {
        switch self {
        case .light: -18.0
        case .medium: -24.0
        case .heavy: -36.0
        }
    }
}

// MARK: - Custom Presets

struct CustomPreset: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var releaseTime: Float
    var makeupGainDb: Float
    var targetLevelDb: Float

    init(name: String, releaseTime: Float, makeupGainDb: Float, targetLevelDb: Float) {
        self.id = UUID()
        self.name = name
        self.releaseTime = releaseTime
        self.makeupGainDb = makeupGainDb
        self.targetLevelDb = targetLevelDb
    }
}

// MARK: - Preset Selection

/// Represents which preset is currently active.
enum PresetSelection: Hashable {
    /// One of the built-in presets (Light, Medium, Heavy).
    case builtIn(BuiltInPreset)
    /// A user-saved custom preset, identified by UUID.
    case custom(UUID)
    /// Sliders have been manually adjusted and don't match any preset.
    case modified
}

// MARK: - Settings Manager

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
        static let globalShortcutEnabled = "globalShortcutEnabled"
        static let appLanguage = "appLanguage"
        static let hasLaunchedBefore = "hasLaunchedBefore"
        static let preferredDeviceUID = "preferredDeviceUID"
        static let hasGrantedAudioPermission = "hasGrantedAudioPermission"
        // New keys for custom preset system
        static let customPresets = "customPresets"
        static let selectedPresetType = "selectedPresetType"
        static let selectedPresetValue = "selectedPresetValue"
        // Legacy key (migrated on first run)
        static let selectedPreset = "selectedPreset"
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

    var hasGrantedAudioPermission: Bool {
        didSet {
            UserDefaults.standard.set(hasGrantedAudioPermission, forKey: Keys.hasGrantedAudioPermission)
        }
    }

    var preferredDeviceUID: String? {
        didSet {
            if let uid = preferredDeviceUID {
                UserDefaults.standard.set(uid, forKey: Keys.preferredDeviceUID)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.preferredDeviceUID)
            }
        }
    }

    // MARK: - Preset Properties

    var customPresets: [CustomPreset] {
        didSet {
            if let data = try? JSONEncoder().encode(customPresets) {
                UserDefaults.standard.set(data, forKey: Keys.customPresets)
            }
        }
    }

    var presetSelection: PresetSelection {
        didSet {
            persistPresetSelection()
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
        self.hasGrantedAudioPermission = defaults.bool(forKey: Keys.hasGrantedAudioPermission)
        self.preferredDeviceUID = defaults.string(forKey: Keys.preferredDeviceUID)

        if let langRaw = defaults.string(forKey: Keys.appLanguage),
           let lang = AppLanguage(rawValue: langRaw) {
            self.appLanguage = lang
        } else {
            self.appLanguage = AppLanguage.detect()
        }

        // Load custom presets from JSON
        let loadedCustomPresets: [CustomPreset]
        if let data = defaults.data(forKey: Keys.customPresets),
           let presets = try? JSONDecoder().decode([CustomPreset].self, from: data) {
            loadedCustomPresets = presets
        } else {
            loadedCustomPresets = []
        }
        self.customPresets = loadedCustomPresets

        // Load preset selection (must come after customPresets)
        if let type = defaults.string(forKey: Keys.selectedPresetType) {
            self.presetSelection = Self.loadPresetSelection(type: type,
                                                             value: defaults.string(forKey: Keys.selectedPresetValue),
                                                             customPresets: loadedCustomPresets)
        } else if let oldRaw = defaults.string(forKey: Keys.selectedPreset) {
            // Migration from old Preset enum
            if let builtIn = BuiltInPreset(rawValue: oldRaw) {
                self.presetSelection = .builtIn(builtIn)
            } else {
                self.presetSelection = .modified
            }
            // Persist in new format and remove old key
            persistPresetSelection()
            defaults.removeObject(forKey: Keys.selectedPreset)
        } else {
            self.presetSelection = .builtIn(.medium)
        }
    }

    // MARK: - Preset Selection Persistence

    private static func loadPresetSelection(type: String, value: String?, customPresets: [CustomPreset]) -> PresetSelection {
        switch type {
        case "builtIn":
            if let raw = value, let preset = BuiltInPreset(rawValue: raw) {
                return .builtIn(preset)
            }
            return .builtIn(.medium)
        case "custom":
            if let uuidStr = value, let uuid = UUID(uuidString: uuidStr),
               customPresets.contains(where: { $0.id == uuid }) {
                return .custom(uuid)
            }
            return .modified
        default:
            return .modified
        }
    }

    private func persistPresetSelection() {
        switch presetSelection {
        case .builtIn(let preset):
            UserDefaults.standard.set("builtIn", forKey: Keys.selectedPresetType)
            UserDefaults.standard.set(preset.rawValue, forKey: Keys.selectedPresetValue)
        case .custom(let id):
            UserDefaults.standard.set("custom", forKey: Keys.selectedPresetType)
            UserDefaults.standard.set(id.uuidString, forKey: Keys.selectedPresetValue)
        case .modified:
            UserDefaults.standard.set("modified", forKey: Keys.selectedPresetType)
            UserDefaults.standard.removeObject(forKey: Keys.selectedPresetValue)
        }
    }

    // MARK: - Preset Application

    func applyBuiltInPreset(_ preset: BuiltInPreset) {
        presetSelection = .builtIn(preset)
        releaseTime = preset.releaseTime
        makeupGainDb = preset.makeupGainDb
        targetLevelDb = preset.targetLevelDb
    }

    func applyCustomPreset(_ preset: CustomPreset) {
        presetSelection = .custom(preset.id)
        releaseTime = preset.releaseTime
        makeupGainDb = preset.makeupGainDb
        targetLevelDb = preset.targetLevelDb
    }

    // MARK: - Custom Preset CRUD

    @discardableResult
    func saveCurrentAsCustomPreset(name: String) -> CustomPreset {
        let preset = CustomPreset(
            name: name,
            releaseTime: releaseTime,
            makeupGainDb: makeupGainDb,
            targetLevelDb: targetLevelDb
        )
        customPresets.append(preset)
        presetSelection = .custom(preset.id)
        return preset
    }

    func deleteCustomPreset(id: UUID) {
        customPresets.removeAll { $0.id == id }
        if case .custom(let selectedID) = presetSelection, selectedID == id {
            presetSelection = .modified
        }
    }

    func renameCustomPreset(id: UUID, newName: String) {
        if let index = customPresets.firstIndex(where: { $0.id == id }) {
            customPresets[index].name = newName
        }
    }

    // MARK: - Defaults

    func resetToDefaults() {
        applyBuiltInPreset(.medium)
        preferredDeviceUID = nil
    }

    // MARK: - Auto Preset Detection

    private func updatePresetIfNeeded() {
        // If we're currently on a custom preset that still matches, keep it
        if case .custom(let id) = presetSelection,
           let preset = customPresets.first(where: { $0.id == id }),
           releaseTime == preset.releaseTime &&
           makeupGainDb == preset.makeupGainDb &&
           targetLevelDb == preset.targetLevelDb {
            return
        }
        // Check if current values match any built-in preset
        for preset in BuiltInPreset.allCases {
            if releaseTime == preset.releaseTime &&
               makeupGainDb == preset.makeupGainDb &&
               targetLevelDb == preset.targetLevelDb {
                if presetSelection != .builtIn(preset) {
                    presetSelection = .builtIn(preset)
                }
                return
            }
        }
        // Check if current values match any custom preset
        for preset in customPresets {
            if releaseTime == preset.releaseTime &&
               makeupGainDb == preset.makeupGainDb &&
               targetLevelDb == preset.targetLevelDb {
                if presetSelection != .custom(preset.id) {
                    presetSelection = .custom(preset.id)
                }
                return
            }
        }
        if presetSelection != .modified {
            presetSelection = .modified
        }
    }
}

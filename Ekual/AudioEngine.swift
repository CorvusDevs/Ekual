import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import os

// Architecture:
// 1. Get the current default output device
// 2. Create a global process tap (mutedWhenTapped to silence original audio)
// 3. Create a PRIVATE aggregate device with the tap + output device as sub-device
// 4. The aggregate's IO proc captures tapped audio (input), processes it in-place,
//    and copies it directly to the aggregate's output buffers → speakers
// 5. On device change: destroy aggregate, recreate with new device, reuse tap
// 6. On stop: stop IO, destroy aggregate, destroy tap

// MARK: - Output Device

struct OutputDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
}

// MARK: - Compressor State

private final class CompressorState: @unchecked Sendable {
    var compressor = LoudnessCompressor()
    var inputPeakDb: Float = -100.0
    var outputPeakDb: Float = -100.0
    var isActive: Bool = false
    var channelCount: Int = 2
}

// Static storage for emergency cleanup on termination signals.
nonisolated(unsafe) private var _staticTapID: AudioObjectID = 0
nonisolated(unsafe) private var _staticAggregateID: AudioObjectID = 0
nonisolated(unsafe) private var _staticIOProcID: AudioDeviceIOProcID?

private func emergencyCleanup() {
    if let procID = _staticIOProcID {
        AudioDeviceStop(_staticAggregateID, procID)
        AudioDeviceDestroyIOProcID(_staticAggregateID, procID)
        _staticIOProcID = nil
    }
    if _staticAggregateID != 0 {
        AudioHardwareDestroyAggregateDevice(_staticAggregateID)
        _staticAggregateID = 0
    }
    if _staticTapID != 0 {
        AudioHardwareDestroyProcessTap(_staticTapID)
        _staticTapID = 0
    }
}

private let _signalCleanupQueue = DispatchQueue(label: "com.pols.ekual.signal")

// MARK: - Running Audio App

struct RunningAudioApp: Identifiable, Hashable {
    let pid: pid_t
    let bundleID: String
    let name: String
    let icon: NSImage?
    var id: pid_t { pid }

    static func == (lhs: RunningAudioApp, rhs: RunningAudioApp) -> Bool {
        lhs.pid == rhs.pid && lhs.bundleID == rhs.bundleID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
        hasher.combine(bundleID)
    }
}

@Observable
@MainActor
final class AudioEngine {

    static let shared = AudioEngine()

    // MARK: - Published State

    var isRunning: Bool = false {
        didSet { StatusBarController.shared.updateIcon() }
    }
    var inputLevelDb: Float = -100.0
    var outputLevelDb: Float = -100.0
    var errorMessage: String?
    var switchingToDevice: String?
    var currentDeviceName: String = ""
    var availableOutputDevices: [OutputDevice] = []
    var preferredDeviceUID: String?

    var releaseTime: Float = 1.0 {
        didSet {
            compressorStatePtr?.pointee.compressor.releaseTime = releaseTime
            SettingsManager.shared.releaseTime = releaseTime
        }
    }

    var makeupGainDb: Float = 12.0 {
        didSet {
            compressorStatePtr?.pointee.compressor.makeupGainDb = makeupGainDb
            SettingsManager.shared.makeupGainDb = makeupGainDb
        }
    }

    var targetLevelDb: Float = -24.0 {
        didSet {
            compressorStatePtr?.pointee.compressor.targetLevelDb = targetLevelDb
            SettingsManager.shared.targetLevelDb = targetLevelDb
        }
    }

    // MARK: - Private Audio Objects (excluded from observation tracking)

    @ObservationIgnored private var tapID: AudioObjectID = kAudioObjectUnknown
    @ObservationIgnored private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    @ObservationIgnored private var ioProcID: AudioDeviceIOProcID?
    @ObservationIgnored private var compressorStatePtr: UnsafeMutablePointer<CompressorState>?
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private var terminationObserver: Any?
    @ObservationIgnored private let ioQueue = DispatchQueue(label: "com.pols.ekual.ioqueue", qos: .userInteractive)
    @ObservationIgnored private var isRestarting = false
    @ObservationIgnored private var switchingStartTime: Date?
    @ObservationIgnored private var deviceChangeListenerBlock: AudioObjectPropertyListenerBlock?

    /// Set to true once the engine has started successfully in this app session,
    /// confirming macOS TCC permission is active for the current code signature.
    var permissionConfirmedThisSession: Bool = false
    @ObservationIgnored private var deviceListListenerBlock: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var currentOutputDeviceID: AudioObjectID = kAudioObjectUnknown

    @ObservationIgnored private let logger = Logger(subsystem: "com.pols.ekual", category: "AudioEngine")
    @ObservationIgnored private var sigTermSource: DispatchSourceSignal?
    @ObservationIgnored private var sigIntSource: DispatchSourceSignal?

    init() {
        let settings = SettingsManager.shared
        self.releaseTime = settings.releaseTime
        self.makeupGainDb = settings.makeupGainDb
        self.targetLevelDb = settings.targetLevelDb
        self.preferredDeviceUID = settings.preferredDeviceUID

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stop()
            }
        }

        // Use DispatchSource for safe signal handling (async-signal-safe)
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: _signalCleanupQueue)
        termSource.setEventHandler {
            emergencyCleanup()
            exit(0)
        }
        termSource.resume()
        sigTermSource = termSource

        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: _signalCleanupQueue)
        intSource.setEventHandler {
            emergencyCleanup()
            exit(0)
        }
        intSource.resume()
        sigIntSource = intSource
    }

    // MARK: - Start / Stop

    // Stored tap UUID so we can reuse the tap across device changes
    @ObservationIgnored private var tapDescUUID: String = ""

    func start() {
        guard !isRunning else { return }
        errorMessage = nil

        // Clean up any zombie aggregate devices from previous crashes
        cleanupZombieDevices()

        do {
            let statePtr = UnsafeMutablePointer<CompressorState>.allocate(capacity: 1)
            statePtr.initialize(to: CompressorState())
            statePtr.pointee.compressor.releaseTime = releaseTime
            statePtr.pointee.compressor.makeupGainDb = makeupGainDb
            statePtr.pointee.compressor.targetLevelDb = targetLevelDb
            compressorStatePtr = statePtr

            // 1. Get the output device (preferred or system default)
            let realOutputDeviceID = try resolveOutputDevice()
            currentOutputDeviceID = realOutputDeviceID
            currentDeviceName = getDeviceName(realOutputDeviceID) ?? "Unknown"
            let outputUID = try getDeviceUID(realOutputDeviceID)
            let outputSampleRate = try getDeviceSampleRate(realOutputDeviceID)
            statePtr.pointee.compressor.setSampleRate(Float(outputSampleRate))
            refreshDeviceList()
            logger.info("Output device: \(self.currentDeviceName) (\(outputUID), ID \(realOutputDeviceID)), sample rate: \(outputSampleRate)")

            // 2. Create the process tap — global tap with mutedWhenTapped
            //    This captures ALL system audio and silences it at the source.
            //    We exclude our own process so the tap doesn't mute our HAL Output AU's audio.
            //    We'll play the processed version through a separate HAL Output AU.
            //    The tap is GLOBAL — it's not tied to any device, so it persists across device changes.
            if tapID == kAudioObjectUnknown {
                let selfProcessObjectID = try getProcessObjectID(for: getpid())
                logger.info("Own process AudioObjectID: \(selfProcessObjectID)")

                // Build exclusion list: self + any user-excluded apps
                // Use the HAL process object list to find ALL process objects (including
                // child/helper processes) matching the excluded bundle IDs.
                var excludedObjectIDs: [AudioObjectID] = [selfProcessObjectID]
                let excludedBundleIDs = SettingsManager.shared.excludedBundleIDs

                let matchedObjects = getAllProcessObjectIDs(forBundleIDs: excludedBundleIDs)
                excludedObjectIDs.append(contentsOf: matchedObjects)
                logger.info("Exclusion list: \(excludedObjectIDs.count) process objects (\(matchedObjects.count) from \(excludedBundleIDs.count) excluded bundle IDs)")

                let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedObjectIDs)
                tapDesc.uuid = UUID()
                tapDesc.name = "Ekual Loudness Tap"
                tapDesc.muteBehavior = .mutedWhenTapped

                self.tapDescUUID = tapDesc.uuid.uuidString
                logger.info("Tap description UUID: \(self.tapDescUUID)")

                var newTapID = AudioObjectID(kAudioObjectUnknown)
                let status = AudioHardwareCreateProcessTap(tapDesc, &newTapID)
                guard status == noErr else {
                    throw AudioEngineError.tapCreationFailed(status)
                }
                tapID = newTapID
                _staticTapID = newTapID
                logger.info("Created process tap: \(self.tapID)")
            } else {
                logger.info("Reusing existing process tap: \(self.tapID)")
            }

            // 3. Set up aggregate device + HAL Output AU + IO proc for the current output device
            try setupDevicePipeline(realOutputDeviceID: realOutputDeviceID, outputUID: outputUID, outputSampleRate: outputSampleRate, statePtr: statePtr)

            isRunning = true
            permissionConfirmedThisSession = true
            if !SettingsManager.shared.hasGrantedAudioPermission {
                SettingsManager.shared.hasGrantedAudioPermission = true
            }
            logger.info("Audio engine started successfully on device \(realOutputDeviceID)")

            installDeviceChangeListener()

        } catch {
            logger.error("Failed to start audio engine: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            cleanup()
        }
    }

    /// Sets up the aggregate device and IO proc for the current output device.
    /// The IO proc reads tapped audio from input, processes it, and writes directly
    /// to the aggregate's output buffers (which go to the speakers). No ring buffer
    /// or HAL Output AU needed — the aggregate device handles both capture and playback.
    /// Called from start() and from handleDeviceChange(). The process tap must already exist.
    private func setupDevicePipeline(realOutputDeviceID: AudioObjectID, outputUID: String, outputSampleRate: Float64, statePtr: UnsafeMutablePointer<CompressorState>) throws {
        // Create PRIVATE aggregate device with tap in creation dictionary
        let aggUID = UUID().uuidString
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Ekual Aggregate",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescUUID
                ]
            ]
        ]

        var newAggID: AudioObjectID = 0
        var status = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &newAggID)
        guard status == noErr else {
            throw AudioEngineError.aggregateDeviceCreationFailed(status)
        }
        aggregateDeviceID = newAggID
        _staticAggregateID = newAggID
        logger.info("Created aggregate device: \(self.aggregateDeviceID)")

        // Log stream config
        let inputStreamCount = try getStreamCount(newAggID, scope: kAudioObjectPropertyScopeInput)
        let outputStreamCount = try getStreamCount(newAggID, scope: kAudioObjectPropertyScopeOutput)
        logger.info("Aggregate input streams: \(inputStreamCount), output streams: \(outputStreamCount)")

        statePtr.pointee.channelCount = 2

        // Register IO proc on the aggregate device
        // Input: tapped system audio (from the process tap)
        // Output: processed audio sent directly to the real output device (speakers/headphones)
        let rawPtr = UnsafeMutableRawPointer(statePtr)
        var newIOProcID: AudioDeviceIOProcID?

        status = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateDeviceID, ioQueue) {
            inNow, inInputData, inInputTime, outOutputData, inOutputTime in

            let state = rawPtr.assumingMemoryBound(to: CompressorState.self)
            guard state.pointee.isActive else { return }

            let outputBufList = UnsafeMutableAudioBufferListPointer(outOutputData)
            let inputBufList = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData)
            )

            let inCount = inputBufList.count
            let outCount = outputBufList.count
            guard inCount > 0, outCount > 0 else { return }

            let pairCount = min(inCount, outCount)

            for i in 0..<pairCount {
                let inputBuf = inputBufList[i]
                guard let inputData = inputBuf.mData else { continue }

                let byteSize = Int(inputBuf.mDataByteSize)
                guard byteSize > 0 else { continue }

                let channels = Int(inputBuf.mNumberChannels)
                guard channels > 0 else { continue }

                let floatPtr = inputData.assumingMemoryBound(to: Float.self)
                let sampleCount = byteSize / MemoryLayout<Float>.size
                let frameCount = sampleCount / channels
                guard frameCount > 0 else { continue }

                // Process in-place on the input buffer
                let levels = state.pointee.compressor.process(
                    buffer: floatPtr,
                    frameCount: frameCount,
                    channelCount: channels
                )

                state.pointee.inputPeakDb = levels.inputPeakDb
                state.pointee.outputPeakDb = levels.outputPeakDb

                // Copy processed audio to the aggregate's output buffers
                if let outputData = outputBufList[i].mData {
                    let outputSize = Int(outputBufList[i].mDataByteSize)
                    let copySize = min(byteSize, outputSize)
                    memcpy(outputData, inputData, copySize)
                }
            }

            // Zero any remaining output buffers that didn't get input data
            if pairCount < outCount {
                for i in pairCount..<outCount {
                    if let data = outputBufList[i].mData {
                        memset(data, 0, Int(outputBufList[i].mDataByteSize))
                    }
                }
            }
        }

        guard status == noErr else {
            throw AudioEngineError.ioProcCreationFailed(status)
        }
        ioProcID = newIOProcID
        _staticIOProcID = newIOProcID
        logger.info("Created IO proc on aggregate")

        // Start
        statePtr.pointee.isActive = true

        status = AudioDeviceStart(aggregateDeviceID, ioProcID)
        guard status == noErr else {
            throw AudioEngineError.deviceStartFailed(status)
        }
        logger.info("Started IO proc on aggregate device \(realOutputDeviceID)")
    }

    func stop() {
        guard isRunning else { return }
        stopMetering()
        removeDeviceChangeListener()
        cleanup()
        isRunning = false
        currentOutputDeviceID = kAudioObjectUnknown
        currentDeviceName = ""
        errorMessage = nil
        logger.info("Audio engine stopped")
    }

    /// Restart the engine (e.g., after a device change or error). Can be called from UI.
    func restart() {
        guard isRunning else { return }
        logger.info("Restarting audio engine")
        let wasMetering = meterTimer != nil
        stop()
        start()
        if wasMetering { startMetering() }
    }

    // MARK: - Reset Defaults

    func resetToDefaults() {
        SettingsManager.shared.resetToDefaults()
        releaseTime = SettingsManager.shared.releaseTime
        makeupGainDb = SettingsManager.shared.makeupGainDb
        targetLevelDb = SettingsManager.shared.targetLevelDb
    }

    func applyBuiltInPreset(_ preset: BuiltInPreset) {
        SettingsManager.shared.applyBuiltInPreset(preset)
        releaseTime = SettingsManager.shared.releaseTime
        makeupGainDb = SettingsManager.shared.makeupGainDb
        targetLevelDb = SettingsManager.shared.targetLevelDb
    }

    func applyCustomPreset(_ preset: CustomPreset) {
        SettingsManager.shared.applyCustomPreset(preset)
        releaseTime = SettingsManager.shared.releaseTime
        makeupGainDb = SettingsManager.shared.makeupGainDb
        targetLevelDb = SettingsManager.shared.targetLevelDb
    }

    // MARK: - Device Selection

    func getOutputDevices() -> [OutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var devices = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices
        ) == noErr else { return [] }

        var result: [OutputDevice] = []
        for device in devices {
            guard let outputStreamCount = try? getStreamCount(device, scope: kAudioObjectPropertyScopeOutput),
                  outputStreamCount > 0 else { continue }
            guard let name = getDeviceName(device) else { continue }
            if name.contains("Ekual") { continue }
            guard let uid = try? getDeviceUID(device) else { continue }
            result.append(OutputDevice(id: device, uid: uid, name: name))
        }
        return result
    }

    func refreshDeviceList() {
        availableOutputDevices = getOutputDevices()
    }

    // MARK: - App Exclusion

    func getRunningAudioApps() -> [RunningAudioApp] {
        let ownBundleID = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier,
                  app.activationPolicy == .regular,
                  bundleID != ownBundleID else { return nil }
            let name = app.localizedName ?? bundleID
            let icon = app.icon
            icon?.size = NSSize(width: 16, height: 16)
            return RunningAudioApp(pid: app.processIdentifier, bundleID: bundleID, name: name, icon: icon)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Rebuilds the entire audio pipeline (tap + aggregate + IO) with the
    /// updated exclusion list. `isRunning` stays `true` throughout so
    /// the UI doesn't flicker or reset.
    func applyExclusionListChange() {
        guard isRunning, tapID != kAudioObjectUnknown else { return }
        logger.info("Applying exclusion list change — rebuilding pipeline")

        let wasMetering = meterTimer != nil
        stopMetering()
        removeDeviceChangeListener()

        // Tear down everything (device pipeline + tap) — but keep isRunning = true
        cleanup()

        // Rebuild from scratch — start() checks `guard !isRunning`, so
        // temporarily clear it, then restore on success or failure.
        isRunning = false
        start()

        // If start() failed, isRunning is still false (correct).
        // If start() succeeded, isRunning is true (correct).
        if wasMetering && isRunning {
            startMetering()
        }
    }

    func switchToDevice(_ device: OutputDevice?) {
        if let device {
            preferredDeviceUID = device.uid
            SettingsManager.shared.preferredDeviceUID = device.uid
        } else {
            preferredDeviceUID = nil
            SettingsManager.shared.preferredDeviceUID = nil
        }

        guard isRunning else { return }
        handleDeviceChange()
    }

    private func resolveOutputDevice() throws -> AudioObjectID {
        if let preferredUID = preferredDeviceUID {
            let devices = getOutputDevices()
            if let match = devices.first(where: { $0.uid == preferredUID }) {
                return match.id
            }
            logger.warning("Preferred device \(preferredUID) not found, falling back to system default")
            preferredDeviceUID = nil
            SettingsManager.shared.preferredDeviceUID = nil
        }
        return try getDefaultOutputDevice()
    }

    // MARK: - Meter Polling

    /// Call when the UI becomes visible to start meter updates.
    func startMetering() {
        guard isRunning, meterTimer == nil else { return }
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 10.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let statePtr = self.compressorStatePtr else { return }
                self.inputLevelDb = statePtr.pointee.inputPeakDb
                self.outputLevelDb = statePtr.pointee.outputPeakDb
            }
        }
    }

    /// Call when the UI is dismissed to stop wasting CPU on meter updates.
    func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
        inputLevelDb = -100.0
        outputLevelDb = -100.0
    }

    // MARK: - Device Change Listener

    private func installDeviceChangeListener() {
        removeDeviceChangeListener()

        let restartBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    guard let self, self.isRunning, !self.isRestarting else { return }

                    // If user pinned a specific device and it's still active, don't switch
                    if let preferredUID = self.preferredDeviceUID {
                        let currentUID = try? self.getDeviceUID(self.currentOutputDeviceID)
                        if currentUID == preferredUID {
                            self.refreshDeviceList()
                            return
                        }
                    }

                    self.handleDeviceChange()
                }
            }
        }
        deviceChangeListenerBlock = restartBlock

        // Listen for the default output device changing (e.g. switching to Bluetooth)
        var defaultDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultDeviceAddress,
            DispatchQueue.main,
            restartBlock
        )

        // Listen for devices being added/removed (only refreshes the picker, no restart)
        let listRefreshBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated {
                    guard let self, self.isRunning else { return }
                    self.refreshDeviceList()
                }
            }
        }
        deviceListListenerBlock = listRefreshBlock

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            DispatchQueue.main,
            listRefreshBlock
        )

        // Also listen for the data source changing on the current output device
        // (e.g. headphones unplugged → internal speakers on the same device ID)
        if currentOutputDeviceID != kAudioObjectUnknown {
            var dataSourceAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDataSource,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(
                currentOutputDeviceID,
                &dataSourceAddress,
                DispatchQueue.main,
                restartBlock
            )
        }
    }

    private func handleDeviceChange() {
        isRestarting = true
        logger.info("Audio output configuration changed, rebuilding device pipeline (tap preserved)")

        // Determine target device name for the "Switching to..." UI
        let targetName: String
        if let preferredUID = preferredDeviceUID {
            let devices = getOutputDevices()
            if let match = devices.first(where: { $0.uid == preferredUID }) {
                targetName = match.name
            } else {
                // Preferred device disappeared — fall back to system default
                preferredDeviceUID = nil
                SettingsManager.shared.preferredDeviceUID = nil
                targetName = (try? getDefaultOutputDevice()).flatMap { getDeviceName($0) } ?? "..."
            }
        } else {
            targetName = (try? getDefaultOutputDevice()).flatMap { getDeviceName($0) } ?? "..."
        }

        switchingToDevice = targetName
        switchingStartTime = Date()

        let wasMetering = meterTimer != nil
        stopMetering()
        removeDeviceChangeListener()

        // Tear down only the device pipeline — keep the process tap alive
        cleanupDevicePipeline()
        isRunning = false
        currentOutputDeviceID = kAudioObjectUnknown
        errorMessage = nil

        // Retry start (which will reuse the existing tap) up to 3 times
        retryStart(attempt: 1, maxAttempts: 3, restoreMetering: wasMetering)
    }

    private func retryStart(attempt: Int, maxAttempts: Int, restoreMetering: Bool) {
        let delay = Double(attempt) * 0.5  // 0.5s, 1.0s, 1.5s
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                self.logger.info("Device switch: start attempt \(attempt)/\(maxAttempts)")
                self.start()

                if self.isRunning {
                    if restoreMetering { self.startMetering() }
                    self.logger.info("Engine restarted on device \(self.currentOutputDeviceID) (attempt \(attempt))")
                    self.isRestarting = false
                    self.clearSwitchingStatus()
                } else if attempt < maxAttempts {
                    self.logger.warning("Start attempt \(attempt) failed, retrying...")
                    self.retryStart(attempt: attempt + 1, maxAttempts: maxAttempts, restoreMetering: restoreMetering)
                } else {
                    self.logger.error("All \(maxAttempts) start attempts failed after device change")
                    self.isRestarting = false
                    self.clearSwitchingStatus()
                }
            }
        }
    }

    private func clearSwitchingStatus() {
        let minDisplayTime: TimeInterval = 1.5
        let elapsed = Date().timeIntervalSince(switchingStartTime ?? .distantPast)
        let remaining = max(0, minDisplayTime - elapsed)

        if remaining > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) {
                MainActor.assumeIsolated {
                    self.switchingToDevice = nil
                    self.switchingStartTime = nil
                }
            }
        } else {
            switchingToDevice = nil
            switchingStartTime = nil
        }
    }

    private func removeDeviceChangeListener() {
        guard let block = deviceChangeListenerBlock else { return }

        // Remove default device listener
        var defaultDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultDeviceAddress,
            DispatchQueue.main,
            block
        )

        // Remove devices list listener
        if let listBlock = deviceListListenerBlock {
            var devicesAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &devicesAddress,
                DispatchQueue.main,
                listBlock
            )
            deviceListListenerBlock = nil
        }

        // Remove data source listener from the current output device
        if currentOutputDeviceID != kAudioObjectUnknown {
            var dataSourceAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDataSource,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                currentOutputDeviceID,
                &dataSourceAddress,
                DispatchQueue.main,
                block
            )
        }

        deviceChangeListenerBlock = nil
    }

    // MARK: - Cleanup

    /// Tears down the device pipeline (IO proc, aggregate, compressor state)
    /// but preserves the process tap so it can be reused on the new device.
    private func cleanupDevicePipeline() {
        compressorStatePtr?.pointee.isActive = false

        // Stop the aggregate IO proc
        if let procID = ioProcID {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            ioProcID = nil
            _staticIOProcID = nil
        }

        // Destroy aggregate device
        if aggregateDeviceID != kAudioObjectUnknown && aggregateDeviceID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
            _staticAggregateID = 0
        }

        if let ptr = compressorStatePtr {
            ptr.pointee.compressor.deallocate()
            ptr.deinitialize(count: 1)
            ptr.deallocate()
            compressorStatePtr = nil
        }
    }

    /// Full cleanup — tears down everything including the process tap.
    /// Only called from stop() or on error during start().
    private func cleanup() {
        meterTimer?.invalidate()
        meterTimer = nil

        cleanupDevicePipeline()

        // Destroy process tap
        if tapID != kAudioObjectUnknown {
            let err = AudioHardwareDestroyProcessTap(tapID)
            if err != noErr {
                logger.error("cleanup: AudioHardwareDestroyProcessTap(\(self.tapID)) failed: \(err)")
            } else {
                logger.info("cleanup: Destroyed process tap \(self.tapID)")
            }
            tapID = kAudioObjectUnknown
            _staticTapID = 0
            tapDescUUID = ""
        }
    }

    // MARK: - Zombie Cleanup

    /// Destroy any leftover Ekual aggregate devices from previous crashes.
    private func cleanupZombieDevices() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var devices = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices
        ) == noErr else { return }

        var zombieIDs: [AudioObjectID] = []

        for device in devices {
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.stride)
            _ = withUnsafeMutablePointer(to: &name) { ptr in
                AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, ptr)
            }
            if (name as String).contains("Ekual") {
                zombieIDs.append(device)
            }
        }

        guard !zombieIDs.isEmpty else { return }

        for zombieID in zombieIDs {
            logger.info("Destroying zombie aggregate device ID \(zombieID)")
            AudioHardwareDestroyAggregateDevice(zombieID)
        }

    }

    // MARK: - Helpers

    private func getDefaultOutputDevice() throws -> AudioObjectID {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr else { throw AudioEngineError.propertyQueryFailed(status) }
        return deviceID
    }

    private func getDeviceUID(_ deviceID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.stride)
        let status = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { throw AudioEngineError.propertyQueryFailed(status) }
        return uid as String
    }

    private func getDeviceName(_ deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.stride)
        let status = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return name as String
    }

    private func getDeviceSampleRate(_ deviceID: AudioObjectID) throws -> Float64 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate)
        guard status == noErr else { throw AudioEngineError.propertyQueryFailed(status) }
        return sampleRate
    }

    private func getStreamCount(_ deviceID: AudioObjectID, scope: AudioObjectPropertyScope) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard status == noErr else { throw AudioEngineError.propertyQueryFailed(status) }
        return Int(size) / MemoryLayout<AudioObjectID>.size
    }

    private func getProcessObjectID(for pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pidValue = pid
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let qualifierSize = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            qualifierSize, &pidValue,
            &size, &processObjectID
        )
        guard status == noErr else { throw AudioEngineError.propertyQueryFailed(status) }
        return processObjectID
    }

    /// Returns ALL HAL process AudioObjectIDs whose bundle ID matches any in the given set.
    /// This uses kAudioHardwarePropertyProcessObjectList to enumerate every process
    /// known to the audio system (including child/helper processes like browser renderers),
    /// then checks each one's kAudioProcessPropertyBundleID.
    private func getAllProcessObjectIDs(forBundleIDs bundleIDs: Set<String>) -> [AudioObjectID] {
        guard !bundleIDs.isEmpty else { return [] }

        // 1. Get the full list of HAL process objects
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var listSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &listSize
        ) == noErr, listSize > 0 else { return [] }

        let count = Int(listSize) / MemoryLayout<AudioObjectID>.size
        var processObjects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &listSize, &processObjects
        ) == noErr else { return [] }

        // 2. For each process object, get its bundle ID and check if it matches
        var matched: [AudioObjectID] = []
        for objID in processObjects {
            var bundleIDAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyBundleID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var bundleIDSize = UInt32(MemoryLayout<CFString>.size)
            var bundleIDRef: CFString = "" as CFString
            let status = withUnsafeMutablePointer(to: &bundleIDRef) { ptr in
                AudioObjectGetPropertyData(objID, &bundleIDAddress, 0, nil, &bundleIDSize, ptr)
            }
            if status == noErr {
                let bundleID = bundleIDRef as String
                // Use prefix matching: e.g. excluding "com.brave.Browser" also
                // catches "com.brave.Browser.helper" (renderer/audio child processes)
                let isMatch = bundleIDs.contains(where: { excludedID in
                    bundleID == excludedID || bundleID.hasPrefix(excludedID + ".")
                })
                if isMatch {
                    matched.append(objID)
                    logger.info("HAL process match: \(bundleID) → AudioObjectID \(objID)")
                }
            }
        }

        return matched
    }
}

// MARK: - Errors

enum AudioEngineError: LocalizedError {
    case tapCreationFailed(OSStatus)
    case aggregateDeviceCreationFailed(OSStatus)
    case ioProcCreationFailed(OSStatus)
    case deviceStartFailed(OSStatus)
    case propertyQueryFailed(OSStatus)
    case auComponentNotFound
    case auCreationFailed(OSStatus)
    case auPropertyFailed(OSStatus, String)

    var errorDescription: String? {
        switch self {
        case .tapCreationFailed(let s): "Failed to create process tap (OSStatus \(s))"
        case .aggregateDeviceCreationFailed(let s): "Failed to create aggregate device (OSStatus \(s))"
        case .ioProcCreationFailed(let s): "Failed to create IO proc (OSStatus \(s))"
        case .deviceStartFailed(let s): "Failed to start audio device (OSStatus \(s))"
        case .propertyQueryFailed(let s): "Failed to query audio property (OSStatus \(s))"
        case .auComponentNotFound: "HAL Output AudioUnit component not found"
        case .auCreationFailed(let s): "Failed to create AudioUnit (OSStatus \(s))"
        case .auPropertyFailed(let s, let prop): "Failed to set AudioUnit property '\(prop)' (OSStatus \(s))"
        }
    }
}

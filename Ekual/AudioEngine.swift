import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import os

// Architecture:
// 1. Get the current default output device, save it
// 2. Create a global process tap (mutedWhenTapped to silence original audio)
// 3. Create a PRIVATE aggregate device with the tap in the creation dict (for capture)
// 4. Create a HAL Output AudioUnit pointed at the REAL output device (for playback)
// 5. The aggregate's IO proc captures tapped audio, processes it, writes to a ring buffer
// 6. The HAL Output AU's render callback reads from the ring buffer → speakers
// 7. On stop: stop AU, stop IO, destroy aggregate, destroy tap

// MARK: - Lock-Free Ring Buffer

/// A simple lock-free SPSC ring buffer for shuttling audio between the aggregate
/// IO proc (producer) and the HAL Output AU render callback (consumer).
/// Both run on real-time threads — no locks, no allocations.
fileprivate final class AudioRingBuffer: @unchecked Sendable {
    private let capacity: Int
    private let buffer: UnsafeMutablePointer<Float>
    private var writeIndex: Int = 0  // only written by producer
    private var readIndex: Int = 0   // only written by consumer

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = .allocate(capacity: capacity)
        self.buffer.initialize(repeating: 0, count: capacity)
    }

    deinit {
        buffer.deinitialize(count: capacity)
        buffer.deallocate()
    }

    var availableToRead: Int {
        let w = writeIndex
        let r = readIndex
        return w >= r ? (w - r) : (capacity - r + w)
    }

    func write(_ data: UnsafePointer<Float>, count: Int) {
        var remaining = count
        var src = data
        var wi = writeIndex
        while remaining > 0 {
            let chunk = min(remaining, capacity - wi)
            buffer.advanced(by: wi).update(from: src, count: chunk)
            wi = (wi + chunk) % capacity
            src = src.advanced(by: chunk)
            remaining -= chunk
        }
        writeIndex = wi
    }

    func read(_ data: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let avail = availableToRead
        let toRead = min(count, avail)
        var remaining = toRead
        var dst = data
        var ri = readIndex
        while remaining > 0 {
            let chunk = min(remaining, capacity - ri)
            dst.update(from: buffer.advanced(by: ri), count: chunk)
            ri = (ri + chunk) % capacity
            dst = dst.advanced(by: chunk)
            remaining -= chunk
        }
        readIndex = ri
        return toRead
    }
}

// MARK: - Compressor State

private final class CompressorState: @unchecked Sendable {
    var compressor = LoudnessCompressor()
    var inputPeakDb: Float = -100.0
    var outputPeakDb: Float = -100.0
    var isActive: Bool = false
    var ringBuffer: AudioRingBuffer?
    var channelCount: Int = 2
}

// Static storage for signal handler cleanup.
nonisolated(unsafe) private var _staticTapID: AudioObjectID = 0
nonisolated(unsafe) private var _staticAggregateID: AudioObjectID = 0
nonisolated(unsafe) private var _staticIOProcID: AudioDeviceIOProcID?
nonisolated(unsafe) private var _staticOutputAU: AudioUnit?
nonisolated private func emergencyCleanup() {
    if let au = _staticOutputAU {
        AudioOutputUnitStop(au)
        AudioComponentInstanceDispose(au)
        _staticOutputAU = nil
    }
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

@Observable
@MainActor
final class AudioEngine {

    static let shared = AudioEngine()

    // MARK: - Published State

    var isRunning: Bool = false
    var inputLevelDb: Float = -100.0
    var outputLevelDb: Float = -100.0
    var errorMessage: String?

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

    // MARK: - Private Audio Objects

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var outputAU: AudioUnit?
    private var compressorStatePtr: UnsafeMutablePointer<CompressorState>?
    private var meterTimer: Timer?
    private var terminationObserver: Any?
    private let ioQueue = DispatchQueue(label: "com.pols.ekual.ioqueue", qos: .userInteractive)

    private let logger = Logger(subsystem: "com.pols.ekual", category: "AudioEngine")

    init() {
        let settings = SettingsManager.shared
        self.releaseTime = settings.releaseTime
        self.makeupGainDb = settings.makeupGainDb
        self.targetLevelDb = settings.targetLevelDb

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stop()
            }
        }

        signal(SIGTERM) { _ in emergencyCleanup(); exit(0) }
        signal(SIGINT) { _ in emergencyCleanup(); exit(0) }
    }

    // MARK: - Start / Stop

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

            // 1. Get the current default output device (the REAL one)
            let realOutputDeviceID = try getDefaultOutputDevice()
            let outputUID = try getDeviceUID(realOutputDeviceID)
            let outputSampleRate = try getDeviceSampleRate(realOutputDeviceID)
            statePtr.pointee.compressor.setSampleRate(Float(outputSampleRate))
            logger.info("Real output device: \(outputUID) (ID \(realOutputDeviceID)), sample rate: \(outputSampleRate)")

            // 2. Create the process tap — global tap with mutedWhenTapped
            //    This captures ALL system audio and silences it at the source.
            //    We exclude our own process so the tap doesn't mute our HAL Output AU's audio.
            //    We'll play the processed version through a separate HAL Output AU.
            let selfProcessObjectID = try getProcessObjectID(for: getpid())
            logger.info("Own process AudioObjectID: \(selfProcessObjectID)")

            let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [selfProcessObjectID])
            tapDesc.uuid = UUID()
            tapDesc.name = "Ekual Loudness Tap"
            tapDesc.muteBehavior = .mutedWhenTapped

            let tapDescUUID = tapDesc.uuid.uuidString
            logger.info("Tap description UUID: \(tapDescUUID)")

            var newTapID = AudioObjectID(kAudioObjectUnknown)
            var status = AudioHardwareCreateProcessTap(tapDesc, &newTapID)
            guard status == noErr else {
                throw AudioEngineError.tapCreationFailed(status)
            }
            tapID = newTapID
            _staticTapID = newTapID
            logger.info("Created process tap: \(self.tapID)")

            // 3. Create PRIVATE aggregate device with tap in creation dictionary
            //    This is used ONLY for capture (reading tapped audio via input streams).
            //    We do NOT set it as the default output device.
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
            status = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &newAggID)
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

            // 4. Create ring buffer (enough for ~0.5 seconds of stereo float audio)
            let ringCapacity = Int(outputSampleRate) * 2  // stereo, 0.5 sec
            let ringBuffer = AudioRingBuffer(capacity: ringCapacity)
            statePtr.pointee.ringBuffer = ringBuffer
            statePtr.pointee.channelCount = 2

            // 5. Create HAL Output AudioUnit pointed at the REAL output device
            var outputAudioUnit: AudioUnit?
            var componentDesc = AudioComponentDescription(
                componentType: kAudioUnitType_Output,
                componentSubType: kAudioUnitSubType_HALOutput,
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0,
                componentFlagsMask: 0
            )
            guard let component = AudioComponentFindNext(nil, &componentDesc) else {
                throw AudioEngineError.auComponentNotFound
            }
            status = AudioComponentInstanceNew(component, &outputAudioUnit)
            guard status == noErr, let au = outputAudioUnit else {
                throw AudioEngineError.auCreationFailed(status)
            }
            outputAU = au
            _staticOutputAU = au

            // Set the AU's output device to the REAL output device
            var realDevID = realOutputDeviceID
            status = AudioUnitSetProperty(
                au,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0,
                &realDevID,
                UInt32(MemoryLayout<AudioObjectID>.size)
            )
            guard status == noErr else {
                throw AudioEngineError.auPropertyFailed(status, "CurrentDevice")
            }

            // Set the stream format on the AU's input scope (bus 0) to match our processing format
            var streamFormat = AudioStreamBasicDescription(
                mSampleRate: outputSampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(MemoryLayout<Float>.size * 2),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(MemoryLayout<Float>.size * 2),
                mChannelsPerFrame: 2,
                mBitsPerChannel: 32,
                mReserved: 0
            )
            status = AudioUnitSetProperty(
                au,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Input, 0,
                &streamFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            )
            guard status == noErr else {
                throw AudioEngineError.auPropertyFailed(status, "StreamFormat")
            }

            // Set the render callback — this pulls processed audio from the ring buffer
            let stateRawPtr = UnsafeMutableRawPointer(statePtr)
            var renderCallback = AURenderCallbackStruct(
                inputProc: { (
                    inRefCon: UnsafeMutableRawPointer,
                    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                    inTimeStamp: UnsafePointer<AudioTimeStamp>,
                    inBusNumber: UInt32,
                    inNumberFrames: UInt32,
                    ioData: UnsafeMutablePointer<AudioBufferList>?
                ) -> OSStatus in
                    guard let ioData else { return noErr }
                    let state = inRefCon.assumingMemoryBound(to: CompressorState.self)
                    let bufList = UnsafeMutableAudioBufferListPointer(ioData)

                    guard state.pointee.isActive, let ring = state.pointee.ringBuffer else {
                        // Output silence
                        for i in 0..<bufList.count {
                            if let data = bufList[i].mData {
                                memset(data, 0, Int(bufList[i].mDataByteSize))
                            }
                        }
                        return noErr
                    }

                    let channels = state.pointee.channelCount
                    let samplesNeeded = Int(inNumberFrames) * channels

                    for i in 0..<bufList.count {
                        guard let data = bufList[i].mData else { continue }
                        let floatPtr = data.assumingMemoryBound(to: Float.self)
                        let bufSamples = Int(bufList[i].mDataByteSize) / MemoryLayout<Float>.size
                        let toRead = min(samplesNeeded, bufSamples)

                        let read = ring.read(floatPtr, count: toRead)
                        // Zero any remaining samples if ring didn't have enough
                        if read < toRead {
                            memset(floatPtr.advanced(by: read), 0, (toRead - read) * MemoryLayout<Float>.size)
                        }
                    }
                    return noErr
                },
                inputProcRefCon: stateRawPtr
            )
            status = AudioUnitSetProperty(
                au,
                kAudioUnitProperty_SetRenderCallback,
                kAudioUnitScope_Input, 0,
                &renderCallback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            )
            guard status == noErr else {
                throw AudioEngineError.auPropertyFailed(status, "RenderCallback")
            }

            // Initialize and start the AU
            status = AudioUnitInitialize(au)
            guard status == noErr else {
                throw AudioEngineError.auPropertyFailed(status, "Initialize")
            }
            logger.info("Initialized HAL Output AU on real device \(realOutputDeviceID)")

            // 6. Register IO proc on the aggregate device (capture side)
            let rawPtr = UnsafeMutableRawPointer(statePtr)
            var newIOProcID: AudioDeviceIOProcID?

            status = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateDeviceID, ioQueue) {
                inNow, inInputData, inInputTime, outOutputData, inOutputTime in

                let state = rawPtr.assumingMemoryBound(to: CompressorState.self)

                // Zero the aggregate's output — we don't use it for playback
                let outputBufList = UnsafeMutableAudioBufferListPointer(outOutputData)
                for i in 0..<outputBufList.count {
                    if let data = outputBufList[i].mData {
                        memset(data, 0, Int(outputBufList[i].mDataByteSize))
                    }
                }

                guard state.pointee.isActive, let ring = state.pointee.ringBuffer else { return }

                let inputBufList = UnsafeMutableAudioBufferListPointer(
                    UnsafeMutablePointer(mutating: inInputData)
                )

                for i in 0..<inputBufList.count {
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

                    // Write processed audio to ring buffer for the HAL Output AU
                    ring.write(floatPtr, count: sampleCount)
                }
            }

            guard status == noErr else {
                throw AudioEngineError.ioProcCreationFailed(status)
            }
            ioProcID = newIOProcID
            _staticIOProcID = newIOProcID
            logger.info("Created IO proc on aggregate")

            // 7. Start everything
            statePtr.pointee.isActive = true

            // Start the HAL Output AU first (consumer), then the aggregate IO proc (producer)
            status = AudioOutputUnitStart(au)
            guard status == noErr else {
                throw AudioEngineError.deviceStartFailed(status)
            }
            logger.info("Started HAL Output AU")

            status = AudioDeviceStart(aggregateDeviceID, ioProcID)
            guard status == noErr else {
                throw AudioEngineError.deviceStartFailed(status)
            }
            logger.info("Started IO proc on aggregate")

            isRunning = true
            logger.info("Audio engine started successfully")
            startMeterTimer()

        } catch {
            logger.error("Failed to start audio engine: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            cleanup()
        }
    }

    func stop() {
        guard isRunning else { return }
        cleanup()
        isRunning = false
        inputLevelDb = -100.0
        outputLevelDb = -100.0
        errorMessage = nil
        logger.info("Audio engine stopped")
    }

    // MARK: - Reset Defaults

    func resetToDefaults() {
        SettingsManager.shared.resetToDefaults()
        releaseTime = SettingsManager.shared.releaseTime
        makeupGainDb = SettingsManager.shared.makeupGainDb
        targetLevelDb = SettingsManager.shared.targetLevelDb
    }

    func applyPreset(_ preset: Preset) {
        SettingsManager.shared.applyPreset(preset)
        releaseTime = SettingsManager.shared.releaseTime
        makeupGainDb = SettingsManager.shared.makeupGainDb
        targetLevelDb = SettingsManager.shared.targetLevelDb
    }

    // MARK: - Meter Polling

    private func startMeterTimer() {
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let statePtr = self.compressorStatePtr else { return }
                self.inputLevelDb = statePtr.pointee.inputPeakDb
                self.outputLevelDb = statePtr.pointee.outputPeakDb
            }
        }
    }

    // MARK: - Cleanup

    private func cleanup() {
        meterTimer?.invalidate()
        meterTimer = nil

        compressorStatePtr?.pointee.isActive = false

        // Stop the HAL Output AU
        if let au = outputAU {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
            outputAU = nil
            _staticOutputAU = nil
        }

        // Stop the aggregate IO proc
        if let procID = ioProcID {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            ioProcID = nil
            _staticIOProcID = nil
        }

        // Destroy aggregate device (no need to restore default — we never changed it)
        if aggregateDeviceID != kAudioObjectUnknown && aggregateDeviceID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
            _staticAggregateID = 0
        }

        // Destroy process tap
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
            _staticTapID = 0
        }

        if let ptr = compressorStatePtr {
            ptr.deinitialize(count: 1)
            ptr.deallocate()
            compressorStatePtr = nil
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

        // Give the system time to settle after destroying devices
        Thread.sleep(forTimeInterval: 0.3)
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

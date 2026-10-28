import AVFoundation
import CoreAudio
import Foundation

// Adapted from amanu (MIT, Copyright (c) 2026 Andrew Jones, Samat Galimov),
// Sources/amanu/Audio/SystemAudioRecorder.swift. See THIRD-PARTY-NOTICES.md.

/// Captures everything the Mac plays except Granula itself, through a Core
/// Audio process tap inside a private aggregate device (macOS 14.2+). First use
/// triggers the "System Audio Recording" permission prompt. A denied or stale
/// permission still delivers buffers — of exact zeros.
public final class SystemAudioCapture: @unchecked Sendable {
    public enum CaptureError: Error, CustomStringConvertible {
        case tapCreationFailed(OSStatus)
        case tapFormatUnreadable(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case ioProcCreationFailed(OSStatus)
        case deviceStartFailed(OSStatus)

        public var description: String {
            switch self {
            case .tapCreationFailed(let s): return String(localized: "не удалось создать tap (\(s))")
            case .tapFormatUnreadable(let s): return String(localized: "не читается формат tap (\(s))")
            case .aggregateCreationFailed(let s): return String(localized: "не создаётся aggregate-устройство (\(s))")
            case .ioProcCreationFailed(let s): return String(localized: "не создаётся IOProc (\(s))")
            case .deviceStartFailed(let s): return String(localized: "устройство не запустилось (\(s))")
            }
        }
    }

    /// Called on the capture queue for every buffer.
    public var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "ai.nahornyi.granula.system-tap", qos: .userInteractive)
    public private(set) var isRunning = false

    public init() {}

    public func start() throws {
        guard !isRunning else { return }
        let excluded = AudioProcesses.ownProcessObject().map { [$0] } ?? []
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
        description.name = "Granula tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTap = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &newTap)
        guard status == noErr else { throw CaptureError.tapCreationFailed(status) }
        tapID = newTap
        do {
            let format = try readTapFormat()
            try createAggregate(tapUUID: description.uuid)
            try installIOProc(format: format)
        } catch {
            cleanup()
            throw error
        }
        isRunning = true
        Log.event("system.started", "excluded=\(excluded.count)")
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        if let procID, aggregateID != kAudioObjectUnknown { AudioDeviceStop(aggregateID, procID) }
        cleanup()
        Log.event("system.stopped")
    }

    // MARK: -

    /// coreaudiod may not have the format ready right after creation; retry.
    private func readTapFormat() throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var lastStatus: OSStatus = noErr
        for _ in 0..<10 {
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            lastStatus = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
            if lastStatus == noErr, asbd.mSampleRate > 0, let format = AVAudioFormat(streamDescription: &asbd) {
                return format
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw CaptureError.tapFormatUnreadable(lastStatus)
    }

    private func createAggregate(tapUUID: UUID) throws {
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Granula-Audio-Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [] as [[String: Any]],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUUID.uuidString, kAudioSubTapDriftCompensationKey: true],
            ],
        ]
        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &newAggregate)
        guard status == noErr else { throw CaptureError.aggregateCreationFailed(status) }
        aggregateID = newAggregate
    }

    private func installIOProc(format: AVAudioFormat) throws {
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) {
            [weak self] _, inInputData, _, _, _ in
            guard let self, let onBuffer = self.onBuffer,
                  let borrowed = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil)
            else { return }
            onBuffer(borrowed)
        }
        guard status == noErr, let procID else { throw CaptureError.ioProcCreationFailed(status) }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw CaptureError.deviceStartFailed(status) }
    }

    private func cleanup() {
        if let procID, aggregateID != kAudioObjectUnknown { AudioDeviceDestroyIOProcID(aggregateID, procID) }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}

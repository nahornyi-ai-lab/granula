import AppKit
import CoreAudio
import Foundation

// Adapted from amanu (MIT, Copyright (c) 2026 Andrew Jones, Samat Galimov),
// Sources/amanu/Audio/AudioProcesses.swift. See THIRD-PARTY-NOTICES.md.

/// Core Audio's per-process objects (macOS 14.4+): who holds the microphone.
public enum AudioProcesses {
    public struct Process: Sendable {
        public let object: AudioObjectID
        public let pid: pid_t
        public let bundleID: String
        public let name: String
        public let runningInput: Bool
    }

    /// Every audio process except our own.
    public static func all() -> [Process] {
        guard let objects = processObjectList() else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return objects.compactMap { object -> Process? in
            guard let raw = uint32(object, kAudioProcessPropertyPID) else { return nil }
            let pid = pid_t(bitPattern: raw)
            guard pid != ownPID else { return nil }
            let app = NSRunningApplication(processIdentifier: pid)
            let bundleID = string(object, kAudioProcessPropertyBundleID) ?? app?.bundleIdentifier ?? ""
            let name = app?.localizedName ?? bundleID.split(separator: ".").last.map(String.init) ?? ""
            return Process(
                object: object, pid: pid, bundleID: bundleID, name: name,
                runningInput: (uint32(object, kAudioProcessPropertyIsRunningInput) ?? 0) != 0)
        }
    }

    /// Our own process object — the one process the system tap must exclude.
    public static func ownProcessObject() -> AudioObjectID? {
        var pid = ProcessInfo.processInfo.processIdentifier
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        guard status == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }

    private static func processObjectList() -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0
        else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = ids.withUnsafeMutableBytes { raw in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, raw.baseAddress!)
        }
        return status == noErr ? ids : nil
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        // Follows the Core Foundation create rule: the string comes back retained.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        let string = value.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }
}

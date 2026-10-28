import CoreAudio
import Foundation

/// Watches the system default input and output devices. Handlers run on main.
public final class AudioDeviceObserver {
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    public init(onInputChange: @escaping () -> Void, onOutputChange: @escaping () -> Void) {
        add(kAudioHardwarePropertyDefaultInputDevice, onInputChange)
        add(kAudioHardwarePropertyDefaultOutputDevice, onOutputChange)
    }

    deinit {
        for (address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        }
    }

    private func add(_ selector: AudioObjectPropertySelector, _ handler: @escaping () -> Void) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block) == noErr {
            listeners.append((address, block))
        }
    }
}

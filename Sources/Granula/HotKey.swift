import Carbon
import GranulaCore
import Foundation

/// Global ⌥⌘R through Carbon's RegisterEventHotKey: works while another app
/// (the call) is in front, without the Accessibility permission.
final class HotKey {
    static let shared = HotKey()

    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    fileprivate var action: (() -> Void)?

    func register(_ action: @escaping () -> Void) {
        guard ref == nil else { return }
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.shared.action?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x47524E4C), id: 1) // "GRNL"
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(cmdKey | optionKey), id,
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr { Log.event("hotkey.failed", "status=\(status)") }
    }
}

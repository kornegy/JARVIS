import Carbon.HIToolbox
import JarvisSettings

public enum PushToTalkHotKeyError: Error, Equatable {
    /// Сочетание уже занято другим приложением или системой.
    case unavailable
}

/// Глобальная горячая клавиша Push-to-Talk: нажал — слушаю, отпустил — команда.
///
/// Используется `RegisterEventHotKey` (Carbon): работает без разрешения Accessibility и
/// не видит никаких других нажатий клавиш — только своё сочетание.
@MainActor
public final class PushToTalkHotKey {
    public var onPress: (() -> Void)?
    public var onRelease: (() -> Void)?
    public private(set) var registeredShortcut: PushToTalkShortcut?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    static let signature: OSType = 0x4A52_5653 // «JRVS»

    public init() {}

    public func register(_ shortcut: PushToTalkShortcut) throws {
        unregister()
        installHandlerIfNeeded()
        let keys = Self.keyCombination(for: shortcut)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keys.keyCode,
            keys.modifiers,
            EventHotKeyID(signature: Self.signature, id: 1),
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else { throw PushToTalkHotKeyError.unavailable }
        hotKeyRef = reference
        registeredShortcut = shortcut
    }

    public func unregister() {
        if let hotKeyRef {
            _ = UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        registeredShortcut = nil
    }

    static func keyCombination(for shortcut: PushToTalkShortcut) -> (keyCode: UInt32, modifiers: UInt32) {
        switch shortcut {
        case .controlOptionSpace: (UInt32(kVK_Space), UInt32(controlKey | optionKey))
        case .optionSpace: (UInt32(kVK_Space), UInt32(optionKey))
        case .shiftOptionSpace: (UInt32(kVK_Space), UInt32(shiftKey | optionKey))
        case .commandOptionJ: (UInt32(kVK_ANSI_J), UInt32(cmdKey | optionKey))
        }
    }

    fileprivate func handle(kind: UInt32) {
        if kind == UInt32(kEventHotKeyPressed) {
            onPress?()
        } else if kind == UInt32(kEventHotKeyReleased) {
            onRelease?()
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()
        _ = InstallEventHandler(GetApplicationEventTarget(), pushToTalkEventHandler, eventTypes.count, &eventTypes, context, &handlerRef)
    }
}

/// C-обработчик событий Carbon. События горячих клавиш приходят в главном потоке.
private func pushToTalkEventHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    let kind = GetEventKind(event)
    let hotKey = Unmanaged<PushToTalkHotKey>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        hotKey.handle(kind: kind)
    }
    return noErr
}

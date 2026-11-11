import Foundation
import AudioToolbox
import CoreAudio
import JarvisCore
import JarvisTools

/// Громкость устройства вывода по умолчанию через CoreAudio. Разрешений macOS не требует.
/// Некоторые устройства (HDMI, часть USB-карт) громкость менять не дают — тогда
/// бросается `ToolFailure.unsupported`.
enum SystemVolume {
    /// Громкость 0…1.
    static func volume() throws -> Float {
        let device = try defaultOutputDevice()
        var address = outputAddress(AudioObjectPropertySelector(kAudioHardwareServiceDeviceProperty_VirtualMainVolume))
        guard AudioObjectHasProperty(device, &address) else { throw ToolFailure.unsupported }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            throw ToolFailure.unsupported
        }
        return value
    }

    static func setVolume(_ value: Float) throws {
        let device = try defaultOutputDevice()
        var address = outputAddress(AudioObjectPropertySelector(kAudioHardwareServiceDeviceProperty_VirtualMainVolume))
        try requireSettable(device, &address)
        var newValue = Float32(min(max(value, 0), 1))
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &newValue)
        guard status == noErr else { throw ToolFailure.unsupported }
    }

    static func isMuted() throws -> Bool {
        let device = try defaultOutputDevice()
        var address = outputAddress(AudioObjectPropertySelector(kAudioDevicePropertyMute))
        guard AudioObjectHasProperty(device, &address) else { throw ToolFailure.unsupported }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            throw ToolFailure.unsupported
        }
        return value != 0
    }

    static func setMuted(_ muted: Bool) throws {
        let device = try defaultOutputDevice()
        var address = outputAddress(AudioObjectPropertySelector(kAudioDevicePropertyMute))
        try requireSettable(device, &address)
        var value = UInt32(muted ? 1 : 0)
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        guard status == noErr else { throw ToolFailure.unsupported }
    }

    /// Снять «без звука», если громкость прибавляют (иначе «громче» ничего не изменит).
    static func unmuteIfNeeded() {
        if (try? isMuted()) == true { try? setMuted(false) }
    }

    private static func defaultOutputDevice() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioHardwarePropertyDefaultOutputDevice),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != 0 else { throw ToolFailure.unsupported }
        return device
    }

    private static func outputAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: AudioObjectPropertyScope(kAudioDevicePropertyScopeOutput),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
    }

    private static func requireSettable(_ device: AudioDeviceID, _ address: inout AudioObjectPropertyAddress) throws {
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue else {
            throw ToolFailure.unsupported
        }
    }

    /// «40 %» по-русски, «40%» по-английски.
    static func format(_ percent: Int, locale: Locale) -> String {
        locale.language.languageCode?.identifier == "en" ? "\(percent)%" : "\(percent) %"
    }
}

/// «Громкость 40». Категория 1.
struct SetVolumeTool: Tool {
    var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: StandardTools.setVolume,
            summary: "Установить громкость звука (0–100).",
            parameters: [ParameterSpec(name: "level", summary: "Громкость в процентах", type: .integer(0...100))],
            risk: .safe,
            effect: .local
        )
    }

    func run(_ arguments: ValidatedArguments, context: ToolContext) async throws -> ToolOutcome {
        let level = arguments.integer("level") ?? 0
        try SystemVolume.setVolume(Float(level) / 100)
        if level > 0 { SystemVolume.unmuteIfNeeded() }
        return ToolOutcome(message: SystemVolume.format(level, locale: context.locale))
    }
}

/// «Громче», «тише». Категория 1.
struct ChangeVolumeTool: Tool {
    var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: StandardTools.changeVolume,
            summary: "Сделать громче или тише на заданное число процентов.",
            parameters: [ParameterSpec(name: "delta", summary: "Изменение в процентах", type: .integer(-100...100))],
            risk: .safe,
            effect: .local
        )
    }

    func run(_ arguments: ValidatedArguments, context: ToolContext) async throws -> ToolOutcome {
        let delta = arguments.integer("delta") ?? 0
        let current = Int((try SystemVolume.volume() * 100).rounded())
        let level = min(max(current + delta, 0), 100)
        try SystemVolume.setVolume(Float(level) / 100)
        if delta > 0 { SystemVolume.unmuteIfNeeded() }
        return ToolOutcome(message: SystemVolume.format(level, locale: context.locale))
    }
}

/// «Выключи звук», «включи звук». Категория 1.
struct SetMutedTool: Tool {
    var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: StandardTools.setMuted,
            summary: "Выключить или включить звук.",
            parameters: [ParameterSpec(name: "muted", summary: "Без звука", type: .boolean)],
            risk: .safe,
            effect: .local
        )
    }

    func run(_ arguments: ValidatedArguments, context: ToolContext) async throws -> ToolOutcome {
        try SystemVolume.setMuted(arguments.boolean("muted") ?? true)
        return ToolOutcome(message: "")
    }
}

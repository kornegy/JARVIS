import AVFoundation
import Speech
import JarvisAssistant

/// Разрешение на микрофон (системный запрос macOS).
@MainActor
public final class MicrophonePermission: PermissionAccess {
    public init() {}

    public var state: PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    public func request() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}

/// Разрешение macOS на распознавание речи.
///
/// Запрашивается **только** если распознавание без него не работает (кнопка в интерфейсе).
/// Само распознавание всё равно идёт через SpeechAnalyzer на устройстве.
@MainActor
public final class SpeechRecognitionPermission: PermissionAccess {
    public init() {}

    public var state: PermissionState {
        SpeechRecognitionAuthorization.state
    }

    public func request() async -> Bool {
        await SpeechRecognitionAuthorization.request()
    }
}

/// Статус разрешения на распознавание речи. Устаревший класс распознавателя здесь
/// используется только для чтения и запроса разрешения — не для распознавания.
enum SpeechRecognitionAuthorization {
    static var state: PermissionState {
        switch SFSpeechRecognizer.authorizationStatus() { // privacy-lint:allow speech-server — только статус разрешения, распознавание идёт через SpeechAnalyzer
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    static var isAuthorized: Bool { state == .granted }

    static func request() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in // privacy-lint:allow speech-server — только запрос разрешения
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}

import AVFoundation
import JarvisAssistant

/// Конвертирует буферы с микрофона (обычно 48 кГц float) в формат, который ждёт анализатор речи.
///
/// Используется только из одного потока — аудиопотока захвата.
final class AudioBufferConverter {
    let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        let inputFormat = buffer.format
        if inputFormat == outputFormat { return buffer }

        if converter == nil || converter?.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            // Без «прайминга», чтобы не сдвигать время относительно источника.
            converter?.primeMethod = .none
            // Качество пересчёта частоты не меняем: свойство поддерживается не для всех пар
            // форматов, а ошибка в нём завершает приложение (исключение Objective-C).
        }
        guard let converter else { throw SpeechEngineError.audioEngineFailed }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw SpeechEngineError.audioEngineFailed
        }

        let source = OneShotBuffer(buffer)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if let next = source.take() {
                inputStatus.pointee = .haveData
                return next
            }
            inputStatus.pointee = .noDataNow
            return nil
        }
        if status == .error { throw SpeechEngineError.audioEngineFailed }
        return output.frameLength > 0 ? output : nil
    }
}

/// Отдаёт буфер ровно один раз (для блока ввода `AVAudioConverter`).
private final class OneShotBuffer: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

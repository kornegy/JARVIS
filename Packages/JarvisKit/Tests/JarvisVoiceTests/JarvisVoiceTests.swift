import AVFoundation
import Testing
import JarvisAssistant
import JarvisSettings
@testable import JarvisVoice

@Suite("Голосовые компоненты macOS")
struct JarvisVoiceTests {
    @Test("Конвертер: 48 кГц float → 16 кГц Int16, примерно втрое меньше кадров")
    func converterResamples() throws {
        let inputFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let outputFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4_800))
        input.frameLength = 4_800
        let samples = try #require(input.floatChannelData?[0])
        for index in 0..<4_800 {
            samples[index] = sinf(Float(index) * 2 * .pi * 440 / 48_000) * 0.5
        }

        let converter = AudioBufferConverter(outputFormat: outputFormat)
        let output = try #require(try converter.convert(input))

        #expect(output.format == outputFormat)
        #expect(output.frameLength > 0)
        #expect(output.frameLength <= 1_601)
    }

    @Test("Конвертер не трогает буфер, если формат уже подходит")
    func converterPassThrough() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160
        let converter = AudioBufferConverter(outputFormat: format)
        #expect(try converter.convert(buffer) === buffer)
    }

    @Test("Скорость речи: 0,5 — обычная, края ограничены")
    func speechRate() {
        #expect(SystemSpeechSynthesizer.rate(for: 0.5) == 0.5)
        #expect(SystemSpeechSynthesizer.rate(for: -1) == 0.35)
        #expect(SystemSpeechSynthesizer.rate(for: 5) == 0.65)
    }

    @Test("Чувствительность → уровень детектора речи")
    func sensitivityLevels() {
        #expect(RecognitionSession.sensitivityLevel(for: 0) == .low)
        #expect(RecognitionSession.sensitivityLevel(for: 0.5) == .medium)
        #expect(RecognitionSession.sensitivityLevel(for: 1) == .high)
    }

    @Test("У каждого сочетания Push-to-Talk есть клавиша и модификаторы")
    @MainActor
    func hotKeyCombinations() {
        for shortcut in PushToTalkShortcut.allCases {
            let keys = PushToTalkHotKey.keyCombination(for: shortcut)
            #expect(keys.modifiers != 0)
        }
        #expect(PushToTalkHotKey.keyCombination(for: .controlOptionSpace).keyCode == 49) // пробел
    }

    @Test("У каждого звукового сигнала есть системный звук")
    @MainActor
    func soundNames() {
        for cue in [SoundCue.listening, .done, .cancelled, .failure] {
            #expect(!SystemFeedbackSounds.soundName(for: cue).isEmpty)
        }
    }
}

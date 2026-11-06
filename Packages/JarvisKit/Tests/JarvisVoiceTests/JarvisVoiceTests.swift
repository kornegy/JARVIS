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
    @MainActor
    func speechRate() {
        #expect(SystemSpeechSynthesizer.rate(for: 0.5) == 0.5)
        #expect(SystemSpeechSynthesizer.rate(for: -1) == 0.35)
        #expect(SystemSpeechSynthesizer.rate(for: 5) == 0.65)
    }

    @Test("Высокая чувствительность → «мягкий» детектор речи, который слышит тихую речь")
    func sensitivityLevels() {
        #expect(RecognitionSession.sensitivityLevel(for: 0) == .high)
        #expect(RecognitionSession.sensitivityLevel(for: 0.5) == .medium)
        #expect(RecognitionSession.sensitivityLevel(for: 1) == .low)
    }

    @Test("Порог ворот: чем выше чувствительность, тем тише звук проходит")
    func gateThreshold() {
        #expect(AudioLevel.threshold(forSensitivity: 0) == -40)
        #expect(AudioLevel.threshold(forSensitivity: 0.5) == -50)
        #expect(AudioLevel.threshold(forSensitivity: 1) == -60)
        #expect(AudioLevel.threshold(forSensitivity: 7) == -60)
    }

    @Test("Уровень сигнала: синус с амплитудой 0,5 ≈ −9 dBFS, тишина — очень низкий")
    func audioLevel() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let loud = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        loud.frameLength = 1_600
        let samples = try #require(loud.floatChannelData?[0])
        for index in 0..<1_600 {
            samples[index] = sinf(Float(index) * 2 * .pi * 440 / 16_000) * 0.5
        }
        let level = try #require(AudioLevel.decibels(of: loud))
        #expect(abs(level - (-9.03)) < 0.5)

        let silent = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        silent.frameLength = 1_600
        let silentLevel = try #require(AudioLevel.decibels(of: silent))
        #expect(silentLevel < -100)
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

@Suite("Ворота тишины перед распознаванием")
struct SpeechGateTests {
    private func makeGate() -> SpeechGate<Int> {
        SpeechGate(thresholdDecibels: -50, hangoverFrames: 300, preRollChunks: 2)
    }

    @Test("Тишина не доходит до распознавания")
    func silenceIsDropped() {
        var gate = makeGate()
        for index in 0..<10 {
            #expect(gate.process(index, startFrame: Int64(index * 100), frameCount: 100, level: -70).isEmpty)
        }
    }

    @Test("Речь открывает ворота и приносит с собой немного звука «до»")
    func speechOpensWithPreRoll() {
        var gate = makeGate()
        _ = gate.process(0, startFrame: 0, frameCount: 100, level: -70)
        _ = gate.process(1, startFrame: 100, frameCount: 100, level: -70)
        _ = gate.process(2, startFrame: 200, frameCount: 100, level: -70)
        let chunks = gate.process(3, startFrame: 300, frameCount: 100, level: -30)
        #expect(chunks.map(\.buffer) == [1, 2, 3]) // два фрагмента «до» + текущий
        #expect(chunks.map(\.startFrame) == [100, 200, 300])
    }

    @Test("После речи ворота открыты ещё немного, затем закрываются")
    func hangover() {
        var gate = makeGate()
        _ = gate.process(0, startFrame: 0, frameCount: 100, level: -30) // открыто до кадра 400
        #expect(gate.process(1, startFrame: 100, frameCount: 100, level: -70).map(\.buffer) == [1])
        #expect(gate.process(2, startFrame: 300, frameCount: 100, level: -70).map(\.buffer) == [2])
        #expect(gate.isOpen)
        #expect(gate.process(3, startFrame: 400, frameCount: 100, level: -70).isEmpty)
        #expect(!gate.isOpen) // момент закрытия — сигнал выдать окончательный текст
    }
}

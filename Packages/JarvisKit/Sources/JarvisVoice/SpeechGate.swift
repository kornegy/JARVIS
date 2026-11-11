import Accelerate
import AVFoundation

/// Отсекает тишину **до** распознавания речи в режиме постоянного прослушивания.
///
/// Распознавание — самая дорогая часть. Пока вокруг тихо, звук до анализатора не доходит,
/// поэтому процессор почти не нагружается. Как только уровень сигнала поднимается выше
/// порога, «ворота» открываются: сначала отдаются ~0,5 с звука *до* этого момента
/// (чтобы не потерять начало слова), затем всё подряд — и ещё 1,5 с после того, как
/// стало тихо (паузы между словами не режутся).
///
/// Порог подстраивается под микрофон: ворота следят за уровнем фонового шума и, если микрофон
/// тихий (AirPods в режиме гарнитуры, шумоподавление), открываются уже на 10 дБ выше шума.
/// Строже настройки «Чувствительность» порог не становится никогда.
///
/// Чистая логика: тип буфера — параметр, поэтому ворота тестируются без звука.
struct SpeechGate<Buffer> {
    struct Chunk {
        let buffer: Buffer
        /// Позиция начала фрагмента в кадрах (для временных меток анализатора).
        let startFrame: Int64
    }

    let thresholdDecibels: Float
    let hangoverFrames: Int64
    let preRollChunks: Int

    /// На сколько выше фонового шума должна быть речь.
    static var noiseMargin: Float { 10 }
    /// Ниже этого шум не считаем: иначе почти цифровая тишина открывала бы ворота на любой шорох.
    static var lowestNoiseFloor: Float { -75 }
    /// Как быстро оценка шума поднимается (за фрагмент); опускается — сразу.
    static var noiseFloorRise: Float { 0.1 }

    /// Пропускаются ли сейчас фрагменты (по последнему обработанному).
    private(set) var isOpen = false
    /// Оценка фонового шума, dBFS.
    private(set) var noiseFloor: Float

    /// Порог с учётом шума: не строже настройки, но ниже для тихого микрофона.
    var effectiveThreshold: Float {
        min(thresholdDecibels, noiseFloor + Self.noiseMargin)
    }

    private var openUntilFrame = Int64.min
    private var preRoll: [Chunk] = []

    init(thresholdDecibels: Float, hangoverFrames: Int64, preRollChunks: Int) {
        self.thresholdDecibels = thresholdDecibels
        self.hangoverFrames = hangoverFrames
        self.preRollChunks = max(0, preRollChunks)
        self.noiseFloor = thresholdDecibels - Self.noiseMargin
    }

    /// Фрагменты, которые нужно отдать анализатору (может быть пусто).
    mutating func process(_ buffer: Buffer, startFrame: Int64, frameCount: Int64, level: Float) -> [Chunk] {
        let chunk = Chunk(buffer: buffer, startFrame: startFrame)
        // Оценка шума: опускается сразу до тишины, поднимается медленно (речь её не «утянет»).
        noiseFloor = level < noiseFloor ? max(level, Self.lowestNoiseFloor) : noiseFloor + Self.noiseFloorRise
        if level >= effectiveThreshold {
            openUntilFrame = startFrame + frameCount + hangoverFrames
        }
        isOpen = startFrame < openUntilFrame
        guard isOpen else {
            preRoll.append(chunk)
            if preRoll.count > preRollChunks {
                preRoll.removeFirst(preRoll.count - preRollChunks)
            }
            return []
        }
        let output = preRoll + [chunk]
        preRoll.removeAll(keepingCapacity: true)
        return output
    }
}

/// Индикатор уровня: пиковое значение за ~¼ секунды, округлённое до 5 дБ. Событие —
/// только когда значение изменилось, поэтому в тишине интерфейс не перерисовывается.
struct LevelMeter {
    static let window: Double = 0.25
    static let step: Float = 5

    private var peak: Float = -.infinity
    private var seconds: Double = 0
    private var lastReported: Float?

    /// Новый уровень для индикатора или `nil`, если показывать нечего.
    mutating func update(_ decibels: Float, frames: Int, sampleRate: Double) -> Float? {
        peak = max(peak, decibels)
        seconds += sampleRate > 0 ? Double(frames) / sampleRate : Self.window
        guard seconds >= Self.window else { return nil }
        let rounded = max((peak / Self.step).rounded() * Self.step, -120)
        peak = -.infinity
        seconds = 0
        guard rounded != lastReported else { return nil }
        lastReported = rounded
        return rounded
    }
}

/// Автоматическое усиление тихого микрофона (AGC).
///
/// Микрофон AirPods на Mac очень тихий, а поменять его громкость macOS не даёт. Zoom, FaceTime
/// и сама диктовка macOS это компенсируют — JARVIS теперь тоже. Следит за уровнем речи:
/// громкая речь сразу уменьшает усиление (без искажений), тихая — постепенно увеличивает,
/// но не больше чем на 24 дБ. Тишина и шум (ниже −65 dBFS) усиление не меняют.
struct AutomaticGain {
    static let targetLevel: Float = -24
    static let maxGain: Float = 24
    static let speechThreshold: Float = -65
    /// На сколько дБ за фрагмент оценка речи может опуститься (≈ 0,5 дБ за 85 мс).
    static let release: Float = 0.5

    /// Оценка уровня речи, dBFS (до усиления).
    private(set) var speechLevel: Float = -40

    var gainDecibels: Float {
        min(max(Self.targetLevel - speechLevel, 0), Self.maxGain)
    }

    var multiplier: Float {
        pow(10, gainDecibels / 20)
    }

    /// Учесть уровень очередного фрагмента и вернуть множитель громкости.
    mutating func update(level: Float) -> Float {
        if level > speechLevel {
            speechLevel = level
        } else if level > Self.speechThreshold {
            speechLevel = max(speechLevel - Self.release, level)
        }
        return multiplier
    }
}

/// Уровень сигнала и порог для ворот.
enum AudioLevel {
    /// Уровень первого канала в dBFS (0 — максимум, −60 — очень тихо);
    /// `nil` для форматов без float-данных.
    static func decibels(of buffer: AVAudioPCMBuffer) -> Float? {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return nil }
        var rms: Float = 0
        vDSP_rmsqv(channel, 1, &rms, vDSP_Length(buffer.frameLength))
        return 20 * log10(max(rms, 1e-9))
    }

    /// Самый громкий отсчёт после усиления не превышает этого значения (1 — предел формата).
    static let ceiling: Float = 0.9

    /// Копия буфера, усиленная не больше чем в `gain` раз. Усиление ограничено самым громким
    /// отсчётом буфера, поэтому звук не искажается. `nil` — усиливать нечего или нельзя
    /// (формат без float-данных, сигнал уже громкий).
    static func amplified(_ buffer: AVAudioPCMBuffer, by gain: Float) -> AVAudioPCMBuffer? {
        guard let source = buffer.floatChannelData, buffer.frameLength > 0 else { return nil }
        let channels = Int(buffer.format.channelCount)
        let interleaved = buffer.format.isInterleaved
        let planes = interleaved ? 1 : channels
        let count = vDSP_Length(Int(buffer.frameLength) * (interleaved ? channels : 1))

        var peak: Float = 0
        for plane in 0..<planes {
            var planePeak: Float = 0
            vDSP_maxmgv(source[plane], 1, &planePeak, count)
            peak = max(peak, planePeak)
        }
        var multiplier = peak > 0 ? min(gain, ceiling / peak) : gain
        guard multiplier > 1.01,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let destination = copy.floatChannelData else { return nil }
        copy.frameLength = buffer.frameLength
        for plane in 0..<planes {
            vDSP_vsmul(source[plane], 1, &multiplier, destination[plane], 1, count)
        }
        return copy
    }

    /// Порог ворот по чувствительности 0…1: 0 → −40 dBFS, 0,5 → −50, 1 → −60 (слышит очень тихую речь).
    static func threshold(forSensitivity sensitivity: Double) -> Float {
        let clamped = Float(min(max(sensitivity, 0), 1))
        return -40 - 20 * clamped
    }
}

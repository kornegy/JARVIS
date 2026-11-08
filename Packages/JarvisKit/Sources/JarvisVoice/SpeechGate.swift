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

    /// Порог ворот по чувствительности 0…1: 0 → −40 dBFS, 0,5 → −50, 1 → −60 (слышит очень тихую речь).
    static func threshold(forSensitivity sensitivity: Double) -> Float {
        let clamped = Float(min(max(sensitivity, 0), 1))
        return -40 - 20 * clamped
    }
}

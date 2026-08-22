import AVFoundation
import Foundation

final class SoundService {
    enum SoundKind: CaseIterable {
        case whoosh
        case tick
        case success
        case failure
    }

    private var players: [SoundKind: AVAudioPlayer] = [:]

    func prepare() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let prepared = Dictionary(uniqueKeysWithValues: SoundKind.allCases.compactMap { kind in
                Self.generateSound(for: kind).map { (kind, $0) }
            }.map { kind, data in
                (kind, try? AVAudioPlayer(data: data, fileTypeHint: "wav"))
            }.compactMap { kind, player in
                player.map { (kind, $0) }
            })

            Task { @MainActor [weak self] in
                self?.players = prepared
            }
        }
    }

    func play(_ kind: SoundKind) {
        let player: AVAudioPlayer

        if let existing = players[kind] {
            existing.currentTime = 0
            player = existing
        } else {
            guard let data = Self.generateSound(for: kind),
                  let created = try? AVAudioPlayer(data: data, fileTypeHint: "wav") else { return }
            created.prepareToPlay()
            players[kind] = created
            player = created
        }

        if kind != .tick {
            players[.whoosh]?.stop()
        }

        player.volume = volume(for: kind)
        player.play()
    }

    private func volume(for kind: SoundKind) -> Float {
        switch kind {
        case .tick: 0.08
        case .whoosh: 0.18
        case .success: 0.16
        case .failure: 0.14
        }
    }

    private static func generateSound(for kind: SoundKind) -> Data? {
        let sampleRate = 44100.0
        let duration = duration(for: kind)
        let count = Int(sampleRate * duration)
        var samples = [Float](repeating: 0, count: count)

        for index in 0..<count {
            let time = Double(index) / sampleRate
            let progress = time / duration
            let envelope = sin(.pi * progress)
            let sample: Double

            switch kind {
            case .whoosh:
                let frequency = 520.0 + 680.0 * progress
                let tone = sin(2.0 * .pi * frequency * time)
                let noise = Double.random(in: -1...1) * 0.22
                sample = (tone + noise) * envelope * 0.055
            case .tick:
                let attack = min(time / 0.002, 1.0)
                let decay = exp(-time * 130.0)
                sample = sin(2.0 * .pi * 1750.0 * time) * attack * decay * 0.10
            case .success:
                let frequency = time < 0.11 ? 784.0 : 1047.0
                let wave = sin(2.0 * .pi * frequency * time)
                sample = wave * envelope * 0.075
            case .failure:
                let frequency = 260.0 - 70.0 * progress
                let wave = sin(2.0 * .pi * frequency * time)
                sample = wave * envelope * 0.065
            }

            samples[index] = Float(sample)
        }

        return wavData(from: samples, sampleRate: sampleRate)
    }

    private static func duration(for kind: SoundKind) -> Double {
        switch kind {
        case .whoosh: 0.22
        case .tick: 0.035
        case .success: 0.24
        case .failure: 0.20
        }
    }

    private static func wavData(from samples: [Float], sampleRate: Double) -> Data {
        var data = Data()
        let dataSize = UInt32(samples.count * MemoryLayout<Float>.size)

        data.append(contentsOf: Array("RIFF".utf8))
        appendUInt32(&data, 36 + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendUInt32(&data, 16)
        appendUInt16(&data, 3)
        appendUInt16(&data, 1)
        appendUInt32(&data, UInt32(sampleRate))
        appendUInt32(&data, UInt32(sampleRate * 4))
        appendUInt16(&data, 4)
        appendUInt16(&data, 32)
        data.append(contentsOf: Array("data".utf8))
        appendUInt32(&data, dataSize)

        for sample in samples {
            withUnsafeBytes(of: sample.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }

        return data
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}

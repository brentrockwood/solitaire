import AppKit

/// Tiny procedurally generated sounds, so no audio assets are needed.
@MainActor
final class Sounds {
    static let shared = Sounds()
    var enabled = true

    private lazy var place = Sounds.makeSound(duration: 0.06, noise: 0.5, tone: 180, decay: 60)
    private lazy var flip = Sounds.makeSound(duration: 0.09, noise: 0.9, tone: 0, decay: 35)
    private lazy var deal = Sounds.makeSound(duration: 0.05, noise: 0.7, tone: 320, decay: 80)
    private lazy var win = Sounds.makeSound(duration: 0.5, noise: 0.0, tone: 523, decay: 4, chord: true)

    enum Kind { case place, flip, deal, win }

    func play(_ kind: Kind) {
        guard enabled else { return }
        let s: NSSound
        switch kind {
        case .place: s = place
        case .flip: s = flip
        case .deal: s = deal
        case .win: s = win
        }
        s.stop()
        s.play()
    }

    private static func makeSound(duration: Double, noise: Double, tone: Double, decay: Double, chord: Bool = false) -> NSSound {
        let rate = 44100.0
        let n = Int(duration * rate)
        var samples = [Int16](repeating: 0, count: n)
        var rng = SystemRandomNumberGenerator()
        for i in 0..<n {
            let t = Double(i) / rate
            let env = exp(-decay * t)
            var v = 0.0
            if noise > 0 { v += noise * Double.random(in: -1...1, using: &rng) }
            if tone > 0 {
                v += 0.6 * sin(2 * .pi * tone * t)
                if chord {
                    v += 0.5 * sin(2 * .pi * tone * 1.25 * t) + 0.4 * sin(2 * .pi * tone * 1.5 * t)
                    v *= 0.5
                }
            }
            samples[i] = Int16(max(-1, min(1, v * env)) * 12000)
        }
        var data = Data()
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(n * 2)
        data.append(contentsOf: "RIFF".utf8); put32(36 + byteCount); data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8); put32(16); put16(1); put16(1); put32(UInt32(rate)); put32(UInt32(rate) * 2); put16(2); put16(16)
        data.append(contentsOf: "data".utf8); put32(byteCount)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return NSSound(data: data)!
    }
}

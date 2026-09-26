import AppKit
import AVFoundation

/// Sliced sprite frames for one pet definition, shared by every window showing that pet.
final class SpriteSheet {
    let frames: [CGImage]
    /// Unscaled frame size in points.
    let frameWidth: Int
    let frameHeight: Int
    let icon: NSImage?

    init(pet: PetDefinition) throws {
        guard let source = NSImage(data: pet.pngData),
              let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw PetXMLError.missing("image/png (undecodable)")
        }
        let w = cg.width / pet.tilesX
        let h = cg.height / pet.tilesY
        frameWidth = w
        frameHeight = h
        var list: [CGImage] = []
        list.reserveCapacity(pet.tilesX * pet.tilesY)
        for row in 0..<pet.tilesY {
            for col in 0..<pet.tilesX {
                let rect = CGRect(x: col * w, y: row * h, width: w, height: h)
                if let f = cg.cropping(to: rect) { list.append(f) }
            }
        }
        frames = list
        if let d = pet.iconData, let img = NSImage(data: d) {
            icon = img
        } else {
            icon = nil
        }
    }

    func frame(_ index: Int) -> CGImage? {
        guard !frames.isEmpty else { return nil }
        return frames[min(max(index, 0), frames.count - 1)]
    }
}

/// Plays the base64 MP3 sounds attached to animations (replaces NAudio).
final class SoundPlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = SoundPlayer()
    var volume: Float = 0.5
    var enabled = true
    private var players: [ObjectIdentifier: AVAudioPlayer] = [:]

    func play(_ sound: PetSound) {
        guard enabled, volume > 0 else { return }
        do {
            let p = try AVAudioPlayer(data: sound.data)
            p.volume = volume
            p.numberOfLoops = max(0, sound.loop)
            p.delegate = self
            players[ObjectIdentifier(p)] = p
            p.play()
        } catch {
            NSLog("DesktopPet: cannot play sound: \(error)")
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        players.removeValue(forKey: ObjectIdentifier(player))
    }
}

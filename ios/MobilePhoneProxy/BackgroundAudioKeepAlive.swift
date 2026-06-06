import Foundation
import AVFoundation

/// Keeps the app alive in the background by playing a silent audio loop.
///
/// iOS has no foreground-service equivalent (unlike Android), so a plain-app
/// `NWListener` is suspended shortly after the app is backgrounded. Declaring
/// the `audio` background mode and continuously playing audio keeps the process
/// running with the screen locked. The audio is true silence (zero PCM samples)
/// and uses `.mixWithOthers`, so it doesn't interrupt the user's music/video.
///
/// Caveats: this is not App-Store-eligible (fine for sideloaded/personal use),
/// costs battery, and an audio interruption (incoming call, Siri) can pause it —
/// we re-activate on `.interruption .ended` and on media-services reset, but it
/// is still less bulletproof than an Android foreground service.
final class BackgroundAudioKeepAlive {

    var onLog: ((String) -> Void)?
    private(set) var isActive = false
    private var player: AVAudioPlayer?
    private var tokens: [NSObjectProtocol] = []

    func start() {
        guard !isActive else { return }
        do {
            try activateAndPlay()
            registerObservers()
            isActive = true
            onLog?("🔊 background keepalive ON (silent audio)")
        } catch {
            onLog?("keepalive start failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard isActive else { return }
        player?.stop()
        player = nil
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
        tokens.removeAll()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        isActive = false
        onLog?("🔇 background keepalive OFF")
    }

    private func activateAndPlay() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, options: [.mixWithOthers])
        try session.setActive(true)
        if player == nil {
            let player = try AVAudioPlayer(data: Self.silentWAV)
            player.numberOfLoops = -1            // loop forever
            player.prepareToPlay()
            self.player = player
        }
        player?.play()
    }

    private func registerObservers() {
        let nc = NotificationCenter.default
        // Resume after an interruption ends (e.g. phone call, Siri).
        tokens.append(nc.addObserver(forName: AVAudioSession.interruptionNotification,
                                     object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            try? self.activateAndPlay()
            self.onLog?("keepalive: resumed after interruption")
        })
        // Rebuild after the audio server is reset.
        tokens.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                     object: nil, queue: .main) { [weak self] _ in
            self?.player = nil
            try? self?.activateAndPlay()
            self?.onLog?("keepalive: media services reset, rebuilt")
        })
    }

    /// A short mono 16-bit PCM WAV of pure silence, synthesized in code so we
    /// don't ship an audio resource. Looped infinitely by the player.
    private static let silentWAV: Data = {
        let sampleRate = 8000, channels = 1, bits = 16
        let frames = sampleRate / 2                       // 0.5 s
        let dataBytes = frames * channels * bits / 8
        let byteRate = sampleRate * channels * bits / 8
        let blockAlign = channels * bits / 8

        func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }

        var d = Data()
        d.append("RIFF".data(using: .ascii)!)
        d.append(le32(36 + dataBytes))
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!)
        d.append(le32(16))                                // fmt chunk size
        d.append(le16(1))                                 // PCM
        d.append(le16(channels))
        d.append(le32(sampleRate))
        d.append(le32(byteRate))
        d.append(le16(blockAlign))
        d.append(le16(bits))
        d.append("data".data(using: .ascii)!)
        d.append(le32(dataBytes))
        d.append(Data(count: dataBytes))                  // zeros == silence
        return d
    }()
}

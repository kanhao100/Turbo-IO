import Foundation
import Combine
import AVFAudio

@MainActor final class SubtitleAudioPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playing = false
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var segmentIndex = 0
    @Published var error: String?
    private var files: [SubtitleAudioFile] = []
    private var player: AVAudioPlayer?
    private var timer: Timer?
    func configure(_ files: [SubtitleAudioFile]) {
        stop(); self.files = files; duration = files.reduce(0) { $0 + $1.duration }
    }
    func toggle() {
        if playing { player?.pause(); playing = false; timer?.invalidate(); timer = nil; return }
        do {
            if player == nil { try openSegment(segmentIndex) }
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            guard player?.play() == true else { return }
            playing = true; error = nil
            timer?.invalidate()
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in Task { @MainActor in self?.updatePosition() } }
            self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        } catch { self.error = "无法播放此音频片段。"; stop() }
    }
    func seek(_ seconds: TimeInterval) {
        guard !files.isEmpty else { return }
        let resume = playing
        player?.stop(); playing = false
        var remaining = min(max(0, seconds), max(0, duration - 0.01)), index = 0
        while index < files.count - 1 && remaining >= files[index].duration { remaining -= files[index].duration; index += 1 }
        do { try openSegment(index); player?.currentTime = remaining; updatePosition(); if resume { toggle() } }
        catch { error = "无法定位此音频片段。" }
    }
    func stop() {
        let hadPlayer = player != nil
        timer?.invalidate(); timer = nil; player?.stop(); player = nil
        playing = false; position = 0; segmentIndex = 0
        if hadPlayer { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
    private func openSegment(_ index: Int) throws {
        guard files.indices.contains(index) else { return }
        let player = try AVAudioPlayer(contentsOf: files[index].url)
        player.delegate = self; player.prepareToPlay(); self.player = player; segmentIndex = index
    }
    private func updatePosition() {
        position = files.prefix(segmentIndex).reduce(0) { $0 + $1.duration } + (player?.currentTime ?? 0)
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.playing = false
            if flag && self.segmentIndex + 1 < self.files.count {
                do { try self.openSegment(self.segmentIndex + 1); self.toggle() }
                catch { self.error = "后续音频片段不可播放。"; self.stop() }
            } else { self.stop() }
        }
    }
    deinit { timer?.invalidate() }
}

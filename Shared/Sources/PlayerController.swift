import AVFoundation
import Foundation
import Observation
import SwiftData

/// Owns the AVPlayer for the selected item: resume, save position, mark watched at the end.
@MainActor @Observable
final class PlayerController {
    let player = AVPlayer()
    private(set) var time: Double = 0
    private(set) var isPlaying = false
    @ObservationIgnored private var item: Item?
    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var rateObserver: NSKeyValueObservation?
    @ObservationIgnored private var lastSaved: Double = 0

    func load(_ item: Item, file: URL, context: ModelContext) {
        guard self.item?.id != item.id else { return }
        unload()
        self.item = item
        self.context = context
        let playerItem = AVPlayerItem(url: file)
        player.replaceCurrentItem(with: playerItem)
        // Resume, unless it was nearly finished.
        if item.position > 5, item.durationSeconds == 0 || item.position < item.durationSeconds - 10 {
            player.seek(to: CMTime(seconds: item.position, preferredTimescale: 600))
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finished() }
        }
        rateObserver = player.observe(\.rate) { [weak self] p, _ in
            let playing = p.rate != 0
            Task { @MainActor in self?.isPlaying = playing }
        }
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        time = seconds
        if player.rate == 0 { player.play() }
    }

    func unload() {
        if let item, time > 0, !item.state.isFinished { item.position = time }
        try? context?.save()
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        rateObserver = nil
        timeObserver = nil
        endObserver = nil
        item = nil
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        time = seconds
        guard let item, abs(seconds - lastSaved) >= 5 else { return }
        lastSaved = seconds
        item.position = seconds
        if item.state == .queued, seconds > 0 { item.state = .inProgress }
    }

    private func finished() {
        guard let item, let context else { return }
        item.position = 0
        Library.finish(item, context: context)
    }
}

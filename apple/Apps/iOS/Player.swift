import AVFoundation
import Observation

/// Plays one recording as a single timeline: its segments laid end to end
/// at their offsets in a composition, so seeking is just a time. Segments
/// come from the phone's own copy when it still has it, else the server.
@MainActor @Observable
final class RecordingPlayer {
    enum Availability: Equatable {
        case loading
        case ready
        /// Audio is past the retention window, or never arrived.
        case unavailable(String)
    }

    private(set) var availability = Availability.loading
    private(set) var isPlaying = false
    private(set) var time: Double = 0
    private(set) var duration: Double = 0
    /// Where the finger is on the waveform, until it lets go.
    private(set) var scrubTime: Double?
    private(set) var rate: Float = 1
    /// Peak level per bar, 0…1, for the waveform.
    private(set) var levels: [Float] = []

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var loadedFor: String?
    /// A periodic tick landing mid-seek would flash the old position.
    private var seeking = false

    /// Bars across the pill when the whole recording fits.
    nonisolated static let barCount = 56
    /// Longer recordings get a bar every two seconds and a waveform that
    /// scrolls, so a finger can still land on a sentence.
    nonisolated static let secondsPerBar: Double = 2

    nonisolated static func bars(for duration: Double) -> Int {
        max(barCount, Int((duration / secondsPerBar).rounded(.up)))
    }
    static let rates: [Float] = [1, 1.25, 1.5, 2]

    /// What the screen shows: the finger while scrubbing, else playback.
    var shownTime: Double { scrubTime ?? time }

    func load(_ detail: SessionDetail) async {
        guard loadedFor != detail.id || availability != .ready else { return }
        loadedFor = detail.id
        let segments = detail.segments.filter(\.hasAudio).sorted { $0.index < $1.index }
        let local = detail.segments.filter {
            FileManager.default.fileExists(atPath: Uploader.audioURL(session: detail.id, index: $0.index).path)
        }
        guard !segments.isEmpty || !local.isEmpty else {
            availability = .unavailable(detail.segments.isEmpty ? "No audio yet" : "Audio no longer kept")
            return
        }

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            availability = .unavailable("Can't play this recording")
            return
        }
        var files: [(url: URL, offset: Double)] = []
        for segment in Set(segments.map(\.index)).union(local.map(\.index)).sorted() {
            guard let info = detail.segments.first(where: { $0.index == segment }),
                  let url = try? await API.audio(session: detail.id, index: segment) else { continue }
            let asset = AVURLAsset(url: url)
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                  let length = try? await asset.load(.duration) else { continue }
            let at = CMTime(seconds: info.offset, preferredTimescale: 600)
            try? track.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: source, at: at)
            files.append((url, info.offset))
        }
        guard !files.isEmpty else {
            availability = .unavailable("Audio no longer kept")
            return
        }

        let item = AVPlayerItem(asset: composition)
        item.audioTimePitchAlgorithm = .timeDomain
        let player = AVPlayer(playerItem: item)
        self.player = player
        duration = composition.duration.seconds
        observe(player, item: item)
        availability = .ready

        let total = duration, bars = Self.bars(for: duration)
        levels = await Task.detached(priority: .utility) {
            Self.waveform(files: files, total: total, bars: bars)
        }.value
    }

    func toggle() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try? AVAudioSession.sharedInstance().setActive(true)
            if time >= duration - 0.5 { player.seek(to: .zero) }
            player.play()
        }
        isPlaying.toggle()
    }

    func seek(to seconds: Double, play: Bool = true) {
        guard let player else { return }
        time = min(max(0, seconds), duration)
        seeking = true
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.seeking = false }
        }
        if play && !isPlaying { toggle() }
    }

    /// The position follows the finger; the audio moves on release.
    func scrub(to seconds: Double) {
        scrubTime = min(max(0, seconds), duration)
    }

    func endScrub() {
        guard let scrubTime else { return }
        self.scrubTime = nil
        seek(to: scrubTime, play: isPlaying)
    }

    /// 1× → 1.25× → 1.5× → 2× and round again.
    func cycleRate() {
        let next = Self.rates.firstIndex(of: rate).map { ($0 + 1) % Self.rates.count } ?? 0
        rate = Self.rates[next]
        player?.defaultRate = rate
        if isPlaying { player?.rate = rate }
    }

    func stop() {
        player?.pause()
        isPlaying = false
    }

    private func observe(_ player: AVPlayer, item: AVPlayerItem) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, !self.seeking else { return }
                self.time = t.seconds
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPlaying = false }
        }
    }

    /// Peak per bar across all segment files. Gaps between segments stay at 0.
    nonisolated private static func waveform(files: [(url: URL, offset: Double)], total: Double, bars: Int) -> [Float] {
        guard total > 0 else { return [] }
        var peaks = [Float](repeating: 0, count: bars)
        for (url, offset) in files {
            guard let file = try? AVAudioFile(forReading: url),
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384) else { continue }
            let rate = file.processingFormat.sampleRate
            var frame: AVAudioFramePosition = 0
            while (try? file.read(into: buffer)) != nil, buffer.frameLength > 0 {
                guard let samples = buffer.floatChannelData?[0] else { break }
                // One peak per buffer is plenty for a few dozen bars.
                var peak: Float = 0
                for i in stride(from: 0, to: Int(buffer.frameLength), by: 4) { peak = max(peak, abs(samples[i])) }
                let t = offset + Double(frame) / rate
                let bar = min(bars - 1, Int(t / total * Double(bars)))
                peaks[bar] = max(peaks[bar], peak)
                frame += AVAudioFramePosition(buffer.frameLength)
            }
        }
        // Speech rarely peaks near full scale; normalize so the shape reads.
        let top = max(peaks.max() ?? 0, 0.05)
        return peaks.map { min(1, sqrt($0 / top)) }
    }
}

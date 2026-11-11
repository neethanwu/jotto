import Foundation
import Observation
import Speech

/// Apple's speech models on this iPhone: which languages are installed,
/// and the ones downloading, with how far along. A language starts
/// downloading as soon as it's picked.
@MainActor @Observable
final class SpeechModels {
    static let shared = SpeechModels()

    private(set) var installed: Set<String> = []
    /// Downloading now, 0…1, by locale identifier.
    private(set) var progress: [String: Double] = [:]
    private(set) var failed: Set<String> = []

    private init() {
        Task { await refresh() }
    }

    func refresh() async {
        installed = Set(await SpeechTranscriber.installedLocales.map(\.identifier))
    }

    func isInstalled(_ id: String) -> Bool { installed.contains(id) }

    /// Downloads whichever of these aren't on the phone yet, side by side.
    /// Needs Jotto in front; returns when all have finished or failed.
    func ensure(_ ids: [String]) async {
        await refresh()
        let missing = ids.filter { !installed.contains($0) && progress[$0] == nil }
        guard !missing.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for id in missing {
                group.addTask { await self.download(id) }
            }
        }
        await refresh()
    }

    private func download(_ id: String) async {
        let transcriber = SpeechTranscriber(locale: Locale(identifier: id), preset: .transcription)
        failed.remove(id)
        do {
            // Nil: nothing to download.
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
            progress[id] = 0
            PhoneLog.shared.note("asr_download", id)
            let poll = Task { [weak self] in
                while !Task.isCancelled {
                    self?.progress[id] = request.progress.fractionCompleted
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer { poll.cancel() }
            try await request.downloadAndInstall()
            PhoneLog.shared.note("asr_downloaded", id)
        } catch {
            failed.insert(id)
            PhoneLog.shared.note("asr_download_failed", "\(id) \(error.localizedDescription)")
        }
        progress[id] = nil
    }
}

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

    /// Ready for jotto, language by language: what SpeechAnalyzer itself
    /// says, not `installedLocales`. A model iOS already has for dictation
    /// is listed there as installed, yet jotto can't use it until it asks
    /// for it (which reserves it), so going by that list said "Downloaded"
    /// while recordings waited for the model forever.
    func refresh() async {
        var ready: Set<String> = []
        for id in Set(AppConfig.shared.languages).union(installed) {
            if await Self.status(id) == .installed { ready.insert(id) }
        }
        installed = ready
    }

    private static func status(_ id: String) async -> AssetInventory.Status {
        await AssetInventory.status(forModules: [SpeechTranscriber(locale: Locale(identifier: id), preset: .transcription)])
    }

    func isInstalled(_ id: String) -> Bool { installed.contains(id) }

    /// A language no longer picked gives back its place: iOS lets an app
    /// hold only a few.
    func release(_ id: String) {
        installed.remove(id)
        Task { _ = await AssetInventory.release(reservedLocale: Locale(identifier: id)) }
    }

    /// Asks for whichever of these jotto can't use yet, side by side: a
    /// download, or only claiming one already on the iPhone. Needs jotto
    /// in front; returns when all have finished or failed.
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
            // Nil: nothing to download; asking was enough to claim it.
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
                PhoneLog.shared.note("asr_claimed", id)
                return
            }
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

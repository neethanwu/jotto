import Foundation

/// Where each recording's audio lives on the phone: the watch's segment
/// files, as they arrived, under Documents/Sessions/<id>/000.m4a.
enum AudioFiles {
    nonisolated static let directory = URL.documentsDirectory.appending(path: "Sessions")

    nonisolated static func url(session: String, index: Int) -> URL {
        directory.appending(path: session).appending(path: String(format: "%03d.m4a", index))
    }

    /// Left behind by the beta's test server: its upload queue, request
    /// bodies, downloaded audio and the account token. Gone once.
    @MainActor static func removeServerLeftovers() {
        let key = "removedServerLeftovers"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let fm = FileManager.default
        for url in [URL.documentsDirectory.appending(path: "upload-queue.json"),
                    URL.documentsDirectory.appending(path: "UploadBodies"),
                    URL.cachesDirectory.appending(path: "Audio")] {
            try? fm.removeItem(at: url)
        }
        let token: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.neethanwu.jotto",
            kSecAttrAccount as String: "api-token",
        ]
        SecItemDelete(token as CFDictionary)
        for old in ["serverURL", "processesLocally"] { UserDefaults.standard.removeObject(forKey: old) }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: key)
    }
}

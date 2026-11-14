import BackgroundAssets
import ExtensionFoundation
import StoreKit

/// Lets the system fetch jotto's Apple-hosted asset packs (the Qwen3-ASR
/// speech model) through the App Store, also while jotto isn't running.
/// The system does the work; this only says yes to it.
@main
struct DownloaderExtension: StoreDownloaderExtension {
    func shouldDownload(_ assetPack: AssetPack) -> Bool {
        true
    }
}

import Foundation
import Observation
import StoreKit

/// Which country's App Store this iPhone gets its apps from. From the
/// App Store in China mainland, "Your own API key" offers only services
/// that operate there (Bailian, SiliconFlow, or another at an address you enter),
/// and jotto names no service from elsewhere. Everything on this iPhone
/// works the same there.
@MainActor @Observable
final class StoreRegion {
    static let shared = StoreRegion()

    /// As StoreKit names it ("USA", "CHN"). Kept from the last launch, so
    /// the answer is there at once; nil only until the App Store has said
    /// for the first time, or where there's no App Store account to ask
    /// (the Simulator, some builds from the source).
    private(set) var country: String?

    var isChinaMainland: Bool { country == "CHN" }

    private init() {
        country = UserDefaults.standard.string(forKey: "storeCountry")
        #if DEBUG
        // Launched with `-storeCountry CHN`: jotto as that store has it.
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-storeCountry"),
           i + 1 < ProcessInfo.processInfo.arguments.count {
            country = ProcessInfo.processInfo.arguments[i + 1]
            Task { Cloud.settle() }
            return
        }
        #endif
        // After this init: settling reads `shared`.
        Task {
            Cloud.settle()
            if let now = await Storefront.current { set(now.countryCode) }
            for await next in Storefront.updates { set(next.countryCode) }
        }
    }

    private func set(_ code: String) {
        guard code != country else { return }
        let wasOn = Cloud.isOn
        country = code
        UserDefaults.standard.set(code, forKey: "storeCountry")
        PhoneLog.shared.note("store", code)
        Cloud.settle()
        // Recordings waiting on the service go to this iPhone's models,
        // or the other way round.
        if wasOn != Cloud.isOn { Pipeline.shared.languageChanged() }
    }
}

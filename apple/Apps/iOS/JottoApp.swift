import SwiftUI

@main
struct JottoApp: App {
    var body: some Scene {
        WindowGroup {
            InboxView(inbox: .shared)
        }
    }
}

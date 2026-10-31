import SwiftUI

struct RecorderView: View {
    let recorder: Recorder
    let transfer: WatchTransfer

    var body: some View {
        VStack(spacing: 8) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(elapsed(at: context.date))
                    .font(.system(.title2, design: .rounded).monospacedDigit())
            }

            Button(action: recorder.toggle) {
                Image(systemName: recorder.state == .idle ? "mic.fill" : "stop.fill")
                    .font(.title)
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .tint(Color("BrandOrange"))  // the one action on screen, start or stop

            VStack(alignment: .leading, spacing: 2) {
                Text("state: \(recorder.state.rawValue)")
                Text("segments: \(recorder.segmentsWritten) · pending: \(transfer.pendingCount)")
                Text("last: \(recorder.lastEvent)")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal)
    }

    private func elapsed(at date: Date) -> String {
        guard let start = recorder.startedAt else { return "00:00:00" }
        let seconds = Int(date.timeIntervalSince(start))
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}

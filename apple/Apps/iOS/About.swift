import SwiftUI

/// Where jotto's pages outside the app live: all in its public repository.
enum Links {
    static let source = URL(string: "https://github.com/neethanwu/jotto")!
    static let privacy = URL(string: "https://github.com/neethanwu/jotto/blob/main/PRIVACY.md")!
    static let support = URL(string: "https://github.com/neethanwu/jotto/blob/main/SUPPORT.md")!
}

/// Whose work jotto builds on, with the licence it comes under in full
/// (the Apache License asks for a copy to go with what's distributed).
struct AcknowledgementsView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Credit: Identifiable {
        let name: String
        let detail: String
        var id: String { name }
    }

    private static let credits = [
        Credit(name: "Qwen3-ASR",
               detail: "The speech model you can download in Processing, by the Qwen team at Alibaba Cloud. Apache License 2.0."),
        Credit(name: "Qwen3-ASR Core ML",
               detail: "That model made ready for Core ML, published by aufklarer on Hugging Face. Apache License 2.0."),
        Credit(name: "speech-swift",
               detail: "jotto's code for running the model is adapted from it. Copyright 2025 Ivan Digital. Apache License 2.0."),
    ]

    /// The licence as paragraphs: its fixed-width line breaks and indents
    /// taken out, so it reads in the app's own type.
    private static let apache: [String] = {
        guard let url = Bundle.main.url(forResource: "Apache-2.0", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n\n").compactMap { paragraph in
            let lines = paragraph.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return lines.isEmpty ? nil : lines.joined(separator: " ")
        }
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(
                    title: "Acknowledgements",
                    detail: "jotto is free software under the GNU General Public License, version 3. It builds on the work below."
                ) { dismiss() }

                SettingsGroup {
                    ForEach(Self.credits) { credit in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(credit.name).font(.reading).foregroundStyle(Color.jText)
                            Text(credit.detail)
                                .font(.scaled(13, .regular, relativeTo: .footnote))
                                .foregroundStyle(Color.jText3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, 24)

                if !Self.apache.isEmpty {
                    Text("Apache License 2.0")
                        .font(.scaled(13, .semibold, relativeTo: .footnote))
                        .foregroundStyle(Color.jText2)
                        .padding(.top, 32)
                        .accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(Self.apache.enumerated()), id: \.offset) { _, paragraph in
                            Text(paragraph)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.scaled(12, .regular, relativeTo: .caption1))
                    .foregroundStyle(Color.jText3)
                    .padding(.top, 10)
                    .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 48)
        }
        .statusBarCover()
        .background(Color.jBg)
        .toolbar(.hidden, for: .navigationBar)
    }
}

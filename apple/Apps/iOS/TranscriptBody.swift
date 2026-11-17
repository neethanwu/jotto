import SwiftUI
import UIKit

/// One paragraph as the transcript body draws it.
struct TranscriptParagraph: Equatable {
    let id: Int
    let start: Double
    /// Shown over the paragraph when the speaker changes (your own API key).
    let speaker: String?
    let newSection: Bool
    /// Highlights that start here: chips over the text.
    let chips: [Highlight]
    let text: NSAttributedString
    /// Said somewhere new (Settings → Places): a chip with the place
    /// above the paragraph, which opens it in Maps.
    var place: PlaceMark? = nil

    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.start == b.start && a.speaker == b.speaker && a.newSection == b.newSection
            && a.chips == b.chips && a.text.isEqual(to: b.text) && a.place == b.place
    }
}

/// The whole transcript as one run of text, so a selection can run across
/// paragraphs, with the times in a gutter, a dashed thread between them,
/// and highlight chips over the paragraphs where they start (all laid
/// out from where the text actually falls).
///
/// Tap the gutter: play from that paragraph. Tap the text: the playhead
/// moves there (and plays only if it already was). Select: Copy, Copy
/// with time(s), Highlight (the paragraphs selected become one section),
/// then the system's Look Up, Share and the rest.
struct TranscriptBody: UIViewRepresentable {
    let paragraphs: [TranscriptParagraph]
    /// Bumped by the caller whenever `paragraphs` changes.
    let version: Int
    let current: Int?
    let play: (Int) -> Void
    let moveHere: (Int) -> Void
    let highlight: (_ first: Int, _ last: Int) -> Void
    /// Where each paragraph starts and ends, from the top, for scrolling to it.
    let anchors: ([Int: TranscriptBodyView.Span]) -> Void

    func makeUIView(context: Context) -> TranscriptBodyView { TranscriptBodyView() }

    func updateUIView(_ view: TranscriptBodyView, context: Context) {
        view.handlers = (play, moveHere, highlight, anchors)
        view.show(paragraphs, version: version, current: current)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TranscriptBodyView, context: Context) -> CGSize? {
        let width = proposal.width ?? 360
        return CGSize(width: width, height: uiView.height(for: width))
    }
}

final class TranscriptBodyView: UIView, UITextViewDelegate, UIGestureRecognizerDelegate {
    /// A paragraph's extent: from its first row (speaker, chips or text)
    /// to the bottom of its last line.
    struct Span: Equatable {
        let top: CGFloat
        let bottom: CGFloat
    }

    static let gutter: CGFloat = 44
    /// How far the playing paragraph's band reaches past the column.
    static let bandBleed: CGFloat = 12
    private static let chipRow: CGFloat = 22
    private static let rowGap: CGFloat = 6
    private static let paragraphGap: CGFloat = 22
    private static let sectionGap: CGFloat = 45
    /// The place a paragraph moved to, between it and the one before.
    private static let placeRow: CGFloat = 24
    private static let placeGap: CGFloat = 10

    var handlers: (play: (Int) -> Void, moveHere: (Int) -> Void, highlight: (Int, Int) -> Void,
                   anchors: ([Int: Span]) -> Void)?

    private let textView = UITextView()
    private var paragraphs: [TranscriptParagraph] = []
    /// Each paragraph's text in the whole, in UTF-16.
    private var ranges: [NSRange] = []
    private var current: Int?
    private var overlays: [UIView] = []
    private var timeLabels: [UILabel] = []
    /// Top of each paragraph's first row (speaker, chips or text), in this view.
    private var tops: [CGFloat] = []
    /// Top of each paragraph's first line of text, and bottom of its last.
    private var textTops: [CGFloat] = []
    /// Where each place row sits, for its tap, and its top, for the thread.
    private var placeHits: [(frame: CGRect, place: PlaceMark)] = []
    private var placeTops: [CGFloat?] = []
    private var bottoms: [CGFloat] = []
    /// Any version: playing (or tapped) shows only once the body says so.
    private var version = -1
    /// A soft band behind the paragraph playing, or where the playhead is.
    private let band = UIView()
    private var reportedAnchors: [Int: Span] = [:]
    private var laidOutWidth: CGFloat = 0
    /// Measuring the text is a full layout: done once per width and text,
    /// not on every frame of a slide or a scrub.
    private var measured: (width: CGFloat, height: CGFloat)?

    static let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17))
    private static let timeFont = UIFontMetrics(forTextStyle: .caption1)
        .scaledFont(for: .monospacedDigitSystemFont(ofSize: 12, weight: .medium))
    private static let currentTimeFont = UIFontMetrics(forTextStyle: .caption1)
        .scaledFont(for: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold))
    private static let speakerFont = UIFontMetrics(forTextStyle: .footnote)
        .scaledFont(for: .systemFont(ofSize: 13, weight: .semibold))

    override init(frame: CGRect) {
        super.init(frame: frame)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 0, left: Self.gutter, bottom: 0, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.dataDetectorTypes = []
        textView.delegate = self
        // A faint tint of the text colour, a little stronger in the dark.
        band.backgroundColor = UIColor { traits in
            UIColor(Color.jText).resolvedColor(with: traits)
                .withAlphaComponent(traits.userInterfaceStyle == .dark ? 0.08 : 0.045)
        }
        band.layer.cornerRadius = Radius.card
        band.layer.cornerCurve = .continuous
        band.alpha = 0
        band.isUserInteractionEnabled = false
        addSubview(band)
        addSubview(textView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Content

    /// `version` changes whenever the paragraphs do, so an unchanged page
    /// (most updates, and every frame of a slide) isn't compared in full.
    func show(_ new: [TranscriptParagraph], version: Int, current: Int?) {
        if version != self.version {
            self.version = version
            if new != paragraphs {
                paragraphs = new
                rebuildText()
                laidOutWidth = 0
                invalidateIntrinsicContentSize()
                setNeedsLayout()
            }
        }
        if current != self.current {
            self.current = current
            styleTimes()
            placeBand(animated: true)
        }
    }

    private func rebuildText() {
        let whole = NSMutableAttributedString()
        ranges = []
        for (i, p) in paragraphs.enumerated() {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 11
            style.paragraphSpacing = i == paragraphs.count - 1 ? 0 : Self.paragraphGap
            style.paragraphSpacingBefore = rowsAbove(p) + (p.newSection && i > 0 ? Self.sectionGap - Self.paragraphGap + 1 : 0)
            let text = NSMutableAttributedString(attributedString: p.text)
            text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
            ranges.append(NSRange(location: whole.length, length: text.length))
            whole.append(text)
            if i < paragraphs.count - 1 {
                whole.append(NSAttributedString(string: "\n", attributes: [.font: Self.font, .paragraphStyle: style]))
            }
        }
        textView.attributedText = whole
        measured = nil
        // Space asked for above the very first paragraph is ignored by the
        // text system; give its chips room with an inset instead.
        textView.textContainerInset.top = paragraphs.first.map(rowsAbove) ?? 0
    }

    /// Room over the text for the speaker's name and the chips.
    private func rowsAbove(_ p: TranscriptParagraph) -> CGFloat {
        var height: CGFloat = 0
        if p.speaker != nil { height += Self.chipRow + Self.rowGap }
        if !p.chips.isEmpty { height += Self.chipRow + Self.rowGap }
        if p.place != nil { height += Self.placeRow + Self.placeGap }
        return height
    }

    // MARK: Layout

    func height(for width: CGFloat) -> CGFloat {
        if let measured, measured.width == width { return measured.height }
        let height = ceil(textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        measured = (width, height)
        return height
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        textView.frame = bounds
        guard bounds.width != laidOutWidth || overlays.isEmpty != paragraphs.isEmpty else { return }
        laidOutWidth = bounds.width
        layOutOverlays()
    }

    private func layOutOverlays() {
        overlays.forEach { $0.removeFromSuperview() }
        overlays = []
        timeLabels = []
        tops = []
        textTops = []
        bottoms = []
        placeHits = []
        placeTops = []
        guard let layout = textView.textLayoutManager else { return }
        layout.ensureLayout(for: layout.documentRange)
        let lineHeight = Self.font.lineHeight

        // Where each paragraph's first line of text sits: the glyphs' own
        // box, so the space asked for above the paragraph doesn't count.
        var lineTops: [CGFloat] = []
        for range in ranges {
            guard let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
                  let end = textView.position(from: start, offset: min(1, range.length)),
                  let textRange = textView.textRange(from: start, to: end) else {
                lineTops.append(lineTops.last ?? 0)
                continue
            }
            let rect = textView.firstRect(for: textRange)
            lineTops.append(rect.isNull ? (lineTops.last ?? 0) : rect.maxY - lineHeight)
            // The last line: the box of the paragraph's final character.
            if let last = textView.position(from: textView.beginningOfDocument, offset: max(range.location, range.location + range.length - 1)),
               let after = textView.position(from: last, offset: 1),
               let lastRange = textView.textRange(from: last, to: after) {
                let r = textView.firstRect(for: lastRange)
                bottoms.append(r.isNull ? (lineTops.last ?? 0) + lineHeight : r.maxY)
            } else {
                bottoms.append((lineTops.last ?? 0) + lineHeight)
            }
        }

        for (i, p) in paragraphs.enumerated() {
            let textTop = lineTops[i]
            var top = textTop
            // Chips, then the speaker, stacked up from the text.
            if !p.chips.isEmpty {
                top -= Self.chipRow + Self.rowGap
                var x = Self.gutter
                for h in p.chips {
                    let chip = UIHostingController(rootView: HighlightChip(highlight: h)).view!
                    chip.backgroundColor = .clear
                    let size = chip.sizeThatFits(CGSize(width: 300, height: Self.chipRow))
                    chip.frame = CGRect(x: x, y: top, width: size.width, height: Self.chipRow)
                    x += size.width + 6
                    add(chip)
                }
            }
            if let speaker = p.speaker {
                top -= Self.chipRow + Self.rowGap
                let label = UILabel(frame: CGRect(x: Self.gutter, y: top, width: bounds.width - Self.gutter, height: Self.chipRow))
                label.text = speaker
                label.font = Self.speakerFont
                label.textColor = UIColor(Color.jText)
                add(label)
            }
            // The place, over the rest, its pin in the gutter on the thread.
            if let place = p.place, let name = place.name {
                let placeTop = top - Self.placeRow - Self.placeGap
                let pin = UIHostingController(rootView: GlyphView(glyph: .pin, color: .jText4)).view!
                pin.backgroundColor = .clear
                pin.frame = CGRect(x: 6, y: placeTop + (Self.placeRow - 13) / 2, width: 13, height: 13)
                add(pin)
                let chip = UIHostingController(rootView: PlaceChip(name: name)).view!
                chip.backgroundColor = .clear
                let size = chip.sizeThatFits(CGSize(width: bounds.width - Self.gutter, height: Self.placeRow))
                chip.frame = CGRect(x: Self.gutter, y: placeTop, width: min(size.width, bounds.width - Self.gutter), height: Self.placeRow)
                add(chip)
                placeHits.append((pin.frame.union(chip.frame).insetBy(dx: -6, dy: -6), place))
                placeTops.append(placeTop)
            } else {
                placeTops.append(nil)
            }
            tops.append(top)
            textTops.append(textTop)
            let firstRow = top == textTop ? lineHeight : Self.chipRow

            let time = UILabel(frame: CGRect(x: 0, y: top, width: Self.gutter, height: firstRow))
            time.text = Format.clock(p.start)
            time.isAccessibilityElement = false
            timeLabels.append(time)
            add(time)

            if p.newSection, i > 0 {
                let rule = UIView(frame: CGRect(x: 0, y: top - Self.sectionGap / 2, width: bounds.width, height: 1))
                rule.backgroundColor = UIColor(Color.jHairline)
                add(rule)
            }
        }
        // The dashed thread from each time down to the next.
        for i in 0..<max(0, paragraphs.count - 1) {
            let from = timeLabels[i].frame.maxY + 6
            let next = timeLabels[i + 1].frame.minY - 6 - (paragraphs[i + 1].newSection ? Self.sectionGap / 2 : 0)
            // Broken around a place's pin, which sits on it.
            if let placeTop = placeTops[i + 1] {
                let pinTop = placeTop + (Self.placeRow - 13) / 2
                if pinTop - 5 > from { add(DashedThread(frame: CGRect(x: 12, y: from, width: 1, height: pinTop - 5 - from))) }
                let after = pinTop + 13 + 5
                if next > after { add(DashedThread(frame: CGRect(x: 12, y: after, width: 1, height: next - after))) }
                continue
            }
            guard next > from else { continue }
            add(DashedThread(frame: CGRect(x: 12, y: from, width: 1, height: next - from)))
        }
        styleTimes()
        placeBand(animated: false)

        let anchors = Dictionary(uniqueKeysWithValues: paragraphs.indices.map {
            (paragraphs[$0].id, Span(top: tops[$0], bottom: bottoms[$0]))
        })
        if anchors != reportedAnchors {
            reportedAnchors = anchors
            let report = handlers?.anchors
            DispatchQueue.main.async { report?(anchors) }
        }
    }

    private func add(_ view: UIView) {
        view.isUserInteractionEnabled = false
        insertSubview(view, belowSubview: textView)
        overlays.append(view)
    }

    private func styleTimes() {
        for (i, label) in timeLabels.enumerated() {
            let isCurrent = paragraphs[i].id == current
            label.font = isCurrent ? Self.currentTimeFont : Self.timeFont
            label.textColor = UIColor(isCurrent ? Color.jLive : Color.jText3)
        }
    }

    /// A little wider than the paragraph and a little above and below
    /// it, so it reads as picked out, with its time inside.
    private func placeBand(animated: Bool) {
        guard let current, let i = paragraphs.firstIndex(where: { $0.id == current }),
              i < tops.count, i < textTops.count, i < bottoms.count else {
            UIView.animate(withDuration: animated ? 0.2 : 0) { self.band.alpha = 0 }
            return
        }
        // The whole paragraph, its time included: 12 pt out on both sides,
        // so the time and the text keep their margins and the band hangs
        // evenly past them. From the speaker or chips when there are any.
        let top = tops[i] < textTops[i] ? tops[i] - 8 : textTops[i] - 7
        let frame = CGRect(x: -Self.bandBleed, y: top,
                           width: bounds.width + Self.bandBleed * 2, height: bottoms[i] + 7 - top)
        if band.alpha == 0 || !animated {
            band.frame = frame
            UIView.animate(withDuration: animated ? 0.2 : 0) { self.band.alpha = 1 }
        } else {
            UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.band.frame = frame
            }
        }
    }

    // MARK: Touch

    private func paragraph(atY y: CGFloat) -> Int? {
        guard !tops.isEmpty else { return nil }
        let i = tops.lastIndex { $0 <= y + 4 } ?? 0
        return i
    }

    private func paragraph(atOffset offset: Int) -> Int? {
        ranges.lastIndex { $0.location <= offset }
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        let point = tap.location(in: self)
        if let hit = placeHits.first(where: { $0.frame.contains(point) }) {
            Places.openInMaps(hit.place)
            return
        }
        if point.x < Self.gutter {
            if let i = paragraph(atY: point.y) { handlers?.play(paragraphs[i].id) }
            return
        }
        guard textView.selectedRange.length == 0,
              let position = textView.closestPosition(to: tap.location(in: textView)) else { return }
        let offset = textView.offset(from: textView.beginningOfDocument, to: position)
        if let i = paragraph(atOffset: offset) { handlers?.moveHere(paragraphs[i].id) }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    /// A touch that stops a scroll, or lands while the page is still
    /// moving, is not a tap on the text.
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g.view === self else { return super.gestureRecognizerShouldBegin(g) }
        var view = superview
        while let v = view {
            if let scroll = v as? UIScrollView, scroll.isDragging || scroll.isDecelerating
                || Date.now.timeIntervalSince(lastScroll(scroll)) < 0.25 { return false }
            view = v.superview
        }
        return true
    }

    /// When the enclosing scroll view last moved, checked by watching its offset.
    private var scrollWatch: (offset: CGFloat, at: Date)?
    private func lastScroll(_ scroll: UIScrollView) -> Date {
        scrollWatch?.at ?? .distantPast
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        offsetObservation = nil
        var view = superview
        while let v = view {
            if let scroll = v as? UIScrollView {
                offsetObservation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, change in
                    let y = change.newValue?.y ?? 0
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if self.scrollWatch?.offset != y { self.scrollWatch = (y, .now) }
                    }
                }
                break
            }
            view = v.superview
        }
    }

    private var offsetObservation: NSKeyValueObservation?

    // MARK: Menu

    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        let whole = textView.text as NSString
        let picked = ranges.enumerated().compactMap { i, r -> (Int, String)? in
            let overlap = NSIntersectionRange(r, range)
            guard overlap.length > 0 else { return nil }
            return (i, whole.substring(with: overlap))
        }
        guard let first = picked.first, let last = picked.last else { return UIMenu(children: suggestedActions) }
        let several = picked.count > 1
        let copyWithTimes = UIAction(title: several ? "Copy with times" : "Copy with time", image: UIImage(systemName: "clock")) { [weak self] _ in
            guard let self else { return }
            UIPasteboard.general.string = picked.map { "[\(Format.clock(self.paragraphs[$0.0].start))] \($0.1)" }
                .joined(separator: "\n\n")
        }
        let highlight = UIAction(title: "Highlight", image: UIImage(systemName: "highlighter")) { [weak self] _ in
            guard let self else { return }
            self.handlers?.highlight(self.paragraphs[first.0].id, self.paragraphs[last.0].id)
            textView.selectedRange = NSRange(location: range.location, length: 0)
        }
        // After the system's Copy (first), before Look Up, Share and the rest.
        var children = suggestedActions
        children.insert(contentsOf: [copyWithTimes, highlight], at: min(1, children.count))
        return UIMenu(children: children)
    }
}

/// "Willow Park ↗": where the paragraph under it moved to. Opens Maps.
struct PlaceChip: View {
    let name: String

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.scaled(12, .medium, relativeTo: .caption1))
                .foregroundStyle(Color.jText2)
                .lineLimit(1)
            Image(systemName: "arrow.up.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.jText4)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Color.jFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .fixedSize()
    }
}

/// The dashed line that links one paragraph's time to the next.
private final class DashedThread: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0.5, y: 0))
        path.addLine(to: CGPoint(x: 0.5, y: bounds.height))
        path.lineWidth = 1
        path.setLineDash([3, 3], count: 2, phase: 0)
        UIColor(Color.jText5).setStroke()
        path.stroke()
    }
}

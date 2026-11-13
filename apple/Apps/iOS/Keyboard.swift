import SwiftUI
import UIKit

extension View {
    /// For a page with text fields, on its scroll view's content: a tap
    /// anywhere that isn't a field puts the keyboard away (the tap still
    /// does whatever it was going to), and a field that comes up under
    /// the keyboard is scrolled into view above it, with a little room.
    func keyboardFriendly() -> some View {
        background(KeyboardHook())
    }
}

/// The field being typed in, if any.
@MainActor
enum Typing {
    private static weak var found: UIResponder?

    static var field: UIView? {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.jottoCaptureResponder), to: nil, from: nil, for: nil)
        guard let view = found as? UIView else { return nil }
        return view is UITextField || (view as? UITextView)?.isEditable == true ? view : nil
    }

    fileprivate static func capture(_ responder: UIResponder) { found = responder }

    /// Where the keyboard is, in screen coordinates; empty when it's away.
    fileprivate(set) static var keyboard: CGRect = .null

    /// The field and what belongs to it: the padding of its ground, the
    /// clear button at its end. A tap in here isn't a tap elsewhere.
    static func reach(of field: UIView, in view: UIView) -> CGRect {
        let frame = field.convert(field.bounds, to: view)
        return CGRect(x: frame.minX - 16, y: frame.minY - 16, width: frame.width + 16 + 48, height: frame.height + 32)
    }
}

extension UIResponder {
    @objc fileprivate func jottoCaptureResponder() {
        Typing.capture(self)
    }
}

private struct KeyboardHook: UIViewRepresentable {
    func makeUIView(context: Context) -> Hook { Hook() }
    func updateUIView(_ view: Hook, context: Context) {}

    final class Hook: UIView, UIGestureRecognizerDelegate {
        private weak var scroll: UIScrollView?
        private var tap: UITapGestureRecognizer!

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
            tap.cancelsTouchesInView = false
            tap.delaysTouchesEnded = false
            tap.delegate = self
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
            center.addObserver(self, selector: #selector(keyboardShown), name: UIResponder.keyboardDidShowNotification, object: nil)
            center.addObserver(self, selector: #selector(keyboardHidden), name: UIResponder.keyboardWillHideNotification, object: nil)
            // From one field to the next with the keyboard already up.
            center.addObserver(self, selector: #selector(began), name: UITextField.textDidBeginEditingNotification, object: nil)
            center.addObserver(self, selector: #selector(began), name: UITextView.textDidBeginEditingNotification, object: nil)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            scroll?.removeGestureRecognizer(tap)
            scroll = nil
            guard window != nil else { return }
            var view = superview
            while let v = view {
                if let found = v as? UIScrollView {
                    scroll = found
                    found.addGestureRecognizer(tap)
                    return
                }
                view = v.superview
            }
        }

        @objc private func tapped() {
            window?.endEditing(true)
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let window, let field = Typing.field else { return false }
            // On a field: typing carries on there, or moves to it.
            var view = touch.view
            while let v = view {
                if v is UITextField || (v as? UITextView)?.isEditable == true { return false }
                view = v.superview
            }
            return !Typing.reach(of: field, in: window).contains(touch.location(in: window))
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc private func keyboardChanged(_ note: Notification) {
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                  let screen = window?.screen.bounds else { return }
            // Off the bottom of the screen is away. (Every page with a hook
            // hears this; what it was comes with the note, not from here.)
            func away(_ rect: CGRect) -> Bool { rect.isEmpty || rect.minY >= screen.maxY - 1 }
            let before = note.userInfo?[UIResponder.keyboardFrameBeginUserInfoKey] as? CGRect ?? .zero
            Typing.keyboard = away(frame) ? .null : frame
            // Coming up: move with it, in its time and on its curve.
            guard away(before), !away(frame) else { return }
            let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.3
            let curve = note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 7
            reveal(duration: duration, options: UIView.AnimationOptions(rawValue: curve << 16))
        }

        @objc private func keyboardHidden() {
            Typing.keyboard = .null
        }

        @objc private func keyboardShown() {
            reveal()
        }

        @objc private func began() {
            // After the page has settled around the new field.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard !Typing.keyboard.isNull else { return }
                self?.reveal()
            }
        }

        /// The field and a couple of lines under it (a note, a footnote)
        /// clear of the keyboard and of the top of the page; moved no
        /// more than needed.
        private func reveal(duration: Double = 0.3, options: UIView.AnimationOptions = .curveEaseOut) {
            guard let scroll, let window, let field = Typing.field, field.isDescendant(of: scroll) else { return }
            let reach = Typing.reach(of: field, in: window)
            let wanted = CGRect(x: reach.minX, y: reach.minY, width: reach.width, height: reach.height + 52)
            let shown = scroll.convert(scroll.bounds, to: window)
            let keyboardTop = Typing.keyboard.isNull ? shown.maxY : min(shown.maxY, window.convert(Typing.keyboard, from: nil).minY)
            let top = shown.minY + scroll.safeAreaInsets.top + 8
            var delta: CGFloat = 0
            if wanted.maxY > keyboardTop { delta = wanted.maxY - keyboardTop }
            if wanted.minY - delta < top { delta = wanted.minY - top }
            guard abs(delta) > 1 else { return }
            let inset = scroll.adjustedContentInset
            // As far as the content goes, with room under it for the
            // keyboard even before the page has made that room itself.
            let under = max(inset.bottom, shown.maxY - keyboardTop)
            let highest = max(-inset.top, scroll.contentSize.height + under - scroll.bounds.height)
            let y = min(max(-inset.top, scroll.contentOffset.y + delta), max(highest, scroll.contentOffset.y))
            UIView.animate(withDuration: duration, delay: 0, options: [options, .allowUserInteraction, .beginFromCurrentState]) {
                scroll.contentOffset.y = y
            }
        }
    }
}

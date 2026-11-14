import SwiftUI
import UIKit

/// A growing editor whose text and selection are changed together. This avoids
/// retaining SwiftUI TextSelection indices across store updates and formatting.
@MainActor
struct NotesTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: Range<Int>?
    var isFocused: Bool
    var dimmed: Bool
    var commit: () -> Void = {}
    var focusChanged: (Bool) -> Void

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        context.coordinator.textView = view
        let toolbar = UIToolbar()
        let done = UIBarButtonItem(title: "Done", style: .done, target: context.coordinator,
                                   action: #selector(Coordinator.done))
        done.accessibilityHint = "Saves the notes and hides the keyboard"
        toolbar.items = [UIBarButtonItem(systemItem: .flexibleSpace), done]
        toolbar.sizeToFit()
        view.inputAccessoryView = toolbar
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityLabel = "Notes"
        view.accessibilityIdentifier = "nog.notes.editor"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        view.textColor = dimmed ? .secondaryLabel : .label
        // Don't replace an in-progress IME composition. Its delegate publishes the
        // composed text normally; writing .text here would discard marked text.
        if view.markedTextRange == nil {
            coordinator.applying = true
            if view.text != text {
                view.text = text
                view.invalidateIntrinsicContentSize()
            }
            if let selection {
                let range = NotesSelection.utf16(selection, in: text)
                if view.selectedRange != range { view.selectedRange = range }
            }
            coordinator.applying = false
        }
        // First responder changes must happen after this update, once mounted.
        if view.isFirstResponder != isFocused {
            DispatchQueue.main.async { [weak view, weak coordinator] in
                guard let view, let coordinator else { return }
                if coordinator.parent.isFocused, view.window != nil {
                    if !view.isFirstResponder { view.becomeFirstResponder() }
                } else if !coordinator.parent.isFocused, view.isFirstResponder {
                    view.resignFirstResponder()
                }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let minimum = (uiView.font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight) * 4 + 8
        return CGSize(width: width, height: max(minimum, ceil(size.height)))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NotesTextView
        var applying = false
        weak var textView: UITextView?

        init(_ parent: NotesTextView) { self.parent = parent }

        @objc func done() {
            parent.commit()
            textView?.resignFirstResponder()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            publishSelection(textView)
            parent.focusChanged(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.focusChanged(false)
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !applying else { return }
            parent.text = textView.text
            publishSelection(textView)
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !applying, textView.text == parent.text else { return }
            publishSelection(textView)
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange,
                      replacementText replacement: String) -> Bool {
            guard !applying, replacement == "\n", textView.markedTextRange == nil,
                  range.length == 0,
                  let caret = NotesSelection.characters(range, in: textView.text)?.lowerBound,
                  let indices = Range(range, in: textView.text) else { return true }
            let old = textView.text ?? ""
            let new = old.replacingCharacters(in: indices, with: replacement)
            guard let result = NotesFormat.continueList(old: old, new: new, caret: caret) else { return true }
            // Register the full formatting operation with the undo manager so
            // automatically inserted list markers can be undone together.
            let previous = old
            let previousSelection = textView.selectedRange
            apply(result.text, selection: NotesSelection.utf16(result.selection, in: result.text),
                  to: textView, undoText: previous, undoSelection: previousSelection)
            return false
        }

        private func apply(_ text: String, selection: NSRange, to view: UITextView,
                           undoText: String, undoSelection: NSRange) {
            view.undoManager?.registerUndo(withTarget: self) { [weak view] target in
                guard let view else { return }
                target.apply(undoText, selection: undoSelection, to: view,
                             undoText: view.text, undoSelection: view.selectedRange)
            }
            applying = true
            view.text = text
            view.selectedRange = selection
            applying = false
            textViewDidChange(view)
        }

        private func publishSelection(_ view: UITextView) {
            parent.selection = NotesSelection.characters(view.selectedRange, in: view.text)
        }
    }
}

import SwiftUI

/// The notes as they read, with lists, checkboxes, headings, bold and links drawn properly.
/// Tap anywhere that isn't a link or a checkbox to edit the words underneath.
/// (See `NotesMarkdown` for what's understood.)
struct NotesMarkdownView: View {
    let text: String
    var dimmed = false
    /// Flips the checkbox on this line of the notes.
    let toggleTask: (Int) -> Void
    let edit: () -> Void

    @ScaledMetric(relativeTo: .body) private var markerWidth: CGFloat = 20
    @ScaledMetric(relativeTo: .body) private var indentStep: CGFloat = 20
    @ScaledMetric(relativeTo: .body) private var gap: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(NotesMarkdown.blocks(text), id: \.index) { line in
                row(line)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAction(named: "Edit notes", edit)
            }
        }
        .foregroundStyle(dimmed ? Theme.muted : .primary)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: edit)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notes")
    }

    @ViewBuilder
    private func row(_ line: NotesLine) -> some View {
        switch line.block {
        case .blank:
            Color.clear.frame(height: gap).accessibilityHidden(true)
        case .rule:
            Rectangle().fill(Theme.edge).frame(height: 1)
                .padding(.vertical, gap / 2)
                .accessibilityHidden(true)
        case .heading(let level, let text):
            Text(NotesMarkdown.inline(text))
                .font(level == 1 ? .title3.weight(.bold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, gap / 2)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(NotesMarkdown.inline(text))
        case .quote(let text):
            Text(NotesMarkdown.inline(text))
                .italic()
                .foregroundStyle(Theme.muted)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Capsule().fill(Theme.violet.opacity(0.6)).frame(width: 3)
                }
        case .code(let text):
            Text(verbatim: text.isEmpty ? " " : text)
                .font(.body.monospaced())
        case .bullet(let indent, let text):
            listItem(indent: indent, text: text) {
                // Hollow for nested bullets, so the levels are told apart by shape, not size.
                Text(verbatim: indent.isMultiple(of: 2) ? "•" : "◦")
                    .fontWeight(.bold)
                    .foregroundStyle(Theme.pink)
            }
        case .ordered(let indent, let marker, let text):
            listItem(indent: indent, text: text) {
                Text(verbatim: marker)
                    .monospacedDigit()
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.violet)
            }
        case .task(let indent, let done, let text):
            taskItem(index: line.index, indent: indent, done: done, text: text)
        }
    }

    /// A mark, then the words with a hanging indent so wrapped lines sit under the words.
    private func listItem<Marker: View>(indent: Int, text: String, @ViewBuilder marker: () -> Marker) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            marker()
                .frame(minWidth: markerWidth, alignment: .leading)
            Text(NotesMarkdown.inline(text))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(indent) * indentStep)
        .accessibilityElement(children: .combine)
    }

    private func taskItem(index: Int, indent: Int, done: Bool, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button {
                toggleTask(index)
            } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done ? Theme.blue : Theme.muted)
                    .frame(minWidth: markerWidth, alignment: .leading)
                    .contentShape(Rectangle().inset(by: -10))
            }
            .buttonStyle(.borderless)
            Text(NotesMarkdown.inline(text))
                .strikethrough(done)
                .foregroundStyle(done ? Theme.muted : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(indent) * indentStep)
        .nogFeedback(.selection, trigger: done)
        // One element: the words, whether it's done, and a double-tap to flip it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NotesMarkdown.plain(text))
        .accessibilityValue(done ? "Done" : "Not done")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(done ? "Marks it not done" : "Marks it done")
        .accessibilityAction { toggleTask(index) }
    }
}

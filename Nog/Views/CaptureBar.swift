import SwiftUI

/// Always-visible capture field. Type, hit return, keep typing.
struct CaptureBar: View {
    @Environment(ItemStore.self) private var store
    @Environment(Router.self) private var router
    @State private var text = ""
    @State private var confirmation: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            if let preview {
                Text("→ " + preview.uppercased())
                    .font(.nogMeta)
                    .tracking(0.4)
                    .foregroundStyle(Theme.blue)
                    .nogLineLimit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
            } else if let confirmation {
                Text(confirmation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            HStack(spacing: 8) {
                TextField("Capture…", text: $text)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit(submit)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(Theme.glass, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.edgeStrong, lineWidth: 1))
                Button(action: submit) {
                    Image(systemName: "arrow.up")
                        .nogFont(16, weight: .semibold)
                        .foregroundStyle(.primary)
                        .nogFrame(width: 40, height: 40)
                        .overlay(Circle().strokeBorder(Theme.synth, lineWidth: 1.5))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(text.trimmingCharacters(in: .whitespaces).isEmpty ? 0.45 : 1)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Rectangle().fill(Theme.edge).frame(height: 1) }
        .onAppear { focused = true }
        .onChange(of: router.captureFocusRequest) { focused = true }
    }

    /// Live read-back of how the text will be understood.
    private var preview: String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parsed = CaptureParser.parse(trimmed, defaults: NogSettings.captureDefaults, now: .now)
        guard !parsed.title.isEmpty else { return nil }
        return "\(parsed.title) — \(Self.describe(parsed.reminder))"
    }

    static func describe(_ reminder: Reminder?) -> String {
        guard let r = reminder else { return "no reminder" }
        let calendar = Calendar.current
        let when: String
        if r.start.timeIntervalSinceNow < 60 * 60 * 6 && calendar.isDateInToday(r.start) {
            when = r.start.formatted(.relative(presentation: .named))
        } else if calendar.isDateInToday(r.start) {
            when = "today " + r.start.formatted(date: .omitted, time: .shortened)
        } else if calendar.isDateInTomorrow(r.start) {
            when = "tomorrow " + r.start.formatted(date: .omitted, time: .shortened)
        } else {
            when = r.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
        }
        guard let summary = r.repeatSummary else { return "no repeat, \(when)" }
        return "\(when), then \(summary)"
    }

    private func submit() {
        guard let item = store.capture(text) else { return }
        text = ""
        focused = true // keep the keyboard up for the next thought
        let message = Self.describe(item.reminder)
        withNogAnimation { confirmation = "✓ \(item.title) — \(message)" }
        Task {
            try? await Task.sleep(for: .seconds(3))
            withNogAnimation { if confirmation?.contains(item.title) == true { confirmation = nil } }
        }
    }
}

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
                Label(preview, systemImage: "wand.and.stars")
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: Capsule())
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
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
        guard let m = r.repeatMinutes else { return "once, \(when)" }
        return "\(when), then every \(IntervalFormat.short(m))"
    }

    private func submit() {
        guard let item = store.capture(text) else { return }
        text = ""
        focused = true // keep the keyboard up for the next thought
        let message = Self.describe(item.reminder)
        withAnimation { confirmation = "✓ \(item.title) — \(message)" }
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation { if confirmation?.contains(item.title) == true { confirmation = nil } }
        }
    }
}

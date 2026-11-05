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
            if let confirmation {
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

    private func submit() {
        guard let item = store.capture(text) else { return }
        text = ""
        focused = true // keep the keyboard up for the next thought
        let message: String
        if let r = item.reminder {
            let start = r.start.formatted(.relative(presentation: .named))
            message = r.repeatMinutes.map { "Nagging \(start), every \(IntervalFormat.short($0))" }
                ?? "Reminding \(start)"
        } else {
            message = "Saved without a reminder"
        }
        withAnimation { confirmation = "✓ \(item.title) — \(message)" }
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation { if confirmation?.contains(item.title) == true { confirmation = nil } }
        }
    }
}

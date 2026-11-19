import SwiftUI

/// The bottom bar while selecting nogs: act on all of them at once.
struct BulkActionBar: View {
    @Environment(ItemStore.self) private var store
    @Binding var selection: Set<UUID>
    @State private var confirmDelete = false
    /// Settings › "Ring as an alarm after": which profiles get the rings-through-Silent mark.
    @AppStorage(NogSettings.Key.escalateAfter) private var globalEscalate = 0

    private var selected: [Item] { selection.compactMap { store.items[$0] } }

    var body: some View {
        let none = selection.isEmpty
        ScrollView(.horizontal) {
            HStack(spacing: 16) {
                Button {
                    apply { $0.status = .done }
                    selection = []
                } label: {
                    Label("Done", systemImage: "checkmark.circle")
                }
                .disabled(none)

                Spacer()

                DrawerButton("Snooze", look: .open(Theme.blue), style: .bare, sections: {
                    let open = selected.filter { $0.status != .done }
                    return [DrawerSection(id: "snooze", items: [
                        DrawerItem("Snooze", systemImage: "zzz") {
                            store.batch {
                                for item in open {
                                    store.snooze(item.id, until: .now.addingTimeInterval(TimeInterval(NogSettings.snoozeLength(for: item) * 60)))
                                }
                            }
                        },
                        DrawerItem("Snooze till morning", systemImage: "sunrise") {
                            store.batch {
                                for item in open { store.snooze(item.id, until: NogSettings.nextMorning(for: item)) }
                            }
                        },
                    ])]
                }) {
                    Label("Snooze", systemImage: "zzz").labelStyle(StackedLabelStyle())
                }
                .disabled(none)

                Spacer()

                DrawerButton("Nog", look: .open(Theme.blue), style: .bare, maxWidth: 250, sections: {
                    let profiles = NogProfile.allCases.map { profile in
                        DrawerItem(profile.label, id: profile.id,
                                   // The rings-through-Silent mark, as a second line.
                                   detail: profile.breaksSilent(globalEscalateAfter: globalEscalate)
                                       ? NogProfile.breaksSilentSpoken : nil,
                                   systemImage: profile.systemImage) {
                            apply { item in
                                var r = item.reminder ?? NogSettings.defaultReminderFromNow
                                r = profile.apply(to: r)
                                // Balanced moves the next reminder to its time of day, as on the item's page.
                                if profile.timeOfDay != nil { r.start = profile.firstStart(from: .now) }
                                // Picked for these items specifically: they stop following a parent.
                                if item.parentID != nil { r.followsParent = false }
                                item.reminder = r
                            }
                        }
                    }
                    return [
                        DrawerSection("Nog them", items: profiles + [
                            DrawerItem("Stop nogging", systemImage: "bell.slash") { apply { $0.reminder = nil } },
                        ]),
                        DrawerSection("Status", items: [
                            DrawerItem("Open", systemImage: "circle") { apply { $0.status = .open } },
                            DrawerItem("Move to Someday", systemImage: "moon.stars") { apply { $0.status = .someday } },
                        ]),
                    ]
                }) {
                    Label("Nog", systemImage: "bell.badge").labelStyle(StackedLabelStyle())
                }
                .disabled(none)

                Spacer()

                // The same tag drawer as everywhere else: ticked = on all of them, a dash = on
                // some (tap to put it on all).
                let tagCounts = Dictionary(grouping: selected.flatMap { item in Set(item.tags.map { $0.lowercased() }) },
                                           by: { $0 }).mapValues(\.count)
                TagMenu(applied: tagCounts.filter { $0.value == selected.count }.keys.sorted(),
                        partial: tagCounts.filter { $0.value < selected.count }.keys.sorted(),
                        add: { tag in apply { $0.addTag(tag) } },
                        remove: { tag in apply { $0.removeTag(tag) } },
                        look: .open(Theme.blue), style: .bare) {
                    Label("Tags", systemImage: "number").labelStyle(StackedLabelStyle())
                }
                .disabled(none)

                Spacer()

                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(none)
                .confirmationDialog("Delete \(selection.count) \(selection.count == 1 ? "item" : "items")?",
                                    isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) {
                        store.batch {
                            for id in selection { store.delete(id) }
                        }
                        selection = []
                    }
                } message: {
                    Text("Their notes go too. Sub-nogs stay.")
                }
            }
        }
        .scrollIndicators(.hidden)
        .labelStyle(StackedLabelStyle())
    }

    /// Changes every selected item, then reschedules nogs once.
    private func apply(_ change: (inout Item) -> Void) {
        store.batch {
            for id in selection {
                guard var item = store.items[id] else { continue }
                change(&item)
                store.update(item)
            }
        }
    }
}

/// Icon over a small caption, for the action bar.
private struct StackedLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 3) {
            configuration.icon.nogFont(18, weight: .medium)
            configuration.title.font(.caption2.weight(.medium))
        }
        .frame(minWidth: 52, minHeight: 44)
        .contentShape(Rectangle())
    }
}

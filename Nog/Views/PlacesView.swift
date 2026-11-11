import CoreLocation
import MapKit
import SwiftUI

/// Settings › Places: Home, Work and anywhere else "when I get to…" should work.
struct PlacesView: View {
    @State private var book = PlaceBook.shared
    @State private var adding = false

    var body: some View {
        List {
            Section {
                if book.places.isEmpty {
                    Text("No places yet.").foregroundStyle(.secondary)
                }
                ForEach(book.places) { place in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(place.name)
                        Text("Within \(Int(place.radius)) m")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                .onDelete { offsets in
                    for i in offsets { book.delete(book.places[i].id) }
                }
                Button {
                    adding = true
                } label: {
                    Label("Add a place", systemImage: "plus")
                }
                .disabled(book.places.count >= PlaceBook.maxWatched)
            } header: {
                SectionLabel(title: "Places")
            } footer: {
                Text("Type “when I get home”. iOS watches the place; Nog never tracks you. Up to \(PlaceBook.maxWatched).")
            }
            .listRowBackground(Theme.glass)
        }
        .nogListStyle()
        .navigationTitle("Places")
        .sheet(isPresented: $adding) { AddPlaceSheet() }
    }
}

private struct AddPlaceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var picked: CLLocationCoordinate2D?
    @State private var pickedLabel: String?
    @State private var locating = false
    @State private var problem: String?

    private let suggestions = ["Home", "Work", "School", "The gym"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, like Home", text: $name)
                        .textInputAutocapitalization(.words)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(suggestions, id: \.self) { s in
                                Button(s) { name = s }
                                    .buttonStyle(OutlineButtonStyle(tint: Theme.violet, expands: false))
                            }
                        }
                    }
                } header: {
                    SectionLabel(title: "Name")
                } footer: {
                    Text("“when I get to \(name.isEmpty ? "…" : name)”")
                }
                .listRowBackground(Theme.glass)

                Section {
                    Button {
                        Task { await useCurrentLocation() }
                    } label: {
                        Label(locating ? "Finding you…" : "Use where I am now", systemImage: "location")
                    }
                    .disabled(locating)
                    TextField("Or search for an address", text: $query)
                        .onSubmit { Task { await search() } }
                        .submitLabel(.search)
                    ForEach(results, id: \.self) { item in
                        Button {
                            picked = item.location.coordinate
                            pickedLabel = item.name ?? query
                            results = []
                        } label: {
                            VStack(alignment: .leading) {
                                Text(item.name ?? "Place")
                                if let address = item.address?.shortAddress {
                                    Text(address).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if let pickedLabel {
                        Label(pickedLabel, systemImage: "checkmark.circle")
                            .foregroundStyle(StatusDial.tint(.done))
                    }
                    if let problem {
                        Text(problem).font(.subheadline).foregroundStyle(Theme.pink)
                    }
                } header: {
                    SectionLabel(title: "Where")
                }
                .listRowBackground(Theme.glass)
            }
            .nogListStyle()
            .navigationTitle("Add a place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || picked == nil)
                }
            }
        }
    }

    private func useCurrentLocation() async {
        locating = true
        defer { locating = false }
        problem = nil
        guard let location = await LocationAccess.shared.currentLocation() else {
            problem = LocationAccess.shared.isAllowed
                ? "Couldn't find you. Try again, or search."
                : "Location is off. Allow it in Settings › Privacy › Location Services › Nog."
            return
        }
        picked = location.coordinate
        pickedLabel = "Where you are now"
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        results = (try? await MKLocalSearch(request: request).start().mapItems.prefix(6).map { $0 }) ?? []
        problem = results.isEmpty ? "Nothing found for “\(text)”." : nil
    }

    private func save() {
        guard let picked else { return }
        Task {
            // iOS only fires place reminders with location allowed.
            _ = await LocationAccess.shared.requestAccess()
            PlaceBook.shared.save(SavedPlace(name: name.trimmingCharacters(in: .whitespaces),
                                             latitude: picked.latitude, longitude: picked.longitude))
            dismiss()
        }
    }
}

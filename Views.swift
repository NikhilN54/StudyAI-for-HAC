import SwiftUI

struct HomeView: View {
    @EnvironmentObject var store: Store
    @State private var showSettings = false
    @State private var showProfiles = false
    var body: some View {
        NavigationStack {
            List {
                ChangesSection()
                PredictBanner()
                Section {
                    Button {
                        store.activeConcept = store.priorities.first?.concept
                        store.tab = 2
                    } label: { Label("Help Me Study", systemImage: "sparkles").font(.headline) }
                }
                Section("Today's priorities") {
                    ForEach(store.priorities) { p in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(store.nm(p.course)): \(p.minutes) min").font(.headline)
                            Text(p.reason).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .themed()
            .navigationTitle("StudyAI")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showProfiles = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "person.crop.circle")
                            Text(store.profileLabel).font(.subheadline)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { Button { showSettings = true } label: { Image(systemName: "gear") } }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showProfiles) { ProfilesSheet() }
        }
    }
}

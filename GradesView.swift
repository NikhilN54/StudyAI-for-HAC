import SwiftUI

struct GradeBadge: View {
    let pct: Double
    var body: some View {
        Text("\(pct1(pct))%").font(.subheadline.bold())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(gradeColor(pct).opacity(0.18), in: Capsule())
            .foregroundStyle(gradeColor(pct))
    }
}

/// Quarter switcher: numbered stops on a track. Drag or tap to change quarter.
struct QuarterSlider: View {
    @EnvironmentObject var store: Store
    @Environment(\.appAccent) private var accent
    let vertical: Bool

    var body: some View {
        let qs = store.quarterOptions
        GeometryReader { geo in
            let n = qs.count
            let pad: CGFloat = 26
            let length = max((vertical ? geo.size.height : geo.size.width) - pad * 2, 1)
            let step: CGFloat = n > 1 ? length / CGFloat(n - 1) : 0
            let pos: (Int) -> CGPoint = { i in
                vertical ? CGPoint(x: geo.size.width / 2, y: pad + step * CGFloat(i))
                         : CGPoint(x: pad + step * CGFloat(i), y: geo.size.height / 2)
            }
            let sel = qs.firstIndex(of: store.quarter) ?? 0
            ZStack {
                Path { p in p.move(to: pos(0)); p.addLine(to: pos(max(n - 1, 0))) }
                    .stroke(Color(.tertiarySystemFill), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                Path { p in p.move(to: pos(0)); p.addLine(to: pos(sel)) }
                    .stroke(accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                ForEach(Array(qs.enumerated()), id: \.offset) { pair in
                    let i = pair.offset
                    ZStack {
                        Circle().fill(i == sel ? accent : Color(.secondarySystemBackground))
                            .overlay(Circle().stroke(i <= sel ? accent : Color(.separator), lineWidth: 2))
                        Text("Q\(pair.element)").font(.system(size: i == sel ? 12 : 10, weight: .bold))
                            .foregroundStyle(i == sel ? Color.white : Color.primary)
                    }
                    .frame(width: i == sel ? 42 : 32, height: i == sel ? 42 : 32)
                    .position(pos(i))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                guard n > 1, step > 0 else { return }
                let raw = ((vertical ? v.location.y : v.location.x) - pad) / step
                let i = min(max(Int(raw.rounded()), 0), n - 1)
                store.selectQuarter(qs[i])
            })
            .animation(.easeOut(duration: 0.15), value: store.quarter)
        }
    }
}

struct ExtraEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let original: ExtraCourse?
    @State private var name: String
    @State private var level: Level
    @State private var credits: Double
    @State private var gradeText: String

    init(extra: ExtraCourse?) {
        original = extra
        _name = State(initialValue: extra?.name ?? "")
        _level = State(initialValue: extra?.lvl ?? .regular)
        _credits = State(initialValue: extra?.credits ?? 1)
        _gradeText = State(initialValue: extra.map { fmt($0.grade) } ?? "90")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text("Extra classes count in your current GPA (see the GPA tab) and stay with this profile.")) {
                    TextField("Class name", text: $name)
                    Picker("Level", selection: $level) { ForEach(Level.allCases) { Text($0.rawValue).tag($0) } }
                    Stepper("Credits: \(fmt(credits))", value: $credits, in: 0.5...2, step: 0.5)
                    HStack {
                        Text("Grade %")
                        TextField("90", text: $gradeText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                }
                if let o = original {
                    Button("Delete class", role: .destructive) { store.removeExtra(o.id); dismiss() }
                }
            }
            .navigationTitle(original == nil ? "Add class" : "Edit class").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.saveExtra(ExtraCourse(id: original?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespaces),
                                                    level: level.rawValue, credits: credits, grade: Double(gradeText) ?? 0))
                        dismiss()
                    }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

struct GradesView: View {
    @EnvironmentObject var store: Store
    @State private var showAdd = false
    @State private var showProfiles = false
    @State private var confirmRemove = false
    @State private var renaming: Course?
    @State private var renameText = ""
    @State private var editingExtra: ExtraCourse?
    @State private var addingExtra = false

    var showSlider: Bool { !store.isDemo && store.quarterOptions.count > 1 }

    var body: some View {
        NavigationStack {
            Group {
                if showSlider && store.quarterBar == "left" {
                    HStack(spacing: 0) {
                        QuarterSlider(vertical: true).frame(width: 60).padding(.vertical, 16)
                        gradeList
                    }
                } else if showSlider {
                    VStack(spacing: 0) {
                        QuarterSlider(vertical: false).frame(height: 60).padding(.horizontal, 12)
                        gradeList
                    }
                } else {
                    gradeList
                }
            }
            .themed()
            .navigationTitle(store.quarter > 0 && showSlider ? "Grades · Q\(store.quarter)" : "Grades")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { GPATabView() } label: { Label("GPA", systemImage: "graduationcap") }
                }
            }
            .sheet(isPresented: $showAdd) { HACLoginView(unlockProfileID: nil) }
            .sheet(isPresented: $showProfiles) { ProfilesSheet() }
            .sheet(item: $editingExtra) { ExtraEditor(extra: $0) }
            .sheet(isPresented: $addingExtra) { ExtraEditor(extra: nil) }
            .alert("Rename class", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Class name", text: $renameText)
                Button("Save") { if let c = renaming { store.rename(c.name, to: renameText) }; renaming = nil }
                Button("Cancel", role: .cancel) { renaming = nil }
            } message: { Text("Only changes how the name looks in StudyAI. Leave it empty to restore the original.") }
            .confirmationDialog("Remove \(store.profileLabel)?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove profile and its data", role: .destructive) { store.deleteProfile(store.currentID) }
            } message: { Text("This deletes its saved password, settings, plans, and chats from this phone.") }
        }
    }

    var gradeList: some View {
        List {
            if store.students.count > 1 {
                Section(footer: Text("Parent account: switch between children.")) {
                    Menu {
                        ForEach(store.students) { s in
                            Button { Task { await store.selectStudent(s.id) } } label: {
                                if s.id == store.currentStudent?.id { Label(s.name, systemImage: "checkmark") } else { Text(s.name) }
                            }
                        }
                    } label: {
                        HStack {
                            Label("Student", systemImage: "person.2")
                            Spacer()
                            Text(store.currentStudent?.name ?? "Choose").foregroundStyle(.secondary)
                            Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            ChangesSection()
            PredictBanner()
            if !store.isDemo && store.courses.isEmpty && !store.loadingQuarter {
                Section {
                    if !store.statusNote.isEmpty {
                        Text(store.statusNote).foregroundStyle(.secondary)
                        if !store.quarterDebug.isEmpty {
                            Button("Copy debug info") { UIPasteboard.general.string = store.quarterDebug }
                        }
                    } else if store.liveCourses.isEmpty {
                        Text("No grades loaded yet for \(store.profileLabel).").foregroundStyle(.secondary)
                        Button("Enter password to load grades") { store.needsLogin = true }
                    }
                }
            }
            Section(footer: Text(store.isDemo ? "Guest profile: demo data, not connected to HAC."
                                              : "Loaded from HAC for \(store.profileLabel) and stored only on this phone.")) {
                ForEach(store.courses) { c in
                    NavigationLink {
                        CourseDetailView(courseID: c.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(store.nm(c.name))
                                Text(store.level(c).rawValue).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if store.isWhatIf(c) {
                                Text("Predicted").font(.caption2.bold()).foregroundStyle(.purple)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.purple.opacity(0.15), in: Capsule())
                            } else if let ch = store.changes.first(where: { $0.course == c.name }), abs(ch.delta) >= 0.05 {
                                Text(String(format: "%+.1f", ch.delta)).font(.caption.bold())
                                    .foregroundStyle(ch.delta >= 0 ? Color.green : Color.red)
                            }
                            HStack(spacing: 4) {
                                GradeBadge(pct: store.displayGrade(c))
                                Text("HAC \(pct1(c.grade))").font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .contextMenu {
                        Button { renameText = store.nm(c.name); renaming = c } label: { Label("Rename", systemImage: "pencil") }
                        if store.nameOverrides[c.name] != nil {
                            Button { store.rename(c.name, to: "") } label: { Label("Reset name", systemImage: "arrow.uturn.backward") }
                        }
                    }
                }
            }
            Section("Extra classes") {
                ForEach(store.extras) { e in
                    Button { editingExtra = e } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(e.name).foregroundStyle(.primary)
                                Text("\(e.level) · \(fmt(e.credits)) cr").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            GradeBadge(pct: e.grade)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { store.removeExtra(e.id) } label: { Label("Delete", systemImage: "trash") }
                    }
                }
                Button { addingExtra = true } label: { Label("Add extra class", systemImage: "plus.circle") }
            }
            Section {
                if store.isDemo {
                    Button("Sign in to HAC (add profile)") { showAdd = true }
                } else {
                    Button("Refresh grades") { Task { await store.refreshHAC(force: true) } }
                }
                Button("Switch or add profile") { showProfiles = true }
                if !store.isDemo {
                    if store.currentProfile?.savePassword == true {
                        Button("Forget saved password") { store.forgetPassword() }
                    }
                    Button("Remove this profile", role: .destructive) { confirmRemove = true }
                }
            }
        }
        .refreshable { if !store.isDemo { await store.refreshHAC(force: true) } }
        .overlay {
            if store.loadingQuarter {
                ProgressView().padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

import SwiftUI

struct Profile: Codable, Identifiable {
    var id: String
    var name: String
    var savePassword: Bool
    var created: Date
    var district: String? = nil     // nil means St. Johns (profiles made before districts existed)
}

extension Store {
    var currentProfile: Profile? { profiles.first { $0.id == currentID } }
    var profileLabel: String { currentID == "guest" ? "Guest" : (currentProfile?.name ?? "Profile") }
    var currentStudent: HACStudent? { students.first { $0.id == studentID } ?? students.first { $0.selected } }

    /// Puts freshly loaded HAC data (HAC's current quarter) into the app for the current profile.
    @MainActor func apply(_ r: HACResult, notify: Bool) {
        liveCourses = r.courses
        assessments = r.assessments
        quarterOptions = r.quarters.map { $0.number }.sorted()
        hacQuarter = r.currentQuarter
        quarterCache = [:]
        if let q = r.currentQuarter { quarterCache[q] = r.courses }
        for c in r.courses where !concepts.contains(where: { $0.course == c.name }) {
            concepts.append(Concept(course: c.name, name: "General review", mastery: 70))
        }
        isDemo = false
        needsLogin = false
        // Show the quarter the user left on, else the one HAC shows, else the first one.
        let saved: Int? = Store.get("quarter.last")
        let want = saved.flatMap { quarterOptions.contains($0) ? $0 : nil } ?? r.currentQuarter ?? quarterOptions.first
        if let w = want, w != r.currentQuarter {
            quarter = w
            courses = quarterCache[w] ?? []
            Task { await self.loadQuarter(w) }
        } else {
            quarter = r.currentQuarter ?? 0
            courses = r.courses
        }
        trackChanges(r.courses, notify: notify, quarter: r.currentQuarter)
        scheduleReminders()
        UserDefaults.standard.set(Date(), forKey: Store.pk("lastCheck"))
        UserDefaults.standard.set(UIApplication.shared.applicationState == .active ? "app open" : "background",
                                  forKey: Store.pk("lastCheckSource"))
    }

    /// Reloads grades for the current profile using its saved password (or the one typed this session).
    @MainActor func refreshHAC(force: Bool = false, notify: Bool = false) async {
        guard currentID != "guest", let u = Keychain.load("hac.user.\(currentID)") else { return }
        guard let p = Keychain.load("hac.pass.\(currentID)") ?? sessionPass else { needsLogin = true; return }
        if !force && Date().timeIntervalSince(lastFetch) < 15 { return }
        lastFetch = Date()
        do {
            let client = HACClient(district: District.find(currentProfile?.district))
            try await client.login(username: u, password: p)
            let st = await client.fetchStudents()
            let serverPick = st.first(where: { $0.selected })?.id
            if let sid = studentID, st.count > 1, st.contains(where: { $0.id == sid }), serverPick != sid {
                try? await client.switchStudent(id: sid)
            }
            let r = try await client.loadAssignmentsChecked()
            hacClient = client
            let current = studentID ?? serverPick
            students = st.map { var s = $0; s.selected = (s.id == current); return s }
            apply(r, notify: notify)
        } catch HACError.badLogin {
            needsLogin = true
        } catch {}
    }

    // MARK: quarters
    /// Called when the user moves the quarter slider.
    @MainActor func selectQuarter(_ q: Int) {
        guard q != quarter else { return }
        quarter = q
        Store.put(q, "quarter.last")
        Task { await loadQuarter(q) }
    }
    /// Loads one quarter's classwork and averages, like picking it in HAC's "Report Card Run" and pressing Refresh View.
    @MainActor func loadQuarter(_ q: Int) async {
        if let c = quarterCache[q] { if quarter == q { courses = c }; return }
        if hacClient == nil { await refreshHAC(force: true) }
        if let c = quarterCache[q] { if quarter == q { courses = c }; return }
        guard let client = hacClient else { return }
        loadingQuarter = true
        defer { loadingQuarter = false }
        do {
            let r = try await client.loadQuarter(q)
            quarterDebug = r.debug
            // If HAC still shows a different quarter, the switch didn't work. Don't show the wrong grades.
            if let cq = r.currentQuarter, cq != q {
                if quarter == q { courses = []; statusNote = "HAC didn't switch to quarter \(q) (it still shows quarter \(cq)). Tap Copy debug info and send it to me." }
                return
            }
            quarterCache[q] = r.courses
            if quarter == q { courses = r.courses; statusNote = r.courses.isEmpty ? "No grades are posted for quarter \(q) yet." : "" }
        } catch {
            var reason = error.localizedDescription
            if case HACError.parse(let d) = error {
                quarterDebug = d
                reason = String(d.split(separator: "\n").first ?? "")
            } else {
                quarterDebug = "\(error)"
            }
            if quarter == q { courses = []; statusNote = "Couldn't load quarter \(q): \(reason)" }
        }
    }

    // MARK: parent accounts
    @MainActor func selectStudent(_ id: String) async {
        guard let client = hacClient, id != currentStudent?.id else { return }
        loadingQuarter = true
        defer { loadingQuarter = false }
        do {
            try await client.switchStudent(id: id)
            studentID = id
            students = students.map { var s = $0; s.selected = (s.id == id); return s }
            transcript = []; tOverrides = [:]; aiDecisions = [:]
            let r = try await client.loadAssignmentsChecked()
            apply(r, notify: false)
        } catch {
            statusNote = "Couldn't switch students. Copy the student picker info in Settings and send it to me."
        }
    }
    @MainActor func loadStudents() async {
        guard let c = hacClient else { return }
        let st = await c.fetchStudents()
        let current = studentID ?? st.first(where: { $0.selected })?.id
        students = st.map { var s = $0; s.selected = (s.id == current); return s }
    }

    // MARK: extra classes
    func saveExtra(_ e: ExtraCourse) {
        if let i = extras.firstIndex(where: { $0.id == e.id }) { extras[i] = e } else { extras.append(e) }
    }
    func removeExtra(_ id: UUID) { extras.removeAll { $0.id == id } }

    // MARK: profiles
    @MainActor func switchProfile(_ id: String) async {
        UserDefaults.standard.set(id, forKey: "profiles.current")
        reloadProfile()
        scheduleReminders()
        BG.schedule()
        await refreshHAC(force: true)
    }

    /// Makes a new profile after a successful login. It starts with the preferences of the profile in use.
    @MainActor func createProfile(name: String, username: String, password: String, save: Bool,
                                  district: String, result: HACResult, client: HACClient?) {
        let id = UUID().uuidString
        for k in Store.prefKeys {
            if let v = UserDefaults.standard.object(forKey: Store.pk(k)) {
                UserDefaults.standard.set(v, forKey: Store.pk(k, id))
            }
        }
        let clean = name.trimmingCharacters(in: .whitespaces)
        profiles.append(Profile(id: id, name: clean.isEmpty ? username : clean, savePassword: save, created: Date(), district: district))
        Keychain.save(username, for: "hac.user.\(id)")
        if save { Keychain.save(password, for: "hac.pass.\(id)") }
        UserDefaults.standard.set(id, forKey: "profiles.current")
        reloadProfile()
        sessionPass = password
        hacClient = client
        apply(result, notify: false)
        Task { await loadStudents() }
    }

    /// Finishes signing back in to a profile that asked for its password.
    @MainActor func unlock(_ id: String, password: String, save: Bool, result: HACResult, client: HACClient?) {
        if save { Keychain.save(password, for: "hac.pass.\(id)") } else { Keychain.delete("hac.pass.\(id)") }
        if let i = profiles.firstIndex(where: { $0.id == id }) { profiles[i].savePassword = save }
        sessionPass = password
        hacClient = client
        apply(result, notify: false)
        Task { await loadStudents() }
    }

    @MainActor func forgetPassword() {
        Keychain.delete("hac.pass.\(currentID)")
        if let i = profiles.firstIndex(where: { $0.id == currentID }) { profiles[i].savePassword = false }
    }

    func renameProfile(_ id: String, to name: String) {
        let t = name.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty, let i = profiles.firstIndex(where: { $0.id == id }) { profiles[i].name = t }
    }

    /// Removes the profile's saved password, settings, plans, and chats from this phone.
    @MainActor func deleteProfile(_ id: String) {
        Keychain.delete("hac.user.\(id)"); Keychain.delete("hac.pass.\(id)")
        let d = UserDefaults.standard
        for k in d.dictionaryRepresentation().keys where k.hasPrefix("p.\(id).") { d.removeObject(forKey: k) }
        let wasCurrent = currentID == id
        profiles.removeAll { $0.id == id }
        if wasCurrent {
            d.set("guest", forKey: "profiles.current")
            reloadProfile()
            scheduleReminders()
        }
    }

    // MARK: page structure for troubleshooting
    @MainActor func runInspector(_ which: String) async -> String {
        guard currentID != "guest", let u = Keychain.load("hac.user.\(currentID)"),
              let p = Keychain.load("hac.pass.\(currentID)") ?? sessionPass else { return "" }
        let c = HACClient(district: District.find(currentProfile?.district))
        do { try await c.login(username: u, password: p) } catch { return "Login failed." }
        return await c.inspect(which)
    }
}

// MARK: Sign in
struct HACLoginView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    var unlockProfileID: String? = nil      // nil = add a new profile
    @State private var user = ""
    @State private var pass = ""
    @State private var nickname = ""
    @State private var districtID: String? = nil
    @State private var errorText = ""
    @State private var debugText = ""
    @State private var busy = false
    @State private var pending: HACResult?
    @State private var pendingClient: HACClient?
    @State private var askSave = false

    var profile: Profile? { unlockProfileID.flatMap { id in store.profiles.first { $0.id == id } } }
    var username: String { profile.flatMap { Keychain.load("hac.user.\($0.id)") } ?? user }

    var body: some View {
        NavigationStack {
            Form {
                if profile == nil {
                    Section(header: Text("Choose your district"),
                            footer: Text("Only St. Johns County is available right now. More districts may be added later.")) {
                        ForEach(District.all) { d in
                            Button { districtID = d.id } label: {
                                HStack {
                                    Text(d.name).foregroundStyle(.primary)
                                    Spacer()
                                    if districtID == d.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                                }
                            }
                        }
                    }
                }
                Section(footer: Text("Your login goes only to your school's HAC site. You'll be asked whether to save the password on this phone's Keychain. StudyAI has no server that sees it.")) {
                    if let p = profile {
                        LabeledContent("Profile", value: p.name)
                        LabeledContent("District", value: District.find(p.district).short)
                        LabeledContent("HAC username", value: username)
                    } else {
                        TextField("HAC username", text: $user)
                            .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Profile name (optional)", text: $nickname)
                    }
                    SecureField("HAC password", text: $pass).textContentType(.password)
                }
                if !errorText.isEmpty { Text(errorText).foregroundStyle(.red) }
                if !debugText.isEmpty { Button("Copy debug info") { UIPasteboard.general.string = debugText } }
                Button(busy ? "Signing in…" : "Sign in") { signIn() }
                    .disabled((profile == nil && (user.isEmpty || districtID == nil)) || pass.isEmpty || busy)
            }
            .themed()
            .navigationTitle(profile == nil ? "Add profile" : "Enter password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .alert("Save password?", isPresented: $askSave) {
                Button("Save password") { finish(save: true) }
                Button("Not now", role: .cancel) { finish(save: false) }
            } message: {
                Text("Next time this profile opens, StudyAI signs in for you. The password stays in this iPhone's Keychain, on this device only.")
            }
        }
    }

    func signIn() {
        busy = true; errorText = ""; debugText = ""
        let u = username, p = pass
        Task {
            do {
                let client = HACClient(district: District.find(profile?.district ?? districtID))
                pending = try await client.loadAll(username: u, password: p)
                pendingClient = client
                askSave = true
            }
            catch HACError.badLogin(let d) { errorText = "Login didn't go through (wrong password, or the form changed)."; debugText = d }
            catch HACError.parse(let d) { debugText = d; errorText = "Signed in, but couldn't read grades. The page layout may differ." }
            catch { errorText = "Couldn't reach HAC." }
            busy = false
        }
    }

    func finish(save: Bool) {
        guard let r = pending else { return }
        if let p = profile { store.unlock(p.id, password: pass, save: save, result: r, client: pendingClient) }
        else { store.createProfile(name: nickname, username: user, password: pass, save: save, district: districtID ?? District.stJohns.id, result: r, client: pendingClient) }
        dismiss()
    }
}

// MARK: Profile list
struct ProfileRow: View {
    @Environment(\.appAccent) private var accent
    let name: String
    let sub: String
    let selected: Bool
    var body: some View {
        HStack(spacing: 12) {
            Text(String(name.prefix(1)).uppercased()).font(.headline).foregroundStyle(.white)
                .frame(width: 36, height: 36).background(Circle().fill(accent))
            VStack(alignment: .leading) {
                Text(name).foregroundStyle(.primary)
                Text(sub).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(accent) }
        }
    }
}

struct ProfilesSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State private var showAdd = false
    @State private var renaming: Profile?
    @State private var renameText = ""
    @State private var deleting: Profile?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            List {
                Section(footer: Text("Each profile keeps its own HAC login, theme, class names, plans, predictions, and chats on this phone.")) {
                    Button { choose("guest") } label: {
                        ProfileRow(name: "Guest", sub: "Sample data, no login", selected: store.currentID == "guest")
                    }
                    ForEach(store.profiles) { p in
                        Button { choose(p.id) } label: {
                            ProfileRow(name: p.name, sub: "\(District.find(p.district).short) · " + (p.savePassword ? "Password saved" : "Asks for password"),
                                       selected: store.currentID == p.id)
                        }
                        .contextMenu {
                            Button { renameText = p.name; renaming = p } label: { Label("Rename", systemImage: "pencil") }
                            Button(role: .destructive) { deleting = p } label: { Label("Delete", systemImage: "trash") }
                        }
                        .swipeActions {
                            Button(role: .destructive) { deleting = p } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
                Section { Button { showAdd = true } label: { Label("Add profile", systemImage: "person.badge.plus") } }
            }
            .themed()
            .navigationTitle("Profiles").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .overlay {
                if busy { ProgressView().padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
            }
            .sheet(isPresented: $showAdd) { HACLoginView(unlockProfileID: nil) }
            .alert("Rename profile", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $renameText)
                Button("Save") { if let p = renaming { store.renameProfile(p.id, to: renameText) }; renaming = nil }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .confirmationDialog("Delete \(deleting?.name ?? "profile")?",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("Delete profile and its data", role: .destructive) {
                    if let p = deleting { store.deleteProfile(p.id) }
                    deleting = nil
                }
            } message: { Text("This removes its saved password, settings, plans, and chats from this phone.") }
        }
    }

    func choose(_ id: String) {
        guard id != store.currentID else { dismiss(); return }
        busy = true
        Task { await store.switchProfile(id); busy = false; dismiss() }
    }
}

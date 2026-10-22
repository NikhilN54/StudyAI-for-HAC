import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var store: Store
    @State private var showShare = false
    @State private var notifStatus = "Checking…"
    @State private var inspectorNote = ""
    @State private var inspecting = false
    @State private var key = Keychain.load("gemini.key") ?? ""
    @State private var model = UserDefaults.standard.string(forKey: "gemini.model2") ?? AIService.defaultModel

    func refreshStatus() async {
        let st = await UNUserNotificationCenter.current().notificationSettings()
        switch st.authorizationStatus {
        case .authorized, .provisional, .ephemeral: notifStatus = "Allowed"
        case .denied: notifStatus = "Off in iPhone Settings"
        case .notDetermined: notifStatus = "Not asked yet"
        @unknown default: notifStatus = "Unknown"
        }
    }
    func sendTest() {
        let c = UNMutableNotificationContent()
        c.title = "StudyAI test"; c.body = "Notifications are working."; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "test-\(UUID().uuidString)", content: c,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)))
    }
    var refreshStatusText: (String, Bool) {
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available: return ("On", true)
        case .denied: return ("Off in iPhone Settings", false)
        default: return ("Restricted", false)
        }
    }
    var lastCheckText: String {
        guard let d = UserDefaults.standard.object(forKey: Store.pk("lastCheck")) as? Date else { return "Never" }
        let src = UserDefaults.standard.string(forKey: Store.pk("lastCheckSource")) ?? ""
        return "\(d.formatted(.dateTime.month().day().hour().minute())) (\(src))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text("Theme, grade alerts, summative share, class names, plans, predictions, and chats are saved separately for each profile. The AI key and app icon are shared on this device.")) {
                    Label("Saved for \(store.profileLabel)", systemImage: "person.crop.circle")
                }
                Section("Appearance") {
                    Picker("Theme", selection: $store.appearance) {
                        Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                    }.pickerStyle(.segmented)
                }
                ThemeSection()
                IconSection()
                Section(header: Text("Grades"),
                        footer: Text("The share of every class grade that comes from summative work. Formative is the rest. Applies to all classes.")) {
                    Stepper("Summative: \(Int((store.summWeight * 100).rounded()))%",
                            value: $store.summWeight, in: 0...1, step: 0.05)
                    Toggle("Skip crossed-out (dropped) grades", isOn: $store.detectDropped)
                        .onChange(of: store.detectDropped) { _, _ in Task { await store.refreshHAC(force: true) } }
                }
                Section(header: Text("Quarters"),
                        footer: Text("Choose where the quarter slider sits on the Grades tab. The app opens on the quarter you left on, or the one HAC shows.")) {
                    Picker("Quarter slider", selection: $store.quarterBar) {
                        Text("Top").tag("top"); Text("Left side").tag("left")
                    }.pickerStyle(.segmented)
                }
                Section(header: Text("GPA")) {
                    Text("St. Johns County scale: A 4.0 (89.5+), B 3.0 (79.5+), C 2.0 (69.5+), D 1.0 (59.5+), F 0. Honors/Pre-AICE adds 0.5 and AP/AICE/IB/Dual Enrollment adds 1.0 to passing grades. An F never gets the bonus.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section(header: Text("Grade alerts"),
                        footer: Text("StudyAI checks HAC and sends a notification when a grade is added or changed. While the app is open it checks on this schedule. When it's closed, iOS decides when to run checks, so they can be later than the interval you pick. Only the profile currently in use is checked.")) {
                    Toggle("Notify me about grade changes", isOn: $store.checkEnabled)
                        .onChange(of: store.checkEnabled) { _, on in on ? BG.schedule() : BG.cancel() }
                    if store.checkEnabled {
                        Picker("Check every", selection: $store.checkMinutes) {
                            Text("15 minutes").tag(15); Text("30 minutes").tag(30); Text("1 hour").tag(60)
                            Text("2 hours").tag(120); Text("4 hours").tag(240)
                        }
                    }
                }
                Section(header: Text("Alert status"),
                        footer: Text("If a row is red, fix it for background grade alerts to work. After tapping the test button, you should get a notification within a few seconds.")) {
                    LabeledContent("Notifications") { Text(notifStatus).foregroundStyle(notifStatus == "Allowed" ? Color.green : Color.red) }
                    LabeledContent("Background setup in app") {
                        Text(BG.ready ? "Ready" : "Missing").foregroundStyle(BG.ready ? Color.green : Color.red)
                    }
                    LabeledContent("Background App Refresh") {
                        Text(refreshStatusText.0).foregroundStyle(refreshStatusText.1 ? Color.green : Color.red)
                    }
                    LabeledContent("Low Power Mode") {
                        Text(ProcessInfo.processInfo.isLowPowerModeEnabled ? "On (pauses checks)" : "Off")
                            .foregroundStyle(ProcessInfo.processInfo.isLowPowerModeEnabled ? Color.red : Color.green)
                    }
                    LabeledContent("Last grade check") { Text(lastCheckText).font(.caption) }
                    Button("Send test notification") { sendTest(); Task { await refreshStatus() } }
                }
                Section(header: Text("HAC page info"),
                        footer: Text("If quarters, the student switcher, or the transcript don't load right, tap a button, then paste the result in a message to me. Letters and numbers on the page are hidden, so it contains no grades or names.\(inspectorNote.isEmpty ? "" : "\n" + inspectorNote)")) {
                    ForEach([("Copy Classwork page info", "assignments"), ("Copy student picker info", "banner"), ("Copy Transcript page info", "transcript")], id: \.1) { item in
                        Button(item.0) {
                            inspecting = true
                            Task {
                                let out = await store.runInspector(item.1)
                                inspecting = false
                                if out.isEmpty { inspectorNote = "Sign in to a real profile first." }
                                else { UIPasteboard.general.string = out; inspectorNote = "Copied. Paste it into a message." }
                            }
                        }.disabled(inspecting)
                    }
                }
                Section(header: Text("Conversations"),
                        footer: Text("When on, this profile's Learn and Understand chats are saved on this phone only.")) {
                    Toggle("Keep conversations saved", isOn: $store.saveChats)
                        .onChange(of: store.saveChats) { _, on in on ? store.persistChats() : store.clearSavedChats() }
                    Button("Clear all conversations", role: .destructive) {
                        store.learnChat = []; store.understandChat = []; store.clearSavedChats()
                    }
                }
                Section(header: Text("AI privacy"),
                        footer: Text("Off by default. When on, the AI receives your class names, averages, summative and formative averages, your lowest two scores per class, and upcoming test dates, so it can tailor advice. It never receives your name, HAC username, or password. This data goes to Google's Gemini API.")) {
                    Toggle("Share my grades with the AI", isOn: Binding(
                        get: { store.shareGrades },
                        set: { on in if on { showShare = true } else { store.shareGrades = false } }))
                }
                Section(header: Text("Gemini AI"),
                        footer: Text("Get a free key at aistudio.google.com (Get API key). The key is stored in this phone's Keychain and requests go straight from your phone to Google. StudyAI has no server. Only your questions and study text are sent, never your HAC login. Grades are sent only if you turn on sharing above. On Google's free tier, prompts may be used to improve their products, so don't type private info.")) {
                    SecureField("API key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Model", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Button("Save AI settings") {
                    Keychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines), for: "gemini.key")
                    UserDefaults.standard.set(model.trimmingCharacters(in: .whitespaces), forKey: "gemini.model2")
                    dismiss()
                }
                Button("Remove key", role: .destructive) { Keychain.delete("gemini.key"); key = "" }
            }
            .themed()
            .navigationTitle("Settings")
            .task { await refreshStatus() }
            .onChange(of: store.checkMinutes) { _, _ in BG.schedule() }
            .alert("Share grades with the AI?", isPresented: $showShare) {
                Button("Share") { store.shareGrades = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your class names, averages, lowest scores, and upcoming tests will be sent to Google's Gemini with your chat messages. On the free tier, Google may use prompts to improve its products. Your name and HAC login are never sent.")
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

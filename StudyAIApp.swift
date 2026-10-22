import SwiftUI
import UserNotifications
import BackgroundTasks

/// Lets notifications show as banners even while the app is open (needed for the test button too).
final class NotifDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotifDelegate()
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

/// Background grade checks for the profile in use. iOS decides the exact timing, so this is best effort.
/// Needs the Background Modes capability and the identifier below in Info (see setup steps).
enum BG {
    static let id = "com.studyai.refresh"
    static var enabled: Bool { UserDefaults.standard.object(forKey: Store.pk("checkEnabled")) as? Bool ?? true }
    static var minutes: Int { let m = UserDefaults.standard.integer(forKey: Store.pk("checkMinutes")); return m > 0 ? m : 30 }
    static var ready: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String])?.contains(id) == true
    }
    static func register() {
        guard ready else { return }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
            Task { @MainActor in
                schedule()
                let work = Task {
                    await Store.shared.refreshHAC(force: true, notify: true)
                    task.setTaskCompleted(success: true)
                }
                task.expirationHandler = { work.cancel() }
            }
        }
    }
    static func schedule() {
        guard ready, enabled else { return }
        let r = BGAppRefreshTaskRequest(identifier: id)
        r.earliestBeginDate = Date(timeIntervalSinceNow: Double(max(minutes, 15)) * 60)
        try? BGTaskScheduler.shared.submit(r)
    }
    static func cancel() { if ready { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: id) } }
}

@main
struct StudyAIApp: App {
    @StateObject private var store = Store.shared
    @Environment(\.scenePhase) private var phase

    init() {
        UNUserNotificationCenter.current().delegate = NotifDelegate.shared
        BG.register()
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $store.tab) {
                HomeView().tabItem { Label("Home", systemImage: "house") }.tag(0)
                UnderstandView().tabItem { Label("Understand", systemImage: "doc.text.viewfinder") }.tag(1)
                LearnView().tabItem { Label("Learn", systemImage: "brain") }.tag(2)
                PlanView().tabItem { Label("Plan", systemImage: "calendar") }.tag(3)
                GradesView().tabItem { Label("Grades", systemImage: "chart.bar") }.tag(4)
            }
            .environmentObject(store)
            .environment(\.appAccent, store.accent)
            .tint(store.accent)
            .preferredColorScheme(store.appearance == "dark" ? .dark : (store.appearance == "light" ? .light : nil))
            .sheet(isPresented: Binding(get: { store.needsLogin && store.currentID != "guest" },
                                        set: { if !$0 { store.needsLogin = false } })) {
                HACLoginView(unlockProfileID: store.currentID)
            }
            .task {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                store.scheduleReminders()
                store.beginSession()
                await store.refreshHAC()
                BG.schedule()
                await pollWhileOpen()
            }
            .onChange(of: phase) { _, p in
                if p == .active { store.beginSession(); Task { await store.refreshHAC() } }
                if p == .background { BG.schedule() }
            }
        }
    }

    /// While the app is open, re-check HAC on the interval chosen in Settings and notify about changes.
    func pollWhileOpen() async {
        var waited = 0
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            waited += 30
            if BG.enabled && waited >= BG.minutes * 60 {
                waited = 0
                await store.refreshHAC(force: true, notify: true)
            }
        }
    }
}

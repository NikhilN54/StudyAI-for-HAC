import SwiftUI
import UserNotifications

func pct1(_ x: Double) -> String { String(format: "%.1f", x) }
private func pctOf(_ s: Double?, _ t: Double) -> Double? { guard let s, t > 0 else { return nil }; return s / t * 100 }

struct ItemChange: Identifiable {
    let id = UUID()
    var name: String
    var oldPct: Double?
    var newPct: Double?
    var isNew: Bool
    var text: String {
        switch (oldPct, newPct) {
        case (nil, let n?): return isNew ? "New grade: \(name), \(pct1(n))%" : "Graded: \(name), \(pct1(n))%"
        case (let o?, let n?): return "\(name): \(pct1(o))% → \(pct1(n))%"
        case (let o?, nil): return "\(name): grade removed (was \(pct1(o))%)"
        default: return "New assignment posted: \(name)"
        }
    }
    var badge: String {
        switch (oldPct, newPct) {
        case (nil, _?): return "New grade"
        case (let o?, _?): return "Was \(pct1(o))%"
        case (_?, nil): return "Grade removed"
        default: return "New assignment"
        }
    }
}

struct CourseChange: Identifiable {
    let id = UUID()
    var course: String
    var oldGrade: Double
    var newGrade: Double
    var items: [ItemChange]
    var delta: Double { newGrade - oldGrade }
}

/// Saved on this phone only. Two copies: what you last saw in the app, and what the last background check saw.
struct ItemSnap: Codable { var score: Double?; var total: Double }
struct CourseSnap: Codable { var grade: Double; var items: [String: ItemSnap] }
struct Snapshot: Codable {
    var courses: [String: CourseSnap]
    var quarter: Int?
    static var seenKey: String { Store.pk("snapshot.seen") }
    static var checkKey: String { Store.pk("snapshot.check") }

    init(_ cs: [Course], quarter: Int? = nil) {
        self.quarter = quarter
        courses = [:]
        for c in cs {
            var items: [String: ItemSnap] = [:]
            for (k, a) in Snapshot.keyed(c.assignments) { items[k] = ItemSnap(score: a.score, total: a.total) }
            courses[c.name] = CourseSnap(grade: c.grade, items: items)
        }
    }
    static func load(_ key: String) -> Snapshot? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
    }
    func save(_ key: String) { if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: key) } }
    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: seenKey)
        UserDefaults.standard.removeObject(forKey: checkKey)
    }

    static func keyed(_ items: [Assignment]) -> [(String, Assignment)] {
        var seen: [String: Int] = [:]
        return items.map { a in
            let base = "\(a.name)|\(Int(a.due?.timeIntervalSince1970 ?? 0))|\(a.category)"
            seen[base, default: 0] += 1
            return (seen[base]! > 1 ? "\(base)#\(seen[base]!)" : base, a)
        }
    }

    static func diff(old: Snapshot, new: [Course], quarter: Int? = nil) -> [CourseChange] {
        if let oq = old.quarter, let nq = quarter, oq != nq { return [] }
        var out: [CourseChange] = []
        for c in new {
            guard let o = old.courses[c.name] else { continue }
            var items: [ItemChange] = []
            for (key, a) in keyed(c.assignments) {
                let n = pctOf(a.score, a.total)
                if let prev = o.items[key] {
                    if prev.score != a.score || prev.total != a.total {
                        items.append(ItemChange(name: a.name, oldPct: pctOf(prev.score, prev.total), newPct: n, isNew: false))
                    }
                } else {
                    items.append(ItemChange(name: a.name, oldPct: nil, newPct: n, isNew: true))
                }
            }
            if abs(c.grade - o.grade) >= 0.005 || !items.isEmpty {
                out.append(CourseChange(course: c.name, oldGrade: o.grade, newGrade: c.grade, items: items))
            }
        }
        return out
    }
}

extension Store {
    /// Call at the start of each time the app is opened.
    @MainActor func beginSession() {
        launchSnapshot = Snapshot.load(Snapshot.seenKey)
        changes = []; checked = false
    }

    /// Called after every successful HAC load.
    /// - notify: send a notification if anything changed since the last check (background and timer checks).
    /// - App open: also show what changed since you last opened it, then remember this as "seen".
    @MainActor func trackChanges(_ new: [Course], notify: Bool, quarter: Int? = nil) {
        let active = UIApplication.shared.applicationState == .active
        if notify, let prev = Snapshot.load(Snapshot.checkKey) {
            let d = Snapshot.diff(old: prev, new: new, quarter: quarter)
            if !d.isEmpty { postGradeNotification(d) }
        }
        Snapshot(new, quarter: quarter).save(Snapshot.checkKey)
        if active {
            if let old = launchSnapshot { changes = Snapshot.diff(old: old, new: new, quarter: quarter); checked = true }
            Snapshot(new, quarter: quarter).save(Snapshot.seenKey)
        }
    }

    func postGradeNotification(_ diffs: [CourseChange]) {
        let c = UNMutableNotificationContent()
        let who = profiles.count > 1 ? "\(profileLabel): " : ""
        c.title = who + (diffs.count == 1 ? "Grade update: \(nm(diffs[0].course))" : "Grade updates in \(diffs.count) classes")
        c.body = diffs.prefix(3).map { d in
            var line = "\(nm(d.course)) \(pct1(d.oldGrade))% → \(pct1(d.newGrade))% (\(String(format: "%+.1f", d.delta)))"
            if let first = d.items.first { line += " · " + first.text }
            return line
        }.joined(separator: "\n")
        c.sound = .default
        // trigger nil = deliver right away. The "grade-" prefix keeps study reminders from ever cancelling it.
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "grade-\(UUID().uuidString)", content: c, trigger: nil))
    }
}

struct ChangesSection: View {
    @EnvironmentObject var store: Store
    var body: some View {
        if !store.changes.isEmpty {
            Section {
                ForEach(store.changes) { c in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(store.nm(c.course)).font(.headline)
                            Spacer()
                            Text("\(pct1(c.oldGrade))% → \(pct1(c.newGrade))%").font(.subheadline)
                            Text(String(format: "%+.1f", c.delta)).font(.subheadline.bold())
                                .foregroundStyle(c.delta >= 0 ? Color.green : Color.red)
                        }
                        ForEach(c.items) { Text($0.text).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Button("Mark all as seen") { store.changes = [] }
            } header: { Text("New since you last opened") }
            footer: { Text("Compared with the last time you opened StudyAI.") }
        } else if store.checked {
            Section { Text("No grade changes since you last opened the app.").foregroundStyle(.secondary) }
        }
    }
}

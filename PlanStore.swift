import SwiftUI
import UserNotifications

extension Store {
    static func classify(_ a: Assignment) -> PlanKind {
        let n = a.name.lowercased()
        if n.contains("test") || n.contains("exam") { return .test }
        if n.contains("quiz") { return .quiz }
        if a.isSummative { return .test }
        return .homework
    }

    /// Everything due or upcoming: ungraded HAC assignments plus items the student added or scanned.
    var planEntries: [PlanEntry] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        var out: [PlanEntry] = []
        if isDemo {
            for a in assessments {
                let day = cal.startOfDay(for: a.date)
                let id = "demo:\(a.course)|\(a.title)|\(Int(day.timeIntervalSince1970))"
                let t = a.title.lowercased()
                let guess: PlanKind = t.contains("quiz") ? .quiz : (t.contains("test") ? .test : .homework)
                let kind = planPrefs[id]?.kind ?? guess
                out.append(PlanEntry(id: id, course: a.course, title: a.title, kind: kind, date: day,
                                     remindDays: planPrefs[id]?.remindDays ?? kind.defaultRemind,
                                     done: planPrefs[id]?.done ?? false, isCustom: false))
            }
        } else {
            for c in liveCourses {
                for (key, a) in Snapshot.keyed(c.assignments) {
                    guard a.score == nil, let due = a.due, due >= today else { continue }
                    let id = "hac:\(c.name)|\(key)"
                    let kind = planPrefs[id]?.kind ?? Store.classify(a)
                    out.append(PlanEntry(id: id, course: c.name, title: a.name, kind: kind, date: due,
                                         remindDays: planPrefs[id]?.remindDays ?? kind.defaultRemind,
                                         done: planPrefs[id]?.done ?? false, isCustom: false))
                }
            }
        }
        for ci in customItems {
            out.append(PlanEntry(id: ci.id.uuidString, course: ci.course, title: ci.title, kind: ci.kind,
                                 date: cal.startOfDay(for: ci.date), remindDays: ci.remindDays,
                                 done: ci.done, isCustom: true))
        }
        return out.sorted { $0.date != $1.date ? $0.date < $1.date : $0.title < $1.title }
    }

    func updateEntry(_ e: PlanEntry) {
        if e.isCustom {
            if let i = customItems.firstIndex(where: { $0.id.uuidString == e.id }) {
                var c = customItems[i]
                c.course = e.course; c.title = e.title; c.kind = e.kind
                c.date = Calendar.current.startOfDay(for: e.date)
                c.remindDays = e.remindDays.sorted(); c.done = e.done
                customItems[i] = c
            }
        } else {
            var p = planPrefs[e.id] ?? ItemPrefs()
            p.remindDays = e.remindDays.sorted(); p.done = e.done; p.kind = e.kind
            planPrefs[e.id] = p
        }
    }
    func addCustom(_ item: CustomItem) {
        var c = item
        c.date = Calendar.current.startOfDay(for: item.date)
        customItems.append(c)
    }
    func removeCustom(_ id: String) { customItems.removeAll { $0.id.uuidString == id } }

    /// One notification per reminder day on every item (4:00 PM), kept inside StudyAI, not the iPhone Calendar.
    /// Only notifications whose id starts with "plan-" are replaced, so grade alerts are never cancelled.
    func scheduleReminders() {
        let center = UNUserNotificationCenter.current()
        let cal = Calendar.current
        var reqs: [(Date, UNNotificationRequest)] = []
        for e in planEntries where !e.done {
            let p = priorities.first(where: { $0.course == e.course })
            for d in e.remindDays {
                guard let day = cal.date(byAdding: .day, value: -d, to: e.date),
                      let fire = cal.date(bySettingHour: 16, minute: 0, second: 0, of: day), fire > .now else { continue }
                let when = d == 0 ? "today" : (d == 1 ? "tomorrow" : "in \(d) days")
                let c = UNMutableNotificationContent()
                let who = e.course.isEmpty ? "Study reminder:" : nm(e.course)
                c.title = e.kind == .homework ? "\(who) homework due \(when)" : "\(who) \(e.kind.label.lowercased()) \(when)"
                var body = e.title
                if let t = p?.concept?.name { body += ". Focus on \(t)." }
                if let m = p?.minutes { body += " \(m) minutes is enough." }
                c.body = body
                c.sound = .default
                let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                reqs.append((fire, UNNotificationRequest(identifier: "plan-\(e.id)-\(d)", content: c, trigger: trigger)))
            }
        }
        let toAdd = reqs.sorted { $0.0 < $1.0 }.prefix(60).map { $0.1 }
        let migrated = UserDefaults.standard.bool(forKey: "notifIdsV2")
        center.getPendingNotificationRequests { pending in
            if migrated {
                center.removePendingNotificationRequests(withIdentifiers: pending.map { $0.identifier }.filter { $0.hasPrefix("plan-") })
            } else {
                center.removeAllPendingNotificationRequests()     // one-time cleanup of older reminders
                UserDefaults.standard.set(true, forKey: "notifIdsV2")
            }
            for r in toAdd { center.add(r) }
        }
    }
}

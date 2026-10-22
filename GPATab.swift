import SwiftUI

// MARK: Transcript GPA logic (St. Johns County rules)
extension Store {
    static let rulePrompt = """
    You check which transcript courses count toward a St. Johns County School District (Florida) high school GPA. \
    Rules: GPA = sum of (grade points x credits) divided by total credits, over high school courses. Middle school \
    courses count only when they are high school credit courses on the high school transcript. Standard grade points: \
    A 4, B 3, C 2, D 1, F 0, Incomplete 0. Honors courses add 0.5. AP, Dual Enrollment (DE), AICE, and IB courses add 1.0. \
    An F never gets the extra weight. Grades NG (no grade), WP (withdrew passing), and WF (withdrew failing) do not count. \
    Courses with no credit or no letter or numeric grade do not count. Decide for each course whether it counts, its level \
    (regular, honors, or ap) from its name and code, and give a short reason. Reply with ONLY a JSON array, no markdown: \
    [{"key": "<the number I gave>", "counts": true or false, "level": "regular" or "honors" or "ap", "reason": "<short>"}]
    """

    func tKey(_ c: TCourse) -> String { c.id }

    func tLevel(_ c: TCourse) -> Level {
        if let l = tOverrides[c.id]?.level, let lv = Level(rawValue: l) { return lv }
        if let d = aiDecisions[c.id] {
            switch d.level.lowercased() { case "ap": return .ap; case "honors": return .honors; default: return .regular }
        }
        return Level.detect(c.name + " " + c.code)
    }

    /// Base grade points for one printed mark, or nil when the mark doesn't count (NG, WP, WF, blank).
    func markPoints(_ m: String) -> Double? {
        let t = m.trimmingCharacters(in: .whitespaces).uppercased()
        if t.isEmpty || ["NG", "WP", "WF", "W", "AU", "P", "NC"].contains(t) { return nil }
        if t == "I" || t == "INC" { return 0 }
        if let d = Double(t) { return gradeInfo(d).points }
        let pts: [Character: Double] = ["A": 4, "B": 3, "C": 2, "D": 1, "F": 0]
        if let f = t.first, let v = pts[f] { return v }
        return nil
    }

    /// Course points averaged over its marks. The honors/AP bonus is added to each passing mark.
    func coursePoints(_ c: TCourse, level: Level) -> (u: Double, w: Double)? {
        let ps = c.marks.compactMap { markPoints($0) }
        guard !ps.isEmpty else { return nil }
        let n = Double(ps.count)
        return (ps.reduce(0, +) / n, ps.map { $0 > 0 ? $0 + level.bonus : 0 }.reduce(0, +) / n)
    }

    func tCounts(_ c: TCourse) -> (counts: Bool, reason: String) {
        if let o = tOverrides[c.id]?.counts { return (o, "Set by you") }
        if coursePoints(c, level: .regular) == nil { return (false, "No usable grade (NG, WP, WF, or blank).") }
        if c.credits <= 0 { return (false, "No credit listed.") }
        if let d = aiDecisions[c.id] { return (d.counts, d.reason) }
        return (true, "Counts by default (AI check not run yet).")
    }

    struct CumulativeGPA { var unweighted: Double; var weighted: Double; var credits: Double; var counted: Int; var skipped: Int }

    func cumulativeGPA() -> CumulativeGPA? {
        var qu = 0.0, qw = 0.0, cr = 0.0, n = 0, skipped = 0
        for c in transcript {
            let (counts, _) = tCounts(c)
            guard counts, let p = coursePoints(c, level: tLevel(c)) else { skipped += 1; continue }
            qu += p.u * c.credits; qw += p.w * c.credits; cr += c.credits; n += 1
        }
        if includeExtras {
            for e in extras {
                let p = gpaPoints(e.grade, level: e.lvl)
                qu += p.unweighted * e.credits; qw += p.weighted * e.credits; cr += e.credits; n += 1
            }
        }
        return cr > 0 ? CumulativeGPA(unweighted: qu / cr, weighted: qw / cr, credits: cr, counted: n, skipped: skipped) : nil
    }

    func setOverride(_ id: String, counts: Bool?? = nil, level: Level?? = nil) {
        var o = tOverrides[id] ?? TOverride()
        if let c = counts { o.counts = c }
        if let l = level { o.level = l?.rawValue }
        tOverrides[id] = (o.counts == nil && o.level == nil) ? nil : o
    }

    static let transcriptDown = "Transcript page is unavailable right now. Please try again later."

    @MainActor func loadTranscript() async {
        guard currentID != "guest" else { transcriptStatus = "Sign in with a real profile to load your transcript."; return }
        transcriptBusy = true
        transcriptDebug = ""
        defer { transcriptBusy = false }
        if hacClient == nil { await refreshHAC(force: true) }
        guard let client = hacClient else {
            transcriptStatus = needsLogin ? "Enter your password to load your transcript." : Store.transcriptDown
            return
        }
        do {
            let t = try await client.fetchTranscript()
            transcript = t
            transcriptStatus = "Loaded \(t.count) courses from your HAC transcript."
            await runRuleCheck()
        } catch {
            if case HACError.parse(let d) = error { transcriptDebug = d } else { transcriptDebug = "\(error)" }
            transcriptStatus = Store.transcriptDown
        }
    }

    /// Asks the AI which courses count under St. Johns County rules. Only course names, codes, credits,
    /// and non-numeric marks (like NG or WP) are sent, never grades.
    @MainActor func runRuleCheck(force: Bool = false) async {
        let todo = transcript.filter { force || aiDecisions[$0.id] == nil }
        guard !todo.isEmpty else { return }
        guard !AIService.apiKey.isEmpty else {
            transcriptStatus += "\nAdd a Gemini key in Settings so the AI can check which courses count. Default rules are used for now."
            return
        }
        transcriptBusy = true
        defer { transcriptBusy = false }
        var lines: [String] = []
        for (i, c) in todo.enumerated() {
            let markers = c.marks.filter { Double($0) == nil }.joined(separator: "/")
            lines.append("\(i) | grade level \(c.gradeLevel) | \(c.code) | \(c.name) | \(fmt(c.credits)) credits | markers: \(markers)")
        }
        let reply = await AIService.ask(system: Store.rulePrompt, messages: [ChatMessage(role: "user", text: lines.joined(separator: "\n"))])
        guard let a = reply.firstIndex(of: "["), let b = reply.lastIndex(of: "]"), a < b,
              let data = String(reply[a...b]).data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            transcriptStatus += "\nThe AI rule check didn't return a usable answer: \(reply.prefix(120))"
            return
        }
        var found = 0
        for d in arr {
            guard let k = d["key"], let i = Int("\(k)"), i >= 0, i < todo.count else { continue }
            aiDecisions[todo[i].id] = AIDecision(counts: (d["counts"] as? Bool) ?? true,
                                                  level: (d["level"] as? String) ?? "regular",
                                                  reason: (d["reason"] as? String) ?? "")
            found += 1
        }
        transcriptStatus += "\nAI checked \(found) courses against St. Johns County GPA rules."
    }
}

// MARK: GPA tab
struct GPATabView: View {
    @EnvironmentObject var store: Store
    @State private var selected: TCourse?
    @State private var showUnavailable = false

    var groups: [(title: String, courses: [TCourse])] {
        var order: [String] = []
        var map: [String: [TCourse]] = [:]
        for c in store.transcript {
            let title = [c.gradeLevel.isEmpty ? "" : "Grade \(c.gradeLevel)", c.year].filter { !$0.isEmpty }.joined(separator: " · ")
            let key = title.isEmpty ? "Courses" : title
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(c)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    var body: some View {
        Group {
            List {
                if let g = store.gpa {
                    Section {
                        NavigationLink { GPAInsightsView() } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(String(format: "%.2f", g.unweighted)).font(.title2.bold())
                                    Text("Unweighted").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing) {
                                    Text(String(format: "%.2f", g.weighted)).font(.title2.bold())
                                    Text("Weighted").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: { Text(store.quarter > 0 && !store.isDemo && store.quarterOptions.count > 1 ? "Quarter \(store.quarter) GPA" : "Current GPA") }
                      footer: { Text("From the classes on your Grades tab plus your extra classes. Tap for insights on how it was calculated.") }
                }
                Section {
                    if let g = store.cumulativeGPA() {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(String(format: "%.2f", g.unweighted)).font(.system(size: 34, weight: .bold))
                                Text("Unweighted (state) GPA").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text(String(format: "%.2f", g.weighted)).font(.system(size: 34, weight: .bold))
                                Text("Weighted (district) GPA").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text("\(g.counted) courses · \(fmt(g.credits)) credits counted · \(g.skipped) skipped")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(store.currentID == "guest" ? "Sign in to a real profile to see your whole high school GPA."
                                                        : "No completed courses loaded yet.").foregroundStyle(.secondary)
                    }
                    Toggle("Include my extra classes", isOn: $store.includeExtras)
                } header: { Text("Cumulative GPA") }
                  footer: { Text("Completed courses from HAC → Grades → Transcript only. Current-quarter grades are on the Grades tab.") }

                Section {
                    Button {
                        Task {
                            await store.loadTranscript()
                            if store.transcriptStatus == Store.transcriptDown { showUnavailable = true }
                        }
                    } label: { Label("Load transcript from HAC", systemImage: "arrow.clockwise") }
                        .disabled(store.transcriptBusy || store.currentID == "guest")
                    Button { Task { await store.runRuleCheck(force: true) } } label: { Label("Check rules with AI", systemImage: "checkmark.shield") }
                        .disabled(store.transcriptBusy || store.transcript.isEmpty)
                    if store.transcriptBusy { HStack { ProgressView(); Text("Working…").foregroundStyle(.secondary) } }
                    if !store.transcriptStatus.isEmpty { Text(store.transcriptStatus).font(.caption).foregroundStyle(.secondary) }
                    if !store.transcriptDebug.isEmpty {
                        Button("Copy debug info") { UIPasteboard.general.string = store.transcriptDebug }.font(.caption)
                    }
                }

                ForEach(groups, id: \.title) { g in
                    Section(g.title) {
                        ForEach(g.courses) { c in
                            let counts = store.tCounts(c).counts
                            Button { selected = c } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(c.name).foregroundStyle(.primary)
                                        Text("\(c.code) · \(fmt(c.credits)) cr · \(store.tLevel(c).rawValue)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(c.marks.joined(separator: " / ")).font(.subheadline).foregroundStyle(.primary)
                                        Image(systemName: counts ? "checkmark.circle.fill" : "minus.circle")
                                            .foregroundStyle(counts ? Color.green : Color.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                Section(footer: Text("St. Johns County rules: GPA is the sum of course grade points times credits, divided by total credits. A 4, B 3, C 2, D 1, F 0. Honors adds 0.5. AP, Dual Enrollment, AICE, and IB add 1.0. NG, WP, and WF grades are left out. The AI checks each course against these rules, and you can override any course by tapping it.")) { EmptyView() }
            }
            .themed()
            .navigationTitle("GPA")
            .refreshable {
                await store.loadTranscript()
                if store.transcriptStatus == Store.transcriptDown { showUnavailable = true }
            }
            .alert("Transcript unavailable", isPresented: $showUnavailable) {
                Button("OK", role: .cancel) {}
            } message: { Text(Store.transcriptDown) }
            .sheet(item: $selected) { CourseRuleSheet(course: $0) }
        }
    }
}

struct CourseRuleSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let course: TCourse

    var body: some View {
        let result = store.tCounts(course)
        NavigationStack {
            Form {
                Section {
                    Text(course.name).font(.headline)
                    LabeledContent("Course code", value: course.code.isEmpty ? "—" : course.code)
                    LabeledContent("Credits", value: fmt(course.credits))
                    LabeledContent("Marks", value: course.marks.joined(separator: " / "))
                }
                Section(header: Text("Counts toward GPA"), footer: Text(result.reason)) {
                    Toggle("Count this course", isOn: Binding(
                        get: { store.tCounts(course).counts },
                        set: { store.setOverride(course.id, counts: .some($0)) }))
                    Picker("Level", selection: Binding(
                        get: { store.tLevel(course) },
                        set: { store.setOverride(course.id, level: .some($0)) })) {
                        ForEach(Level.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                if store.tOverrides[course.id] != nil {
                    Button("Go back to the AI's decision", role: .destructive) {
                        store.tOverrides[course.id] = nil
                    }
                }
            }
            .navigationTitle("Course").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

import SwiftUI
import Combine
import UserNotifications

final class Store: ObservableObject {
    static let shared = Store()

    // MARK: Per-profile storage. Every saved setting is stored under "p.<profile id>.<name>".
    static let prefKeys = ["themeID", "customRGB", "appearance", "summWeight", "checkEnabled", "checkMinutes", "saveChats", "shareGrades"]
    static let legacyKeys = ["levelOv", "summWeight", "whatIf.v1", "creditOv", "themeID", "customRGB", "nameOv", "plan.custom",
                             "plan.prefs", "shareGrades", "chat.learn", "chat.understand", "saveChats", "appearance",
                             "checkEnabled", "checkMinutes", "snapshot.seen", "snapshot.check", "lastCheck", "lastCheckSource"]

    static let migrationOnce: Void = { Store.migrateLegacy() }()
    static var cid: String { _ = migrationOnce; return UserDefaults.standard.string(forKey: "profiles.current") ?? "guest" }
    static func pk(_ n: String, _ id: String? = nil) -> String { "p.\(id ?? cid).\(n)" }
    static func get<T>(_ n: String) -> T? { UserDefaults.standard.object(forKey: pk(n)) as? T }
    static func put(_ v: Any, _ n: String) { UserDefaults.standard.set(v, forKey: pk(n)) }
    static func loadJSON<T: Decodable>(_ n: String, _ def: T) -> T {
        UserDefaults.standard.data(forKey: pk(n)).flatMap { try? JSONDecoder().decode(T.self, from: $0) } ?? def
    }
    static func saveJSON<T: Encodable>(_ n: String, _ v: T) {
        if let d = try? JSONEncoder().encode(v) { UserDefaults.standard.set(d, forKey: pk(n)) }
    }
    static func loadProfiles() -> [Profile] {
        UserDefaults.standard.data(forKey: "profiles.v1").flatMap { try? JSONDecoder().decode([Profile].self, from: $0) } ?? []
    }
    static func saveProfiles(_ v: [Profile]) {
        if let d = try? JSONEncoder().encode(v) { UserDefaults.standard.set(d, forKey: "profiles.v1") }
    }
    static func loadChat(_ key: String) -> [ChatMessage] {
        guard (Store.get("saveChats") as Bool?) ?? false else { return [] }
        return loadJSON(key, [ChatMessage]())
    }
    static func loadConcepts() -> [Concept] {
        if let d = UserDefaults.standard.data(forKey: pk("concepts.v1")),
           let v = try? JSONDecoder().decode([Concept].self, from: d) { return v }
        return cid == "guest" ? demoConcepts() : []
    }

    /// One-time move of settings saved by older versions into a profile (or the guest profile).
    static func migrateLegacy() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "profilesMigrated") else { return }
        d.set(true, forKey: "profilesMigrated")
        var target = "guest"
        if let u = Keychain.load("hac.user"), let p = Keychain.load("hac.pass") {
            let id = UUID().uuidString
            Keychain.save(u, for: "hac.user.\(id)"); Keychain.save(p, for: "hac.pass.\(id)")
            Keychain.delete("hac.user"); Keychain.delete("hac.pass")
            let prof = Profile(id: id, name: u, savePassword: true, created: Date())
            if let data = try? JSONEncoder().encode([prof]) { d.set(data, forKey: "profiles.v1") }
            target = id
        }
        for k in legacyKeys { if let v = d.object(forKey: k) { d.set(v, forKey: "p.\(target).\(k)") } }
        d.set(target, forKey: "profiles.current")
    }

    // MARK: State
    @Published var profiles: [Profile] = Store.loadProfiles() { didSet { Store.saveProfiles(profiles) } }
    @Published var currentID: String = Store.cid
    @Published var needsLogin = false
    @Published var tab = 0
    @Published var isDemo: Bool = Store.cid == "guest"
    @Published var changes: [CourseChange] = []
    @Published var checked = false
    @Published var activeConcept: Concept?
    var launchSnapshot: Snapshot? = Snapshot.load(Snapshot.seenKey)
    var lastFetch = Date.distantPast
    var sessionPass: String?          // typed this session only, never saved unless the user agrees
    var loading = false

    @Published var levelOverrides: [String: String] = Store.get("levelOv") ?? [:] {
        didSet { Store.put(levelOverrides, "levelOv") } }
    @Published var summWeight: Double = Store.get("summWeight") ?? 0.7 {
        didSet { Store.put(summWeight, "summWeight") } }
    @Published var detectDropped: Bool = Store.get("detectDropped") ?? true {
        didSet { Store.put(detectDropped, "detectDropped") } }
    @Published var shareGrades: Bool = Store.get("shareGrades") ?? false {
        didSet { Store.put(shareGrades, "shareGrades") } }
    @Published var appearance: String = Store.get("appearance") ?? "system" {
        didSet { Store.put(appearance, "appearance") } }
    @Published var checkEnabled: Bool = Store.get("checkEnabled") ?? true {
        didSet { Store.put(checkEnabled, "checkEnabled") } }
    @Published var checkMinutes: Int = Store.get("checkMinutes") ?? 30 {
        didSet { Store.put(checkMinutes, "checkMinutes") } }
    @Published var saveChats: Bool = Store.get("saveChats") ?? false {
        didSet { Store.put(saveChats, "saveChats") } }
    @Published var themeID: String = Store.get("themeID") ?? "default" {
        didSet { Store.put(themeID, "themeID") } }
    @Published var customRGB: [Double] = Store.get("customRGB") ?? [0.2, 0.5, 1.0] {
        didSet { Store.put(customRGB, "customRGB") } }
    @Published var nameOverrides: [String: String] = Store.get("nameOv") ?? [:] {
        didSet { Store.put(nameOverrides, "nameOv") } }
    @Published var creditOverrides: [String: Double] = Store.get("creditOv") ?? [:] {
        didSet { Store.put(creditOverrides, "creditOv") } }
    @Published var whatIf: [String: WhatIf] = Store.loadJSON("whatIf.v1", [String: WhatIf]()) {
        didSet { Store.saveJSON("whatIf.v1", whatIf) } }
    @Published var customItems: [CustomItem] = Store.loadJSON("plan.custom", [CustomItem]()) {
        didSet { Store.saveJSON("plan.custom", customItems); scheduleReminders() } }
    @Published var planPrefs: [String: ItemPrefs] = Store.loadJSON("plan.prefs", [String: ItemPrefs]()) {
        didSet { Store.saveJSON("plan.prefs", planPrefs); scheduleReminders() } }
    @Published var learnChat: [ChatMessage] = Store.loadChat("chat.learn") { didSet { persistChats() } }
    @Published var understandChat: [ChatMessage] = Store.loadChat("chat.understand") { didSet { persistChats() } }
    @Published var concepts: [Concept] = Store.loadConcepts() { didSet { Store.saveJSON("concepts.v1", concepts) } }
    @Published var courses: [Course] = Store.cid == "guest" ? Store.demoCourses() : []
    @Published var assessments: [Assessment] = Store.cid == "guest" ? Store.demoAssessments() : []
    /// HAC's current quarter. The planner and reminders always use this, even while another quarter is on screen.
    @Published var liveCourses: [Course] = Store.cid == "guest" ? Store.demoCourses() : []
    @Published var quarter: Int = 0
    @Published var quarterOptions: [Int] = []
    @Published var loadingQuarter = false
    @Published var quarterBar: String = Store.get("quarterBar") ?? "top" { didSet { Store.put(quarterBar, "quarterBar") } }
    @Published var students: [HACStudent] = []
    @Published var studentID: String? = Store.get("studentID") {
        didSet { if let s = studentID { Store.put(s, "studentID") } else { UserDefaults.standard.removeObject(forKey: Store.pk("studentID")) } } }
    @Published var extras: [ExtraCourse] = Store.loadJSON("extras.v1", [ExtraCourse]()) { didSet { Store.saveJSON("extras.v1", extras) } }
    @Published var includeExtras: Bool = Store.get("inclExtras") ?? false { didSet { Store.put(includeExtras, "inclExtras") } }
    @Published var transcript: [TCourse] = Store.loadJSON("transcript.v1", [TCourse]()) { didSet { Store.saveJSON("transcript.v1", transcript) } }
    @Published var tOverrides: [String: TOverride] = Store.loadJSON("tOv.v1", [String: TOverride]()) { didSet { Store.saveJSON("tOv.v1", tOverrides) } }
    @Published var aiDecisions: [String: AIDecision] = Store.loadJSON("aiDec.v1", [String: AIDecision]()) { didSet { Store.saveJSON("aiDec.v1", aiDecisions) } }
    @Published var transcriptStatus = ""
    @Published var transcriptBusy = false
    @Published var transcriptDebug = ""
    @Published var statusNote = ""
    @Published var quarterDebug = ""
    var hacQuarter: Int?
    var quarterCache: [Int: [Course]] = [:]
    var hacClient: HACClient?

    /// Reloads everything for whichever profile is now current.
    @MainActor func reloadProfile() {
        loading = true
        defer { loading = false }
        currentID = Store.cid
        let guest = currentID == "guest"
        levelOverrides = Store.get("levelOv") ?? [:]
        summWeight = Store.get("summWeight") ?? 0.7
        shareGrades = Store.get("shareGrades") ?? false
        detectDropped = Store.get("detectDropped") ?? true
        appearance = Store.get("appearance") ?? "system"
        checkEnabled = Store.get("checkEnabled") ?? true
        checkMinutes = Store.get("checkMinutes") ?? 30
        saveChats = Store.get("saveChats") ?? false
        themeID = Store.get("themeID") ?? "default"
        customRGB = Store.get("customRGB") ?? [0.2, 0.5, 1.0]
        nameOverrides = Store.get("nameOv") ?? [:]
        creditOverrides = Store.get("creditOv") ?? [:]
        whatIf = Store.loadJSON("whatIf.v1", [String: WhatIf]())
        customItems = Store.loadJSON("plan.custom", [CustomItem]())
        planPrefs = Store.loadJSON("plan.prefs", [String: ItemPrefs]())
        learnChat = Store.loadChat("chat.learn")
        understandChat = Store.loadChat("chat.understand")
        concepts = Store.loadConcepts()
        courses = guest ? Store.demoCourses() : []
        liveCourses = courses
        assessments = guest ? Store.demoAssessments() : []
        isDemo = guest
        quarter = 0; quarterOptions = []; quarterCache = [:]; hacQuarter = nil; hacClient = nil
        students = []; studentID = Store.get("studentID"); statusNote = ""; quarterDebug = ""
        quarterBar = Store.get("quarterBar") ?? "top"
        extras = Store.loadJSON("extras.v1", [ExtraCourse]())
        includeExtras = Store.get("inclExtras") ?? false
        transcript = Store.loadJSON("transcript.v1", [TCourse]())
        tOverrides = Store.loadJSON("tOv.v1", [String: TOverride]())
        aiDecisions = Store.loadJSON("aiDec.v1", [String: AIDecision]())
        transcriptStatus = ""
        launchSnapshot = Snapshot.load(Snapshot.seenKey)
        changes = []; checked = false; activeConcept = nil; needsLogin = false; sessionPass = nil
        lastFetch = .distantPast
    }

    // MARK: Demo data for the guest profile
    static func a(_ n: String, _ c: String, _ s: Double?, _ t: Double, _ w: Double = 1) -> Assignment {
        Assignment(name: n, category: c, score: s, total: t, weight: w)
    }
    static func demoCourses() -> [Course] {
        [Course(name: "Biology HN", grade: 81, trend: [76, 78, 79, 81], assignments: [
            a("Cell test", "Summative", 41, 50), a("Lab report", "Summative", 33, 40, 2),
            a("Osmosis quiz", "Formative", 6, 10), a("Vocab check", "Formative", 9, 10)]),
         Course(name: "Algebra", grade: 74, trend: [86, 81, 78, 74], assignments: [
            a("Unit 3 test", "Summative", 62, 100), a("Quadratics quiz", "Summative", 18, 25),
            a("Homework 7", "Formative", 8, 10), a("Practice set", "Formative", 14, 20)]),
         Course(name: "AP English", grade: 94, trend: [92, 93, 94, 94], assignments: [
            a("Essay 1", "Summative", 47, 50, 2), a("Rhetoric test", "Summative", 46, 50),
            a("Reading check", "Formative", 10, 10), a("Vocab quiz", "Formative", 18, 20)]),
         Course(name: "World History", grade: 88, trend: [84, 86, 87, 88], assignments: [
            a("Unit 2 test", "Summative", 44, 50), a("Document essay", "Summative", 36, 40),
            a("Map quiz", "Formative", 9, 10), a("Reading notes", "Formative", 18, 20)]),
         Course(name: "Spanish 2 HN", grade: 91, trend: [89, 90, 91, 91], assignments: [
            a("Preterite test", "Summative", 46, 50), a("Oral presentation", "Summative", 18, 20),
            a("Vocab quiz", "Formative", 9, 10), a("Workbook p. 40", "Formative", 10, 10)]),
         Course(name: "Chemistry", grade: 77, trend: [82, 80, 78, 77], assignments: [
            a("Stoichiometry test", "Summative", 31, 45), a("Lab report", "Summative", 34, 40),
            a("Balancing quiz", "Formative", 7, 10), a("Practice set", "Formative", 15, 20)]),
         Course(name: "Digital Art", grade: 96, trend: [94, 95, 96, 96], assignments: [
            a("Portfolio piece 1", "Summative", 48, 50), a("Final project", "Summative", 19, 20),
            a("Sketchbook check", "Formative", 10, 10), a("Critique", "Formative", 9, 10)])]
    }
    static func demoAssessments() -> [Assessment] {
        func d(_ n: Int) -> Date { Calendar.current.date(byAdding: .day, value: n, to: .now)! }
        return [Assessment(course: "Algebra", title: "Quiz", date: d(1)),
                Assessment(course: "Biology HN", title: "Test", date: d(3)),
                Assessment(course: "AP English", title: "Quiz", date: d(5)),
                Assessment(course: "Chemistry", title: "Quiz", date: d(2)),
                Assessment(course: "World History", title: "Test", date: d(7)),
                Assessment(course: "Spanish 2 HN", title: "Test", date: d(9))]
    }
    static func demoConcepts() -> [Concept] {
        [Concept(course: "Biology HN", name: "Osmosis", mastery: 60),
         Concept(course: "Biology HN", name: "Hypertonic vs. hypotonic", mastery: 55),
         Concept(course: "Biology HN", name: "Diffusion", mastery: 94),
         Concept(course: "Algebra", name: "Quadratic equations", mastery: 67),
         Concept(course: "AP English", name: "Vocabulary", mastery: 91),
         Concept(course: "World History", name: "Causes of World War I", mastery: 72),
         Concept(course: "Chemistry", name: "Stoichiometry", mastery: 58),
         Concept(course: "Spanish 2 HN", name: "Preterite tense", mastery: 65),
         Concept(course: "Digital Art", name: "Color theory", mastery: 88)]
    }

    // MARK: Chats
    func persistChats() {
        guard !loading, saveChats else { return }
        Store.saveJSON("chat.learn", learnChat.filter { !$0.pending })
        Store.saveJSON("chat.understand", understandChat.filter { !$0.pending })
    }
    func clearSavedChats() {
        UserDefaults.standard.removeObject(forKey: Store.pk("chat.learn"))
        UserDefaults.standard.removeObject(forKey: Store.pk("chat.understand"))
    }

    // MARK: Course settings, predictions and GPA
    func level(_ c: Course) -> Level { levelOverrides[c.name].flatMap(Level.init(rawValue:)) ?? Level.detect(c.name) }
    func setLevel(_ c: Course, _ l: Level) { levelOverrides[c.name] = l.rawValue }

    func isWhatIf(_ c: Course) -> Bool { whatIf[c.name] != nil }
    func setPredict(_ c: Course, _ on: Bool) { whatIf[c.name] = on ? WhatIf() : nil }

    /// Real assignments with this class's predictions applied.
    func rows(_ c: Course) -> [GradeRow] {
        var out = Snapshot.keyed(c.assignments).map { GradeRow(id: $0.0, a: $0.1) }
        guard let w = whatIf[c.name] else { return out }
        for i in out.indices { if let s = w.edits[out[i].id] { out[i].a.score = s; out[i].a.edited = true } }
        out += w.added.map {
            GradeRow(id: "added:\($0.id.uuidString)",
                     a: Assignment(name: $0.name, category: $0.category, score: $0.score, total: $0.total,
                                   weight: $0.weight, isHypothetical: true))
        }
        for i in out.indices where w.exempt.contains(out[i].id) { out[i].a.exempted = true }
        return out
    }
    func setScore(_ c: Course, key: String, value: Double?) {
        var w = whatIf[c.name] ?? WhatIf()
        if key.hasPrefix("added:") {
            let id = String(key.dropFirst(6))
            if let i = w.added.firstIndex(where: { $0.id.uuidString == id }), let v = value { w.added[i].score = v }
        } else { w.edits[key] = value }
        whatIf[c.name] = w
    }
    func addGrade(_ c: Course, _ item: AddedItem) {
        var w = whatIf[c.name] ?? WhatIf(); w.added.append(item); whatIf[c.name] = w
    }
    func removeAdded(_ c: Course, key: String) {
        var w = whatIf[c.name] ?? WhatIf()
        w.added.removeAll { "added:\($0.id.uuidString)" == key }
        whatIf[c.name] = w
    }
    func toggleExempt(_ c: Course, key: String) {
        var w = whatIf[c.name] ?? WhatIf()
        if let i = w.exempt.firstIndex(of: key) { w.exempt.remove(at: i) } else { w.exempt.append(key) }
        whatIf[c.name] = w
    }
    func credits(_ c: Course) -> Double { creditOverrides[c.name] ?? 1.0 }
    func setCredits(_ c: Course, _ v: Double) { creditOverrides[c.name] = v }

    func baseGrade(_ c: Course) -> Double {
        calcAverages(c.assignments, summWeight: summWeight).overall ?? c.grade
    }
    func displayGrade(_ c: Course) -> Double {
        calcAverages(rows(c).map { $0.a }, summWeight: summWeight).overall ?? c.grade
    }

    var gpa: (unweighted: Double, weighted: Double)? {
        var qu = 0.0, qw = 0.0, cr = 0.0
        for c in courses {
            let p = gpaPoints(displayGrade(c), level: level(c)), k = credits(c)
            qu += p.unweighted * k; qw += p.weighted * k; cr += k
        }
        for e in extras {
            let p = gpaPoints(e.grade, level: e.lvl)
            qu += p.unweighted * e.credits; qw += p.weighted * e.credits; cr += e.credits
        }
        return cr > 0 ? (qu / cr, qw / cr) : nil
    }

    // MARK: Planner
    func daysUntil(_ date: Date) -> Int {
        max(0, Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now),
                                               to: Calendar.current.startOfDay(for: date)).day ?? 0)
    }

    var priorities: [Priority] {
        assessments.map { a in
            let grade = liveCourses.first { $0.name == a.course }.map { displayGrade($0) } ?? 85
            let mine = concepts.filter { $0.course == a.course }
            let weakest = mine.min { $0.mastery < $1.mastery }
            let avg = mine.isEmpty ? 80 : mine.map(\.mastery).reduce(0, +) / Double(mine.count)
            let days = daysUntil(a.date)
            let score = 50.0 / Double(days + 1) + (100 - grade) * 0.5 + (100 - avg) * 0.5
            let mins = score > 60 ? 30 : (score > 40 ? 20 : 10)
            let when = days == 0 ? "today" : (days == 1 ? "tomorrow" : "in \(days) days")
            var why = "\(a.title) \(when), grade \(Int(grade))%"
            if let w = weakest { why += ", weakest: \(w.name) (\(Int(w.mastery))%)" }
            return Priority(course: a.course, title: a.title, minutes: mins, reason: why, concept: weakest, score: score)
        }.sorted { $0.score > $1.score }
    }

    func record(_ concept: Concept, correct: Int, total: Int) {
        guard let i = concepts.firstIndex(where: { $0.id == concept.id }) else { return }
        concepts[i].mastery = 0.5 * concepts[i].mastery + 0.5 * (Double(correct) / Double(total) * 100)
        scheduleReminders()
    }
}

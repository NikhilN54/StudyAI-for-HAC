import SwiftUI

enum Level: String, CaseIterable, Identifiable {
    case regular = "Regular", honors = "Honors/Pre-AICE", ap = "AP/AICE/IB/DE"
    var id: String { rawValue }
    var bonus: Double { self == .regular ? 0 : (self == .honors ? 0.5 : 1.0) }
    static func detect(_ name: String) -> Level {
        let n = name.uppercased()
        if n.range(of: #"PRE-?\s?(AP|AICE)|\bHN\b|\bHON(ORS)?\b|\bPAP\b"#, options: .regularExpression) != nil { return .honors }
        if n.range(of: #"\bAP\b|\bIB\b|\bAICE\b|ADV(ANCED)? PLACEMENT|DUAL ENROLL(MENT)?"#, options: .regularExpression) != nil { return .ap }
        return .regular
    }
}

struct Assignment: Identifiable {
    let id = UUID()
    var name: String
    var category: String
    var score: Double?
    var total: Double
    var weight: Double = 1
    var due: Date? = nil
    var isHypothetical = false
    var edited = false
    var exempted = false
    var dropped = false       // crossed out in HAC
    var excluded: Bool { exempted || dropped }
    var isSummative: Bool { category.lowercased().contains("summative") }
}

/// An assignment with a stable id (so text fields keep focus while typing).
struct GradeRow: Identifiable { let id: String; var a: Assignment }

struct Course: Identifiable {
    let id = UUID()
    var name: String
    var grade: Double
    var trend: [Double]
    var assignments: [Assignment] = []
    var calibratedWeight: Double = 0.7
}
struct Assessment: Identifiable { let id = UUID(); var course: String; var title: String; var date: Date }
struct Concept: Identifiable, Codable { var id = UUID(); var course: String; var name: String; var mastery: Double }
struct Priority: Identifiable {
    let id = UUID(); var course: String; var title: String; var minutes: Int
    var reason: String; var concept: Concept?; var score: Double
}

/// A "what if" the student is trying on one class. Saved on the phone until predictions are turned off.
struct AddedItem: Codable, Identifiable {
    var id = UUID()
    var name: String
    var category: String
    var score: Double
    var total: Double
    var weight: Double
}
struct WhatIf: Codable {
    var edits: [String: Double] = [:]     // assignment key -> predicted score
    var added: [AddedItem] = []
    var exempt: [String] = []             // assignment keys left out of the grade
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        edits = try c.decodeIfPresent([String: Double].self, forKey: .edits) ?? [:]
        added = try c.decodeIfPresent([AddedItem].self, forKey: .added) ?? []
        exempt = try c.decodeIfPresent([String].self, forKey: .exempt) ?? []
    }
}

struct Averages { var summ: Double?; var form: Double?; var overall: Double? }

func calcAverages(_ items: [Assignment], summWeight w: Double) -> Averages {
    func pct(_ xs: [Assignment]) -> Double? {
        let g = xs.filter { $0.score != nil && $0.total > 0 && !$0.excluded }
        let den = g.reduce(0) { $0 + $1.total * $1.weight }
        guard den > 0 else { return nil }
        return g.reduce(0) { $0 + ($1.score ?? 0) * $1.weight } / den * 100
    }
    let s = pct(items.filter { $0.isSummative })
    let f = pct(items.filter { !$0.isSummative })
    var overall: Double?
    if let s, let f { overall = w * s + (1 - w) * f } else { overall = s ?? f }
    return Averages(summ: s, form: f, overall: overall)
}

func calibrateWeight(_ items: [Assignment], reported: Double) -> Double {
    let a = calcAverages(items, summWeight: 0.5)
    guard let s = a.summ, let f = a.form, abs(s - f) > 1 else { return 0.7 }
    let w = (reported - f) / (s - f)
    guard w.isFinite else { return 0.7 }
    return (min(max(w, 0), 1) * 20).rounded() / 20
}

// St. Johns County scale (whole letters). Percent cutoffs round at .5, so 89.5 and up is an A.
// Honors/Pre-AICE adds 0.5 and AP/AICE/IB/Dual Enrollment adds 1.0 to a passing grade. F stays 0.
private let wholeScale: [(cut: Double, letter: String, pts: Double)] = [
    (89.5, "A", 4.0), (79.5, "B", 3.0), (69.5, "C", 2.0), (59.5, "D", 1.0)
]
func gradeInfo(_ p: Double) -> (letter: String, points: Double) {
    for r in wholeScale where p >= r.cut { return (r.letter, r.pts) }
    return ("F", 0)
}
func letterGrade(_ p: Double) -> String { gradeInfo(p).letter }
func gpaPoints(_ p: Double, level: Level) -> (unweighted: Double, weighted: Double) {
    let b = gradeInfo(p).points
    return (b, b > 0 ? b + level.bonus : 0)
}
/// The percent where the next higher letter starts, if there is one.
func nextCut(_ p: Double) -> Double? { wholeScale.map { $0.cut }.sorted().first { $0 > p } }

// F red, D orange, C yellow, B blue, A green (with short blends between letters).
private let colorStops: [(x: Double, r: Double, g: Double, b: Double)] = [
    (0, 0.90, 0.22, 0.22), (57, 0.90, 0.22, 0.22),
    (62, 0.96, 0.55, 0.15), (67, 0.96, 0.55, 0.15),
    (72, 0.93, 0.76, 0.12), (77, 0.93, 0.76, 0.12),
    (81, 0.20, 0.48, 0.95), (88, 0.20, 0.48, 0.95),
    (91.5, 0.16, 0.70, 0.34), (100, 0.16, 0.70, 0.34)
]
func gradeColor(_ p: Double) -> Color {
    let x = max(p, 0)
    for i in 1..<colorStops.count {
        let a = colorStops[i - 1], b = colorStops[i]
        if x <= b.x {
            let t = b.x == a.x ? 0 : (x - a.x) / (b.x - a.x)
            return Color(red: a.r + (b.r - a.r) * t, green: a.g + (b.g - a.g) * t, blue: a.b + (b.b - a.b) * t)
        }
    }
    return Color(red: 0.16, green: 0.70, blue: 0.34)
}
func fmt(_ x: Double) -> String { String(format: x.rounded() == x ? "%.0f" : "%.1f", x) }

// MARK: Plan (kept inside StudyAI, never touches the iPhone Calendar)
enum PlanKind: String, Codable, CaseIterable, Identifiable {
    case test, quiz, homework, other
    var id: String { rawValue }
    var label: String {
        switch self { case .test: return "Test"; case .quiz: return "Quiz"; case .homework: return "Homework"; case .other: return "Other" }
    }
    var icon: String {
        switch self { case .test: return "doc.text.fill"; case .quiz: return "questionmark.circle.fill"
                      case .homework: return "book.closed.fill"; case .other: return "star.fill" }
    }
    var color: Color {
        switch self { case .test: return .red; case .quiz: return .orange; case .homework: return .blue; case .other: return .gray }
    }
    var defaultRemind: [Int] {
        switch self { case .test: return [3, 1]; default: return [1] }
    }
}
struct CustomItem: Codable, Identifiable {
    var id = UUID()
    var course: String
    var title: String
    var kind: PlanKind
    var date: Date
    var remindDays: [Int]
    var done = false
}
struct ItemPrefs: Codable { var remindDays: [Int]?; var done = false; var kind: PlanKind? }
struct PlanEntry: Identifiable {
    let id: String
    var course: String
    var title: String
    var kind: PlanKind
    var date: Date
    var remindDays: [Int]
    var done: Bool
    var isCustom: Bool
}
struct ExtractedItem: Identifiable {
    let id = UUID()
    var course: String
    var title: String
    var kind: PlanKind
    var date: Date
    var include = true
}

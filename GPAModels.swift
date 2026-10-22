import SwiftUI

/// A class the student adds by hand. It counts in the Grades-tab GPA and stays with the profile.
struct ExtraCourse: Codable, Identifiable {
    var id = UUID()
    var name: String
    var level: String = Level.regular.rawValue
    var credits: Double = 1.0
    var grade: Double = 90
    var lvl: Level { Level(rawValue: level) ?? .regular }
}

/// One course line from the HAC transcript (completed work).
struct TCourse: Codable, Identifiable {
    var id: String
    var year: String
    var gradeLevel: String
    var school: String
    var code: String
    var name: String
    var marks: [String]       // semester/final marks as printed (percent, letter, NG, WP, WF...)
    var credits: Double
}
struct TOverride: Codable { var counts: Bool?; var level: String? }
struct AIDecision: Codable { var counts: Bool; var level: String; var reason: String }

struct HACQuarter { var value: String; var label: String; var number: Int; var selected: Bool }
struct HACStudent: Identifiable, Codable, Hashable { var id: String; var name: String; var selected: Bool }

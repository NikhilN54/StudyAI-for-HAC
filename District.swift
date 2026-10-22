import Foundation

/// A school district's Home Access Center. Only St. Johns County is available for now.
struct District: Identifiable, Hashable {
    let id: String
    let name: String
    let short: String
    let base: String      // the HAC address, with no trailing slash

    static let stJohns = District(id: "stjohns", name: "St. Johns County School District (FL)", short: "St. Johns",
                                  base: "https://homeaccesscenter.stjohns.k12.fl.us")
    static let all: [District] = [stJohns]
    static func find(_ id: String?) -> District { all.first { $0.id == id } ?? stJohns }
}

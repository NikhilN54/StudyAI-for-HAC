import Foundation

struct HACResult {
    var courses: [Course]
    var assessments: [Assessment]
    var debug: String
    var quarters: [HACQuarter] = []
    var currentQuarter: Int? = nil
}
enum HACError: Error { case badLogin(String), network, parse(String) }

// MARK: small HTML helpers
private func rx(_ p: String) -> NSRegularExpression? {
    try? NSRegularExpression(pattern: p, options: [.dotMatchesLineSeparators, .caseInsensitive])
}
/// First capture group (or the whole match when the pattern has none) of every match.
func hacAll(_ p: String, in s: String) -> [String] {
    guard let re = rx(p) else { return [] }
    let ns = s as NSString
    return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m -> String in
        let r = m.numberOfRanges > 1 ? m.range(at: 1) : m.range
        return r.location == NSNotFound ? "" : ns.substring(with: r)
    }
}
func hacFirst(_ p: String, in s: String) -> String? { hacAll(p, in: s).first }
/// Every capture group of every match.
func hacGroups(_ p: String, in s: String) -> [[String]] {
    guard let re = rx(p) else { return [] }
    let ns = s as NSString
    return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
        (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }
}
func hacStrip(_ s: String) -> String {
    s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
     .replacingOccurrences(of: "&nbsp;", with: " ")
     .replacingOccurrences(of: "&amp;", with: "&")
     .trimmingCharacters(in: .whitespacesAndNewlines)
}
func hacHidden(_ html: String) -> [String: String] {
    var out: [String: String] = [:]
    for tag in hacAll(#"<input[^>]*type="hidden"[^>]*>"#, in: html) {
        if let n = hacFirst(#"name="([^"]*)""#, in: tag) { out[n] = hacDecode(hacFirst(#"value="([^"]*)""#, in: tag) ?? "") }
    }
    return out
}
private func hacDecode(_ s: String) -> String {
    guard s.contains("&") else { return s }
    var t = s
    for (a, b) in [("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", "\u{00A0}")] {
        t = t.replacingOccurrences(of: a, with: b)
    }
    if let re = try? NSRegularExpression(pattern: "&#(x?)([0-9A-Fa-f]+);") {
        for m in re.matches(in: t, range: NSRange(location: 0, length: (t as NSString).length)).reversed() {
            let ns = t as NSString
            let hex = ns.substring(with: m.range(at: 1)).lowercased() == "x"
            if let code = UInt32(ns.substring(with: m.range(at: 2)), radix: hex ? 16 : 10), let u = Unicode.Scalar(code) {
                t = ns.replacingCharacters(in: m.range, with: String(Character(u)))
            }
        }
    }
    return t.replacingOccurrences(of: "&amp;", with: "&")
}
/// Every value the browser would send with the form: hidden fields, text boxes, and checked boxes.
func hacFormFields(_ html: String) -> [String: String] {
    var out = hacHidden(html)
    for tag in hacAll(#"<input[^>]*>"#, in: html) {
        guard let n = hacFirst(#"name="([^"]*)""#, in: tag) else { continue }
        let type = (hacFirst(#"type="([^"]*)""#, in: tag) ?? "text").lowercased()
        let v = hacDecode(hacFirst(#"value="([^"]*)""#, in: tag) ?? "")
        switch type {
        case "text", "search", "number": out[n] = v
        case "checkbox", "radio": if tag.lowercased().contains("checked") { out[n] = v.isEmpty ? "on" : v }
        default: break
        }
    }
    return out
}
struct HACSelect { var name: String; var options: [(value: String, text: String, selected: Bool)] }
func hacSelects(in html: String) -> [HACSelect] {
    hacGroups(#"<select([^>]*)>(.*?)</select>"#, in: html).compactMap { g in
        guard g.count > 2, let name = hacFirst(#"name="([^"]*)""#, in: g[1]) else { return nil }
        let opts = hacGroups(#"<option([^>]*)>(.*?)</option>"#, in: g[2]).map { o -> (value: String, text: String, selected: Bool) in
            let text = hacStrip(o[2])
            return (hacDecode(hacFirst(#"value="([^"]*)""#, in: o[1]) ?? text), text, o[1].lowercased().contains("selected"))
        }
        return HACSelect(name: name, options: opts)
    }
}
private func maskText(_ s: String) -> String { String(s.map { $0.isLetter ? "a" : ($0.isNumber ? "9" : $0) }) }
/// Hides letters and digits in page text so structure can be shared without personal info.
func hacMask(_ html: String) -> String {
    var s = html.replacingOccurrences(of: #"\s(href|src|onclick)="[^"]*""#, with: "", options: .regularExpression)
    for pass in [(#"((?:value|title|aria-label|alt)=")([^"]*)(")"#, true), (#"(>)([^<]+)(<)"#, false)] {
        guard let re = rx(pass.0) else { continue }
        let ns = s as NSString
        var out = s
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            let inner = ns.substring(with: m.range(at: 2))
            let masked = (pass.1 && inner.count <= 3) ? inner : maskText(inner)
            let rep = ns.substring(with: m.range(at: 1)) + masked + ns.substring(with: m.range(at: 3))
            out = (out as NSString).replacingCharacters(in: m.range, with: rep)
        }
        s = out
    }
    return s
}

// MARK: Client
/// Logs in on-device and reads the student's own pages. Nothing here talks to any server except HAC.
final class HACClient {
    let district: District
    init(district: District = .stJohns) { self.district = district }
    var base: String { district.base }
    var loginURL: URL { URL(string: base + "/HomeAccess/Account/LogOn?ReturnUrl=%2fHomeAccess")! }
    var gradesURL: URL { URL(string: base + "/HomeAccess/Content/Student/Assignments.aspx")! }
    var transcriptURL: URL { URL(string: base + "/HomeAccess/Content/Student/Transcript.aspx")! }
    var shellURL: URL { URL(string: base + "/HomeAccess/Classes/Classwork")! }
    static let dateFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "M/d/yyyy"; return f }()

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            "Accept-Language": "en-US,en;q=0.9"
        ]
        return URLSession(configuration: c)
    }()
    private var form: [String: String] = [:]
    private var quarterField: String?
    private var refreshTarget: String?
    private var buttonList: [String] = []
    private var shellFields: [String: String] = [:]
    private var pickerURL: URL?
    private var formURL: URL?
    private var lastSelects: [HACSelect] = []
    private var loginDebug = ""
    private(set) var quarters: [HACQuarter] = []

    private func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
    private func post(_ url: URL, _ fields: [String: String]) async throws -> (String, URL?) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(url.absoluteString, forHTTPHeaderField: "Referer")
        req.setValue(base, forHTTPHeaderField: "Origin")
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        req.httpBody = fields.map { "\(enc($0.key))=\(enc($0.value))" }.joined(separator: "&").data(using: .utf8)
        let (d, resp) = try await session.data(for: req)
        return (String(decoding: d, as: UTF8.self), resp.url)
    }

    // MARK: login
    func login(username: String, password: String) async throws {
        let (pageData, _) = try await session.data(from: loginURL)
        var fields = hacHidden(String(decoding: pageData, as: UTF8.self))
        let names = fields.keys.sorted().joined(separator: ", ")
        fields["LogOnDetails.UserName"] = username
        fields["LogOnDetails.Password"] = password
        if fields["VerificationOption"] == nil { fields["VerificationOption"] = "UsernamePassword" }
        let (_, after) = try await post(loginURL, fields)
        loginDebug = "Login page hidden fields: \(names)\nURL after login: \(after?.absoluteString ?? "?")\n"
        if (after?.absoluteString ?? "").contains("LogOn") { throw HACError.badLogin(loginDebug) }
    }
    func loadAll(username: String, password: String) async throws -> HACResult {
        try await login(username: username, password: password)
        return try await loadAssignmentsChecked()
    }

    // MARK: grades
    func loadAssignmentsChecked() async throws -> HACResult {
        let r = try await loadAssignments()
        guard !r.courses.isEmpty else { throw HACError.parse(r.debug) }
        return r
    }
    func loadAssignments() async throws -> HACResult {
        let (d, resp) = try await session.data(from: gradesURL)
        return ingest(String(decoding: d, as: UTF8.self), url: resp.url, prefix: loginDebug)
    }
    /// Same as choosing a number in "Report Card Run" and pressing Refresh View on the HAC Classwork page.
    func loadQuarter(_ q: Int) async throws -> HACResult {
        // Start from a fresh copy of the page so the form state (view state, dropdown values) is valid.
        _ = try await loadAssignments()
        guard let field = quarterField else {
            throw HACError.parse("the Classwork page has no Report Card Run dropdown. Dropdowns found: \(lastSelects.map { $0.name })")
        }
        guard let opt = quarters.first(where: { $0.number == q }) else {
            throw HACError.parse("the Report Card Run dropdown has no option for quarter \(q). Options: \(quarters.map { $0.label })")
        }
        var f = form
        f[field] = opt.value
        // A separate "marking period" dropdown, if the page has one, is set to the matching number.
        for s in lastSelects where s.name != field {
            let looksLikeMP = s.name.lowercased().contains("markingperiod") || s.name.lowercased().contains("ddlmp")
                || s.options.contains { $0.text.range(of: "^m\\d$", options: [.regularExpression, .caseInsensitive]) != nil }
            if looksLikeMP, let o = s.options.first(where: { String($0.text.filter { $0.isNumber }) == String(q) }) { f[s.name] = o.value }
        }
        // The Refresh View button is a postback: its onclick runs __doPostBack('<id>', '').
        let eventTarget = refreshTarget ?? "ctl00$plnMain$btnRefreshView"
        var postback = f; postback["__EVENTTARGET"] = eventTarget; postback["__EVENTARGUMENT"] = ""
        var submitStyle = f; submitStyle[eventTarget] = "Refresh View"; submitStyle["__EVENTTARGET"] = ""; submitStyle["__EVENTARGUMENT"] = ""
        let target = formURL ?? gradesURL
        var tried: [String] = []
        for (i, body) in [postback, submitStyle].enumerated() {
            let (html, url) = try await post(target, body)
            if (url?.path ?? "").lowercased().contains("/error") { tried.append("way \(i + 1) got the error page"); continue }
            return ingest(html, url: url, prefix: "Quarter \(q) request to \(target.path) using way \(i + 1)\nPosted fields: \(body.keys.sorted())\n")
        }
        throw HACError.parse("HAC returned its error page for the quarter request (\(tried.joined(separator: ", "))). Refresh target: \(eventTarget). Buttons on the page: \(buttonList)")
    }

    private func ingest(_ html: String, url: URL?, prefix: String) -> HACResult {
        var r = parse(html)
        form = hacFormFields(html)
        let sels = hacSelects(in: html)
        lastSelects = sels
        let formTags = hacAll(#"<form[^>]*>"#, in: html)
        formURL = nil
        if let t = formTags.first(where: { $0.contains("fmMain") }) ?? formTags.first,
           let a = hacFirst(#"action="([^"]*)""#, in: t) {
            formURL = URL(string: hacDecode(a), relativeTo: url ?? gradesURL)?.absoluteURL
        }
        for s in sels { if let o = s.options.first(where: { $0.selected }) ?? s.options.first { form[s.name] = o.value } }
        quarterField = nil; quarters = []
        if let s = sels.first(where: { $0.name.lowercased().contains("reportcardrun") }) {
            quarterField = s.name
            quarters = s.options.enumerated().compactMap { (i, o) -> HACQuarter? in
                let digits = String((o.text.filter { $0.isNumber }).prefix(2))
                guard let n = Int(digits) ?? Int(o.value) else { return nil }
                return HACQuarter(value: o.value, label: o.text, number: n, selected: o.selected)
            }
        }
        if !quarters.isEmpty && !quarters.contains(where: { $0.selected }) { quarters[0].selected = true }
        // Find the "Refresh View" button by its label or name. If the page doesn't reveal it, use HAC's usual name.
        let btnTags = hacAll(#"<(?:input|button)[^>]*>"#, in: html).filter { t in
            let l = t.lowercased()
            return l.contains("type=\"submit\"") || l.contains("type=\"button\"") || l.hasPrefix("<button")
        }
        buttonList = btnTags.prefix(12).map { t in
            "\(hacFirst(#"name="([^"]*)""#, in: t) ?? hacFirst(#"id="([^"]*)""#, in: t) ?? "?")=\(hacFirst(#"value="([^"]*)""#, in: t) ?? "")"
        }
        // Read the postback target from the Refresh View button's onclick, or use HAC's usual id.
        refreshTarget = nil
        var guessed = false
        if quarterField != nil {
            let btn = btnTags.first { $0.lowercased().contains("refreshview") }
            let fromClick = btn.flatMap { hacFirst(#"__doPostBack\((?:&#39;|&quot;|')([^'&"]*)"#, in: $0) }
            refreshTarget = fromClick ?? "ctl00$plnMain$btnRefreshView"
            guessed = (fromClick == nil)
        }
        r.quarters = quarters
        r.currentQuarter = quarters.first(where: { $0.selected })?.number
        var dbg = prefix
        dbg += "Grades URL: \(url?.absoluteString ?? "?")\nLength: \(html.count)\n"
        dbg += "Title: \(hacFirst("<title>(.*?)</title>", in: html) ?? "none")\n"
        for k in ["AssignmentClass", "sg-header-heading", "lblHdrAverage", "sg-asp-table-data-row", "line-through", "LogOn"] {
            dbg += "count[\(k)] = \(html.components(separatedBy: k).count - 1)\n"
        }
        dbg += "Quarter dropdown: \(quarterField ?? "none") options \(quarters.map { $0.label }) selected \(r.currentQuarter.map(String.init) ?? "none")\n"
        dbg += "Refresh target: \(refreshTarget ?? "none")\(guessed ? " (default)" : "")\nButtons on page: \(buttonList)\n"
        r.debug = dbg + r.debug
        return r
    }

    // HAC's HTML differs by district. If this finds nothing, send the debug info to adjust these patterns.
    func parse(_ html: String) -> HACResult {
        var courses: [Course] = []
        var assessments: [Assessment] = []
        let today = Calendar.current.startOfDay(for: .now)
        let detect = UserDefaults.standard.object(forKey: Store.pk("detectDropped")) as? Bool ?? true
        for b in html.components(separatedBy: "AssignmentClass").dropFirst() {
            guard let rawName = hacFirst(#"sg-header-heading[^>]*>\s*([^<]+?)\s*<"#, in: b) else { continue }
            let name = rawName
                .replacingOccurrences(of: #"^\d+\s*-\s*(?:\d+\s+(?=[A-Za-z]))?"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            let avg = hacFirst(#"lblHdrAverage[^>]*>[^<]*?(\d+(?:\.\d+)?)\s*<"#, in: b).flatMap(Double.init)
            var items: [Assignment] = []
            // cells: [due, assigned, name, category, score, total, weight, ...]
            for row in b.components(separatedBy: "sg-asp-table-data-row").dropFirst() {
                let tr = row.components(separatedBy: "</tr>").first ?? row
                let rawCells = hacGroups(#"(<td[^>]*>)(.*?)</td>"#, in: tr)
                let cells = rawCells.map { hacStrip($0[2]) }
                guard cells.count >= 6, let due = Self.dateFmt.date(from: cells[0]), let total = Double(cells[5]) else { continue }
                let title = cells[2].replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
                let weight = cells.count > 6 ? (Double(cells[6]) ?? 1) : 1
                let score = Double(cells[4])
                // A crossed-out name or score means the teacher dropped it. Only those two cells are checked.
                func struck(_ i: Int) -> Bool {
                    i < rawCells.count && (rawCells[i][1] + rawCells[i][2])
                        .range(of: "line-through|<strike|<s>|<del[ >]", options: [.regularExpression, .caseInsensitive]) != nil
                }
                let dropped = detect && (struck(2) || struck(4))
                var a = Assignment(name: title, category: cells[3], score: score, total: total, weight: weight, due: due)
                a.dropped = dropped
                items.append(a)
            }
            if let avg {
                courses.append(Course(name: name, grade: avg, trend: [avg], assignments: items,
                                      calibratedWeight: calibrateWeight(items, reported: avg)))
            }
        }
        // Safety net: real drops are rare. If most rows look crossed out, the detection is wrong, so ignore it.
        let every = courses.flatMap { $0.assignments }
        let flagged = every.filter { $0.dropped }.count
        var note = "Crossed-out rows flagged: \(flagged) of \(every.count)\n"
        if every.count >= 6, Double(flagged) / Double(every.count) > 0.5 {
            for i in courses.indices {
                for j in courses[i].assignments.indices { courses[i].assignments[j].dropped = false }
                courses[i].calibratedWeight = calibrateWeight(courses[i].assignments, reported: courses[i].grade)
            }
            note += "Too many rows looked crossed out, so crossed-out detection was ignored for this page.\n"
        }
        for c in courses {
            for a in c.assignments where a.score == nil && !a.dropped && (a.due ?? .distantPast) >= today
                && a.name.range(of: "test|quiz|exam|summative", options: [.regularExpression, .caseInsensitive]) != nil {
                assessments.append(Assessment(course: c.name, title: a.name, date: a.due ?? today))
            }
        }
        return HACResult(courses: courses, assessments: assessments, debug: note)
    }

    // MARK: parent accounts (switch between children)
    /// Reads a student list out of HAC markup: a dropdown, radio buttons, or elements with a student id attribute.
    static func parseStudents(_ html: String) -> [HACStudent] {
        for sel in hacSelects(in: html) where sel.options.count > 1 {
            return sel.options.map { HACStudent(id: $0.value, name: $0.text, selected: $0.selected) }
        }
        var out: [HACStudent] = []
        for g in hacGroups(#"<input[^>]*type="radio"[^>]*value="([^"]+)"[^>]*>\s*(?:<label[^>]*>)?\s*([^<]{2,80})"#, in: html) {
            out.append(HACStudent(id: g[1], name: hacStrip(g[2]), selected: g[0].lowercased().contains("checked")))
        }
        if out.isEmpty {
            for g in hacGroups(#"<(?:a|button|li|div|tr|span)[^>]*data-(?:student-?id|studentid|id)="([^"]+)"[^>]*>(.*?)</(?:a|button|li|div|tr|span)>"#, in: html) {
                let name = hacStrip(g[2])
                if !name.isEmpty && name.count < 80 && !out.contains(where: { $0.id == g[1] }) {
                    out.append(HACStudent(id: g[1], name: name, selected: false))
                }
            }
        }
        return out
    }

    func fetchStudents() async -> [HACStudent] {
        guard let (d, _) = try? await session.data(from: shellURL) else { return [] }
        let html = String(decoding: d, as: UTF8.self)
        shellFields = hacHidden(html)
        guard let r = html.range(of: "sg-banner-chooser") else { return [] }
        let chunk = String(html[r.lowerBound...].prefix(8000))
        pickerURL = nil
        if let path = hacFirst(#"(?:data-url|data-action|action)="([^"]*student[^"]*)""#, in: chunk) {
            pickerURL = URL(string: path, relativeTo: URL(string: base)!)?.absoluteURL
        }
        for s in hacSelects(in: chunk) where s.options.count > 1 {
            return s.options.map { HACStudent(id: $0.value, name: $0.text, selected: $0.selected) }
        }
        // The "Change Student" pop-up is loaded by script. Try the page it most likely comes from.
        if let url = URL(string: base + "/HomeAccess/Frame/StudentPicker"),
           let (d2, _) = try? await session.data(from: url) {
            let found = Self.parseStudents(String(decoding: d2, as: UTF8.self))
            if found.count > 1 { pickerURL = pickerURL ?? url; return found }
        }
        return []
    }
    func switchStudent(id: String) async throws {
        let url = pickerURL ?? URL(string: base + "/HomeAccess/Frame/StudentPicker")!
        var f = shellFields
        f["studentId"] = id
        _ = try await post(url, f)
    }

    // MARK: transcript (completed courses)
    func fetchTranscript() async throws -> [TCourse] {
        let (d, _) = try await session.data(from: transcriptURL)
        let html = String(decoding: d, as: UTF8.self)
        let list = Self.parseTranscript(html)
        if list.isEmpty {
            let heads = hacAll(#"<tr[^>]*header-row[^>]*>(.*?)</tr>"#, in: html).prefix(3).map { hacStrip($0.replacingOccurrences(of: "</td>", with: " | ")) }
            throw HACError.parse("Transcript tables: \(html.components(separatedBy: "sg-asp-table").count - 1)\nHeaders: \(heads)\nLength: \(html.count)")
        }
        return list
    }

    static func parseTranscript(_ html: String) -> [TCourse] {
        var out: [TCourse] = []
        let ns = html as NSString
        guard let tre = rx(#"<table[^>]*sg-asp-table[^>]*>(.*?)</table>"#) else { return [] }
        for m in tre.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let table = ns.substring(with: m.range(at: 1))
            let before = ns.substring(to: m.range.location)
            func last(_ key: String) -> String {
                hacAll(key + #"[^>]*>\s*([^<]*?)\s*<"#, in: before).last ?? ""
            }
            let year = last("lblYearValue"), level = last("lblGradeValue"), school = last("lblSchoolValue")
            var headers: [String] = []
            var n = 0
            for r in table.components(separatedBy: "<tr").dropFirst() {
                let cells = hacAll(#"<t[dh][^>]*>(.*?)</t[dh]>"#, in: r).map(hacStrip)
                if r.lowercased().contains("header-row") || r.lowercased().contains("<th") { headers = cells.map { $0.lowercased() }; continue }
                if headers.isEmpty || cells.count < 3 { continue }
                let codeI = headers.firstIndex { $0.contains("course") && !$0.contains("desc") }
                let nameI = headers.firstIndex { $0.contains("descr") }
                let creditI = headers.firstIndex { $0.contains("attempt") } ?? headers.firstIndex { $0.contains("credit") }
                let markIs = headers.indices.filter { i in
                    let h = headers[i]
                    return (h.contains("sem") || h.contains("final") || h.contains("avg") || h.contains("average")
                            || h.contains("grade") || h.contains("mark")) && !h.contains("credit") && !h.contains("level")
                }
                guard nameI != nil || codeI != nil, !markIs.isEmpty else { continue }
                let name = nameI.flatMap { $0 < cells.count ? cells[$0] : nil } ?? ""
                let code = codeI.flatMap { $0 < cells.count ? cells[$0] : nil } ?? ""
                if (name + code).isEmpty || (name + code).lowercased().contains("total") { continue }
                let marks = markIs.compactMap { $0 < cells.count ? cells[$0] : nil }.filter { !$0.isEmpty }
                let credits = creditI.flatMap { $0 < cells.count ? Double(cells[$0]) : nil } ?? 0
                n += 1
                out.append(TCourse(id: "\(year)|\(code)|\(name)|\(n)", year: year, gradeLevel: level, school: school,
                                   code: code, name: name.isEmpty ? code : name, marks: marks, credits: credits))
            }
        }
        return out
    }

    /// Looks through the page's scripts for where the "Change Student" pop-up comes from, then fetches those pages.
    func discoverStudentPicker(shellHTML html: String) async -> String {
        var out = "\nDISCOVERY\n"
        let baseURL = URL(string: base)!
        func clean(_ t: String) -> String {
            t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
             .replacingOccurrences(of: #"\d{4,}"#, with: "9999", options: .regularExpression)
        }
        var scripts: [(String, String)] = []
        for block in hacAll(#"<script(?![^>]*\ssrc=)[^>]*>(.*?)</script>"#, in: html) where block.lowercased().contains("student") {
            scripts.append(("inline script", block))
        }
        let srcs = hacAll(#"<script[^>]*\ssrc="([^"]+)""#, in: html)
            .filter { !$0.lowercased().contains("jquery") && !$0.lowercased().contains("kendo") }.prefix(10)
        for src in srcs {
            guard let u = URL(string: src.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: baseURL)?.absoluteURL,
                  u.host == baseURL.host, let (d, _) = try? await session.data(from: u) else { continue }
            scripts.append((u.path, String(decoding: d, as: UTF8.self)))
        }
        var cands: [String] = []
        for (name, t) in scripts {
            for m in hacAll(#"["'](/?(?:HomeAccess/)?[A-Za-z0-9_/]*[Ss]tudent[A-Za-z0-9_/]*)(?:\?[^"']*)?["']"#, in: t) where !cands.contains(m) {
                cands.append(m)
            }
            if let r = t.range(of: "add-change-student") {
                let lo = t.index(r.lowerBound, offsetBy: -400, limitedBy: t.startIndex) ?? t.startIndex
                let hi = t.index(r.upperBound, offsetBy: 700, limitedBy: t.endIndex) ?? t.endIndex
                out += "CODE AROUND add-change-student in \(name):\n\(clean(String(t[lo..<hi])))\n"
            }
        }
        out += "Candidate paths: \(cands.prefix(15))\n"
        for c in cands.prefix(6) {
            let path = c.hasPrefix("/") ? c : "/" + (c.hasPrefix("HomeAccess") ? c : "HomeAccess/" + c)
            guard let u = URL(string: base + path), let (d, resp) = try? await session.data(from: u) else { continue }
            let h = String(decoding: d, as: UTF8.self)
            out += "GET \(path) -> \((resp as? HTTPURLResponse)?.statusCode ?? 0), \(h.count) chars\n\(String(hacMask(h).prefix(1200)))\n"
        }
        return out
    }

    // MARK: page structure for troubleshooting (letters and digits are masked)
    func inspect(_ which: String) async -> String {
        let url = which == "transcript" ? transcriptURL : (which == "banner" ? shellURL : gradesURL)
        guard let (d, resp) = try? await session.data(from: url) else { return "Couldn't load the page." }
        let html = String(decoding: d, as: UTF8.self)
        var s = "PAGE \(which)\nPath: \(resp.url?.path ?? "?")\nLength: \(html.count)\n"
        s += "Forms: \(hacAll(#"<form[^>]*>"#, in: html).map(hacMask))\n"
        for sel in hacSelects(in: html) {
            let opts = sel.options.map { o in "\(o.value.count <= 3 ? o.value : maskText(o.value))=\(o.text.count <= 3 ? o.text : maskText(o.text))\(o.selected ? "*" : "")" }
            s += "Select \(sel.name): \(opts.prefix(12))\n"
        }
        let buttons = hacAll(#"<(?:input|button)[^>]*(?:type="submit"|type="button")[^>]*>"#, in: html).prefix(10).map(hacMask)
        s += "Buttons: \(Array(buttons))\n"
        s += "Hidden fields: \(hacHidden(html).keys.sorted().prefix(30))\n"
        let ids = Array(Set(hacAll(#"\sid="([^"]{1,70})""#, in: html))).sorted().prefix(60)
        s += "Ids: \(ids.joined(separator: ","))\n"
        if which == "banner", let r = html.range(of: "sg-banner-chooser") {
            s += "BANNER CHOOSER:\n" + String(hacMask(String(html[r.lowerBound...].prefix(2500))).prefix(2500))
            s += await discoverStudentPicker(shellHTML: html)
        } else if let r = html.range(of: "<table") {
            s += "FIRST TABLE:\n" + String(hacMask(String(html[r.lowerBound...].prefix(4000))).prefix(3000))
        }
        return s
    }
}

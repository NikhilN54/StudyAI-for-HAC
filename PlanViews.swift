import SwiftUI
import PhotosUI

func planWhen(_ date: Date) -> String {
    let cal = Calendar.current
    let n = cal.dateComponents([.day], from: cal.startOfDay(for: .now), to: cal.startOfDay(for: date)).day ?? 0
    if n < 0 { return "overdue" }
    if n == 0 { return "today" }
    if n == 1 { return "tomorrow" }
    return "in \(n) days"
}
func reminderText(_ days: [Int]) -> String {
    days.isEmpty ? "None" : days.sorted(by: >).map { $0 == 0 ? "day of" : "\($0)d before" }.joined(separator: ", ")
}

// MARK: AI import of photos and screenshots
enum Planner {
    static func prompt(courses: [String]) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return """
        Today is \(f.string(from: .now)). Extract upcoming tests, quizzes, homework, projects and other due items \
        from the text the student gives you. Reply with ONLY a JSON array and nothing else (no markdown, no explanation). \
        Each element: {"course": string, "title": string, "type": "test" or "quiz" or "homework" or "other", "date": "YYYY-MM-DD"}. \
        If a date has no year, use its next upcoming occurrence. Skip anything without a date. \
        The student's classes are: \(courses.joined(separator: ", ")). Use one of these exact names for "course" when it \
        clearly matches, otherwise use the name as written, or an empty string if unknown.
        """
    }
    static func match(_ s: String, known: [String]) -> String {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return "" }
        return known.first { let k = $0.lowercased(); return k == t || k.contains(t) || t.contains(k) } ?? s
    }
    static func parse(_ reply: String, known: [String]) -> [ExtractedItem] {
        guard let a = reply.firstIndex(of: "["), let b = reply.lastIndex(of: "]"), a < b,
              let data = String(reply[a...b]).data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        var out: [ExtractedItem] = []
        for d in arr {
            guard let title = d["title"] as? String, let ds = d["date"] as? String, let date = f.date(from: ds) else { continue }
            let t = ((d["type"] as? String) ?? "other").lowercased()
            let kind = PlanKind(rawValue: t) ?? (t.contains("home") ? .homework : .other)
            out.append(ExtractedItem(course: match((d["course"] as? String) ?? "", known: known), title: title, kind: kind, date: date))
        }
        return out
    }
}

// MARK: Plan tab
struct DayPick: Identifiable { let id: Date }

struct PlanView: View {
    @EnvironmentObject var store: Store
    @State private var mode = 0
    @State private var showDone = false
    @State private var showAdd = false
    @State private var selected: PlanEntry?
    @State private var dayPick: DayPick?
    @State private var showPicker = false
    @State private var photo: PhotosPickerItem?
    @State private var importing = false
    @State private var importStatus = ""
    @State private var importError = ""
    @State private var extracted: [ExtractedItem] = []
    @State private var showReview = false

    var entries: [PlanEntry] { store.planEntries.filter { showDone || !$0.done } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("View", selection: $mode) { Text("List").tag(0); Text("Calendar").tag(1) }
                    .pickerStyle(.segmented).padding(.horizontal).padding(.bottom, 6)
                if mode == 0 {
                    PlanListView(entries: entries) { selected = $0 }
                } else {
                    PlanCalendarView(entries: entries) { dayPick = DayPick(id: $0) }
                }
            }
            .themed()
            .navigationTitle("Plan")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showAdd = true } label: { Label("Add manually", systemImage: "square.and.pencil") }
                        Button { showPicker = true } label: { Label("Scan photo or screenshot", systemImage: "photo") }
                        Button {
                            let t = UIPasteboard.general.string ?? ""
                            if t.isEmpty { importError = "Nothing copied to paste." } else { Task { await analyze(t) } }
                        } label: { Label("Paste text", systemImage: "doc.on.clipboard") }
                        Toggle("Show completed", isOn: $showDone)
                    } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: $selected) { ItemDetailSheet(entry: $0) }
            .sheet(item: $dayPick) { DayInsightSheet(date: $0.id) }
            .sheet(isPresented: $showAdd) { AddItemSheet(date: Date()) }
            .sheet(isPresented: $showReview) { ImportReviewSheet(items: extracted) }
            .photosPicker(isPresented: $showPicker, selection: $photo, matching: .images)
            .onChange(of: photo) { _, new in
                guard let new else { return }
                Task {
                    if let d = try? await new.loadTransferable(type: Data.self), let img = UIImage(data: d) {
                        importing = true; importStatus = "Reading the photo…"
                        let t = await recognizeText(img)
                        if t.isEmpty { importing = false; importError = "I couldn't find any text in that photo." }
                        else { await analyze(t) }
                    }
                    photo = nil
                }
            }
            .overlay {
                if importing {
                    ZStack {
                        Color.black.opacity(0.25).ignoresSafeArea()
                        VStack(spacing: 10) {
                            ProgressView()
                            Text(importStatus).font(.caption)
                        }.padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            .alert("Plan", isPresented: Binding(get: { !importError.isEmpty }, set: { if !$0 { importError = "" } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(importError) }
        }
    }

    func analyze(_ text: String) async {
        importing = true; importStatus = "Analyzing with AI…"
        let known = store.courses.map { $0.name }
        let reply = await AIService.ask(system: Planner.prompt(courses: known),
                                        messages: [ChatMessage(role: "user", text: text)]) { s in importStatus = s }
        importing = false
        let items = Planner.parse(reply, known: known)
        if items.isEmpty {
            importError = reply.contains("[") ? "I couldn't find any dated tests, quizzes, or homework. Try a clearer photo, or add items by hand." : reply
        } else {
            extracted = items; showReview = true
        }
    }
}

// MARK: List
struct PlanListView: View {
    @EnvironmentObject var store: Store
    let entries: [PlanEntry]
    var onPick: (PlanEntry) -> Void

    var groups: [(key: Date, value: [PlanEntry])] {
        Dictionary(grouping: entries, by: { $0.date }).sorted { $0.key < $1.key }
    }

    var body: some View {
        List {
            if !store.priorities.isEmpty {
                Section("Study suggestions") {
                    ForEach(store.priorities.prefix(2)) { p in
                        Button {
                            store.activeConcept = p.concept; store.tab = 2
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(store.nm(p.course)): \(p.minutes) min").font(.headline)
                                Text("Review \(p.concept?.name ?? "material")").font(.subheadline)
                                Text(p.reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if entries.isEmpty {
                Section { Text("Nothing planned. Tap + to add an item or scan a photo.").foregroundStyle(.secondary) }
            }
            ForEach(groups, id: \.key) { group in
                Section {
                    ForEach(group.value) { e in
                        Button { onPick(e) } label: { PlanRow(e: e) }
                    }
                } header: {
                    Text("\(group.key.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · \(planWhen(group.key))")
                }
            }
        }
    }
}

struct PlanRow: View {
    @EnvironmentObject var store: Store
    let e: PlanEntry
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: e.kind.icon).foregroundStyle(e.kind.color).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.title).lineLimit(2).strikethrough(e.done)
                Text("\(e.course.isEmpty ? "No class" : store.nm(e.course)) · \(e.kind.label)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(planWhen(e.date)).font(.caption.bold())
                    .foregroundStyle(planWhen(e.date) == "overdue" ? Color.red : Color.secondary)
                if !e.remindDays.isEmpty {
                    Label(reminderText(e.remindDays), systemImage: "bell.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }.foregroundStyle(.primary)
    }
}

// MARK: Calendar
struct PlanCalendarView: View {
    @Environment(\.appAccent) private var accent
    let entries: [PlanEntry]
    var onPick: (Date) -> Void
    @State private var month: Date = {
        let c = Calendar.current
        return c.date(from: c.dateComponents([.year, .month], from: .now)) ?? .now
    }()

    var weekdays: [String] {
        let s = Calendar.current.veryShortStandaloneWeekdaySymbols
        let f = Calendar.current.firstWeekday - 1
        return Array(s[f...]) + Array(s[..<f])
    }
    var days: [Date?] {
        let cal = Calendar.current
        guard let range = cal.range(of: .day, in: .month, for: month) else { return [] }
        let first = cal.component(.weekday, from: month)
        var out: [Date?] = Array(repeating: nil, count: (first - cal.firstWeekday + 7) % 7)
        for d in range { out.append(cal.date(byAdding: .day, value: d - 1, to: month)) }
        return out
    }
    func kinds(on d: Date) -> [PlanKind] {
        let on = entries.filter { $0.date == d }
        return PlanKind.allCases.filter { k in on.contains { $0.kind == k } }
    }
    func shift(_ n: Int) { month = Calendar.current.date(byAdding: .month, value: n, to: month) ?? month }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                HStack {
                    Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    Spacer()
                    Text(month.formatted(.dateTime.month(.wide).year())).font(.headline)
                    Spacer()
                    Button { shift(1) } label: { Image(systemName: "chevron.right") }
                }.padding(.horizontal)
                HStack {
                    ForEach(Array(weekdays.enumerated()), id: \.offset) { pair in
                        Text(pair.element).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    }
                }.padding(.horizontal, 8)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 4) {
                    ForEach(Array(days.enumerated()), id: \.offset) { pair in
                        if let d = pair.element {
                            let today = Calendar.current.isDateInToday(d)
                            VStack(spacing: 2) {
                                Text("\(Calendar.current.component(.day, from: d))")
                                    .font(.callout).fontWeight(today ? .bold : .regular)
                                    .foregroundStyle(today ? Color.white : Color.primary)
                                    .frame(width: 28, height: 28)
                                    .background(Circle().fill(today ? accent : Color.clear))
                                HStack(spacing: 1) {
                                    ForEach(kinds(on: d)) { k in
                                        Image(systemName: k.icon).font(.system(size: 9)).foregroundStyle(k.color)
                                    }
                                }.frame(height: 11)
                            }
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .contentShape(Rectangle())
                            .onTapGesture { onPick(d) }
                        } else {
                            Color.clear.frame(height: 48)
                        }
                    }
                }.padding(.horizontal, 8)
                HStack(spacing: 12) {
                    ForEach(PlanKind.allCases) { k in
                        HStack(spacing: 3) {
                            Image(systemName: k.icon).font(.system(size: 9)).foregroundStyle(k.color)
                            Text(k.label).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Tap a date to see what's due.").font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(.vertical)
        }
    }
}

// MARK: Reminder chips
struct ReminderPicker: View {
    @Environment(\.appAccent) private var accent
    @Binding var days: [Int]
    let options = [0, 1, 2, 3, 5, 7]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84))], spacing: 8) {
            ForEach(options, id: \.self) { d in
                let on = days.contains(d)
                Button {
                    if on { days.removeAll { $0 == d } } else { days.append(d); days.sort() }
                } label: {
                    Text(d == 0 ? "Day of" : "\(d)d before").font(.caption.bold())
                        .padding(.vertical, 6).frame(maxWidth: .infinity)
                        .background(on ? accent : Color(.tertiarySystemFill), in: Capsule())
                        .foregroundStyle(on ? Color.white : Color.primary)
                }.buttonStyle(.plain)
            }
        }
    }
}

// MARK: Item editing
struct ItemForm: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State private var e: PlanEntry
    init(entry: PlanEntry) { _e = State(initialValue: entry) }

    var body: some View {
        Form {
            Section {
                if e.isCustom {
                    TextField("Title", text: $e.title)
                    TextField("Class", text: $e.course)
                    DatePicker("Due", selection: $e.date, displayedComponents: .date)
                } else {
                    Text(e.title)
                    Text(store.nm(e.course)).foregroundStyle(.secondary)
                    LabeledContent("Due", value: e.date.formatted(.dateTime.weekday().month().day()))
                }
                Picker("Type", selection: $e.kind) {
                    ForEach(PlanKind.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
                }
            }
            Section(header: Text("Remind me to study"),
                    footer: Text("Reminders arrive at 4:00 PM. They stay inside StudyAI and never touch your iPhone Calendar.")) {
                ReminderPicker(days: $e.remindDays)
            }
            Section {
                Toggle("Mark as done", isOn: $e.done)
                if e.isCustom {
                    Button("Delete", role: .destructive) { store.removeCustom(e.id); dismiss() }
                }
            }
        }
        .navigationTitle(e.kind.label).navigationBarTitleDisplayMode(.inline)
        .onDisappear { store.updateEntry(e) }
    }
}

struct ItemDetailSheet: View {
    @Environment(\.dismiss) var dismiss
    let entry: PlanEntry
    init(entry: PlanEntry) { self.entry = entry }
    var body: some View {
        NavigationStack {
            ItemForm(entry: entry)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct AddItemSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State private var course = ""
    @State private var title = ""
    @State private var kind: PlanKind = .test
    @State private var date: Date
    @State private var remind = PlanKind.test.defaultRemind
    init(date: Date) { _date = State(initialValue: date) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What is it? (like Unit 3 test)", text: $title)
                    HStack {
                        TextField("Class", text: $course)
                        Menu {
                            ForEach(store.courses) { c in Button(store.nm(c.name)) { course = c.name } }
                        } label: { Image(systemName: "chevron.up.chevron.down") }
                    }
                    Picker("Type", selection: $kind) {
                        ForEach(PlanKind.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
                    }
                    DatePicker("Due", selection: $date, displayedComponents: .date)
                }
                Section("Remind me to study") { ReminderPicker(days: $remind) }
            }
            .navigationTitle("Add to plan").navigationBarTitleDisplayMode(.inline)
            .onChange(of: kind) { _, k in remind = k.defaultRemind }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        store.addCustom(CustomItem(course: course, title: title, kind: kind, date: date, remindDays: remind))
                        dismiss()
                    }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

struct ImportReviewSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State private var items: [ExtractedItem]
    init(items: [ExtractedItem]) { _items = State(initialValue: items) }

    var body: some View {
        NavigationStack {
            List {
                Section(footer: Text("Check what the AI found and uncheck anything wrong. You can change each item's reminders after adding.")) {
                    ForEach($items) { $it in
                        Toggle(isOn: $it.include) {
                            HStack {
                                Image(systemName: it.kind.icon).foregroundStyle(it.kind.color)
                                VStack(alignment: .leading) {
                                    Text(it.title)
                                    Text("\(it.course.isEmpty ? "No class" : store.nm(it.course)) · \(it.date.formatted(.dateTime.month().day()))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Found \(items.count)").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(items.filter { $0.include }.count)") {
                        for it in items where it.include {
                            store.addCustom(CustomItem(course: it.course, title: it.title, kind: it.kind,
                                                       date: it.date, remindDays: it.kind.defaultRemind))
                        }
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: Tapping a date
struct DayInsightSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let date: Date
    @State private var showAdd = false

    var items: [PlanEntry] { store.planEntries.filter { $0.date == Calendar.current.startOfDay(for: date) } }

    func study(_ e: PlanEntry) {
        store.activeConcept = store.priorities.first(where: { $0.course == e.course })?.concept
        store.tab = 2
        dismiss()
    }

    var body: some View {
        NavigationStack {
            List {
                if items.isEmpty { Section { Text("Nothing due on this day.").foregroundStyle(.secondary) } }
                ForEach(items) { e in
                    Section {
                        NavigationLink {
                            ItemForm(entry: e)
                        } label: {
                            HStack {
                                Image(systemName: e.kind.icon).foregroundStyle(e.kind.color)
                                VStack(alignment: .leading) {
                                    Text(e.title).font(.headline)
                                    Text("\(e.course.isEmpty ? "No class" : store.nm(e.course)) · \(e.kind.label)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(planWhen(e.date)).font(.caption)
                            }
                        }
                        if let c = store.courses.first(where: { $0.name == e.course }) {
                            LabeledContent("Class grade") {
                                Text("\(pct1(store.displayGrade(c)))%").foregroundStyle(gradeColor(store.displayGrade(c)))
                            }
                        }
                        if let p = store.priorities.first(where: { $0.course == e.course }) {
                            if let k = p.concept {
                                LabeledContent("Weakest topic") { Text("\(k.name) (\(Int(k.mastery))%)") }
                            }
                            LabeledContent("Suggested prep") { Text("\(p.minutes) min") }
                        }
                        LabeledContent("Reminders") { Text(reminderText(e.remindDays)) }
                        Button { study(e) } label: { Label("Study now", systemImage: "sparkles") }
                    }
                }
                Section { Button("Add an item on this day") { showAdd = true } }
            }
            .navigationTitle(date.formatted(.dateTime.weekday(.wide).month().day()))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showAdd) { AddItemSheet(date: date) }
        }
    }
}

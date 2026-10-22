import SwiftUI

struct PredictBanner: View {
    @EnvironmentObject var store: Store
    var body: some View {
        if !store.whatIf.isEmpty {
            Section {
                Label("Predictions on: " + store.whatIf.keys.sorted().map { store.nm($0) }.joined(separator: ", "), systemImage: "wand.and.stars")
                    .foregroundStyle(.purple)
                Button("Turn all predictions off") { store.whatIf = [:] }
            }
        }
    }
}

struct ScoreField: View {
    let onChange: (Double?) -> Void
    @State private var text: String
    init(initial: String, onChange: @escaping (Double?) -> Void) {
        self.onChange = onChange
        _text = State(initialValue: initial)
    }
    var body: some View {
        TextField("—", text: $text)
            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            .frame(width: 64).textFieldStyle(.roundedBorder)
            .onChange(of: text) { _, v in onChange(Double(v)) }
    }
}

struct AssignmentRow: View {
    let row: GradeRow
    var tag: String?
    var editing: Bool
    var onEdit: (Double?) -> Void
    var onExempt: () -> Void
    var a: Assignment { row.a }
    var pct: Double? { guard let s = a.score, a.total > 0 else { return nil }; return s / a.total * 100 }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(a.name).lineLimit(2).strikethrough(a.excluded)
                HStack(spacing: 6) {
                    Text("Weight \(fmt(a.weight))").font(.caption).foregroundStyle(.secondary)
                    if a.dropped {
                        Text("dropped").font(.caption2.bold()).foregroundStyle(.gray)
                    } else if a.exempted {
                        Text("exempt").font(.caption2.bold()).foregroundStyle(.orange)
                    } else if a.edited || a.isHypothetical {
                        Text(a.isHypothetical ? "added" : "edited").font(.caption2.bold()).foregroundStyle(.purple)
                    }
                }
                if let tag { Text(tag).font(.caption2.bold()).foregroundStyle(.blue) }
            }
            Spacer()
            if editing {
                ScoreField(initial: a.score.map { fmt($0) } ?? "", onChange: onEdit).disabled(a.excluded)
                Text("/ \(fmt(a.total))").foregroundStyle(.secondary)
                Button(action: onExempt) {
                    Image(systemName: a.exempted ? "arrow.uturn.backward.circle.fill" : "minus.circle")
                        .foregroundStyle(a.exempted ? Color.green : Color.orange)
                        .font(.title3)
                }.buttonStyle(.borderless).disabled(a.dropped)
            } else if let p = pct, let s = a.score {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(pct1(p))%").bold().foregroundStyle(gradeColor(p))
                    Text("\(fmt(s))/\(fmt(a.total))").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Not graded").font(.caption).foregroundStyle(.secondary)
            }
        }
        .opacity(a.excluded ? 0.5 : 1)
        .listRowBackground(a.excluded ? Color(.secondarySystemGroupedBackground)
                                      : (pct.map { gradeColor($0).opacity(0.15) } ?? Color(.secondarySystemGroupedBackground)))
    }
}

struct CourseDetailView: View {
    @EnvironmentObject var store: Store
    let courseID: UUID
    @State private var newName = ""
    @State private var newCat = "Summative"
    @State private var newScore = ""
    @State private var newTotal = "100"
    @State private var newWeight = "1"

    var body: some View {
        if let c = store.courses.first(where: { $0.id == courseID }) { content(c) } else { Text("Class not found") }
    }

    func content(_ c: Course) -> some View {
        let w = store.summWeight
        let lvl = store.level(c)
        let on = store.isWhatIf(c)
        let rows = store.rows(c)
        let avg = calcAverages(rows.map { $0.a }, summWeight: w)
        let shown = store.displayGrade(c)
        let base = store.baseGrade(c)
        let g = gpaPoints(shown, level: lvl)
        let before = gpaPoints(base, level: lvl)
        return List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(pct1(shown))%").font(.system(size: 40, weight: .bold)).foregroundStyle(gradeColor(shown))
                            Text("HAC \(pct1(c.grade))%").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Text(on ? "Predicted (was \(pct1(base))%)" : "From summative and formative averages")
                            .font(.caption).foregroundStyle(on ? Color.purple : Color.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text(letterGrade(shown)).font(.system(size: 44, weight: .bold)).foregroundStyle(gradeColor(shown))
                        if on {
                            Text(String(format: "%+.1f", shown - base)).font(.subheadline.bold())
                                .foregroundStyle(shown - base >= 0 ? Color.green : Color.red)
                        }
                    }
                }
                HStack {
                    VStack(alignment: .leading) {
                        Text(String(format: "%.1f", g.unweighted)).font(.title3.bold())
                        Text(on ? "Unweighted GPA (was \(String(format: "%.1f", before.unweighted)))" : "Unweighted GPA")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text(String(format: "%.1f", g.weighted)).font(.title3.bold())
                        Text(on ? "Weighted GPA (was \(String(format: "%.1f", before.weighted)))" : "Weighted GPA")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Picker("Course level", selection: Binding(get: { lvl }, set: { store.setLevel(c, $0) })) {
                    ForEach(Level.allCases) { Text($0.rawValue).tag($0) }
                }
                Stepper("Credits: \(fmt(store.credits(c)))",
                        value: Binding(get: { store.credits(c) }, set: { store.setCredits(c, $0) }),
                        in: 0.5...2, step: 0.5)
                Button {
                    store.setPredict(c, !on)
                } label: {
                    Label(on ? "Stop predicting" : "Predict grades", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(on ? .purple : .blue)
                if on {
                    Button("Reset my changes", role: .destructive) { store.whatIf[c.name] = WhatIf() }
                }
            } footer: {
                Text(on ? "Edit a score, add a grade, or tap the minus button to exempt an assignment. The prediction shows everywhere in the app until you stop predicting."
                        : "The big number is calculated from the summative and formative averages below. HAC's own number is shown small next to it.")
            }
            if on { addSection(c) }
            categorySection("Summative", avg.summ, w, rows.filter { $0.a.isSummative }, c, on)
            categorySection("Formative", avg.form, 1 - w, rows.filter { !$0.a.isSummative }, c, on)
        }
        .themed()
        .navigationTitle(store.nm(c.name)).navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button { hideKeyboard() } label: { Image(systemName: "keyboard.chevron.compact.down") }
            }
        }
    }

    func addSection(_ c: Course) -> some View {
        Section("Add a predicted grade") {
            TextField("Name (optional)", text: $newName)
            Picker("Category", selection: $newCat) {
                Text("Summative").tag("Summative"); Text("Formative").tag("Formative")
            }.pickerStyle(.segmented)
            HStack {
                TextField("Score", text: $newScore).keyboardType(.decimalPad)
                Text("/")
                TextField("Total", text: $newTotal).keyboardType(.decimalPad)
            }
            HStack {
                Text("Weight (like 1 or 2)")
                TextField("1", text: $newWeight).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            }
            Button("Add") {
                store.addGrade(c, AddedItem(name: newName.isEmpty ? "New assignment" : newName, category: newCat,
                                            score: Double(newScore) ?? 0, total: Double(newTotal) ?? 100,
                                            weight: Double(newWeight) ?? 1))
                newName = ""; newScore = ""
            }.disabled(Double(newScore) == nil || (Double(newTotal) ?? 0) <= 0)
        }
    }

    func categorySection(_ title: String, _ avg: Double?, _ weight: Double, _ rows: [GradeRow],
                         _ c: Course, _ editing: Bool) -> some View {
        Section {
            ForEach(rows) { r in
                AssignmentRow(row: r,
                              tag: store.changes.first(where: { $0.course == c.name })?.items.first(where: { $0.name == r.a.name })?.badge,
                              editing: editing,
                              onEdit: { v in store.setScore(c, key: r.id, value: v) },
                              onExempt: { store.toggleExempt(c, key: r.id) })
                    .swipeActions {
                        if r.a.isHypothetical {
                            Button(role: .destructive) { store.removeAdded(c, key: r.id) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
            }
            if rows.isEmpty { Text("No assignments").foregroundStyle(.secondary) }
        } header: {
            HStack {
                Text("\(title) · \(Int((weight * 100).rounded()))% of grade")
                Spacer()
                if let avg { Text("\(pct1(avg))%").bold().foregroundStyle(gradeColor(avg)) }
            }
        }
    }
}

// MARK: GPA insights
struct GPAInsightsView: View {
    @EnvironmentObject var store: Store
    struct Item: Identifiable {
        let id = UUID()
        var name: String
        var grade: Double
        var level: Level
        var credits: Double
        var uw: Double
        var w: Double
    }
    var items: [Item] {
        var out = store.courses.map { c -> Item in
            let g = store.displayGrade(c), l = store.level(c)
            let p = gpaPoints(g, level: l)
            return Item(name: store.nm(c.name), grade: g, level: l, credits: store.credits(c), uw: p.unweighted, w: p.weighted)
        }
        for e in store.extras {
            let p = gpaPoints(e.grade, level: e.lvl)
            out.append(Item(name: e.name + " (extra)", grade: e.grade, level: e.lvl, credits: e.credits, uw: p.unweighted, w: p.weighted))
        }
        return out
    }

    var body: some View {
        let its = items
        let totalCr = its.map { $0.credits }.reduce(0, +)
        let qu = its.map { $0.uw * $0.credits }.reduce(0, +)
        let qw = its.map { $0.w * $0.credits }.reduce(0, +)
        let uwGPA = totalCr > 0 ? qu / totalCr : 0
        let wGPA = totalCr > 0 ? qw / totalCr : 0
        var tips: [(Item, Double, String, Double, Double)] = []
        for it in its {
            guard let cut = nextCut(it.grade), totalCr > 0 else { continue }
            let p = gpaPoints(cut, level: it.level)
            let gu = (p.unweighted - it.uw) * it.credits / totalCr
            let gw = (p.weighted - it.w) * it.credits / totalCr
            tips.append((it, cut - it.grade, gradeInfo(cut).letter, gu, gw))
        }
        tips.sort { $0.1 < $1.1 }
        let top = Array(tips.prefix(3))
        return List {
            Section("How it's calculated") {
                Text("Each class's grade points × its credits = quality points. Add them up and divide by total credits.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Unweighted: \(String(format: "%.1f", qu)) ÷ \(fmt(totalCr)) = \(String(format: "%.2f", uwGPA))")
                Text("Weighted: \(String(format: "%.1f", qw)) ÷ \(fmt(totalCr)) = \(String(format: "%.2f", wGPA))")
                if !store.whatIf.isEmpty { Text("Includes your predictions.").font(.caption).foregroundStyle(.purple) }
            }
            Section("Each class") {
                ForEach(its) { it in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(it.name)
                            Text("\(pct1(it.grade))% · \(letterGrade(it.grade)) · \(it.level.rawValue) · \(fmt(it.credits)) cr")
                                .font(.caption).foregroundStyle(gradeColor(it.grade))
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text(String(format: "%.1f", it.uw))
                            Text(String(format: "%.1f weighted", it.w)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("What the honors and AP/IB bonus does") {
                Text("Honors adds 0.5 and AP/IB adds 1.0 to a class's points (not to an F). Together that lifts your weighted GPA by \(String(format: "%.2f", wGPA - uwGPA)) over unweighted.")
            }
            if !top.isEmpty {
                Section("Quickest ways to raise it") {
                    ForEach(top, id: \.0.id) { t in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(t.0.name): \(pct1(t.1)) points from a \(t.2)")
                            Text("Reaching it adds +\(String(format: "%.2f", t.3)) unweighted, +\(String(format: "%.2f", t.4)) weighted.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section(footer: Text("St. Johns County scale: A 4.0 (89.5+), B 3.0 (79.5+), C 2.0 (69.5+), D 1.0 (59.5+), F 0. Honors/Pre-AICE adds 0.5 and AP/AICE/IB/Dual Enrollment adds 1.0 to passing grades (an A is 4.5 or 5.0). An F never gets the bonus. Set credits on each class page. This covers current classes only, not past semesters.")) { EmptyView() }
        }
        .themed()
        .navigationTitle("GPA insights").navigationBarTitleDisplayMode(.inline)
    }
}

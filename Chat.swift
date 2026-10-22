import SwiftUI
import PhotosUI
import Vision
import AVFoundation

func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

struct Speaker {
    static let synth = AVSpeechSynthesizer()
    static func say(_ t: String) { synth.speak(AVSpeechUtterance(string: t)) }
}

func recognizeText(_ img: UIImage) async -> String {
    guard let cg = img.cgImage else { return "" }
    return await withCheckedContinuation { cont in
        let req = VNRecognizeTextRequest { r, _ in
            let t = (r.results as? [VNRecognizedTextObservation])?
                .compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? ""
            cont.resume(returning: t)
        }
        DispatchQueue.global().async {
            do { try VNImageRequestHandler(cgImage: cg).perform([req]) } catch { cont.resume(returning: "") }
        }
    }
}

extension Store {
    /// Short grade summary for the AI. Empty unless the student turned on sharing in Settings.
    /// Never includes the student's name, HAC username, or password.
    func gradeContext() -> String {
        guard shareGrades, !isDemo, !courses.isEmpty else { return "" }
        var lines = ["The student chose to share their grades. Use them only to tailor study advice."]
        for c in courses {
            let avg = calcAverages(c.assignments, summWeight: summWeight)
            var l = "- \(nm(c.name)) (\(level(c).rawValue)): \(pct1(baseGrade(c)))% (HAC \(pct1(c.grade))%)"
            if let sm = avg.summ { l += ", summative \(pct1(sm))%" }
            if let f = avg.form { l += ", formative \(pct1(f))%" }
            var scored: [(String, Double)] = []
            for a in c.assignments where !a.excluded {
                if let sc = a.score, a.total > 0 { scored.append((a.name, sc / a.total * 100)) }
            }
            scored.sort { $0.1 < $1.1 }
            let low = scored.prefix(2).map { "\($0.0) \(pct1($0.1))%" }
            if !low.isEmpty { l += ". Lowest: " + low.joined(separator: ", ") }
            lines.append(l)
        }
        for a in assessments.prefix(5) {
            let d = daysUntil(a.date)
            lines.append("- Upcoming: \(nm(a.course)) \(a.title) " + (d == 0 ? "today" : "in \(d) day\(d == 1 ? "" : "s")"))
        }
        return "\n" + lines.joined(separator: "\n")
    }

    /// Adds the user's message and a pending reply bubble, then fills the reply in when the AI answers
    /// (retrying automatically if the AI is busy).
    @MainActor func sendChat(_ text: String, in path: ReferenceWritableKeyPath<Store, [ChatMessage]>, system: String) async {
        self[keyPath: path].append(ChatMessage(role: "user", text: text))
        let history = Array(self[keyPath: path].suffix(12).drop(while: { $0.role != "user" }))
        let pending = ChatMessage(role: "assistant", text: "", pending: true, status: "Thinking…")
        self[keyPath: path].append(pending)
        let reply = await AIService.ask(system: system + gradeContext(), messages: history) { [weak self] s in
            self?.updateMessage(path, pending.id) { $0.status = s }
        }
        updateMessage(path, pending.id) { $0.text = reply; $0.pending = false; $0.status = "" }
    }
    @MainActor func updateMessage(_ path: ReferenceWritableKeyPath<Store, [ChatMessage]>, _ id: UUID,
                                  _ f: (inout ChatMessage) -> Void) {
        if let i = self[keyPath: path].firstIndex(where: { $0.id == id }) { f(&self[keyPath: path][i]) }
    }
}

struct ChatBubble: View {
    @Environment(\.appAccent) private var accent
    let m: ChatMessage
    var body: some View {
        HStack {
            if m.role == "user" { Spacer(minLength: 40) }
            Group {
                if m.pending {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(m.status.isEmpty ? "Thinking…" : m.status).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(m.text).textSelection(.enabled)
                }
            }
            .padding(12)
            .background(m.role == "user" ? accent.opacity(0.18) : Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 18))
            if m.role != "user" { Spacer(minLength: 40) }
        }
    }
}

struct ChatScroll: View {
    let messages: [ChatMessage]
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(messages) { ChatBubble(m: $0).id($0.id) }
                }.padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }
}

/// Chat box in the style of ChatGPT / Gemini: a + menu on the left, the text field, and a send button.
struct Composer<MenuItems: View>: View {
    @Binding var text: String
    var placeholder: String
    var busy: Bool
    var onSend: () -> Void
    @ViewBuilder var menuItems: () -> MenuItems

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Menu { menuItems() } label: {
                Image(systemName: "plus").font(.system(size: 17, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color(.tertiarySystemFill)))
            }
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...5).padding(.vertical, 7)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button { hideKeyboard() } label: { Image(systemName: "keyboard.chevron.compact.down") }
                    }
                }
            if busy {
                ProgressView().frame(width: 32, height: 32)
            } else {
                Button(action: onSend) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 32)) }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 26))
    }
}

// MARK: Learn
struct LearnView: View {
    @EnvironmentObject var store: Store
    @State private var input = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if store.shareGrades {
                    Label("Sharing class grades with the AI", systemImage: "eye").font(.caption2).foregroundStyle(.orange).padding(.top, 4)
                }
                if let c = store.activeConcept {
                    HStack {
                        Text("Topic: \(c.name) (\(Int(c.mastery))%)").font(.subheadline)
                        Spacer()
                        Button("Got it ✅") { store.record(c, correct: 1, total: 1) }
                        Button("Still stuck") { store.record(c, correct: 0, total: 1) }
                    }.buttonStyle(.bordered).padding(.horizontal).padding(.top, 6)
                }
                if store.learnChat.isEmpty {
                    Spacer()
                    Text("Ask a question, or tap + for hints and topics.").foregroundStyle(.secondary).padding()
                    Spacer()
                } else {
                    ChatScroll(messages: store.learnChat)
                }
                Composer(text: $input, placeholder: "Ask StudyAI", busy: busy, onSend: send) {
                    Menu {
                        ForEach(store.concepts) { c in
                            Button("\(store.nm(c.course)): \(c.name)") { store.activeConcept = c }
                        }
                    } label: { Label("Pick a topic", systemImage: "list.bullet") }
                    Button { quick("Give me a hint, not the answer.") } label: { Label("Give me a hint", systemImage: "lightbulb") }
                    Button { quick("Explain that a different way.") } label: { Label("Explain differently", systemImage: "arrow.triangle.2.circlepath") }
                    Button { quick("Quiz me with 3 questions, one at a time.") } label: { Label("Quiz me", systemImage: "questionmark.circle") }
                    Button { if let s = UIPasteboard.general.string { input = s } } label: { Label("Paste copied text", systemImage: "doc.on.clipboard") }
                }
                .padding(.horizontal).padding(.bottom, 8)
            }
            .navigationTitle("Learn")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { store.learnChat = [] } label: { Image(systemName: "square.and.pencil") }
                }
            }
        }
    }

    func quick(_ t: String) { input = t; send() }

    func send() {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !busy else { return }
        input = ""; busy = true
        let topic = store.activeConcept.map { "Current topic: \($0.name) in \(store.nm($0.course)). " } ?? ""
        Task {
            await store.sendChat(t, in: \.learnChat, system: topic + AIService.tutorPrompt)
            busy = false
        }
    }
}

// MARK: Understand
struct UnderstandView: View {
    @EnvironmentObject var store: Store
    @State private var input = ""
    @State private var busy = false
    @State private var scanned = ""
    @State private var showPicker = false
    @State private var item: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if store.shareGrades {
                    Label("Sharing class grades with the AI", systemImage: "eye").font(.caption2).foregroundStyle(.orange).padding(.top, 4)
                }
                if store.understandChat.isEmpty {
                    Spacer()
                    Text("Tap + to add a photo or paste text, then ask me to simplify it, quiz you, or make notes.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).padding()
                    Spacer()
                } else {
                    ChatScroll(messages: store.understandChat)
                }
                if !scanned.isEmpty {
                    HStack {
                        Image(systemName: "doc.text")
                        Text("Material added (\(scanned.count) characters)").font(.caption)
                        Spacer()
                        Button { scanned = "" } label: { Image(systemName: "xmark.circle.fill") }
                    }
                    .padding(10).background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                }
                Composer(text: $input, placeholder: "Ask about your material", busy: busy, onSend: send) {
                    Button { showPicker = true } label: { Label("Photo library", systemImage: "photo") }
                    Button { if let s = UIPasteboard.general.string { scanned = s } } label: { Label("Paste copied text", systemImage: "doc.on.clipboard") }
                    Button { quick("Explain this in simple words for a student.") } label: { Label("Simplify", systemImage: "text.badge.minus") }
                    Button { quick("Write 3 short practice questions about this, without answers.") } label: { Label("Quiz me", systemImage: "questionmark.circle") }
                    Button { quick("Turn this into short study notes.") } label: { Label("Make notes", systemImage: "list.bullet.rectangle") }
                    Button {
                        if let last = store.understandChat.last(where: { $0.role == "assistant" && !$0.pending }) { Speaker.say(last.text) }
                    } label: { Label("Read last answer aloud", systemImage: "speaker.wave.2") }
                }
                .padding(.horizontal).padding(.bottom, 8).padding(.top, 4)
            }
            .navigationTitle("Understand")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { store.understandChat = []; scanned = "" } label: { Image(systemName: "square.and.pencil") }
                }
            }
            .photosPicker(isPresented: $showPicker, selection: $item, matching: .images)
            .onChange(of: item) { _, new in
                guard let new else { return }
                Task {
                    if let d = try? await new.loadTransferable(type: Data.self), let img = UIImage(data: d) {
                        let t = await recognizeText(img)
                        scanned = t
                        if t.isEmpty {
                            store.understandChat.append(ChatMessage(role: "assistant", text: "I couldn't find any text in that photo. Try a clearer, well-lit picture."))
                        }
                    }
                    item = nil
                }
            }
        }
    }

    func quick(_ instruction: String) {
        if scanned.isEmpty {
            store.understandChat.append(ChatMessage(role: "assistant", text: "Add some material first: tap + and choose Photo library or Paste copied text."))
            return
        }
        input = instruction; send()
    }

    func send() {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !busy else { return }
        input = ""; busy = true
        var system = "You help students understand school material clearly. Be concise."
        if !scanned.isEmpty { system += "\nThe student's material:\n\(scanned)" }
        Task {
            await store.sendChat(t, in: \.understandChat, system: system)
            busy = false
        }
    }
}

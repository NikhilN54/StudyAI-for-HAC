import Foundation

struct ChatMessage: Identifiable, Codable {
    var id = UUID()
    var role: String          // "user" or "assistant"
    var text: String
    var pending = false       // true while waiting for (or retrying) the AI
    var status = ""
}

/// Talks directly from the phone to Google's Gemini API using the user's own key (stored in the Keychain).
enum AIService {
    static let defaultModel = "gemini-3.1-flash-lite"
    static let fallbackModel = "gemini-2.5-flash-lite"
    static var apiKey: String { Keychain.load("gemini.key") ?? "" }
    static var model: String { UserDefaults.standard.string(forKey: "gemini.model2") ?? defaultModel }

    enum Outcome { case ok(String), busy(String), badModel(String), failed(String) }

    /// Asks Gemini. If Google says it is busy or the limit was reached, waits and tries again a few times,
    /// calling onStatus so the screen can show a loading note. The last retry uses the fallback model.
    static func ask(system: String, messages: [ChatMessage],
                    onStatus: (@MainActor (String) -> Void)? = nil) async -> String {
        guard !apiKey.isEmpty else { return "Add your Gemini API key in Settings (gear icon on Home)." }
        let delays: [UInt64] = [5, 12, 25]
        var useFallback = false
        var lastNote = ""
        for attempt in 0...delays.count {
            let m = (useFallback || (attempt == delays.count && model != fallbackModel)) ? fallbackModel : model
            switch await once(model: m, system: system, messages: messages) {
            case .ok(let t): return t
            case .failed(let e): return "AI error: \(e)"
            case .badModel(let e):
                if useFallback || m == fallbackModel { return "AI error: \(e)" }
                useFallback = true; lastNote = e
            case .busy(let e):
                lastNote = e
                if attempt < delays.count {
                    if let cb = onStatus {
                        let msg = "AI is busy, retrying (\(attempt + 1)/\(delays.count))…"
                        await MainActor.run { cb(msg) }
                    }
                    try? await Task.sleep(nanoseconds: delays[attempt] * 1_000_000_000)
                    if Task.isCancelled { return "Cancelled." }
                }
            }
        }
        return "The AI is still busy. Please try again in a minute. (\(lastNote))"
    }

    private static func once(model: String, system: String, messages: [ChatMessage]) async -> Outcome {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent") else {
            return .failed("Invalid model name in Settings.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let contents: [[String: Any]] = messages.map {
            ["role": $0.role == "assistant" ? "model" : "user", "parts": [["text": $0.text]]]
        }
        let body: [String: Any] = ["system_instruction": ["parts": [["text": system]]], "contents": contents]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let busyCodes = [429, 500, 502, 503, 504]
            if let err = json?["error"] as? [String: Any] {
                let msg = (err["message"] as? String) ?? "Unknown error"
                let low = msg.lowercased()
                if code == 404 || low.contains("not found") || low.contains("not supported") { return .badModel(msg) }
                let words = ["high demand", "overloaded", "unavailable", "quota", "rate limit", "resource_exhausted", "try again"]
                if busyCodes.contains(code) || words.contains(where: { low.contains($0) }) { return .busy(msg) }
                return .failed(msg)
            }
            if busyCodes.contains(code) { return .busy("HTTP \(code)") }
            let cands = json?["candidates"] as? [[String: Any]]
            let parts = (cands?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
            let text = parts?.compactMap { $0["text"] as? String }.joined() ?? ""
            return .ok(text.isEmpty ? "No response." : text)
        } catch {
            return .busy(error.localizedDescription)
        }
    }

    static let tutorPrompt = """
    You are StudyAI, a tutor for a middle/high school student. Never give the final answer right away. \
    Give one short hint at a time, then offer a stronger hint, then a similar worked example, and only \
    explain the full concept if the student is still stuck. Keep replies under 80 words.
    """
}

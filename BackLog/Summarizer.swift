import BackLogCore
import Foundation
import FoundationModels
import Observation
import SwiftData

@Generable
struct GeneratedNotes {
    @Guide(description: "The substantive points made in this part, in the order they appear. Concrete facts, numbers, advice and conclusions; skip greetings, sponsor reads and calls to subscribe.", .maximumCount(6))
    var points: [GeneratedPoint]
}

@Generable
struct GeneratedPoint {
    @Guide(description: "Seconds from the start where the point is made, taken from the nearest [m:ss] marker before it. 0 when there are no markers.")
    var seconds: Int
    @Guide(description: "The point in one plain sentence.")
    var text: String
}

@Generable
struct GeneratedSummary {
    @Guide(description: "The single most important takeaway, in one or two sentences. State it directly, don't describe the video.")
    var takeaway: String
    @Guide(description: "The most important points, at most five, in the order they appear.", .maximumCount(5))
    var keyPoints: [GeneratedPoint]
}

/// Summarizes transcripts and articles with Apple's on-device model. Long sources are summarized in
/// chunks (the model's context is small), then the chunk notes are summarized again.
@MainActor @Observable
final class Summarizer {
    enum Status: Equatable { case idle, working(String), failed(String) }

    private(set) var status: [UUID: Status] = [:]
    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private var queue: [UUID] = []
    @ObservationIgnored private var busy = false

    init(container: ModelContainer) { self.container = container }

    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in System Settings to get summaries."
        case .unavailable(.modelNotReady): return "The on-device model is still downloading."
        case .unavailable(.deviceNotEligible): return "This Mac can't run Apple's on-device model."
        case .unavailable: return "Summaries aren't available on this Mac."
        }
    }

    func status(of item: Item) -> Status { status[item.id] ?? .idle }

    /// Queues a summary when the item has a transcript and no summary yet (or always, with `force`).
    func summarize(_ item: Item, force: Bool = false) {
        guard force || item.summaryJSON.isEmpty, !queue.contains(item.id) else { return }
        guard case .idle = status(of: item), Self.unavailableReason == nil else {
            if let reason = Self.unavailableReason { status[item.id] = .failed(reason) }
            return
        }
        guard !ItemFiles(id: item.id).transcript.isEmpty else { return }
        queue.append(item.id)
        status[item.id] = .working("Waiting…")
        Task { await drain() }
    }

    /// Checks every minute whether the model has become available (it downloads after Apple
    /// Intelligence is turned on), then summarizes everything that's waiting.
    func watchAvailability() async {
        var wasAvailable = Self.unavailableReason == nil
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            let available = Self.unavailableReason == nil
            if available, !wasAvailable {
                for (id, s) in status { if case .failed = s { status[id] = nil } }
                summarizeMissing()
            }
            wasAvailable = available
        }
    }

    func summarizeMissing() {
        let items = (try? container.mainContext.fetch(FetchDescriptor<Item>())) ?? []
        for item in items where item.summaryJSON.isEmpty && !item.state.isFinished { summarize(item) }
    }

    private func drain() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        while !queue.isEmpty {
            let id = queue.removeFirst()
            let items = (try? container.mainContext.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.id == id }))) ?? []
            guard let item = items.first else { status[id] = nil; continue }
            do {
                let summary = try await summarize(lines: ItemFiles(id: id).transcript, title: item.title, id: id)
                item.summaryJSON = summary.json
                try? container.mainContext.save()
                status[id] = .idle
            } catch {
                status[id] = .failed(Self.describe(error))
            }
        }
    }

    private func summarize(lines: [TranscriptLine], title: String, id: UUID) async throws -> Summary {
        let model = SystemLanguageModel.default
        // ~3.5 characters per token; leave room for instructions and the answer.
        let budget = max(2000, Int(Double(model.contextSize) * 3.5 * 0.55))
        let chunks = Transcript.chunks(lines, maxCharacters: budget)
        let instructions = """
        You take notes on videos so someone can decide whether to watch them, or skip them and still \
        know what was said. Be specific and factual. Write in the language of the transcript.
        """
        var notes: [SummaryPoint] = []
        for (i, chunk) in chunks.enumerated() {
            status[id] = .working(chunks.count > 1 ? "Reading part \(i + 1) of \(chunks.count)…" : "Summarizing…")
            let session = LanguageModelSession(model: model, instructions: instructions)
            let response = try await session.respond(
                to: "Video: \(title)\nTranscript part \(i + 1) of \(chunks.count):\n\(chunk)",
                generating: GeneratedNotes.self)
            notes += response.content.points.map { SummaryPoint(seconds: Double($0.seconds), text: $0.text) }
        }
        notes.sort { ($0.seconds ?? 0) < ($1.seconds ?? 0) }

        status[id] = .working("Writing the takeaway…")
        var noteText = notes.map { "[\(Transcript.clock($0.seconds ?? 0))] \($0.text)" }.joined(separator: "\n")
        if noteText.count > budget { noteText = String(noteText.prefix(budget)) }
        let session = LanguageModelSession(model: model, instructions: instructions)
        let final = try await session.respond(
            to: "Video: \(title)\nNotes taken while watching:\n\(noteText)",
            generating: GeneratedSummary.self).content
        let minutes = (lines.last?.start ?? 0) / 60
        return Summary(takeaway: final.takeaway,
                       keyPoints: final.keyPoints.map { SummaryPoint(seconds: Double($0.seconds), text: $0.text) },
                       allPoints: notes,
                       sourceMinutes: minutes > 0 ? minutes : nil)
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? LanguageModelSession.GenerationError {
            switch e {
            case .guardrailViolation: return "The on-device model declined to summarize this."
            case .exceededContextWindowSize: return "Too long for the on-device model."
            case .unsupportedLanguageOrLocale: return "This language isn't supported by the on-device model."
            default: break
            }
        }
        return error.localizedDescription
    }
}

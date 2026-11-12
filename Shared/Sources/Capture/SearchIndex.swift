import BackLogCore
import Foundation
import NaturalLanguage
import Observation
import SwiftData

/// Finds items by words and by meaning. Words match anywhere in the stored search text (title,
/// caption, note, who shared it, text in the picture, what's in the picture, summary, transcript).
/// Meaning uses Apple's on-device sentence embedding, so "that bean snack recipe" finds a reel
/// captioned "crispy chickpeas". Vectors live only on this Mac and are rebuilt when missing.
@MainActor @Observable
final class SearchIndex {
    struct Hit: Identifiable {
        let item: Item
        let score: Double
        let snippet: String
        var id: UUID { item.id }
    }

    @ObservationIgnored private var vectors: [UUID: [[Double]]] = [:]
    @ObservationIgnored private let embedding = NLEmbedding.sentenceEmbedding(for: .english)
    @ObservationIgnored private let file: URL = ItemFiles.root.deletingLastPathComponent().appending(path: "search-vectors.json")
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init() {
        if let data = try? Data(contentsOf: file),
           let stored = try? JSONDecoder().decode([UUID: [[Double]]].self, from: data) {
            vectors = stored
        }
    }

    /// Transcript and article text for keyword search (first ~20k characters).
    static func extraText(for item: Item) -> String {
        let files = ItemFiles(id: item.id)
        let body = files.articleText ?? Transcript.plainText(files.transcript)
        return String(body.prefix(20_000))
    }

    /// Embeds the item's describing text in a few passages; search takes the best-matching one.
    func index(_ item: Item) {
        guard let embedding else { return }
        let passages = Self.passages(for: item)
        vectors[item.id] = passages.compactMap { embedding.vector(for: $0) }
        scheduleSave()
    }

    func indexMissing(_ items: [Item]) {
        for item in items where vectors[item.id] == nil { index(item) }
    }

    func remove(_ id: UUID) {
        vectors[id] = nil
        scheduleSave()
    }

    static func passages(for item: Item) -> [String] {
        var passages = [item.title]
        if !item.details.isEmpty { passages.append(String(item.details.prefix(600))) }
        if !item.imageLabels.isEmpty { passages.append(item.imageLabels) }
        if !item.imageText.isEmpty { passages.append(String(item.imageText.prefix(400))) }
        if !item.note.isEmpty { passages.append(item.note) }
        if let s = item.summary {
            passages.append(s.takeaway)
            passages += s.keyPoints.prefix(5).map(\.text)
        }
        // A few sentences from the start of the body, so "the one about X" finds it even
        // without a summary. Sentence embeddings work best on short passages.
        let body = SearchIndex.extraText(for: item)
        let sentences = body.split(whereSeparator: { ".!?\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 40 && !$0.hasPrefix("#") && !$0.hasPrefix("![") }
        passages += sentences.prefix(6).map { String($0.prefix(300)) }
        return passages.filter { $0.count > 2 }
    }

    /// Ranks items for a query: every word must appear (prefix match) for a keyword hit; meaning
    /// adds to that and can surface items with none of the words.
    func search(_ query: String, in items: [Item]) -> [Hit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        let words = q.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).map(String.init)
        let queryVector = q.count > 2 ? embedding?.vector(for: q) : nil

        // Meaning-only hits must be among the closest few and reasonably close; sentence
        // similarity scores are low in absolute terms, so the cut is relative.
        var semanticScores: [UUID: Double] = [:]
        if let queryVector {
            for item in items {
                if let passages = vectors[item.id] {
                    semanticScores[item.id] = passages.map { Self.cosine(queryVector, $0) }.max() ?? 0
                }
            }
        }
        let topSemantic = Set(semanticScores.sorted { $0.value > $1.value }.prefix(8).filter { $0.value >= 0.33 }.map(\.key))

        var hits: [Hit] = []
        for item in items {
            let text = item.searchText.isEmpty ? item.title.lowercased() : item.searchText
            let matched = words.filter { text.contains($0) }
            var score = Double(matched.count) / Double(max(1, words.count))
            if matched.count == words.count { score += 1 }
            if words.allSatisfy({ item.title.lowercased().contains($0) }) { score += 0.5 }
            let semantic = semanticScores[item.id] ?? 0
            score += max(0, semantic - 0.2) * 3
            // Keep keyword hits, and meaning-only hits that are clearly related.
            guard matched.count == words.count || topSemantic.contains(item.id) else { continue }
            hits.append(Hit(item: item, score: score, snippet: Self.snippet(for: item, words: words)))
        }
        return hits.sorted { $0.score > $1.score }.prefix(100).map { $0 }
    }

    static func snippet(for item: Item, words: [String]) -> String {
        let fields = [item.details, item.note, item.imageText, item.summary?.takeaway ?? "", item.imageLabels]
        for field in fields where !field.isEmpty {
            let lower = field.lowercased()
            if let w = words.first(where: { lower.contains($0) }), let r = lower.range(of: w) {
                let start = field.index(field.startIndex, offsetBy: max(0, lower.distance(from: lower.startIndex, to: r.lowerBound) - 40), limitedBy: field.endIndex) ?? field.startIndex
                return (start > field.startIndex ? "…" : "") + String(field[start...].prefix(140))
            }
        }
        return String((item.summary?.takeaway ?? item.details).prefix(140))
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return dot / (sqrt(na * nb) + 1e-9)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = vectors
        let file = file
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: file, options: .atomic)
        }
    }
}

import Foundation
import Vision

/// Reads text and recognizes things in an item's preview image, on this Mac, so you can find a
/// reel by what's in its picture ("pasta", "beach", the words on a slide).
enum ImageAnalyzer {
    struct Result {
        var text: String
        var labels: [String]
    }

    static func analyze(_ file: URL) async -> Result? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return await Task.detached(priority: .utility) {
            let handler = VNImageRequestHandler(url: file)
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.usesLanguageCorrection = true
            textRequest.automaticallyDetectsLanguage = true
            let classify = VNClassifyImageRequest()
            do { try handler.perform([textRequest, classify]) } catch { return nil }

            let text = (textRequest.results ?? [])
                .compactMap { $0.topCandidates(1).first }
                .filter { $0.confidence > 0.4 }
                .map(\.string)
                .joined(separator: " ")
            let labels = (classify.results ?? [])
                .filter { $0.hasMinimumPrecision(0.2, forRecall: 0.7) }
                .sorted { $0.confidence > $1.confidence }
                .prefix(12)
                .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
            return Result(text: text, labels: Array(labels))
        }.value
    }
}

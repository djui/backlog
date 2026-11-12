import AVFoundation
import BackLogCore
import Foundation
import NaturalLanguage
import Speech
import Vision

/// For short videos without captions (reels, Shorts): a transcript from the speech, made with
/// Apple's on-device transcriber, and the text shown on screen (recipes, lists, subtitles burned
/// into the video), read from frames. Both stay on this Mac.
enum MediaAnalyzer {
    /// Only short videos: long ones have captions far more often, and take long to transcribe.
    static let maxDuration: Double = 10 * 60

    static func shouldAnalyze(_ item: Item, files: ItemFiles) -> Bool {
        item.kind.isPlayable && files.media != nil && item.durationSeconds > 0 && item.durationSeconds <= maxDuration
    }

    /// Writes subs.speech.vtt when there are no captions yet, and screen.txt with the text on
    /// screen. Returns the on-screen text, if any.
    @discardableResult
    static func analyze(_ item: Item, files: ItemFiles) async -> String? {
        guard let media = files.media else { return nil }
        if files.subtitles.isEmpty {
            let language = languageHint(for: item)
            if let lines = try? await transcribe(media, language: language), !lines.isEmpty {
                try? Transcript.vtt(lines).write(to: files.directory.appending(path: "subs.speech.vtt"), atomically: true, encoding: .utf8)
            }
        }
        let screenFile = files.directory.appending(path: "screen.txt")
        if let existing = try? String(contentsOf: screenFile, encoding: .utf8) { return existing }
        guard media.pathExtension != "m4a", let text = await screenText(media), !text.isEmpty else {
            try? "".write(to: screenFile, atomically: true, encoding: .utf8)
            return nil
        }
        try? text.write(to: screenFile, atomically: true, encoding: .utf8)
        return text
    }

    /// The caption's language is the best guess for what's spoken; else the system language.
    static func languageHint(for item: Item) -> Locale {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString([item.title, item.details].joined(separator: " "))
        if let lang = recognizer.dominantLanguage, lang != .undetermined { return Locale(identifier: lang.rawValue) }
        return Locale.current
    }

    // MARK: Speech

    static func transcribe(_ media: URL, language: Locale) async throws -> [TranscriptLine] {
        var supported = await SpeechTranscriber.supportedLocale(equivalentTo: language)
        if supported == nil { supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) }
        guard let locale = supported else { return [] }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        // The language model is a system download the first time a language is used.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let audioURL = try await extractAudio(media)
        defer { if audioURL != media { try? FileManager.default.removeItem(at: audioURL) } }
        let file = try AVAudioFile(forReading: audioURL)

        let collector = Task {
            var lines: [TranscriptLine] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                lines.append(TranscriptLine(start: result.range.start.seconds, text: text))
            }
            return lines
        }
        let analyzer = try await SpeechAnalyzer(inputAudioFile: file, modules: [transcriber], finishAfterFile: true)
        _ = analyzer
        return try await collector.value
    }

    /// An audio-only copy, since AVAudioFile can't read the audio of a video file directly.
    static func extractAudio(_ media: URL) async throws -> URL {
        if media.pathExtension == "m4a" { return media }
        let out = FileManager.default.temporaryDirectory.appending(path: "backlog-\(UUID().uuidString).m4a")
        let asset = AVURLAsset(url: media)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ToolFailure(message: "Couldn't read the audio")
        }
        try await export.export(to: out, as: .m4a)
        return out
    }

    // MARK: Text on screen

    /// Text recognized in a frame every two seconds (at most 45 frames), each line once, in order.
    static func screenText(_ media: URL) async -> String? {
        let asset = AVURLAsset(url: media)
        guard let duration = try? await asset.load(.duration).seconds, duration > 0 else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        let step = max(2, duration / 45)
        // Text often appears a word at a time or half cut off; keep the fullest version of each line.
        var keys: [String] = []
        var lines: [String] = []
        var t = min(0.5, duration / 2)
        while t < duration {
            if let image = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                for line in recognize(image) {
                    let key = line.lowercased().filter { $0.isLetter || $0.isNumber }
                    guard key.count >= 3, !keys.contains(where: { $0.contains(key) }) else { continue }
                    if let i = keys.firstIndex(where: { key.contains($0) }) {
                        keys[i] = key
                        lines[i] = line
                    } else {
                        keys.append(key)
                        lines.append(line)
                    }
                }
            }
            t += step
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    static func recognize(_ image: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first }
            .filter { $0.confidence > 0.5 }
            .map(\.string)
    }
}

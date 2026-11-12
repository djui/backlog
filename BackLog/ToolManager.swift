import AVFoundation
import BackLogCore
import Foundation
import Observation

/// Keeps BackLog's own copies of yt-dlp and deno (which yt-dlp needs for YouTube) in
/// ~/Library/Application Support/BackLog/bin, downloaded from their GitHub releases and
/// refreshed weekly — sites change often and yt-dlp follows quickly. Homebrew's copies are used
/// instead when they're installed. ffmpeg is optional: without it, BackLog joins video and audio
/// itself.
@MainActor @Observable
final class ToolManager {
    static let shared = ToolManager()

    enum State: Equatable { case unknown, ready, installing(String), failed(String) }
    private(set) var state: State = .unknown
    private(set) var ytdlpVersion: String?

    nonisolated static let directory: URL = ItemFiles.root.deletingLastPathComponent().appending(path: "bin", directoryHint: .isDirectory)

    private static let sources: [String: URL] = [
        "yt-dlp": URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!,
        "deno": URL(string: "https://github.com/denoland/deno/releases/latest/download/deno-aarch64-apple-darwin.zip")!,
    ]

    /// Makes sure yt-dlp and deno exist and are fresh. Cheap when they are.
    func ensure(forceUpdate: Bool = false) async {
        do {
            for name in ["yt-dlp", "deno"] {
                let managed = Self.directory.appending(path: name)
                let elsewhere = Tools.searchPaths.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(name)") }
                if elsewhere && !FileManager.default.fileExists(atPath: managed.path) { continue }
                let age = (try? managed.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Date.now.timeIntervalSince($0) }
                guard forceUpdate || age == nil || age! > 7 * 86_400 else { continue }
                state = .installing(name)
                try await install(name, to: managed)
            }
            if let ytdlp = Tools.ytdlp {
                ytdlpVersion = try? await Tools.run(ytdlp, ["--version"]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            state = Tools.ytdlp == nil ? .failed("yt-dlp isn't installed") : .ready
        } catch {
            state = Tools.ytdlp == nil ? .failed("Couldn't download the video tools: \(error.localizedDescription)") : .ready
        }
    }

    private func install(_ name: String, to destination: URL) async throws {
        guard let source = Self.sources[name] else { return }
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let (download, response) = try await URLSession.shared.download(from: source)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ToolFailure(message: "\(name): download failed") }
        let staging = Self.directory.appending(path: ".\(name).new")
        try? FileManager.default.removeItem(at: staging)
        if source.pathExtension == "zip" {
            let unzipDir = Self.directory.appending(path: ".\(name)-unzip")
            try? FileManager.default.removeItem(at: unzipDir)
            _ = try await Tools.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", download.path, unzipDir.path])
            try FileManager.default.moveItem(at: unzipDir.appending(path: name), to: staging)
            try? FileManager.default.removeItem(at: unzipDir)
        } else {
            try FileManager.default.moveItem(at: download, to: staging)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
        _ = try? FileManager.default.replaceItemAt(destination, withItemAt: staging)
        if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.moveItem(at: staging, to: destination) }
        // Make the age check count from now.
        try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: destination.path)
    }
}

/// Joins separately downloaded video and audio streams into media.mp4 without re-encoding.
enum MediaJoiner {
    static func joinIfNeeded(in directory: URL) async throws {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let parts = YTDLP.streamParts(in: names)
        let output = directory.appending(path: "media.mp4")
        defer {
            // A single downloaded file (or audio only) is used as is.
            for name in [parts.video, parts.audio].compactMap({ $0 }) {
                let url = directory.appending(path: name)
                guard FileManager.default.fileExists(atPath: url.path), !FileManager.default.fileExists(atPath: output.path) else { continue }
                let ext = url.pathExtension
                try? FileManager.default.moveItem(at: url, to: directory.appending(path: "media.\(ext)"))
            }
        }
        guard let v = parts.video, let a = parts.audio else { return }
        let video = AVURLAsset(url: directory.appending(path: v))
        let audio = AVURLAsset(url: directory.appending(path: a))
        let composition = AVMutableComposition()
        let duration = try await video.load(.duration)
        if let track = try await video.loadTracks(withMediaType: .video).first,
           let out = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try out.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
            out.preferredTransform = try await track.load(.preferredTransform)
        }
        if let track = try await audio.loadTracks(withMediaType: .audio).first,
           let out = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let audioDuration = try await audio.load(.duration)
            try out.insertTimeRange(CMTimeRange(start: .zero, duration: min(duration, audioDuration)), of: track, at: .zero)
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw ToolFailure(message: "Couldn't join video and audio")
        }
        try await export.export(to: output, as: .mp4)
        try? FileManager.default.removeItem(at: directory.appending(path: v))
        try? FileManager.default.removeItem(at: directory.appending(path: a))
    }

    /// yt-dlp saves thumbnails as WebP without ffmpeg; BackLog uses JPEG.
    static func normalizeThumbnail(in directory: URL) {
        let jpg = directory.appending(path: "thumb.jpg")
        guard !FileManager.default.fileExists(atPath: jpg.path) else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        guard let other = names.first(where: { $0.hasPrefix("thumb.") }),
              let data = try? Data(contentsOf: directory.appending(path: other)),
              let jpeg = ImageTools.jpeg(from: data, maxDimension: 1280) else { return }
        try? jpeg.write(to: jpg)
        try? FileManager.default.removeItem(at: directory.appending(path: other))
    }
}

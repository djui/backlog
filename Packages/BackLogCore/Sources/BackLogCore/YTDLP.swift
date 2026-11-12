import Foundation

/// Download size presets. Small is the default: good enough for a laptop screen, ~4 MB a minute.
public enum DownloadQuality: String, Codable, CaseIterable, Sendable {
    case small, medium, high, audio

    public var label: String {
        switch self {
        case .small: "Small · 480p"
        case .medium: "Medium · 720p"
        case .high: "High · 1080p"
        case .audio: "Audio only"
        }
    }

    /// Approximate megabytes per minute, for showing sizes before downloading.
    public var megabytesPerMinute: Double {
        switch self {
        case .small: 4
        case .medium: 9
        case .high: 21
        case .audio: 1
        }
    }

    /// Without ffmpeg: the video and audio streams downloaded separately (BackLog joins them with
    /// AVFoundation), else a single file that has both.
    public var separateStreamsSelector: String {
        func video(_ height: Int) -> String {
            "bv*[height<=\(height)][vcodec^=avc1][ext=mp4],ba[ext=m4a]/b[height<=\(height)][ext=mp4]/b[ext=mp4]"
        }
        switch self {
        case .small: return video(480)
        case .medium: return video(720)
        case .high: return video(1080)
        case .audio: return "ba[ext=m4a]"
        }
    }

    /// yt-dlp format selector. Video must be H.264 (avc1) and audio AAC (m4a): AVFoundation plays
    /// neither VP9 nor Opus from an mp4.
    public var formatSelector: String {
        func video(_ height: Int) -> String {
            "bv*[height<=\(height)][vcodec^=avc1]+ba[ext=m4a]/b[height<=\(height)][vcodec^=avc1]/bv*[height<=\(height)]+ba/b[height<=\(height)]/b"
        }
        switch self {
        case .small: return video(480)
        case .medium: return video(720)
        case .high: return video(1080)
        case .audio: return "ba[ext=m4a]/ba"
        }
    }
}

/// What `yt-dlp -J` says about a URL. Only the fields BackLog uses.
public struct YTDLPMetadata: Decodable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var uploader: String?
    public var channel: String?
    public var duration: Double?
    public var thumbnail: String?
    public var webpageURL: String?
    public var uploadDate: String?
    public var description: String?
    public var chapters: [Chapter]?
    public var language: String?
    /// The site, as yt-dlp names it ("Youtube", "Instagram").
    public var extractor: String?

    public struct Chapter: Decodable, Equatable, Sendable {
        public var title: String
        public var startTime: Double
        enum CodingKeys: String, CodingKey { case title, startTime = "start_time" }
    }

    enum CodingKeys: String, CodingKey {
        case id, title, uploader, channel, duration, thumbnail, description, chapters, language
        case extractor = "extractor_key"
        case webpageURL = "webpage_url", uploadDate = "upload_date"
    }

    public var author: String { channel ?? uploader ?? "" }
}

/// Download progress as yt-dlp reports it through BackLog's progress template.
public struct DownloadProgress: Equatable, Sendable {
    public var downloadedBytes: Double
    public var totalBytes: Double?
    public var bytesPerSecond: Double?

    public var fraction: Double? {
        guard let total = totalBytes, total > 0 else { return nil }
        return min(1, max(0, downloadedBytes / total))
    }
}

public enum YTDLP {
    static let progressPrefix = "BLPROG"

    /// Arguments for reading a URL's metadata as JSON.
    public static func metadataArguments(for url: URL) -> [String] {
        ["--dump-single-json", "--no-playlist", "--no-warnings", "--skip-download", url.absoluteString]
    }

    /// Arguments that download into `directory` as `media.<ext>`, with `thumb.<ext>` and
    /// `info.info.json` beside it. Without ffmpeg, separate streams land as `media.f<id>.<ext>` to be
    /// joined afterwards (`MediaStreams.parts`).
    public static func downloadArguments(for url: URL, into directory: URL, quality: DownloadQuality, ffmpeg: URL?) -> [String] {
        let dir = directory.path
        guard ffmpeg != nil else {
            return [
                "--no-playlist", "--newline", "--no-colors", "--no-warnings", "--no-part",
                "-f", quality.separateStreamsSelector,
                "-o", "\(dir)/media.f%(format_id)s.%(ext)s",
                "-o", "thumbnail:\(dir)/thumb.%(ext)s",
                "-o", "infojson:\(dir)/info",
                "--write-thumbnail", "--write-info-json",
                "--progress-template", "download:\(progressPrefix) %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s %(progress.speed)s",
                url.absoluteString,
            ]
        }
        var args = [
            "--no-playlist", "--newline", "--no-colors", "--no-warnings", "--no-part",
            "-f", quality.formatSelector,
            "-o", "\(dir)/media.%(ext)s",
            "-o", "thumbnail:\(dir)/thumb.%(ext)s",
            "-o", "infojson:\(dir)/info",
            "--write-thumbnail", "--convert-thumbnails", "jpg",
            "--write-info-json",
            "--progress-template", "download:\(progressPrefix) %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s %(progress.speed)s",
        ]
        if quality == .audio {
            args += ["-x", "--audio-format", "m4a"]
        } else {
            args += ["--merge-output-format", "mp4", "--remux-video", "mp4"]
        }
        if let ffmpeg { args += ["--ffmpeg-location", ffmpeg.path] }
        args.append(url.absoluteString)
        return args
    }

    /// Separate stream files (`media.f<id>.<ext>`) in a folder: the video and the audio part.
    public static func streamParts(in names: [String]) -> (video: String?, audio: String?) {
        let parts = names.filter { $0.hasPrefix("media.f") }
        let audio = parts.first { $0.hasSuffix(".m4a") }
        let video = parts.first { $0.hasSuffix(".mp4") || $0.hasSuffix(".m4v") || $0.hasSuffix(".mov") }
        return (video, audio)
    }

    /// Arguments that fetch captions only, as `subs.<lang>.vtt`: uploaded captions first, else the
    /// automatic ones, in the video's own language. Never translations — asking for many languages
    /// gets rate-limited.
    public static func subtitleArguments(for url: URL, into directory: URL, language: String?) -> [String] {
        let lang = (language?.isEmpty == false ? language! : "en").split(separator: "-").first.map(String.init) ?? "en"
        return [
            "--no-playlist", "--no-colors", "--no-warnings", "--skip-download", "--ignore-errors",
            "--write-subs", "--write-auto-subs", "--sub-langs", "\(lang),\(lang)-orig,\(lang)-[A-Z]+",
            "--sub-format", "vtt",
            "-o", "\(directory.path)/subs.%(ext)s",
            url.absoluteString,
        ]
    }

    /// Parses one stdout line. Returns nil for lines that aren't progress.
    public static func parseProgress(_ line: String) -> DownloadProgress? {
        let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard parts.count == 5, parts[0] == progressPrefix, let downloaded = Double(parts[1]) else { return nil }
        let total = Double(parts[2]) ?? Double(parts[3])
        return DownloadProgress(downloadedBytes: downloaded, totalBytes: total, bytesPerSecond: Double(parts[4]))
    }

    /// A short, human message for yt-dlp's stderr.
    public static func friendlyError(_ stderr: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline).map(String.init)
        let error = lines.last { $0.hasPrefix("ERROR:") } ?? lines.last ?? "Download failed"
        let lower = error.lowercased()
        if lower.contains("sign in") || lower.contains("login") || lower.contains("members-only") || lower.contains("private") {
            return "Needs a sign-in — kept as a link"
        }
        if lower.contains("unsupported url") { return "Not downloadable — kept as a link" }
        if lower.contains("http error 429") { return "Rate-limited by the site, try again later" }
        var message = error.replacingOccurrences(of: "ERROR: ", with: "")
        if let range = message.range(of: #"^\[[^\]]+\] [^:]+: "#, options: .regularExpression) { message.removeSubrange(range) }
        return message
    }
}

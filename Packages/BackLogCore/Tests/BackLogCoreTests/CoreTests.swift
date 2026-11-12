import Foundation
import Testing
@testable import BackLogCore

@Suite struct ClassifierTests {
    @Test(arguments: [
        ("https://www.youtube.com/watch?v=abc", MediaKind.video),
        ("https://youtu.be/abc", .video),
        ("https://m.youtube.com/watch?v=abc", .video),
        ("https://www.youtube.com/shorts/abc", .reel),
        ("https://www.instagram.com/reel/XYZ/", .reel),
        ("https://www.instagram.com/someone/", .link),
        ("https://news.ycombinator.com/item?id=1", .thread),
        ("https://example.com/post/1", .article),
        ("https://x.com/a/status/1", .link),
    ])
    func classifies(_ url: String, _ kind: MediaKind) {
        #expect(SourceClassifier.kind(for: URL(string: url)!) == kind)
    }

    @Test func canonicalizesYouTube() {
        #expect(SourceClassifier.canonical(URL(string: "https://youtu.be/abc?si=track")!).absoluteString == "https://www.youtube.com/watch?v=abc")
        #expect(SourceClassifier.canonical(URL(string: "https://www.youtube.com/shorts/abc")!).absoluteString == "https://www.youtube.com/watch?v=abc")
    }

    @Test func dropsTrackingParameters() {
        let url = URL(string: "http://example.com/a?utm_source=x&id=3&fbclid=y#top")!
        #expect(SourceClassifier.canonical(url).absoluteString == "https://example.com/a?id=3")
    }
}

@Suite struct SharedLinkTests {
    @Test func findsURLInChatMessage() throws {
        let link = try #require(SharedLink.parse("you have to watch this 👇\nhttps://youtu.be/abc\n(part 2 especially)"))
        #expect(link.url.absoluteString == "https://youtu.be/abc")
        #expect(link.kind == .video)
        #expect(link.note == "you have to watch this 👇 (part 2 especially)")
    }

    @Test func rejectsTextWithoutLink() {
        #expect(SharedLink.parse("no link here") == nil)
        #expect(SharedLink.parse("   ") == nil)
    }
}

@Suite struct YTDLPTests {
    @Test func parsesProgress() throws {
        let p = try #require(YTDLP.parseProgress("BLPROG 500 1000 NA 250.5"))
        #expect(p.fraction == 0.5)
        #expect(p.bytesPerSecond == 250.5)
        let estimated = try #require(YTDLP.parseProgress("BLPROG 10 NA 40 NA"))
        #expect(estimated.fraction == 0.25)
        #expect(estimated.bytesPerSecond == nil)
        #expect(YTDLP.parseProgress("[download] Destination: x.mp4") == nil)
    }

    @Test func downloadArgumentsUseFolderAndQuality() {
        let args = YTDLP.downloadArguments(for: URL(string: "https://youtu.be/a")!, into: URL(fileURLWithPath: "/tmp/item"), quality: .small, ffmpeg: nil)
        #expect(args.contains("/tmp/item/media.%(ext)s"))
        #expect(args.contains(DownloadQuality.small.formatSelector))
        #expect(args.last == "https://youtu.be/a")
        #expect(!args.contains("--ffmpeg-location"))
    }

    @Test func subtitleArgumentsUseOwnLanguageOnly() {
        let args = YTDLP.subtitleArguments(for: URL(string: "https://youtu.be/a")!, into: URL(fileURLWithPath: "/tmp/i"), language: "de-DE")
        #expect(args.contains("de,de-orig,de-[A-Z]+"))
        #expect(args.contains("/tmp/i/subs.%(ext)s"))
        #expect(args.contains("--skip-download"))
    }

    @Test func decodesMetadata() throws {
        let json = #"{"id":"a","title":"T","channel":"C","duration":61.0,"webpage_url":"https://x","chapters":[{"title":"Intro","start_time":0}]}"#
        let m = try JSONDecoder().decode(YTDLPMetadata.self, from: Data(json.utf8))
        #expect(m.author == "C")
        #expect(m.chapters?.first?.title == "Intro")
    }

    @Test func friendlyErrors() {
        #expect(YTDLP.friendlyError("ERROR: [youtube] abc: Sign in to confirm your age") == "Needs a sign-in — kept as a link")
        #expect(YTDLP.friendlyError("WARNING: x\nERROR: [generic] Unsupported URL: https://a") == "Not downloadable — kept as a link")
    }
}

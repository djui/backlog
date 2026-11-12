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

@Suite struct TranscriptTests {
    // YouTube automatic captions: rolling cues that repeat the previous line, with word timing tags.
    let autoVTT = """
    WEBVTT
    Kind: captions
    Language: en

    00:00:00.000 --> 00:00:02.000 align:start position:0%
    hello<00:00:00.500><c> everyone</c>

    00:00:02.000 --> 00:00:02.010 align:start position:0%
    hello everyone

    00:00:02.010 --> 00:00:05.000 align:start position:0%
    hello everyone
    today<00:00:03.000><c> we bake</c> &amp; eat

    00:01:05.000 --> 00:01:06.000
    the end
    """

    @Test func parsesAndDeduplicatesRollingCaptions() {
        let lines = Transcript.parseVTT(autoVTT)
        #expect(lines.map(\.text) == ["hello everyone", "today we bake & eat", "the end"])
        #expect(lines.map(\.start) == [0, 2.01, 65])
    }

    @Test func groupsIntoParagraphsAndChunks() {
        let lines = Transcript.parseVTT(autoVTT)
        #expect(Transcript.paragraphs(lines).count == 2)
        let chunks = Transcript.chunks(lines, maxCharacters: 40)
        #expect(chunks.count == 2)
        #expect(chunks[0].hasPrefix("[0:00] hello everyone today"))
        #expect(chunks[1].hasPrefix("[1:05] the end"))
    }

    @Test func formatsClock() {
        #expect(Transcript.clock(65) == "1:05")
        #expect(Transcript.clock(3725) == "1:02:05")
    }
}

@Suite struct SummaryTests {
    @Test func levelsAndRoundTrip() throws {
        let s = Summary(takeaway: "Feed it daily.", keyPoints: [.init(seconds: 10, text: "a")], allPoints: [.init(seconds: 10, text: "a"), .init(seconds: 20, text: "b")])
        #expect(s.points(for: .tldr).isEmpty)
        #expect(s.points(for: .keyPoints).count == 1)
        #expect(s.points(for: .detailed).count == 2)
        #expect(Summary(json: s.json) == s)
        #expect(Summary(json: "") == nil)
    }
}

@Suite struct LinkMetadataTests {
    @Test func parsesOpenGraph() {
        let html = """
        <html><head><title>Fallback &amp; title</title>
        <meta property="og:title" content="Crispy chickpeas in 20 minutes">
        <meta content="Roast them hot &amp; fast. #recipe" property="og:description" />
        <meta property='og:image' content='/img/a.jpg'>
        <meta property="og:site_name" content="Instagram">
        <meta name="author" content="chef.anna">
        <meta property="article:published_time" content="2025-03-01T10:00:00Z">
        </head><body><meta property="og:title" content="ignored"></body></html>
        """
        let m = LinkMetadata.parse(html: html, baseURL: URL(string: "https://www.instagram.com/reel/X/")!)
        #expect(m.title == "Crispy chickpeas in 20 minutes")
        #expect(m.description == "Roast them hot & fast. #recipe")
        #expect(m.imageURL?.absoluteString == "https://www.instagram.com/img/a.jpg")
        #expect(m.siteName == "Instagram")
        #expect(m.author == "chef.anna")
        #expect(m.publishedAt != nil)
    }

    @Test func fallsBackToTitleTag() {
        let m = LinkMetadata.parse(html: "<head><title> A &#8211; B </title></head>", baseURL: URL(string: "https://a.b")!)
        #expect(m.title == "A – B")
    }

    @Test func hackerNewsID() {
        #expect(HackerNews.itemID(from: URL(string: "https://news.ycombinator.com/item?id=123")!) == 123)
        #expect(HackerNews.itemID(from: URL(string: "https://example.com/item?id=123")!) == nil)
    }
}

@Suite struct MarkdownTests {
    @Test func convertsArticleHTML() {
        let html = #"<h1>Title</h1><p>Some <strong>bold</strong> and <a href="https://x.y">a link</a>.</p><ul><li>One</li><li>Two</li></ul><img src="p.jpg" alt="Pic"><script>bad()</script>"#
        let md = MarkdownConverter.markdown(fromHTML: html)
        #expect(md == "# Title\n\nSome **bold** and [a link](https://x.y).\n\n- One\n- Two\n\n![Pic](p.jpg)\n")
    }
}

@Suite struct HistoryExportTests {
    let utc = TimeZone(identifier: "UTC")!
    func entry(_ title: String, at seconds: TimeInterval, takeaway: String? = nil) -> ExportEntry {
        ExportEntry(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(Int(seconds) % 10)")!, url: "https://x.y/\(title)",
                    title: title, type: "video", status: "watched", added: Date(timeIntervalSince1970: seconds - 60),
                    consumed: Date(timeIntervalSince1970: seconds), author: "Ch", durationMinutes: 12, sharedBy: "Anna · WhatsApp",
                    note: "line one\nline two", takeaway: takeaway, keyPoints: takeaway == nil ? [] : ["p1"])
    }

    @Test func markdownIsStableAndParseable() {
        let md = HistoryExport.markdown(day: "1970-01-01", entries: [entry("B", at: 7200, takeaway: "Do X."), entry("A", at: 3600)], timeZone: utc)
        #expect(md == """
        ---
        date: 1970-01-01
        source: backlog
        count: 2
        ---

        ## 01:00 · Watched · A

        - id: 00000000-0000-0000-0000-000000000000
        - url: https://x.y/A
        - type: video
        - status: watched
        - added: 1970-01-01T00:59:00Z
        - consumed: 1970-01-01T01:00:00Z
        - author: Ch
        - duration: 12 min
        - from: Anna · WhatsApp
        - note: line one line two

        ## 02:00 · Watched · B

        - id: 00000000-0000-0000-0000-000000000000
        - url: https://x.y/B
        - type: video
        - status: watched
        - added: 1970-01-01T01:59:00Z
        - consumed: 1970-01-01T02:00:00Z
        - author: Ch
        - duration: 12 min
        - from: Anna · WhatsApp
        - note: line one line two

        > Do X.

        - p1

        """)
    }

    @Test func writesFilesPerDayAndSkipsUnchanged() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let entries = [entry("A", at: 3600), entry("B", at: 86_400 * 400)]
        #expect(try HistoryExport.write(entries, to: dir) == 3)
        #expect(try HistoryExport.write(entries, to: dir) == 0)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "1970/" + HistoryExport.dayKey(Date(timeIntervalSince1970: 3600)) + ".md").path))
        let jsonl = try String(contentsOf: dir.appending(path: "backlog.jsonl"), encoding: .utf8)
        #expect(jsonl.split(separator: "\n").count == 2)
    }
}

@Suite struct StoragePolicyTests {
    let now = Date(timeIntervalSince1970: 100 * 86_400)
    func c(_ n: Int, finished: Bool = false, finishedDaysAgo: Double? = nil, addedDaysAgo: Double = 1, played: Double = 0, media: Bool = true, bytes: Int64 = 100) -> StoragePolicy.Candidate {
        .init(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02d", n))")!, isPlayable: true, isFinished: finished,
              finishedAt: finishedDaysAgo.map { now.addingTimeInterval(-$0 * 86_400) }, addedAt: now.addingTimeInterval(-addedDaysAgo * 86_400),
              lastPlayedPosition: played, sortIndex: Double(n), hasMedia: media, mediaBytes: bytes)
    }

    @Test func downloadsOnlyTheNextFew() {
        var p = StoragePolicy()
        p.downloadAhead = 2
        let items = [c(1, media: true), c(2, media: false), c(3, media: false), c(4, finished: true, media: false)]
        #expect(p.toDownload(items) == [items[1].id])
        p.autoDownload = .everything
        #expect(p.toDownload(items) == [items[1].id, items[2].id])
        p.autoDownload = .manual
        #expect(p.toDownload(items).isEmpty)
    }

    @Test func deletesWatchedUntouchedAndOverLimit() {
        var p = StoragePolicy()
        p.deleteWatchedAfterDays = 3
        p.deleteUntouchedAfterDays = 30
        p.limitBytes = 250
        let items = [
            c(1, finished: true, finishedDaysAgo: 5),       // watched long ago → delete
            c(2, finished: true, finishedDaysAgo: 1),       // watched recently → over limit → delete (oldest watched)
            c(3, addedDaysAgo: 40),                         // untouched 40 days → delete
            c(4, addedDaysAgo: 40, played: 12),             // started → keep
            c(5), c(6),
        ]
        #expect(Set(p.toDelete(items, now: now)) == Set([items[0].id, items[1].id, items[2].id, items[5].id]))
    }
}

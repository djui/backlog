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

    @Test func instagramAndYouTubeIgnoreShareParameters() {
        #expect(SourceClassifier.canonical(URL(string: "https://www.instagram.com/p/DdT_LiUCFKA/?img_index=9&stkn=MTVw")!).absoluteString == "https://www.instagram.com/p/DdT_LiUCFKA/")
        #expect(SourceClassifier.canonical(URL(string: "https://youtube.com/shorts/s2XKd0pe2Gc?is=Zec9")!).absoluteString == "https://www.youtube.com/watch?v=s2XKd0pe2Gc")
        #expect(SourceClassifier.canonical(URL(string: "https://www.youtube.com/watch?v=a&t=30&pp=x&feature=y")!).absoluteString == "https://www.youtube.com/watch?v=a&t=30")
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
        let args = YTDLP.downloadArguments(for: URL(string: "https://youtu.be/a")!, into: URL(fileURLWithPath: "/tmp/item"), quality: .small, ffmpeg: URL(fileURLWithPath: "/bin/ffmpeg"))
        #expect(args.contains("/tmp/item/media.%(ext)s"))
        #expect(args.contains(DownloadQuality.small.formatSelector))
        #expect(args.last == "https://youtu.be/a")
        #expect(args.contains("--ffmpeg-location"))
    }

    @Test func withoutFFmpegDownloadsSeparateStreams() {
        let args = YTDLP.downloadArguments(for: URL(string: "https://youtu.be/a")!, into: URL(fileURLWithPath: "/tmp/item"), quality: .small, ffmpeg: nil)
        #expect(args.contains(DownloadQuality.small.separateStreamsSelector))
        #expect(args.contains("/tmp/item/media.f%(format_id)s.%(ext)s"))
        #expect(!args.contains("--convert-thumbnails"))
        let parts = YTDLP.streamParts(in: ["media.f135.mp4", "media.f140.m4a", "thumb.webp"])
        #expect(parts.video == "media.f135.mp4" && parts.audio == "media.f140.m4a")
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

@Suite struct ChatImportTests {
    let utc = TimeZone(identifier: "UTC")!

    @Test func parsesWhatsAppExport() throws {
        let chat = """
        [2026-08-16, 06:37:56] Uwe: https://www.instagram.com/reel/DZ-0egMNKvD/?igsh=MXUw
        [2026-08-17, 14:43:08] Anna: look at this https://youtube.com/shorts/s2XKd0pe2Gc?is=Zec9
        still the same message
        [2026-08-18, 11:57:56] Uwe: https://www.instagram.com/reel/DZ-0egMNKvD/?stkn=other
        17/08/2026, 09:05 - Max: https://example.com/a
        """
        let entries = ChatImport.parse(chat, timeZone: utc)
        #expect(entries.count == 3)  // the second Instagram link is the same reel
        #expect(entries[0].sender == "Uwe")
        #expect(entries[0].link.kind == .reel)
        #expect(entries[0].date == Date(timeIntervalSince1970: 1786862276))
        #expect(entries[1].sender == "Anna" && entries[1].link.note == "look at this")
        #expect(entries[1].link.kind == .reel)
        #expect(entries[2].sender == "Max")
        let max = try #require(entries[2].date)
        #expect(Calendar(identifier: .gregorian).dateComponents(in: utc, from: max).day == 17)
    }

    @Test func plainTextWithSeveralLinks() {
        let entries = ChatImport.parse("one https://a.com/x and https://b.com/y")
        #expect(entries.map(\.link.url.host) == ["a.com", "b.com"])
        #expect(entries.allSatisfy { $0.date == nil && $0.sender == nil })
    }
}

@Suite struct CaptionTitleTests {
    @Test func recognizesPlaceholders() {
        #expect(CaptionTitle.isGeneric("Video by omer_yaskil"))
        #expect(CaptionTitle.isGeneric("Instagram"))
        #expect(CaptionTitle.isGeneric("omer_yaskil", author: "omer_yaskil"))
        #expect(!CaptionTitle.isGeneric("Crispy chickpeas in 20 minutes"))
    }

    @Test func titleFromCaption() {
        #expect(CaptionTitle.make(from: "🔥🔥🔥\nCrispy roasted chickpeas in 20 minutes. Oven at 220°C, olive oil, paprika. #recipe #snack @chef") == "Crispy roasted chickpeas in 20 minutes.")
        #expect(CaptionTitle.make(from: "#tbt #mood") == nil)
        #expect(CaptionTitle.make(from: "Wait for it 😂 @friend") == "Wait for it 😂")
        let long = String(repeating: "word ", count: 40)
        #expect(CaptionTitle.make(from: long)!.count <= 91)
        #expect(CaptionTitle.make(from: long)!.hasSuffix("…"))
    }

    @Test func instagramPageTitle() {
        #expect(CaptionTitle.instagramCaption(fromPageTitle: "Anna on Instagram: \"Best pasta ever\"") == "Best pasta ever")
        #expect(CaptionTitle.instagramCaption(fromPageTitle: "Some page") == nil)
    }
}

@Suite struct ListOptionsTests {
    @Test func lengthBuckets() {
        #expect(LengthFilter.under5.matches(seconds: 43))
        #expect(!LengthFilter.under5.matches(seconds: 0))
        #expect(LengthFilter.from5to15.matches(seconds: 600))
        #expect(LengthFilter.over15.matches(seconds: 1120))
        #expect(LengthFilter.any.matches(seconds: 0))
    }

    @Test func sortsByLengthWithUnknownLast() {
        let items: [(Double, Double)] = [(0, 1), (600, 2), (40, 3), (1200, 4)]
        let d = Date()
        let shortest = items.sorted { ListSort.shortest.areInIncreasingOrder(seconds: $0.0, $1.0, added: d, d, manual: $0.1, $1.1) }.map(\.1)
        let longest = items.sorted { ListSort.longest.areInIncreasingOrder(seconds: $0.0, $1.0, added: d, d, manual: $0.1, $1.1) }.map(\.1)
        #expect(shortest == [3, 2, 4, 1])
        #expect(longest == [4, 2, 3, 1])
    }
}

@Suite struct SpotifyTests {
    @Test func classifiesAndCanonicalizes() {
        let url = URL(string: "https://open.spotify.com/episode/0jZjDghybB9p3QnZVXIhgq?si=-Afh&utm_source=native-share-menu&t=5726&pi=i9SS")!
        #expect(SourceClassifier.kind(for: url) == .podcast)
        #expect(SourceClassifier.kind(for: URL(string: "https://open.spotify.com/track/abc")!) == .music)
        #expect(SourceClassifier.canonical(url).absoluteString == "https://open.spotify.com/episode/0jZjDghybB9p3QnZVXIhgq?t=5726")
    }

    @Test func parsesEpisodePage() {
        let html = """
        <head><meta property="og:site_name" content="Spotify"><meta name="description" content="Listen to this episode from The Joe Rogan Experience on Spotify. Jimmy Carr is a comedian.">
        <meta name="music:duration" content="10235"><meta name="music:release_date" content="2026-10-28T19:00:00Z">
        <meta property="og:title" content="#2571 - Jimmy Carr"><meta property="og:description" content="The Joe Rogan Experience · Episode"></head>
        """
        let m = LinkMetadata.parse(html: html, baseURL: URL(string: "https://open.spotify.com/episode/x")!)
        #expect(m.title == "#2571 - Jimmy Carr")
        #expect(m.author == "The Joe Rogan Experience")
        #expect(m.durationSeconds == 10235)
        #expect(m.publishedAt != nil)
        #expect(m.description?.hasPrefix("Listen to this episode") == true)
    }

    @Test func noteDropsRepeatedLink() throws {
        let link = try #require(SharedLink.parse("https://open.spotify.com/episode/x\nhttps://open.spotify.com/episode/x?si=1 Maybe good life advice"))
        #expect(link.note == "Maybe good life advice")
    }
}

@Suite struct VTTWriterTests {
    @Test func roundTrips() {
        let lines = [TranscriptLine(start: 0.5, text: "Preheat the oven."), TranscriptLine(start: 65.25, text: "Bake for 20 minutes.")]
        let vtt = Transcript.vtt(lines)
        #expect(vtt.contains("00:00:00.500 --> 00:01:05.250"))
        #expect(Transcript.parseVTT(vtt) == lines)
    }
}

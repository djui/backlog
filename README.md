# BackLog

Watch later, read later — offline. A Mac app (iPhone app to follow) that keeps everything you want
to watch or read in one queue, downloads what it can so it works offline, and keeps a permanent
history of what you've consumed.

- **Save anything.** Paste a link (⌘V), drop it on the window, press ⌘N, or share a whole chat
  message: BackLog finds the link and keeps the text as a note.
- **Videos offline.** YouTube and the other sites [yt-dlp](https://github.com/yt-dlp/yt-dlp)
  supports are downloaded small by default (480p, ≈4 MB a minute), with thumbnail and captions.
- **Resume anywhere.** Playback position is saved; finishing a video moves it to History.
- **History forever.** Items stay in History after their files are deleted.

## Status

Early. M1: add links, download, play, history. M2: transcripts, on-device summaries (TL;DR → detailed), Skim mode. M3: any link (articles saved offline, reels, Hacker News), preview images read with Vision, search by words and meaning (⌘F). M4: storage rules (download the next few, auto-delete watched, size limit), History export to Markdown + JSONL (for LifeLog), Settings, menu bar, Share menu, ⌥⌘L from any browser, stars.

## Install

Download the DMG from the [latest release](https://github.com/djui/backlog/releases/latest)
(macOS 26+, Apple silicon) — or see [uwe.social/backlog](https://uwe.social/backlog/).
BackLog fetches yt-dlp (and deno, which yt-dlp needs for YouTube) on first use and keeps them
current; Homebrew's copies are used when installed. ffmpeg is optional.

## Build

Needs Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
make run        # debug build and launch
make install    # release build into /Applications
make test       # core unit tests
make release    # tests, notarized DMG, Sparkle appcast, GitHub release
```

Add from anywhere with the URL scheme: `open "backlog://add?url=<url-encoded link>&from=Anna"`.

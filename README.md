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

## Build

Needs Xcode 27, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and, for now, Homebrew's
yt-dlp and ffmpeg:

```bash
brew install xcodegen yt-dlp ffmpeg
make run        # debug build and launch
make install    # release build into /Applications
make test       # core unit tests
```

Add from anywhere with the URL scheme: `open "backlog://add?url=<url-encoded link>&from=Anna"`.

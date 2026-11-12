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

Early. Milestone 1 (proof of concept): add links, download videos, play them, history.

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

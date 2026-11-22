# Digital Reaper

Media downloader built by Wheezy.

Repository: https://github.com/Wheezy72/Digital-Reaper

## What it does

Downloads video and audio from any site `yt-dlp` supports. You can queue links in two text files, paste one link, or drop a JSON manifest on the launcher. Playlists download in one pass and resume where they stopped. Every finished file is checked with `ffprobe` before its link is removed from the queue, so a broken download stays queued for the next run.

When YouTube refuses a download, the run changes the request instead of repeating it: another player client, a longer pause, one cooldown, then it asks for cookies. Settings, failures and hints are logged to `engine/reaper.log` and `engine/last-run.json`.

## Install

Windows:

1. Download or clone this repository.
2. Double-click `setup.bat` and wait for it to finish.

Setup puts `yt-dlp`, `ffmpeg` and `ffprobe` in `engine/`, creates the link files, and installs a `dr` launcher. After that, Win+R, type `dr`, Enter starts the tool from anywhere.

Linux:

1. Install `pwsh` (PowerShell 7).
2. `chmod +x setup.sh digitalReaper.sh scheduler.sh`
3. `./setup.sh`

The launcher is written to `~/.local/bin/dr`. Add that folder to PATH if it is not there already and `dr` works like on Windows.

Requirements: Windows 10/11 with PowerShell 5.1 or newer, or Linux with PowerShell 7. `ffmpeg` is taken from PATH when you already have it and downloaded into `engine/` otherwise. A JavaScript runtime (`node` or `deno`) is recommended because current `yt-dlp` needs one for YouTube.

## Use it

Start with `dr`, `digitalReaper.bat` or `./digitalReaper.sh`.

Queue files: put one URL per line in `audioLinks.txt` or `videoLinks.txt` and start the tool. Files land in `downloads/audio/` and `downloads/videos/`. Finished links are removed from the file, failed ones stay.

Pasted link: there is no queue, so the tool asks for the type. `1` is video, `2` is audio, and Enter takes `defaultDownloadType`.

After a run the menu offers another item, and Run again when the previous run left failures queued. Press a number to choose. If you leave a successful run alone for a minute the window closes itself. If a run had failures, thirty seconds of silence starts the retry instead. Escape closes the window while the countdown is up.

File names are the video title, nothing else: `Lucia Has Bigger Problems Than Money - GTA VI Walkthrough #7.mp4`. Playlist items keep their position, `01 - Title.mp4`, so the order survives. A link you already downloaded is skipped rather than fetched twice, and a transfer that was cut off picks up where it stopped. The tool remembers the video id behind each finished file, so a repeat is still recognised when the video was renamed upstream. The run says `skipped` for those instead of counting them as new downloads.

## Options

```bat
digitalReaper.bat -DryRun
```

| Option | What it does |
| --- | --- |
| `-LinksFile <path>` | Use that file instead of the queues. |
| `-ConfigFile <path>` | Use a manifest or settings file. |
| `-Silent` | No prompts. Failures become the exit code. |
| `-DryRun` | Print each `yt-dlp` command, download nothing, keep the queue. |
| `-Status` | Print the last completed run, including anything skipped. Exit code 1 when it had failures. |
| `-Rollback` | Swap the previous `yt-dlp` build back in, then exit. |
| `-Doctor` | Self-check of engine, cookies, folders, lock and a live probe. |
| `-SetupOnly` | Install or update the engine, then exit. |
| `-VideoQuality`, `-AudioFormat`, `-OutputFolder` | Override one run. |

Overrides never rewrite `settings.json`.

## Settings

A fresh clone has no `settings.json`; copy `settings.example.json` to `settings.json`. The script has defaults either way. Common keys:

- `oneClickMode`, `defaultDownloadType`
- `videoQuality`, `audioFormat`, `useHEVC`
- `outputFolder`, `outputTemplate`
- `cookieSource`, `cookieFile`
- `maxRate`, `concurrentFragments`
- `retryCount`, `outerRetryCount`
- `autoUpdate`, `diagnosticsLog`

## Playlists

Paste a playlist URL like any other link. The whole playlist downloads in a single pass into a folder named after it, and running it again only fills the gaps. A playlist that partly failed keeps its URL, so the next run retries only what is missing.

## Scheduled runs

Windows: `scheduler.bat`, choose an interval, and option 3 for one pass right away.

Linux: `./scheduler.sh` does the same through a systemd user timer. Option 3 runs one silent pass now, option 4 shows the timer and the last pass. To keep the timer running after you log out, run `loginctl enable-linger $USER` once.

A plain cron entry works too, every four hours:

```bash
0 */4 * * * cd /path/to/Digital-Reaper && pwsh -NoProfile -File digitalReaper.ps1 -Silent >> engine/cron.log 2>&1
```

`-Status` is the quickest way to see what the last pass did. Interrupted transfers left as `.part` files are reported at the start and end of a run, and resume on the next one.

## When something breaks

`dr /doctor` checks the binaries, the JS runtime, cookies, folder permissions, the session lock and a real extraction. Every `[FAIL]` line says what to fix.

If the tool says another instance is running but no window is open, delete `engine/reaper.lock`. If PowerShell blocks the script, run `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser`.

A download that fails often needs cookies: set `cookieSource` to `chrome`, `edge` or `firefox`, or point `cookieFile` at an exported `cookies.txt`.

If a `yt-dlp` update breaks downloads, run `dr -Rollback`: the previous build is kept as `engine/yt-dlp.exe.backup`, and a binary that will not start is restored from it automatically. Set `autoUpdate` to `false` to stay on the older release.

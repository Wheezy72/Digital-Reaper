# Digital Reaper

Custom YouTube/media downloader built by Wheezy.

Repository: https://github.com/Wheezy72/Digital-Reaper

## Features

- High-quality video downloads (720p, 1080p, 1440p, 4K)
- Audio extraction (MP3, M4A, FLAC)
- Subtitle support (including auto-generated)
- Optional HEVC/H.265 output
- Configurable settings via `settings.json`
- Auto-update support for `yt-dlp`
- Batch downloads from `audioLinks.txt` and `videoLinks.txt`
- JSON manifest/job file support
- Live download progress (speed and ETA)
- Optional scheduled automation via `scheduler.bat`

## Requirements

- Windows 10/11 with PowerShell 5.1+ or Linux with PowerShell 7+
- Internet connection
- `ffmpeg` and `ffprobe`
  - Windows: installed by setup
  - Linux: must already be installed on your system

## Setup (Run Once)

### Windows

1. Download or clone this repository.
2. In the project folder, run:
   - `setup.bat` (double-click), or
   - `setup.ps1` from PowerShell.
3. Wait for setup to finish.
4. Optional: run `cleanup.bat` to hide internal helper files.

### Linux

1. Download or clone this repository.
2. Install prerequisites (`pwsh`, `ffmpeg`, `ffprobe`) if missing.
3. In the project folder, run:
   - `chmod +x setup.sh`
   - `./setup.sh`
4. Wait for setup to finish.

## How to Run

### Fastest method (batch files)

1. Add audio URLs to `audioLinks.txt` (one URL per line).
2. Add video URLs to `videoLinks.txt` (one URL per line).
3. Run `digitalReaper.bat`.
4. Files are saved under `downloads/audio/` and `downloads/videos/`.

### Single job with custom settings (manifest)

1. Create a JSON file with a `links` array (example: `job.json`).
2. Add any overrides like `videoQuality`, `useHEVC`, or subtitle settings.
3. Drag and drop the JSON file onto `digitalReaper.bat`.

### Interactive mode

If no link files or manifest are provided:

1. Run `digitalReaper.bat`.
2. Paste a URL when prompted.
3. Use `settings` or `file` commands if needed.

### Scheduled mode (Windows)

1. Run `scheduler.bat`.
2. Choose `1` to create/update a schedule.
3. Select an interval.
4. Use option `2` to remove the schedule later.

## Configuration

Edit `settings.json` to control default behavior.

Common settings:

- `oneClickMode`
- `defaultDownloadType` (`video` or `audio`)
- `outputFolder`
- `cookieSource` (`none`, `chrome`, `edge`, `firefox`)
- `maxRate`
- `concurrentFragments`
- `retryCount`
- `outerRetryCount`

Detailed setting descriptions are in `downloads/settings.txt`.

## Project Structure

```text
Digital-Reaper/
├── setup.bat
├── setup.sh
├── setup.ps1
├── digitalReaper.bat
├── digitalReaper.ps1
├── settings.json
├── audioLinks.txt
├── videoLinks.txt
├── cleanup.bat
├── scheduler.bat
├── README.md
├── engine/
│   ├── yt-dlp(.exe)
│   ├── ffmpeg(.exe)
│   └── ffprobe(.exe)
└── downloads/
    ├── audio/
    └── videos/
```

## Troubleshooting

### PowerShell execution policy error

Run in PowerShell:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### Download fails

- Confirm URL is valid and publicly accessible.
- Try removing query parameters after `?`.
- Check internet stability.

### Settings do not load

- Validate `settings.json` format.
- Check `downloads/settings.txt` for valid options.
- Delete `settings.json` to regenerate defaults.

### Scheduled task issues

- Run `scheduler.bat` as Administrator if task registration fails.
- Confirm URLs exist in `audioLinks.txt` or `videoLinks.txt`.
- Check Task Scheduler for `DigitalReaper`.

## Contributing

1. Fork the repository.
2. Create a feature branch.
3. Commit your changes.
4. Open a pull request.

## License

This project is licensed under the [MIT License](LICENSE).

## Acknowledgments

- [yt-dlp](https://github.com/yt-dlp/yt-dlp)
- [FFmpeg](https://ffmpeg.org/)

## Support

- GitHub profile: https://github.com/Wheezy72
- Repository: https://github.com/Wheezy72/Digital-Reaper

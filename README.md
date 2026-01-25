🔥 DIGITAL REAPER - YouTube Downloader

**Custom YouTube/media downloader with style, built for the culture.**

Made by **Wheezy** 

---

## ✨ Features

- **🎯 High-Quality Downloads** - 720p, 1080p, 1440p, 4K support
- **🎵 Audio Extraction** - MP3, M4A, FLAC formats
- **📝 Subtitle Support** - Multiple languages, auto-generated
- **🔧 HEVC/H.265** - Better compression, smaller files
- **⚙️ JSON Settings** - Customizable configuration
- **🔄 Auto-Updates** - Latest yt-dlp versions
- **📁 Drag & Drop** - Drop a `.txt` links file or `.json` manifest on the launcher
- **🎨 Beautiful Interface** - Purple-blue gradient ASCII art
- **🔒 Clean Directory** - Auto-hides technical files

---

## 🚀 Quick Start

### 1. One-time engine setup

1. **Download** this repository
2. **Run** `initDigitalReaper.ps1` (right-click → “Run with PowerShell”)  
   - This creates the `engine/` folder  
   - Downloads **yt-dlp.exe** and **ffmpeg.exe** into `engine/`  
   - Cleans up and deletes itself
3. (Optional) **Run** `cleanup.bat` once to hide internal files and keep the folder tidy

After that, your visible root is basically:

- `digitalReaper.bat` (launcher)
- `settings.json` (config)
- `audioLinks.txt` / `videoLinks.txt` (optional)
- `downloads\`
- `README.md`

### 2. Simple batch mode (zero interaction)

1. Put **audio-only URLs** in `audioLinks.txt` (one per line)
2. Put **video URLs** in `videoLinks.txt` (one per line)
3. **Double-click** `digitalReaper.bat`

Digital Reaper will:

- Auto-detect `audioLinks.txt` / `videoLinks.txt`
- Download:
  - audio → `downloads\audio\`
  - video → `downloads\videos\`
- Remove **only** successfully downloaded lines from the text files  
  (failed URLs stay for the next run)

### 3. Manifest / job file mode (per-job settings)

1. Create a JSON file, e.g. `job_1080_hevc.json`:

   ```json
   {
     "downloadType": "video",
     "videoQuality": "1080p",
     "useHEVC": true,
     "downloadSubtitles": true,
     "subtitleLanguages": ["en", "en-US"],
     "outputTemplate": "%(uploader)s/[%(upload_date)s] %(title)s [%(id)s].%(ext)s",
     "links": [
       "https://www.youtube.com/watch?v=AAA",
       "https://youtu.be/BBB"
     ]
   }
   ```

2. **Drag** this `.json` file onto `digitalReaper.bat`

Digital Reaper will:

- Load the settings from the manifest (overriding defaults where specified)
- Download all URLs under `links` to the normal `downloads\` folder

### 4. Interactive mode

If you run `digitalReaper.bat` with **no** `audioLinks.txt`/`videoLinks.txt` and **no** manifest or links file dropped:

1. Script starts in interactive mode
2. Choose:
   - Manual single URL  
   - Load URLs from a `.txt` file
3. Downloads go to `downloads\` using `settings.json` defaults

---

## ⚙️ Configuration

Edit `settings.json` to customize behavior.

There are three main entry points:

1. **Global defaults** – `settings.json` at the project root
2. **Per-job manifest** – any `.json` file you drop on `digitalReaper.bat`  
   (same shape as `settings.json`, plus a `links` field)
3. **Batch link files** – `audioLinks.txt` and `videoLinks.txt` in the root

For a description of each setting, see `downloads/settings.txt`.

---

## 📁 File Structure

📁 DigitalReaper/
├── 📄 digitalReaper.bat       (🎯 Main launcher)
├── 📄 digitalReaper.ps1       (👻 Main PowerShell engine – usually hidden)
├── 📄 settings.json           (⚙️ Global configuration)
├── 📄 audioLinks.txt          (🎵 Batch audio URLs – optional)
├── 📄 videoLinks.txt          (📼 Batch video URLs – optional)
├── 📄 initDigitalReaper.ps1   (🚀 One-time engine bootstrap – self-deletes)
├── 📄 cleanup.bat             (🧹 Hides internal files for a clean view)
├── 📄 README.md               (📖 This file)
├── 📁 engine/                 (⚙️ Internal binaries)
│   ├── yt-dlp.exe             (Downloader binary)
│   └── ffmpeg.exe             (Media processing binary)
└── 📁 downloads/              (📥 Output folder)
    ├── audio/                 (Extracted audio)
    └── videos/                (Video files)

Extra helper:
- `downloads/settings.txt` – human-readable guide to all `settings.json` options

text

---

## 💡 Usage Examples

### **Single Video:**
https://youtu.be/xvFZjo5PgG0?si=Nr5n3YLI442ixGDi

text

### **Playlist:**
https://youtube.com/playlist?list=PLo_mCdoeO0g9WdS38ko_bpVWPp23DvxPr&si=Nithu0Rq7tLyEO-2

text

### **Batch File (links.txt):**
Digital Reaper Links
https://www.youtube.com/watch?v=dQw4w9WgXcQ
https://www.youtube.com/watch?v=oHg5SJYRHA0
https://youtu.be/9bZkp7q19f0

text

---

## 🛠️ Requirements

- **Windows 10/11** (PowerShell 5.1+)
- **Internet connection** for downloads and updates
- **~200MB free space** for binaries and cache

*No additional software installation required!*

---

## 🔧 Troubleshooting

### **"Execution Policy" Error:**
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

text

### **Download Fails:**
- Check URL is valid and accessible
- Try removing URL parameters (everything after `?`)
- Ensure stable internet connection

### **Settings Not Loading:**
- Verify `settings.json` has valid JSON syntax
- Use `downloads/settings-guide.txt` for reference
- Delete `settings.json` to reset to defaults

---

## 🎨 Customization

- **Colors:** Modify ASCII gradient in script functions
- **Output:** Change `outputTemplate` in settings.json
- **Quality:** Adjust `videoQuality` and `useHEVC` settings
- **Subtitles:** Configure `subtitleLanguages` array

---

## 🤝 Contributing

1. **Fork** this repository
2. **Create** feature branch (`git checkout -b feature/amazing-feature`)
3. **Commit** changes (`git commit -m 'Add amazing feature'`)
4. **Push** to branch (`git push origin feature/amazing-feature`)
5. **Open** Pull Request

---

## 📜 License

This project is open source and available under the [MIT License](LICENSE).

---

## 🙏 Acknowledgments

- **[yt-dlp](https://github.com/yt-dlp/yt-dlp)** - Powerful media downloader

- **[FFmpeg](https://ffmpeg.org/)** - Media processing toolkit

---

## 📞 Support

https://github.com/Wheezy72

---

**Made with 💜 by Wheezy | Harvest responsibly! 🌾**
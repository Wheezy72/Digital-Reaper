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
- **📁 Drag & Drop** - Drop links.txt on launcher
- **🎨 Beautiful Interface** - Purple-blue gradient ASCII art
- **🔒 Clean Directory** - Auto-hides technical files

---

## 🚀 Quick Start

### **Method 1: Simple Double-Click**
1. **Download** this repository
2.**Run** `cleanup.bat` once after setup
3. **Double-click** `digitalReaper.bat`
4. **Enter URLs** or load from file
5. **Enjoy!** Downloads appear in `downloads/` folder

### **Method 2: Drag & Drop**
1. **Create** `links.txt` with URLs (one per line)
2. **Drag** `links.txt` onto `digitalReaper.bat`
3. **Automatic download** starts immediately

---

## ⚙️ Configuration

Edit `settings.json` to customize behavior:

See `downloads/settings-guide.txt` for full configuration guide.

---

## 📁 File Structure

📁 DigitalReaper/
├── 📄 digitalReaper.bat (🎯 Main launcher)
├── 📄 settings.json (⚙️ Configuration)
├── 📄 README.md (📖 This file)
└── 📁 downloads/ (📥 Output folder)
└── 📄 settings-guide.txt (📋 Help file)

Hidden files (auto-managed):
├── 👻 digitalReaper.ps1
├── 👻 yt-dlp.exe
├── 👻 links.txt
└── 👻 bin/ffmpeg.exe

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
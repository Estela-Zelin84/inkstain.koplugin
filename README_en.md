# 📖 KOReader Ink Stain Wallpaper

[![English](https://img.shields.io/badge/English-555555?style=for-the-badge&logo=github)](./README_en.md)
[![简体中文](https://img.shields.io/badge/简体中文-12B7F5?style=for-the-badge&logo=github)](./README.md)


![License](https://img.shields.io/badge/License-GPL--3.0-12B7F5?style=for-the-badge)
![KOReader](https://img.shields.io/badge/KOReader-Plugin-555555?style=for-the-badge)
![Version](https://img.shields.io/badge/Version-2.0.7-12B7F5?style=for-the-badge)
![Tested](https://img.shields.io/badge/Tested-KPW4-12B7F5?style=for-the-badge)

> Leave an ink stain bill for every sleep.

**KOReader Ink Stain Wallpaper** is a custom screensaver plugin for KOReader. It reads the built‑in reading statistics database (`statistics.sqlite3`) and generates an ink‑stain‑style “bill” as a PNG wallpaper, which can be automatically set as the KOReader screensaver.

The plugin supports KOReader’s native reading stats and the MiuRead (WeChat Reading) plugin’s shelf data. It works well on Kindle, Kobo, Android e‑ink devices, and any device running KOReader.

## 💬 Feedback & Support

For issues, adaptations, or feature requests, please open an issue on GitHub.

You can also join our QQ group: [![QQ Group](https://img.shields.io/badge/QQ_Group-627525507-12B7F5?style=for-the-badge&logo=tencentqq)](https://qun.qq.com/universal-share/share?ac=1&authKey=VKivI9TClDYdHh4PIDBbirSz4JdVzFjxh%2BtlceiKCvxWzci%2Byanuoqg6GmfNks3j&busi_data=eyJncm91cENvZGUiOiI2Mjc1MjU1MDciLCJ0b2tlbiI6ImQzMk0yWC9ydldGVnFieGxiUENERFQ0TGRKcXZRTGJwN2wxYjlPc3UyYXVwRUtUbHQ0bDFDcFNaZktJQjJ1YzEiLCJ1aW4iOiIxODc1NTEzNDIxIn0%3D&data=mbMZn5gWt_Esh-aWbBK2mLGZHmEfqmoxwucfon_fkmGbb-lDzeybXV6PZqeROrXIw1Gk0ij2lyG3Qz1haSxBwQ&svctype=4&tempid=h5_group_info)

The current version has only been tested on Kindle Paperwhite 4 (KPW4). Please back up your KOReader settings before using it on other devices.

## ✨ Features

- 📊 **Ink Stain Bill Wallpaper**: Generate a receipt/bill‑style screensaver based on reading statistics.
- 🔀 **Multiple Data Sources**: Choose from KOReader stats, MiuRead shelf, or a merge of both.
- ⏱️ **Reading Duration Stats**: Show total, daily average, and aggregate reading time.
- 📚 **Top Book List**: Display top 2/3/4/5 books by reading time in the period.
- 📈 **Daily Trend Chart**: A line chart showing daily reading duration.
- 🧾 **Receipt‑Style Layout**: Includes order number, period, source, barcode, and signature.
- 🔄 **Auto‑refresh Before Sleep**: Automatically regenerate the wallpaper when going to sleep if it is currently in use.
- 🧹 **Auto‑cleanup**: Old images in the output directory are removed when generating a new wallpaper.
- 🛡️ **Native Screensaver Backup**: Backs up native screensaver settings before enabling, and restores them when disabled.
- 🏠 **Scope Control**: Choose to apply only on the home screen to avoid interfering with the reading‑view screensaver.
- 🔤 **Custom Wallpaper Font**: Specify any installed font file name via the menu, or revert to the built‑in font at any time.
- 🌐 **Online Update**: One‑click check for new GitHub Releases and automatically download & install updates.
- 🌍 **GitHub Mirror Acceleration**: Three built‑in mirrors for faster downloads in China.
- 🖼️ **PNG Rendering**: Uses KOReader’s own text rendering engine to generate PNG, avoiding blank SVG text issues.
- 📦 **Embedded Font**: Bundled with Huiwen Ming font for a consistent style without depending on user font settings.

## 📸 Preview

<img width="200" alt="Ink Stain Bill Preview" src="./docs/preview.jpg" />

The wallpaper follows a receipt / ink‑stain bill style with four main sections:

- Header: order number, period, data source, total duration, and book count.
- Book list: up to 5 books with author, progress, and reading time in this period.
- Chart: daily reading trend line.
- Footer: QR code, Code128 barcode, a random quote, and the signature `Design by Estela-Zelin84`.

## 🔧 Usage

1. Download `inkstain.koplugin-v2.0.7.zip` from the release page.
2. Extract the archive and copy the `inkstain.koplugin` folder into your KOReader `plugins` directory.
3. Restart KOReader.
4. Open the top menu, find “墨痕壁纸” (Ink Stain Wallpaper) under the plugin section.
5. Tap “生成并设为休眠壁纸” (Generate and set as screensaver).

Make sure you have enabled the built‑in “Reading Statistics” plugin in KOReader and have read for a while; otherwise the plugin will generate a fallback wallpaper.

The generated wallpaper is saved at:

`koreader/screensaver/inkstain_png/inkstain_wallpaper.png`

The plugin uses KOReader’s single‑image screensaver mode:

`screensaver_type = document_cover`

`screensaver_document_cover = koreader/screensaver/inkstain_png/inkstain_wallpaper.png`

## 📋 Configuration Options

| Option | Description |
|--------|-------------|
| Generate and set as screensaver | Generate a new wallpaper and set it as KOReader screensaver. |
| Disable Ink Stain Wallpaper | Stop auto‑refresh and restore the previous native screensaver settings. |
| Generate only | Generate the image without modifying KOReader screensaver settings. |
| Auto‑refresh before sleep | Automatically regenerate when going to sleep if the wallpaper is in use. |
| Auto‑set KOReader screensaver | Automatically set as screensaver after generation. |
| Screensaver scope | Choose to apply only on the home screen, or both home and reading view. |
| Statistics period | Today, Last 7 days, Last 30 days. |
| Book list size | Top 2, Top 3, Top 4, Top 5. |
| Data source | KOReader stats / MiuRead shelf / Merge both. |
| Wallpaper font | Specify a font file name (e.g., `NotoSansCJKsc-Regular.otf`), or leave empty to use the built‑in font. |
| Show output path | Display the current wallpaper file location. |
| Check for updates | Check GitHub Releases and install updates online. |

## 📝 Changelog

### v2.0.7 (2026-08)

- 🆕 Added custom wallpaper font – set any installed font via the menu.
- 🐛 Fixed font‑loading crashes with fallback mechanism.
- 🌐 Enhanced online update: built‑in GitHub mirrors, multi‑level download fallback (Lua HTTP / curl / wget).
- 📚 Added Top 5 option for book list.
- 🧹 Improved update integrity verification (SHA256).
- 🛠️ Optimised wallpaper layout, adjusted title and footer styles.
- 📝 Improved error messages and logging.

### v2.0.0 (2026-08)

- ✅ First stable release.
- ✅ Ink‑stain bill style wallpaper generation.
- ✅ Reading statistics database reader.
- ✅ Periods: Today / Last 7 days / Last 30 days.
- ✅ Top book list, reading progress, daily trend chart.
- ✅ Auto‑refresh before sleep, auto‑cleanup.
- ✅ Native screensaver backup and restore.
- ✅ Screensaver scope setting.
- ✅ Localisation: Simplified Chinese, Traditional Chinese (Taiwan, Hong Kong, Macau), Korean.

## 🙏 Acknowledgements

- [KOReader](https://github.com/koreader/koreader) for the reading statistics, plugin system, and PNG rendering capabilities.
- [MiuRead](https://github.com/miumiupy98-art) by [@miumiupy98-art](https://github.com/miumiupy98-art) for the shelf data structure that inspired the multi‑data‑source feature.

## 📄 License

GNU General Public License v3.0

Copyright (C) 2026 Estela-Zelin84

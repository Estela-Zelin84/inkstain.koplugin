# 📖 Ink Stain Plugin for KOReader

[![English](https://img.shields.io/badge/English-555555?style=for-the-badge&logo=github)](./README_en.md)
[![简体中文](https://img.shields.io/badge/简体中文-12B7F5?style=for-the-badge&logo=github)](./README.md)
[![QQ Group](https://img.shields.io/badge/QQ_Group-627525507-12B7F5?style=for-the-badge&logo=tencentqq)](https://qun.qq.com/universal-share/share?ac=1&authKey=VKivI9TClDYdHh4PIDBbirSz4JdVzFjxh%2BtlceiKCvxWzci%2Byanuoqg6GmfNks3j&busi_data=eyJncm91cENvZGUiOiI2Mjc1MjU1MDciLCJ0b2tlbiI6ImQzMk0yWC9ydldGVnFieGxiUENERFQ0TGRKcXZRTGJwN2wxYjlPc3UyYXVwRUtUbHQ0bDFDcFNaZktJQjJ1YzEiLCJ1aW4iOiIxODc1NTEzNDIxIn0%3D&data=mbMZn5gWt_Esh-aWbBK2mLGZHmEfqmoxwucfon_fkmGbb-lDzeybXV6PZqeROrXIw1Gk0ij2lyG3Qz1haSxBwQ&svctype=4&tempid=h5_group_info)

![License](https://img.shields.io/badge/License-GPL--3.0-12B7F5?style=for-the-badge)
![KOReader](https://img.shields.io/badge/KOReader-Plugin-555555?style=for-the-badge)
![Version](https://img.shields.io/badge/Version-3.8.2-12B7F5?style=for-the-badge)
![Tested](https://img.shields.io/badge/Tested-KPW4-12B7F5?style=for-the-badge)

> Turn every sleep screen into a small imprint of your reading life.

**KOReader Ink Stain Wallpaper** is a sleep screen wallpaper plugin for KOReader. It reads KOReader's built-in reading statistics database `statistics.sqlite3`, generates an Ink Stain-style reading imprint PNG wallpaper, and can automatically set it as the KOReader sleep screen image.

The plugin supports reading from KOReader's native reading statistics and MiuRead (WeRead) plugin shelf data. It is intended for Kindle, Kobo, Android e-ink devices, and other devices running KOReader.

In addition to the sleep wallpaper, the plugin ships a **full-screen "Ink Stain Reading Stats" panel** that you can open anytime to review your reading overview, and can be invoked from the simpleui navbar, a KOReader gesture (Dispatcher), and more.

## 💬 Feedback

For questions, compatibility reports, or feature suggestions, please open a GitHub Issue.

You can also join the QQ group: `627525507`

This version has only been tested on Kindle Paperwhite 4 (KPW4). Other devices and platforms have not been tested yet. Please back up your KOReader settings before using it on other devices.

## ✨ Features

- 📊 **Reading imprint wallpaper**: Generate ink-stain style sleep screen wallpapers from reading statistics
- 📈 **Reading stats panel**: A full-screen reading overview panel you can open anytime (see below)
- 🔀 **Multiple data sources**: KOReader statistics, MiuRead shelf, or both combined
- ⏱️ **Reading time summary**: Show total reading time, average daily reading time, and period total
- 📚 **Top books**: Display Top 2 / Top 3 / Top 4 / Top 5 books by reading time
- 📉 **Daily trend line / heatmap**: Wallpaper can show a daily reading trend line, or a heatmap of the last 26 weeks (~half a year)
- 🧾 **Imprint-style layout**: Include serial number, period, data source, barcode, and signature
- 🖼️ **Custom background image**: Choose a plain white background, or specify a custom image as the wallpaper base
- 💧 **Ink stain effect**: Overlay ink-drop texture on the wallpaper (off by default to avoid slowdowns on low-end devices)
- 🔄 **Auto refresh before suspend**: Regenerate the wallpaper before suspend when Ink Stain wallpaper is currently in use
- 🧹 **Old image cleanup**: Clean old images in the plugin output directory when generating a new wallpaper
- 🛡️ **Native screensaver protection**: Back up KOReader's original screensaver settings before enabling, and restore them when disabled
- 🏠 **Scope control**: Use only on the home screen to avoid interfering with independent reader screensaver settings
- 🚀 **Navbar & gesture entry**: Bind "Ink Stain Stats" in the simpleui navbar, a KOReader gesture (Settings → Gestures), or the ZenOS navbar for one-tap access
- 🌐 **Online update**: Check for new GitHub Release versions and install directly within the plugin
- 🔒 **OTA hash verification**: Automatically verify SHA256 after download to prevent corruption or tampering
- 📡 **GitHub mirror acceleration**: Configurable mirror sources (off by default) for more stable downloads in China
- 🖼️ **PNG rendering**: Use KOReader's built-in text rendering widgets to generate PNG
- 🔤 **Embedded font**: Includes Huiwen Ming typeface for consistent wallpaper styling
- 🔤 **Custom font**: Enter a system font filename to customize the wallpaper rendering font
- 📐 **Progress mode**: Choose total progress (all-time reading position) or period progress (pages read this period)
- 🌐 **Wallpaper language**: Simplified Chinese, Traditional Chinese (Hong Kong), or English wallpaper rendering, independent from KOReader UI language
- 📦 **.po language packs**: Standard gettext .po text files, pure Lua runtime parsing, no compilation needed
- 🪶 **Lightweight mode**: Lower render resolution and skip heavy computation, for low-memory devices
- ✍️ **Brand signature**: Customize the brand text (e.g. "墨痕 / 书斋"), applied to both the sleep wallpaper and the stats panel

## 📸 Preview

<img width="369.2" height="514" alt="0484432950f42d6c567a13832850aa64" src="https://github.com/user-attachments/assets/85a21e15-c006-4c96-9b39-af5fd6536c3a" /><img width="369.2" height="514" alt="布丁扫描2026年09月01日11时02分04秒" src="https://github.com/user-attachments/assets/9157a0ab-1a13-4ce4-97c4-a624aed71fe7" />

The wallpaper uses an ink-stain style layout with four main areas:

- Header: serial number, statistics period, data source, total reading time, and list count
- Book list: up to 5 books, including author, progress, and reading time in the selected period
- Chart: daily reading trend line, or a heatmap of the last 26 weeks
- Footer: QR code, Code128-style barcode, random quote, and `Design by Estela-Zelin84`

## 📊 Ink Stain Reading Stats Panel

Beyond the sleep wallpaper, the plugin ships a **full-screen "Ink Stain Reading Stats" panel** (a live panel, not a wallpaper image) that reuses the lock-screen imprint style. It focuses on the data itself and includes:

- Header stats (period, data source, total reading time, etc.)
- Book list: up to 9 books (sorted by reading time)
- Ink-stain logo at the bottom

The panel **excludes** the QR code, barcode, quote, and chart, keeping it lean for quick review.

**How to open it:**

| Entry | Description |
|------|------|
| Plugin menu | Top menu → Ink Stain Wallpaper → **View Ink Stain Stats** |
| simpleui navbar | In simpleui bottom-bar settings, add "Ink Stain Stats" as a quick tab |
| KOReader gesture | In Settings → Gestures, bind any gesture (swipe / long-press / double-tap) to the "Ink Stain Stats" action (Dispatcher) |
| ZenOS navbar | In the ZenOS navbar "Add action", choose "Ink Stain Stats" |

**How to close:** tap the top-right ✕ close button, swipe left/right anywhere, or press the hardware back key.

> Note: the stats panel shows a one-year (year) reading overview by default; its brand signature is shared with the sleep wallpaper via the menu (Appearance → Brand signature).

## 🔧 Usage

1. Download `inkstain.koplugin-v3.8.2.zip` from the release page
2. Unzip it and copy the `inkstain.koplugin` folder to KOReader's `plugins` directory
3. Restart KOReader
4. Open KOReader's top menu and find `墨痕壁纸` in the plugin menu
5. Tap `生成并设为休眠壁纸`

Please enable KOReader's built-in `Reading statistics` plugin first and read for a while. If the statistics database does not exist yet, this plugin will generate a placeholder wallpaper.

Generated wallpaper path:

`koreader/screensaver/inkstain_png/inkstain_wallpaper.png`

The plugin uses KOReader's single-image screensaver mode:

`screensaver_type = document_cover`

`screensaver_document_cover = koreader/screensaver/inkstain_png/inkstain_wallpaper.png`

## 📋 Options

| Menu item | Description |
|------|------|
| View Ink Stain Stats | Open the full-screen reading stats panel (also reachable via simpleui / gesture / ZenOS) |
| 生成并设为休眠壁纸 | Generate a new wallpaper and set it as the KOReader sleep screen image |
| 关闭墨痕壁纸 | Stop auto refresh and restore the original KOReader screensaver settings |
| Data & Stats → Period | Today / Last 7 days / Last 30 days / Last quarter / Last half-year / Last year / Last 10 years |
| Data & Stats → Book list size | Top 2, Top 3, Top 4, or Top 5 |
| Data & Stats → Data source | KOReader statistics / MiuRead shelf / Both combined |
| Data & Stats → Progress mode | Total progress (all-time reading position) or period progress (pages read this period) |
| Appearance → Background mode | Plain white, or a custom background image |
| Appearance → Select / Clear background image | Set or clear the wallpaper base image |
| Appearance → Ink stain effect | Overlay ink-drop texture (off by default) |
| Appearance → Chart style | Line chart, or heatmap (last 26 weeks of reading) |
| Appearance → Brand signature | Custom brand text, applied to both sleep wallpaper and stats panel |
| Appearance → Wallpaper font | Choose a font / restore the built-in Huiwen Ming font |
| Appearance → Wallpaper language | Simplified Chinese / Traditional Chinese (Hong Kong) / English |
| General → Generate only | Generate the image only, without changing KOReader screensaver settings |
| General → Auto refresh before suspend | Regenerate before suspend when Ink Stain wallpaper is currently in use |
| General → Auto set KOReader sleep screen | Automatically set the generated image as the sleep screen wallpaper |
| General → Scope | Use only on the home screen, or both home and reader screens |
| General → Lightweight mode (low-memory devices) | Lower resolution and skip heavy computation for low-memory devices |
| General → Software update | Check for new GitHub Release versions and install |
| General → Show output path | Show the current wallpaper output path |
| Join beta | Join the beta QQ group: 627525507 |
| About | Show the plugin version and design credit |

## 📝 Changelog

### v3.8.2 (2026.09)

- ✅ New **full-screen "Ink Stain Reading Stats" panel**: review your reading overview anytime, openable from the menu / simpleui navbar / KOReader gesture (Dispatcher) / ZenOS navbar; close via top-right ✕, swipe, or back key
- ✅ New **navbar & gesture entry**: register an "Ink Stain Stats" action with simpleui, KOReader Dispatcher, and ZenOS, bindable to a navbar or any gesture
- ✅ **Period** expanded to 7 options: added last quarter, last half-year, last year, last 10 years
- ✅ New **custom background image**: wallpaper base can be plain white or a custom image
- ✅ New **ink stain effect**: overlay ink-drop texture on the wallpaper (off by default)
- ✅ New **chart style**: wallpaper trend chart supports "line" or "heatmap (last 26 weeks)"
- ✅ New **brand signature**: customize the brand text (e.g. "墨痕 / 书斋"), applied to both sleep wallpaper and stats panel
- ✅ New **lightweight mode**: lower render resolution, skip QR image loading and ink-drop computation, for low-memory devices
- ✅ **Wallpaper language** adds Traditional Chinese (Hong Kong)
- ✅ New "Join beta" menu entry

### v3.5.7 (2026.08)

- ✅ Public API v2 adds status, enable/disable, refresh, and a native `openSettings()` entry for MiuRead
- ✅ InkStain now owns its full settings UI when opened from MiuRead; OTA, file pickers, and nested menus are no longer proxied by MiuRead
- ✅ Disabling InkStain fully releases the sleep-screen takeover and restores the previous screensaver
- ✅ Restored the software update entry with delayed, network-aware update checks and safe OTA verification/rollback

### v3.0.0 (2026.08)

- ✅ Fixed crash when generating wallpaper after switching wallpaper language (`pickQuote` parameter error)
- ✅ Fixed MiuRead reading records not showing: now reads `library` (local book store) in addition to `shelf_cache` (cloud shelf)
- ✅ Fixed incomplete MiuRead progress lookup: aligned with MiuRead's `local_progress` logic, added `pending`/`verified` progress fields
- ✅ Refactored wallpaper localization to .po language pack system (modeled after ZenUI plugin)
- ✅ Added `locales/zh.po` and `locales/en.po`, plain text .po files, no compilation needed
- ✅ Added `i18n.lua` module: pure Lua .po parser with caching and fallback
- ✅ Removed hardcoded `WALLPAPER_I18N` table, all wallpaper text now driven by .po files

### v2.0.9 (2026.08)

- ✅ Added wallpaper language toggle: choose Chinese or English rendering
- ✅ English wallpaper includes full English title, labels, quotes, and error messages
- ✅ English title style: Ink Stain + reading receipt subtitle

### v2.0.8 (2026.08)

- ✅ Added progress mode toggle: choose between "Total progress" (all-time reading position) or "Period progress" (pages read this period)
- ✅ Fixed incorrect progress display: use all-time max page read instead of period-only page count
- ✅ Fixed MiuRead progress not applied in combined data source mode: always prioritize MiuRead progress_local_percent
- ✅ Fixed potential time formatting issue: added 60-minute carry protection

### v2.0.7 (2026.08)

- ✅ Added custom wallpaper font: enter a font filename to switch
- ✅ Fixed font selection crash: switched to text input instead of scanning font directories
- ✅ Fixed MiuRead data source showing empty: reuse KOReader statistics query, MiuRead only supplements progress
- ✅ Fixed progress showing 0% in combined data source mode
- ✅ Top 5 book list support, max displayed books increased from 4 to 5
- ✅ Added OTA SHA256 hash verification to prevent file corruption or tampering
- ✅ Rewrote OTA network layer with manual HTTP redirect handling, fixed crashes on some devices
- ✅ Title layout optimization: equal-sized characters with English subtitle
- ✅ Optimized download speed following MiuRead plugin's OTA method

### v2.0.0 (2026.08)

- ✅ Added multiple data source support: KOReader statistics / MiuRead shelf / Both combined
- ✅ Added online update with GitHub Release check, download, and auto-install
- ✅ Added GitHub mirror acceleration with three mirror sources
- ✅ Added download fallback (ssl.https / curl / wget)
- ✅ Added embedded Huiwen Ming font
- ✅ Improved title sizing and footer layout
- ✅ Fixed font loading crash, version comparison, and unzip module issues

### v1.0.0 (2026.08)

- ✅ Initial stable release
- ✅ Ink Stain-style reading imprint wallpaper generation
- ✅ KOReader reading statistics database support
- ✅ Today / last 7 days / last 30 days periods
- ✅ Top books, reading progress, and daily reading trend line
- ✅ Auto refresh before suspend, old image cleanup
- ✅ Original screensaver settings backup and restore
- ✅ Scope control for home-screen-only usage
- ✅ Simplified Chinese, Traditional Chinese (TW, HK, MO), Korean localization

## 🙏 Credits

- Thanks to [KOReader](https://github.com/koreader/koreader) for reading statistics, plugin system, and PNG rendering
- Thanks to [MiuRead](https://github.com/miumiupy98-art/miuread-koreader) author [@miumiupy98-art](https://github.com/miumiupy98-art), data source and OTA implementation referenced from MiuRead plugin
- Thanks to [ZenUI](https://github.com/AnthonyGress/zen_ui.koplugin), the .po language pack implementation references ZenUI's i18n approach

## 📄 License

GNU General Public License v3.0

Copyright (C) 2026 Estela-Zelin84

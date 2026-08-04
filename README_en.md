# 📖 Ink Stain Plugin for KOReader

[![English](https://img.shields.io/badge/English-555555?style=for-the-badge&logo=github)](./README_en.md)
[![简体中文](https://img.shields.io/badge/简体中文-12B7F5?style=for-the-badge&logo=github)](./README.md)
[![QQ Group](https://img.shields.io/badge/QQ_Group-627525507-12B7F5?style=for-the-badge&logo=tencentqq)](https://qun.qq.com/universal-share/share?ac=1&authKey=VKivI9TClDYdHh4PIDBbirSz4JdVzFjxh%2BtlceiKCvxWzci%2Byanuoqg6GmfNks3j&busi_data=eyJncm91cENvZGUiOiI2Mjc1MjU1MDciLCJ0b2tlbiI6ImQzMk0yWC9ydldGVnFieGxiUENERFQ0TGRKcXZRTGJwN2wxYjlPc3UyYXVwRUtUbHQ0bDFDcFNaZktJQjJ1YzEiLCJ1aW4iOiIxODc1NTEzNDIxIn0%3D&data=mbMZn5gWt_Esh-aWbBK2mLGZHmEfqmoxwucfon_fkmGbb-lDzeybXV6PZqeROrXIw1Gk0ij2lyG3Qz1haSxBwQ&svctype=4&tempid=h5_group_info)

![License](https://img.shields.io/badge/License-GPL--3.0-12B7F5?style=for-the-badge)
![KOReader](https://img.shields.io/badge/KOReader-Plugin-555555?style=for-the-badge)
![Version](https://img.shields.io/badge/Version-2.0.0-12B7F5?style=for-the-badge)
![Tested](https://img.shields.io/badge/Tested-KPW4-12B7F5?style=for-the-badge)

> Turn every sleep screen into a small imprint of your reading life.

**KOReader Ink Stain Wallpaper** is a sleep screen wallpaper plugin for KOReader. It reads KOReader's built-in reading statistics database `statistics.sqlite3`, generates an Ink Stain-style reading imprint PNG wallpaper, and can automatically set it as the KOReader sleep screen image.

The plugin supports reading from KOReader's native reading statistics and the MiuRead (觅阅) WeRead plugin's shelf data. It is intended for Kindle, Kobo, Android e-ink devices, and other devices running KOReader.

## 💬 Feedback

For questions, compatibility reports, or feature suggestions, please open a GitHub Issue.

You can also join the QQ group: `627525507`

This version has only been tested on Kindle Paperwhite 4 (KPW4). Other devices and platforms have not been tested yet. Please back up your KOReader settings before using it on other devices.

## ✨ Features

- 📊 **Reading imprint wallpaper**: Generate ink-stain style sleep screen wallpapers from reading statistics
- 🔀 **Multiple data sources**: Choose from KOReader statistics, MiuRead shelf, or both combined
- ⏱️ **Reading time summary**: Show total reading time, average daily reading time, and period total
- 📚 **Top books**: Display Top 2 / Top 3 / Top 4 books by reading time in the selected period
- 📈 **Daily trend line**: Show daily reading time changes within the selected period
- 🧾 **Imprint-style layout**: Include serial number, period, data source, barcode, and signature
- 🔄 **Auto refresh before suspend**: Regenerate the wallpaper before suspend when Ink Stain wallpaper is currently in use
- 🧹 **Old image cleanup**: Clean old images in the plugin output directory when generating a new wallpaper
- 🛡️ **Native screensaver protection**: Back up KOReader's original screensaver settings before enabling, and restore them when disabled
- 🏠 **Scope control**: Use only on the home screen to avoid interfering with independent reader screensaver settings
- 🌐 **Online update**: Check for new GitHub releases and download/install updates directly within the plugin
- 🌍 **GitHub mirror acceleration**: Built-in mirrors for faster downloads in regions with poor GitHub connectivity
- 🖼️ **PNG rendering**: Use KOReader's built-in text rendering widgets to generate PNG and avoid SVG text rendering issues
- 🔤 **Embedded font**: Bundled Huiwen Ming typeface for consistent wallpaper styling without depending on user font settings

## 📸 Preview

<img width="200" alt="Ink Stain wallpaper preview" src="./docs/preview.jpg" />

The wallpaper uses an ink-stain style layout with four main areas:

- Header: serial number, statistics period, data source, total reading time, and list count
- Book list: up to 4 books, including author, progress, and reading time in the selected period
- Chart: daily reading trend line
- Footer: QR code, Code128-style barcode, random quote, and `Design by Estela-Zelin84`

## 🔧 Usage

1. Download `inkstain.koplugin-v2.0.0.zip` from the release page
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

| Option | Description |
|------|------|
| 生成并设为休眠壁纸 | Generate a new wallpaper and set it as the KOReader sleep screen image |
| 关闭墨痕壁纸 | Stop auto refresh and restore the original KOReader screensaver settings |
| 仅生成壁纸 | Generate the image only, without changing KOReader screensaver settings |
| 休眠前自动刷新 | Regenerate before suspend when Ink Stain wallpaper is currently in use |
| 自动设置 KOReader 休眠屏幕 | Automatically set the generated image as the sleep screen wallpaper |
| 锁屏使用范围 | Use only on the home screen, or both home and reader screens |
| 统计周期 | Today, last 7 days, or last 30 days |
| 书单数量 | Top 2, Top 3, or Top 4 |
| 数据源 | KOReader statistics / MiuRead shelf / Both combined |
| 显示输出路径 | Show the current wallpaper output path |
| 检查更新 | Check for new GitHub releases and install updates online |

## 📝 Changelog

### v2.0.0 (2026.08)

- ✅ Added multiple data sources: KOReader statistics / MiuRead shelf / Both combined
- ✅ Added online update with GitHub Release check, download, and auto-install
- ✅ Added GitHub mirror acceleration with three mirror sources
- ✅ Added download fallback chain (ssl.https / curl / wget)
- ✅ Added embedded Huiwen Ming font, no longer depends on user font settings
- ✅ Improved title font size and footer layout
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

- Thanks to the [KOReader](https://github.com/koreader/koreader) project for providing reading statistics, the plugin system, and PNG rendering capabilities
- Thanks to [MiuRead](https://github.com/miumiupy98-art) author [@miumiupy98-art](https://github.com/miumiupy98-art) — the multi-data-source feature references MiuRead's data storage structure

## 📄 License

GNU General Public License v3.0

Copyright (C) 2026 Estela-Zelin84

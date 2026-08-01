# 📖 KOReader 阅迹壁纸插件

[![English](https://img.shields.io/badge/English-555555?style=for-the-badge&logo=github)](./README_en.md)
[![简体中文](https://img.shields.io/badge/简体中文-12B7F5?style=for-the-badge&logo=github)](./README.md)


![License](https://img.shields.io/badge/License-GPL--3.0-12B7F5?style=for-the-badge)
![KOReader](https://img.shields.io/badge/KOReader-Plugin-555555?style=for-the-badge)
![Tested](https://img.shields.io/badge/Tested-KPW4-12B7F5?style=for-the-badge)

> 让每一次休眠，都留下一张属于自己的阅读小票。

**KOReader 阅迹壁纸** 是一个为 KOReader 定制的休眠屏幕壁纸插件。它会读取 KOReader 内置阅读统计数据库 `statistics.sqlite3`，生成一张 ReadTrace 风格的「阅读账单」PNG 壁纸，并可自动设置为 KOReader 的休眠屏幕图片。

插件不依赖网络、不依赖外部命令，只读取 KOReader 本地阅读统计数据，适合 Kindle、Kobo、Android 墨水屏等运行 KOReader 的设备使用。

## 💬 交流反馈

如有使用问题、适配反馈或功能建议，欢迎在 GitHub Issues 中提交。

也可以加入 QQ 群交流：[![QQ Group](https://img.shields.io/badge/QQ_Group-627525507-12B7F5?style=for-the-badge&logo=tencentqq)](https://qun.qq.com/universal-share/share?ac=1&authKey=VKivI9TClDYdHh4PIDBbirSz4JdVzFjxh%2BtlceiKCvxWzci%2Byanuoqg6GmfNks3j&busi_data=eyJncm91cENvZGUiOiI2Mjc1MjU1MDciLCJ0b2tlbiI6ImQzMk0yWC9ydldGVnFieGxiUENERFQ0TGRKcXZRTGJwN2wxYjlPc3UyYXVwRUtUbHQ0bDFDcFNaZktJQjJ1YzEiLCJ1aW4iOiIxODc1NTEzNDIxIn0%3D&data=mbMZn5gWt_Esh-aWbBK2mLGZHmEfqmoxwucfon_fkmGbb-lDzeybXV6PZqeROrXIw1Gk0ij2lyG3Qz1haSxBwQ&svctype=4&tempid=h5_group_info)

当前版本仅在 Kindle Paperwhite 4（KPW4）上进行了测试，其他设备和平台尚未测试。若在其他设备上使用，建议先备份 KOReader 设置。

## ✨ 功能特性

- 📊 **阅读账单壁纸**：根据 KOReader 阅读统计生成收据 / 小票风格休眠壁纸
- ⏱️ **阅读时长统计**：显示本期累计阅读时长、日均阅读时长和合计时长
- 📚 **Top 书单展示**：按本期阅读时长展示 Top 2 / Top 3 / Top 4 书籍
- 📈 **每日趋势折线**：显示统计周期内每日阅读时长变化
- 🧾 **小票风格排版**：包含单号、统计周期、来源、条码和底部署名
- 🔄 **休眠前自动刷新**：当前正在使用阅迹壁纸时，休眠前自动重新生成
- 🧹 **旧图自动清理**：生成新壁纸时清理插件输出目录里的旧图片
- 🛡️ **原生屏保保护**：启用前备份 KOReader 原生屏保设置，关闭后可恢复
- 🏠 **使用范围控制**：可选择只在主页使用，避免干涉阅读界面的独立屏保设置
- 🌐 **完全中文界面**：插件菜单、提示信息和生成壁纸内容均为中文
- 🖼️ **PNG 渲染输出**：使用 KOReader 自带文字渲染组件生成 PNG，避免 SVG 文字空白问题

## 📸 效果预览

壁纸采用收据 / 阅读账单风格，主要包含四个区域：

- 页眉：单号、统计周期、数据来源、总时长、书单数量
- 书单：最多显示 4 本书，包含作者、进度和本期阅读时长
- 图表：显示每日阅读趋势折线
- 底部：二维码、Code128 风格条码、随机格言和 `Design by Estela-Zelin84` 署名

## 🔧 使用方法

1. 下载 release 中的 `readtrace-koreader-plugin.zip`
2. 解压后，将 `readtrace.koplugin` 文件夹复制到 KOReader 的 `plugins` 目录
3. 重启 KOReader
4. 打开 KOReader 顶部菜单，在插件菜单位置找到「阅迹壁纸」
5. 点击「生成并设为休眠壁纸」

请先在 KOReader 中启用内置「阅读统计」插件，并正常阅读一段时间。否则插件找不到统计数据库时，会生成一张提示壁纸。

生成后的壁纸会保存在：

`koreader/screensaver/readtrace_png/readtrace_wallpaper.png`

插件会使用 KOReader 的单图屏保模式：

`screensaver_type = document_cover`

`screensaver_document_cover = koreader/screensaver/readtrace_png/readtrace_wallpaper.png`

## 📋 配置选项

| 选项 | 说明 |
|------|------|
| 生成并设为休眠壁纸 | 生成新壁纸，并设置为 KOReader 休眠屏幕图片 |
| 关闭阅迹壁纸 | 停止自动刷新，并恢复启用阅迹前的原生屏保设置 |
| 仅生成壁纸 | 只生成图片，不修改 KOReader 屏保设置 |
| 休眠前自动刷新 | 当前正在使用阅迹壁纸时，休眠前自动重新生成 |
| 自动设置 KOReader 休眠屏幕 | 生成后自动设置为休眠壁纸 |
| 锁屏使用范围 | 可选择只在主页使用，或主页和阅读界面都使用 |
| 统计周期 | 支持今天、最近 7 天、最近 30 天 |
| 书单数量 | 支持 Top 2、Top 3、Top 4 |
| 显示输出路径 | 查看当前壁纸输出位置 |

## 📝 更新日志

### v1.0.0（2026.08）

- ✅ 首个稳定版本
- ✅ 新增 ReadTrace 风格阅读账单壁纸生成
- ✅ 新增 KOReader 阅读统计数据库读取
- ✅ 新增今天 / 最近 7 天 / 最近 30 天统计周期
- ✅ 新增 Top 书单、阅读进度、每日阅读趋势折线
- ✅ 新增休眠前自动刷新
- ✅ 新增旧图片自动清理
- ✅ 新增原生屏保设置备份与恢复
- ✅ 新增锁屏使用范围设置，支持只在主页使用
- ✅ 新增 GPL-3.0 许可证

## 🙏 致谢

本插件的视觉风格参考 ReadTrace 的「阅读账单」样式。

感谢 KOReader 项目提供阅读统计、插件系统和 PNG 渲染能力。

## 📄 许可证

GNU General Public License v3.0

Copyright (C) 2026 Estela-Zelin84

# 📖 KOReader 墨痕壁纸
[![English](https://img.shields.io/badge/English-555555?style=for-the-badge&logo=github)](./README_en.md)
[![简体中文](https://img.shields.io/badge/简体中文-12B7F5?style=for-the-badge&logo=github)](./README.md)
![License](https://img.shields.io/badge/License-GPL--3.0-12B7F5?style=for-the-badge)
![KOReader](https://img.shields.io/badge/KOReader-Plugin-555555?style=for-the-badge)
![Version](https://img.shields.io/badge/Version-3.2.0-12B7F5?style=for-the-badge)
![Tested](https://img.shields.io/badge/Tested-KPW4-12B7F5?style=for-the-badge)

> 让每一次休眠，都留下一张属于自己的墨痕账单。

**KOReader 墨痕壁纸** 是一个为 KOReader 定制的休眠屏幕壁纸插件。它会读取 KOReader 内置阅读统计数据库 `statistics.sqlite3`，生成一张 Ink Stain 风格的「墨痕账单」PNG 壁纸，并可自动设置为 KOReader 的休眠屏幕图片。

插件支持读取 KOReader 原生阅读统计和觅阅（MiuRead）微信读书插件的书架数据，适合 Kindle、Kobo、Android 墨水屏等运行 KOReader 的设备使用。

## 💬 交流反馈

如有使用问题、适配反馈或功能建议，欢迎在 GitHub Issues 中提交。

也可以加入 QQ 群交流：[![QQ Group](https://img.shields.io/badge/QQ_Group-627525507-12B7F5?style=for-the-badge&logo=tencentqq)](https://qun.qq.com/universal-share/share?ac=1&authKey=VKivI9TClDYdHh4PIDBbirSz4JdVzFjxh%2BtlceiKCvxWzci%2Byanuoqg6GmfNks3j&busi_data=eyJncm91cENvZGUiOiI2Mjc1MjU1MDciLCJ0b2tlbiI6ImQzMk0yWC9ydldGVnFieGxiUENERFQ0TGRKcXZRTGJwN2wxYjlPc3UyYXVwRUtUbHQ0bDFDcFNaZktJQjJ1YzEiLCJ1aW4iOiIxODc1NTEzNDIxIn0%3D&data=mbMZn5gWt_Esh-aWbBK2mLGZHmEfqmoxwucfon_fkmGbb-lDzeybXV6PZqeROrXIw1Gk0ij2lyG3Qz1haSxBwQ&svctype=4&tempid=h5_group_info)

当前版本仅在 Kindle Paperwhite 4（KPW4）上进行了测试，其他设备和平台尚未测试。若在其他设备上使用，建议先备份 KOReader 设置。

## ✨ 功能特性

- 📊 **墨痕账单壁纸**：根据阅读统计生成收据 / 账单风格休眠壁纸
- 🖼️ **自定义背景图片**：支持选择本地图片（PNG / JPG）作为壁纸背景，自动等比例缩放填满屏幕并居中裁剪，账单文字直接叠加在背景图上，可随时切换纯白背景与自定义图片
- 🎨 **墨水污渍效果**：背景添加墨点聚集式污渍，模拟墨水溅在纸上的质感，默认关闭，同一天生成的污渍位置一致，每天变化
- 🔀 **多数据源支持**：可选 KOReader 阅读统计、觅阅书架或两者合并
- ⏱️ **阅读时长统计**：显示本期累计阅读时长、日均阅读时长和合计时长
- 📚 **Top 书单展示**：按本期阅读时长展示 Top 2 / Top 3 / Top 4 / Top 5 书籍
- 📈 **每日趋势折线**：显示统计周期内每日阅读时长变化
- 📅 **灵活统计周期**：支持今天、最近 7 天、30 天、一个季度（90 天）、半年（180 天）、一年（365 天）及最近 10 年（3650 天）
- 🧾 **小票风格排版**：包含单号、统计周期、来源、条码和底部署名
- 🔄 **休眠前自动刷新**：当前正在使用墨痕壁纸时，休眠前自动重新生成
- 🧹 **旧图自动清理**：生成新壁纸时清理插件输出目录里的旧图片
- 🛡️ **原生屏保保护**：启用前备份 KOReader 原生屏保设置，关闭后可恢复
- 🏠 **使用范围控制**：可选择只在主页使用，避免干涉阅读界面的独立屏保设置
- 🌐 **在线更新**：插件内一键检查 GitHub Release 新版本，支持下载并自动安装
- 🔒 **OTA 哈希验证**：下载完成后自动校验 SHA256，防止文件损坏或篡改
- 🌍 **GitHub 镜像加速**：内置三个镜像，国内设备下载不再超时
- 🖼️ **PNG 渲染输出**：使用 KOReader 自带文字渲染组件生成 PNG，避免 SVG 文字空白问题
- 🔤 **内嵌字体**：自带汇文明朝体，壁纸风格统一，不依赖用户字体设置
- 🔤 **自定义字体**：可手动输入系统字体文件名，替换壁纸渲染字体
- 📐 **进度模式**：可选总进度（全期阅读位置）或本期进度（本期阅读页数占比）
- 🌐 **多语言壁纸**：支持简体中文、英文、繁體中文（香港）壁纸渲染，独立于 KOReader UI 语言
- 📦 **.po 语言包**：采用标准 gettext .po 文本文件，纯 Lua 运行时解析，无需编译

## 📸 效果预览

<img width="369.2" height="514" alt="0484432950f42d6c567a13832850aa64" src="https://github.com/user-attachments/assets/85a21e15-c006-4c96-9b39-af5fd6536c3a" />


壁纸采用收据 / 墨痕账单风格，主要包含四个区域：

- 页眉：单号、统计周期、数据来源、总时长、书单数量
- 书单：最多显示 5 本书，包含作者、进度和本期阅读时长
- 图表：显示每日阅读趋势折线
- 底部：二维码、Code128 风格条码、随机格言和 `Design by Estela-Zelin84` 署名

## 🔧 使用方法

1. 下载 release 中的 `inkstain.koplugin-v3.2.0.zip`
2. 解压后，将 `inkstain.koplugin` 文件夹复制到 KOReader 的 `plugins` 目录
3. 重启 KOReader
4. 打开 KOReader 顶部菜单，在插件菜单位置找到「墨痕壁纸」
5. 点击「生成并设为休眠壁纸」

请先在 KOReader 中启用内置「阅读统计」插件，并正常阅读一段时间。否则插件找不到统计数据库时，会生成一张提示壁纸。

生成后的壁纸会保存在：

`koreader/screensaver/inkstain_png/inkstain_wallpaper.png`

插件会使用 KOReader 的单图屏保模式：

```
screensaver_type = document_cover
screensaver_document_cover = koreader/screensaver/inkstain_png/inkstain_wallpaper.png
```

## 📋 配置选项

v3.2.0 将设置菜单归类整理为三大分组：「数据与统计」「外观设置」「通用设置」。

### 数据与统计

| 选项 | 说明 |
|------|------|
| 统计周期 | 今天、最近 7 天、最近 30 天、最近一个季度（90 天）、最近半年（180 天）、最近一年（365 天）、最近 10 年（3650 天） |
| 书单数量 | 支持 Top 2、Top 3、Top 4、Top 5 |
| 数据源 | KOReader 阅读统计 / 觅阅书架 / 两者合并 |
| 进度模式 | 总进度（全期阅读位置）或本期进度（本期阅读页数占比） |

### 外观设置

| 选项 | 说明 |
|------|------|
| 自定义背景图片 | 选择本地图片（PNG / JPG）作为壁纸背景，图片自动等比例缩放填满屏幕并居中裁剪，可随时切换纯白背景与自定义图片 |
| 墨水污渍效果 | 背景添加墨点聚集式污渍，模拟墨水溅在纸上的质感，默认关闭，同一天生成的污渍位置一致，每天变化 |
| 壁纸字体 | 输入字体文件名自定义壁纸字体，留空使用内置汇文明朝体 |
| 壁纸语言 | 简体中文、英文、繁體中文（香港），独立于 KOReader UI 语言 |

### 通用设置

| 选项 | 说明 |
|------|------|
| 生成并设为休眠壁纸 | 生成新壁纸，并设置为 KOReader 休眠屏幕图片 |
| 关闭墨痕壁纸 | 停止自动刷新，并恢复启用墨痕前的原生屏保设置 |
| 仅生成壁纸 | 只生成图片，不修改 KOReader 屏保设置 |
| 休眠前自动刷新 | 当前正在使用墨痕壁纸时，休眠前自动重新生成 |
| 自动设置 KOReader 休眠屏幕 | 生成后自动设置为休眠壁纸 |
| 锁屏使用范围 | 可选择只在主页使用，或主页和阅读界面都使用 |
| 显示输出路径 | 查看当前壁纸输出位置 |
| 检查更新 | 检查 GitHub Release 新版本并在线安装 |

## 📝 更新日志

### v3.2.0（2026.08）

**新增**

- 自定义背景图片：支持选择本地图片作为壁纸背景（PNG / JPG）
    - 图片自动等比例缩放填满屏幕，居中裁剪
    - 账单文字直接叠加在背景图上
    - 可随时切换：纯白背景 / 自定义图片
- 墨水污渍效果：背景添加墨点聚集式污渍，模拟墨水溅在纸上的质感
    - 默认关闭，可在外观设置中手动开启
    - 同一天生成的污渍位置一致，每天变化
- 繁體中文（香港）语言包（zh-HK）
- 统计周期新增四个选项：最近一个季度（90 天）、最近半年（180 天）、最近一年（365 天）、最近 10 年（3650 天）

**修复**

- 修复觅阅阅读记录同步率低的问题
    - 书名匹配升级为三级：精确匹配 → 规范化匹配 → 前缀/包含模糊匹配
    - 支持公众号/漫画书架（shelf_cache.mp）进度读取
    - 进度新增云端回退：progress_remote_percent 等多源回退
    - 增加详细调试日志，方便排查问题
- 修复 i18n 翻译条数统计一直显示 0 的 bug

**优化**

- 设置菜单归类整理，分为「数据与统计」「外观设置」「通用设置」三大分组
- 壁纸语言菜单将「中文」改标为「简体中文」，新增「繁體中文（香港）」选项

### v3.0.2（2026.08）

**新增**

- 新增繁體中文（香港）语言包（zh-HK）
- 觅阅书架支持公众号/漫画（shelf_cache.mp）进度读取
- 觅阅进度新增云端回退：progress_remote_percent / progress_upload_percent / pending_progress.percent

**修复**

- 修复觅阅阅读记录同步率低的问题
    - 书名匹配升级为三级：精确匹配 → 规范化匹配（去空格/标点）→ 前缀/包含模糊匹配
    - stream 模式下从本地 library 补充书架进度
    - 增加详细调试日志，方便排查问题
- 修复 i18n 翻译条数统计一直显示 0 的 bug
- 补齐缺失的 async.lua / json.lua（OTA 异步更新依赖）

**优化**

- 壁纸语言菜单将「中文」改标为「简体中文」，新增「繁體中文（香港）」选项
- 觅阅进度读取增加容错，避免 sessions/library 为 nil 时崩溃

### v3.0.1（2026.08）

- 修复了一些已知问题
- OTA 网络层重写，修复部分设备闪退

### v3.0.0（2026.08）

- 修复切换壁纸语言后生成壁纸闪退（`pickQuote` 参数错误）
- 修复觅阅阅读记录不显示：补充读取 `library`（本地书库），不再仅依赖 `shelf_cache`（云端书架）
- 修复觅阅进度取值不完整：对齐觅阅 `local_progress` 逻辑，补全 `pending`/`verified` 进度字段
- 重构壁纸本地化为 .po 语言包系统（仿 ZenUI 插件方案）
- 新增 `locales/zh.po` 和 `locales/en.po`，纯文本 .po 文件，无需编译
- 新增 `i18n.lua` 模块：运行时纯 Lua 解析 .po，带缓存和回退
- 移除硬编码 `WALLPAPER_I18N` 对照表，所有壁纸文本由 .po 文件驱动

### v2.1.0（2026.08）

- 修复切换壁纸语言后生成壁纸闪退：`pickQuote` 误传 `lang` 字符串而非翻译对象 `T`，导致 Lua 调用字符串值崩溃
- 壁纸本地化系统重构为 .po 语言包（仿 ZenUI 插件方案）
- 新增 `i18n.lua` 模块：纯 Lua .po 解析器，运行时解析，无需编译 .mo
- 新增 `locales/zh.po` 和 `locales/en.po`：标准 gettext .po 格式，纯文本可编辑
- 移除硬编码 `WALLPAPER_I18N` Lua 表和 `QUOTES`/`QUOTES_EN` 数组
- 所有壁纸渲染文本（标题、标签、格言、错误提示等）统一由 .po 文件驱动
- 支持语言缓存：切换语言时自动清除缓存并重新加载

### v2.0.9（2026.08）

- 新增壁纸语言切换：设置中可选中文或英文壁纸渲染
- 英文版壁纸包含全英文标题、标签、格言和错误提示
- 英文标题样式：Ink Stain + reading receipt 副标题

### v2.0.7（2026.08）

- 新增壁纸字体自定义功能：输入字体文件名即可切换
- 彻底修复字体选择闪退：改为文本输入，不再扫描字体目录
- 修复觅阅数据源不显示记录的问题：复用 KOReader 统计查询，觅阅仅补充进度
- 修复两者合并模式下进度全部显示 0% 的问题
- Top 5 书单支持，最大展示书籍数从 4 本提升至 5 本
- OTA 加入 SHA256 哈希验证，防止文件损坏或篡改
- 重写 OTA 网络层，手动处理 HTTP 重定向，修复部分设备闪退
- 标题排版优化：「墨」与「痕」等大，「ink stain」左对齐垫于「痕」下方
- 仿照觅阅插件 OTA 方法，优化下载速度

### v2.0.0（2026.08）

- 新增多数据源支持：KOReader 阅读统计 / 觅阅书架 / 两者合并
- 新增在线更新功能，支持 GitHub Release 检查、下载并自动安装
- 新增 GitHub 镜像加速，内置三个镜像源
- 新增下载三级回退（ssl.https / curl / wget）
- 新增内嵌汇文明朝体字体，不依赖用户字体设置
- 改进标题字号和底部布局
- 修复字体加载闪退、版本号比较、解压模块等多个问题

### v1.0.0（2026.08）

- 首个稳定版本
- Ink Stain 风格墨痕账单壁纸生成
- KOReader 阅读统计数据库读取
- 今天 / 最近 7 天 / 最近 30 天统计周期
- Top 书单、阅读进度、每日阅读趋势折线
- 休眠前自动刷新、旧图片自动清理
- 原生屏保设置备份与恢复
- 锁屏使用范围设置
- 简体中文、繁体中文（台湾、香港、澳门）、韩语本地化

## 🙏 致谢

- 感谢 [KOReader](https://github.com/koreader/koreader) 项目提供阅读统计、插件系统和 PNG 渲染能力
- 感谢 [觅阅 MiuRead](https://github.com/miumiupy98-art/miuread-koreader) 作者 [@miumiupy98-art](https://github.com/miumiupy98-art)，多数据源功能和 OTA 方法参考了觅阅插件的实现
- 感谢 [ZenUI](https://github.com/AnthonyGress/zen_ui.koplugin) 插件，.po 语言包方案参考了 ZenUI 的 i18n 实现

## 📄 许可证

GNU General Public License v3.0

Copyright (C) 2026 Estela-Zelin84

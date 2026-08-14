--[[--
KOReader 墨痕壁纸。

本插件根据 KOReader 内置阅读统计数据库生成“墨痕账单”风格休眠壁纸。
输出格式为 PNG，使用 KOReader 自己的文字渲染组件绘制，避免 SVG 文本不显示。
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local FontList = require("fontlist")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local RenderImage = require("ui/renderimage")
local SQ3 = require("lua-ljsqlite3/init")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = ffiutil.template

-- HTTP 相关模块（仿照 MiuRead 插件，手动处理重定向）
local ltn12 = require("ltn12")
local ok_socketutil, socketutil = pcall(require, "socketutil")
local ok_http, http = pcall(require, "socket.http")
local ok_https, https = pcall(require, "ssl.https")

local UPDATE_API = "https://api.github.com/repos/Estela-Zelin84/inkstain.koplugin/releases/latest"
local PLUGIN_VERSION = "2.0.9"

-- GitHub 镜像加速地址，仅对 github.com / api.github.com / raw.githubusercontent.com 生效
local GITHUB_MIRRORS = {
    "https://ghfast.top/",
    "https://gh-proxy.com/",
    "https://ghproxy.net/",
}

local function isGithubUrl(url)
    return type(url) == "string" and (
        url:match("^https://github%.com/")
        or url:match("^https://api%.github%.com/")
        or url:match("^https://raw%.githubusercontent%.com/")
    ) ~= nil
end

-- 将一个 GitHub URL 展开为：原始地址 + 各镜像地址（镜像前缀 + 原始 URL）
local function buildMirrorUrls(url)
    local urls = { url }
    if not isGithubUrl(url) then return urls end
    for _, prefix in ipairs(GITHUB_MIRRORS) do
        local p = prefix
        if p:sub(-1) ~= "/" then p = p .. "/" end
        urls[#urls + 1] = p .. url
    end
    return urls
end

local Screen = Device.screen
local PLUGIN_FONT_NAME = "huiwen_ming.otf"
-- 当前渲染使用的字体（在 buildPng 时从 settings 同步）
local _active_font_name = ""

local DEFAULT_SETTINGS = {
    days = 7,
    top_n = 5,
    min_minutes = 1,
    title = "墨痕账单",
    auto_set_screensaver = true,
    auto_refresh_on_suspend = true,
    refresh_interval = 10 * 60,
    menu_scope = "home",
    data_source = "koreader",
    font_name = "",  -- 空字符串表示使用内置字体
    progress_mode = "total",  -- "total" 总进度 / "period" 本期进度
    wallpaper_lang = "zh",  -- "zh" 中文 / "en" 英文
}

local SCREENSAVER_SETTING_KEYS = {
    "screensaver_type",
    "screensaver_dir",
    "screensaver_document_cover",
    "screensaver_img_background",
    "screensaver_msg_background",
    "screensaver_stretch_images",
    "screensaver_stretch_limit_percentage",
    "screensaver_rotate_auto_for_best_fit",
    "screensaver_show_message",
    "screensaver_message",
    "screensaver_message_container",
    "screensaver_message_vertical_position",
    "screensaver_message_alpha",
    "screensaver_delay",
    "screensaver_show_exit_message",
    "screensaver_hide_cover_in_filemanager",
    "screensaver_exclude_finished_books",
    "screensaver_exclude_on_hold_books",
    "screensaver_cycle_images_alphabetically",
}

local InkStain = WidgetContainer:extend{
    name = "inkstain",
    is_doc_only = false,
    settings_key = "inkstain_wallpaper",
    last_refresh_ts = 0,
}

local QUOTES = {
    "书卷多情似故人，晨昏忧乐每相亲。",
    "读书不觉已春深，一寸光阴一寸金。",
    "纸上得来终觉浅，绝知此事要躬行。",
    "我本愿将心向明月，奈何明月照沟渠。",
    "黑发不知勤学早，白首方悔读书迟。",
    "粗缯大布裹生涯，腹有诗书气自华。",
    "灯火纸窗修竹里，读书声。",
    "读万卷书，行万里路。",
}

local QUOTES_EN = {
    "A reader lives a thousand lives before he dies.",
    "Books are a uniquely portable magic.",
    "The more that you read, the more things you will know.",
    "Reading is to the mind what exercise is to the body.",
    "A book is a dream that you hold in your hand.",
    "Today a reader, tomorrow a leader.",
    "Books let us travel without moving our feet.",
    "Reading is conversation across centuries.",
}

--- 壁纸渲染文本 i18n 对照表
local WALLPAPER_I18N = {
    zh = {
        title_cn1 = "墨",
        title_cn2 = "痕",
        title_en = "ink stain",
        serial = "单号：",
        period = "时间：",
        device_source = "设备：KOReader    来源：",
        duration = "时长：",
        top_books = "书单：Top ",
        col_category = "品类",
        col_qty = "数量",
        col_unit = "单位",
        author = "作者：",
        progress = "进度：",
        period_time = "  本期：",
        unit_book = "本",
        omitted = " 本因屏幕高度省略",
        omitted_prefix = "另有 ",
        daily_avg = "日均：",
        total = "合计：",
        min_suffix = "分",
        err_read = "读取统计失败：",
        err_no_db = "未找到 KOReader 阅读统计数据库，请先启用\"阅读统计\"。",
        err_empty = "本周期暂无可显示的阅读记录。",
        source_koreader = "阅读统计",
        source_miuread = "觅阅",
        source_both = "KOReader + 觅阅",
        hr = "小时",
        min = "分钟",
    },
    en = {
        title_cn1 = "Ink",
        title_cn2 = "Stain",
        title_en = "",
        serial = "No. ",
        period = "Date: ",
        device_source = "Device: KOReader    Source: ",
        duration = "Total: ",
        top_books = "List: Top ",
        col_category = "Title",
        col_qty = "Qty",
        col_unit = "Unit",
        author = "Author: ",
        progress = "Progress: ",
        period_time = "  Period: ",
        unit_book = "ea",
        omitted = " more omitted (screen height)",
        omitted_prefix = "",
        daily_avg = "Daily avg: ",
        total = "Total: ",
        min_suffix = "m",
        err_read = "Failed to read stats: ",
        err_no_db = "KOReader statistics DB not found. Please enable Reading Statistics.",
        err_empty = "No reading records in this period.",
        source_koreader = "Statistics",
        source_miuread = "MiuRead",
        source_both = "KOReader + MiuRead",
        hr = "h ",
        min = "m",
    },
}

local function getI18n(lang)
    return WALLPAPER_I18N[lang] or WALLPAPER_I18N.zh
end

local CODE128_PATTERNS = {
    "212222","222122","222221","121223","121322","131222","122213","122312","132212","221213",
    "221312","231212","112232","122132","122231","113222","123122","123221","223211","221132",
    "221231","213212","223112","312131","311222","321122","321221","312212","322112","322211",
    "212123","212321","232121","111323","131123","131321","112313","132113","132311","211313",
    "231113","231311","112133","112331","132131","113123","113321","133121","313121","211331",
    "231131","213113","213311","213131","311123","311321","331121","312113","312311","332111",
    "314111","221411","431111","111224","111422","121124","121421","141122","141221","112214",
    "112412","122114","122411","142112","142211","241211","221114","413111","241112","134111",
    "111242","121142","121241","114212","124112","124211","411212","421112","421211","212141",
    "214121","412121","111143","111341","131141","114113","114311","411113","411311","113141",
    "114131","311141","411131","211412","211214","211232","2331112",
}

local function copyDefaults(settings)
    settings = settings or {}
    for key, value in pairs(DEFAULT_SETTINGS) do
        if settings[key] == nil then
            settings[key] = value
        end
    end
    return settings
end

local function truncate(value, limit)
    value = tostring(value or "")
    limit = limit or 18
    local ok, chars = pcall(util.splitToChars, value)
    if not ok or type(chars) ~= "table" then
        if #value > limit * 3 then
            return value:sub(1, limit * 3) .. "…"
        end
        return value
    end
    if #chars <= limit then
        return value
    end
    local out = {}
    for i = 1, limit do
        out[i] = chars[i]
    end
    out[#out + 1] = "…"
    return table.concat(out)
end

local function formatDuration(seconds, i18n)
    seconds = tonumber(seconds) or 0
    local minutes = math.floor(seconds / 60 + 0.5)
    local hours = math.floor(minutes / 60)
    local mins = minutes - hours * 60
    if mins >= 60 then
        hours = hours + 1
        mins = mins - 60
    end
    if not i18n then i18n = WALLPAPER_I18N.zh end
    if hours > 0 then
        return string.format("%d%s%d%s", hours, i18n.hr, mins, i18n.min)
    end
    return string.format("%d%s", mins, i18n.min)
end

local function dayStart(ts)
    local t = os.date("*t", ts or os.time())
    t.hour, t.min, t.sec = 0, 0, 0
    return os.time(t)
end

local function dateKey(ts)
    return os.date("%Y-%m-%d", ts)
end

local function shortDate(ts)
    return os.date("%m-%d", ts)
end

local function ensureDir(path)
    if lfs.attributes(path, "mode") == "directory" then return true end
    if util.makePath then
        return util.makePath(path)
    end

    local current = ""
    for part in string.gmatch(path, "[^/]+") do
        current = current .. "/" .. part
        if lfs.attributes(current, "mode") ~= "directory" then
            local ok = lfs.mkdir(current)
            if not ok then return false end
        end
    end
    return true
end

local function cleanupImageFilesInDir(path, keep_path)
    if lfs.attributes(path, "mode") ~= "directory" then
        return
    end
    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then
            local fullpath = path .. "/" .. entry
            local mode = lfs.attributes(fullpath, "mode")
            local lower = entry:lower()
            if mode == "file" and (
                lower:match("%.png$")
                or lower:match("%.jpg$")
                or lower:match("%.jpeg$")
                or lower:match("%.svg$")
                or lower:match("%.webp$")
            ) and fullpath ~= keep_path then
                os.remove(fullpath)
            end
        end
    end
end

function InkStain:init()
    self.settings = copyDefaults(G_reader_settings:readSetting(self.settings_key, {}))
    self.output_dir = DataStorage:getDataDir() .. "/screensaver/inkstain_png"
    self.output_file = self.output_dir .. "/inkstain_wallpaper.png"
    self.legacy_output_dir = DataStorage:getDataDir() .. "/screensaver/inkstain"
    self.db_location = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    local font_src = (self.path or "") .. "/assets/" .. PLUGIN_FONT_NAME
    local font_dest = FontList.fontdir .. "/" .. PLUGIN_FONT_NAME
    if lfs.attributes(font_src, "mode") == "file" and not lfs.attributes(font_dest, "mode") then
        local src_f = io.open(font_src, "rb")
        if src_f then
            local content = src_f:read("*a")
            src_f:close()
            local dest_f = io.open(font_dest, "wb")
            if dest_f then
                dest_f:write(content)
                dest_f:close()
                logger.info("墨痕壁纸：已复制字体到", font_dest)
            end
        end
    end
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    _G.InkStainWallpaper = self
end

function InkStain:saveSettings()
    G_reader_settings:saveSetting(self.settings_key, self.settings)
    if G_reader_settings.flush then
        G_reader_settings:flush()
    end
end

function InkStain:getRange()
    local days = tonumber(self.settings.days) or DEFAULT_SETTINGS.days
    if days < 1 then days = 1 end
    local today = dayStart()
    local start_ts = today - (days - 1) * 86400
    local end_ts = today + 86400
    return start_ts, end_ts, days
end

--- 从 miuread.lua 获取书架进度信息（不查询数据库）
-- 觅阅通过 KOReader 打开书籍，阅读统计已写入 statistics.sqlite3，
-- 这里只需获取觅阅书架的进度（progress_local_percent）来补充 KOReader 统计结果
function InkStain:readMiureadProgress()
    local miuread_path = DataStorage:getSettingsDir() .. "/miuread.lua"
    local result = {
        progress_map = {},
        has_miuread = lfs.attributes(miuread_path, "mode") == "file",
    }
    if not result.has_miuread then
        return result
    end
    local ok, LuaSettings = pcall(require, "luasettings")
    if not ok then
        return result
    end
    local ok_open, miuread_db = pcall(LuaSettings.open, miuread_path)
    if not ok_open or not miuread_db then
        return result
    end
    local shelf = miuread_db:readSetting("shelf_cache", nil)
    local sessions = miuread_db:readSetting("sessions", nil) or {}
    if miuread_db.close then miuread_db:close() end

    -- shelf_cache 结构兼容：{books = {...}} 或直接为数组
    local shelf_books = nil
    if shelf then
        if shelf.books then
            shelf_books = shelf.books
        elseif type(shelf) == "table" and #shelf > 0 and type(shelf[1]) == "table" and shelf[1].title then
            shelf_books = shelf
        end
    end

    -- 构建书名 → 进度 查找表
    -- 进度优先取 sessions[bookId].progress_local_percent，其次取 shelf_cache 的 progress
    if shelf_books then
        for _, row in ipairs(shelf_books) do
            local book_id = tostring(row.bookId or row.book_id or "")
            local session = sessions[book_id] or {}
            local title = row.title or "未命名书籍"
            local progress = tonumber(session.progress_local_percent or row.progress or 0) or 0
            if progress > 0 then
                result.progress_map[title] = math.min(100, math.max(0, progress))
            end
        end
    end

    logger.dbg("墨痕壁纸：觅阅进度表", result.progress_map)
    return result
end

--- 模糊匹配书名获取进度
local function matchProgress(progress_map, title)
    if not title or title == "" then return nil end
    -- 精确匹配
    if progress_map[title] then
        return progress_map[title]
    end
    -- 前缀模糊匹配
    for shelf_title, shelf_progress in pairs(progress_map) do
        if shelf_title:sub(1, #title) == title or title:sub(1, #shelf_title) == shelf_title then
            return shelf_progress
        end
    end
    return nil
end

function InkStain:readStats()
    local start_ts, end_ts, days = self:getRange()
    local result = {
        start_ts = start_ts,
        end_ts = end_ts,
        days = days,
        books = {},
        daily = {},
        total_seconds = 0,
        total_pages = 0,
        book_count = 0,
        has_db = lfs.attributes(self.db_location, "mode") == "file",
    }

    for i = 1, days do
        local ts = start_ts + (i - 1) * 86400
        result.daily[i] = {
            date = dateKey(ts),
            label = shortDate(ts),
            seconds = 0,
        }
    end

    if not result.has_db then
        return result
    end

    local ok, conn = pcall(SQ3.open, self.db_location)
    if not ok or not conn then
        result.error = "无法打开统计数据库"
        return result
    end

    local ok_query, err = pcall(function()
        local daily_sql = string.format([[
            SELECT strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime') AS day,
                   sum(duration) AS seconds,
                   count(DISTINCT page) AS pages
            FROM page_stat_data
            WHERE start_time >= %d AND start_time < %d
            GROUP BY day
            ORDER BY day;
        ]], start_ts, end_ts)
        local daily_rows = conn:exec(daily_sql)
        local by_day = {}
        if daily_rows then
            local days_col, seconds_col, pages_col = daily_rows[1] or {}, daily_rows[2] or {}, daily_rows[3] or {}
            for i, day in ipairs(days_col) do
                by_day[day] = {
                    seconds = tonumber(seconds_col[i]) or 0,
                    pages = tonumber(pages_col[i]) or 0,
                }
            end
        end
        for _, item in ipairs(result.daily) do
            if by_day[item.date] then
                item.seconds = by_day[item.date].seconds
                result.total_pages = result.total_pages + by_day[item.date].pages
            end
        end

        local total_sql = string.format([[
            SELECT sum(duration), count(DISTINCT id_book)
            FROM page_stat_data
            WHERE start_time >= %d AND start_time < %d;
        ]], start_ts, end_ts)
        local total_seconds, book_count = conn:rowexec(total_sql)
        result.total_seconds = tonumber(total_seconds) or 0
        result.book_count = tonumber(book_count) or 0

        local min_seconds = math.max(0, tonumber(self.settings.min_minutes) or 0) * 60
        local top_n = math.max(1, math.min(5, tonumber(self.settings.top_n) or DEFAULT_SETTINGS.top_n))
        local books_sql = string.format([[
            SELECT b.title,
                   ifnull(b.authors, ''),
                   sum(p.duration) AS seconds,
                   count(DISTINCT p.page) AS read_pages,
                   max(ifnull(b.pages, 0)) AS pages,
                   max(p.start_time) AS last_time,
                   (SELECT MAX(ps.page) FROM page_stat_data ps WHERE ps.id_book = p.id_book) AS max_page
            FROM page_stat_data p
            JOIN book b ON b.id = p.id_book
            WHERE p.start_time >= %d AND p.start_time < %d
            GROUP BY p.id_book
            HAVING seconds >= %d
            ORDER BY seconds DESC, last_time DESC
            LIMIT %d;
        ]], start_ts, end_ts, min_seconds, top_n)
        local book_rows = conn:exec(books_sql)
        if book_rows then
            local titles = book_rows[1] or {}
            local authors = book_rows[2] or {}
            local seconds = book_rows[3] or {}
            local read_pages = book_rows[4] or {}
            local pages = book_rows[5] or {}
            local max_pages_col = book_rows[7] or {}
            for i, title in ipairs(titles) do
                table.insert(result.books, {
                    title = title ~= "" and title or "未命名书籍",
                    authors = authors[i] ~= "" and authors[i] or "未知作者",
                    seconds = tonumber(seconds[i]) or 0,
                    read_pages = tonumber(read_pages[i]) or 0,
                    pages = tonumber(pages[i]) or 0,
                    max_page = tonumber(max_pages_col[i]) or 0,
                    source = "koreader",
                })
            end
        end
    end)

    conn:close()
    if not ok_query then
        result.error = tostring(err)
        logger.warn("墨痕壁纸：读取统计数据失败：", err)
    end

    local source = self.settings.data_source or "koreader"
    if source == "miuread" or source == "both" then
        local miuread_data = self:readMiureadProgress()
        result.has_miuread = miuread_data.has_miuread
        local progress_map = miuread_data.progress_map or {}

        if source == "miuread" then
            -- 觅阅数据源：KOReader 统计提供基础数据（书单/时长/页数），觅阅提供进度
            -- 不再独立查询数据库，复用 readStats 已有的 KOReader 查询结果
            result.data_source_key = "miuread"
            for _, b in ipairs(result.books) do
                local found = matchProgress(progress_map, b.title)
                if found and found > 0 then
                    b.progress = found
                    b.source = "miuread"
                end
            end
        elseif source == "both" then
            -- 两者合并：优先使用觅阅进度（progress_local_percent），更准确
            -- 觅阅进度不可用时，回退到 max_page/pages 计算
            result.data_source_key = "both"
            for _, b in ipairs(result.books) do
                local found = matchProgress(progress_map, b.title)
                if found and found > 0 then
                    b.progress = found
                end
            end
        end
    else
        result.data_source_key = "koreader"
    end

    local top_n = math.max(1, math.min(5, tonumber(self.settings.top_n) or DEFAULT_SETTINGS.top_n))
    while #result.books > top_n do
        table.remove(result.books)
    end

    return result
end

local function getFontFace(size, font_name)
    local sz = math.max(8, math.floor(size))
    local fname = font_name or _active_font_name
    -- 优先使用用户自定义字体
    if fname and fname ~= "" then
        -- Font:getFace 支持字体族名（如 "Noto Sans CJK SC"）或文件名（如 "NotoSansCJKsc-Regular.otf"）
        -- 不支持完整文件路径，如果传入路径则提取文件名
        local ok_face, face = pcall(Font.getFace, Font, fname, sz)
        if ok_face and face then return face end
        -- 尝试从路径提取文件名
        local basename = fname:match("([^/]+)$")
        if basename and basename ~= fname then
            local ok2, face2 = pcall(Font.getFace, Font, basename, sz)
            if ok2 and face2 then return face2 end
        end
        logger.warn("墨痕壁纸：自定义字体加载失败，回退到内置字体", fname)
    end
    -- 回退到内置字体
    local font_dest = FontList.fontdir .. "/" .. PLUGIN_FONT_NAME
    if lfs.attributes(font_dest, "mode") == "file" then
        local face = Font:getFace(PLUGIN_FONT_NAME, sz)
        if face then return face end
    end
    return Font:getFace("cfont", sz)
end

local function drawText(bb, text, x, y, size, bold, max_width, align, color)
    local widget = TextWidget:new{
        text = tostring(text or ""),
        face = getFontFace(size),
        bold = bold and true or false,
        fgcolor = color or Blitbuffer.COLOR_BLACK,
        max_width = max_width,
    }
    widget:updateSize()
    local draw_x = math.floor(x)
    if align == "right" then
        draw_x = math.floor(x - widget:getSize().w)
    elseif align == "center" then
        draw_x = math.floor(x - widget:getSize().w / 2)
    end
    widget:paintTo(bb, draw_x, math.floor(y))
    local widget_size = widget:getSize()
    if widget.free then widget:free() end
    return widget_size
end

local function drawImage(bb, path, x, y, size)
    local ok, image = pcall(RenderImage.renderImageFile, RenderImage, path, false, size, size)
    if ok and image then
        local ok_blit = pcall(bb.blitFrom, bb, image, math.floor(x), math.floor(y), 0, 0, image:getWidth(), image:getHeight())
        if image.free then image:free() end
        return ok_blit
    end
    return false
end

local function drawBoxText(bb, text, x, y, width, size, bold, align)
    local widget = TextBoxWidget:new{
        text = tostring(text or ""),
        face = getFontFace(size),
        bold = bold and true or false,
        fgcolor = Blitbuffer.COLOR_BLACK,
        bgcolor = Blitbuffer.COLOR_WHITE,
        width = math.floor(width),
        alignment = align or "left",
        height_overflow_show_ellipsis = true,
    }
    widget:paintTo(bb, math.floor(x), math.floor(y))
    if widget.free then widget:free() end
end

local function drawRect(bb, x, y, w, h, color)
    bb:paintRect(math.floor(x), math.floor(y), math.max(1, math.floor(w)), math.max(1, math.floor(h)), color or Blitbuffer.COLOR_BLACK)
end

local function drawLine(bb, x1, y1, x2, y2, width, color)
    x1, y1, x2, y2 = math.floor(x1), math.floor(y1), math.floor(x2), math.floor(y2)
    width = math.max(1, math.floor(width or 1))
    local dx = math.abs(x2 - x1)
    local sx = x1 < x2 and 1 or -1
    local dy = -math.abs(y2 - y1)
    local sy = y1 < y2 and 1 or -1
    local err = dx + dy
    while true do
        drawRect(bb, x1, y1, width, width, color)
        if x1 == x2 and y1 == y2 then break end
        local e2 = 2 * err
        if e2 >= dy then
            err = err + dy
            x1 = x1 + sx
        end
        if e2 <= dx then
            err = err + dx
            y1 = y1 + sy
        end
    end
end

local function drawFrame(bb, x, y, w, h, width, color)
    width = math.max(1, math.floor(width or 1))
    drawRect(bb, x, y, w, width, color)
    drawRect(bb, x, y + h - width, w, width, color)
    drawRect(bb, x, y, width, h, color)
    drawRect(bb, x + w - width, y, width, h, color)
end

local function drawPseudoQR(bb, x, y, size, seed)
    size = math.floor(size)
    local cells = 21
    local cell = math.max(1, math.floor(size / cells))
    local actual = cell * cells
    drawRect(bb, x, y, actual, actual, Blitbuffer.COLOR_WHITE)
    local function finder(fx, fy)
        drawRect(bb, x + fx * cell, y + fy * cell, 7 * cell, 7 * cell)
        drawRect(bb, x + (fx + 1) * cell, y + (fy + 1) * cell, 5 * cell, 5 * cell, Blitbuffer.COLOR_WHITE)
        drawRect(bb, x + (fx + 2) * cell, y + (fy + 2) * cell, 3 * cell, 3 * cell)
    end
    finder(0, 0)
    finder(14, 0)
    finder(0, 14)
    seed = tostring(seed or os.time())
    for row = 0, cells - 1 do
        for col = 0, cells - 1 do
            local in_finder = (row < 7 and col < 7) or (row < 7 and col >= 14) or (row >= 14 and col < 7)
            if not in_finder then
                local s = seed:byte((row + col) % #seed + 1) or 1
                if ((row * 7 + col * 11 + s) % 5) < 2 then
                    drawRect(bb, x + col * cell, y + row * cell, cell, cell)
                end
            end
        end
    end
end

local function code128Patterns(data)
    data = tostring(data or "")
    if data == "" then data = os.date("%Y%m%d") end
    local codes = { 104 } -- Start Code B
    local checksum = 104
    for i = 1, #data do
        local b = data:byte(i)
        if b < 32 or b > 126 then b = 63 end
        local value = b - 32
        codes[#codes + 1] = value
        checksum = checksum + value * i
    end
    codes[#codes + 1] = checksum % 103
    codes[#codes + 1] = 106
    return codes
end

local function drawBarcode128(bb, data, x, y, width, height)
    local codes = code128Patterns(data)
    local modules = 0
    for _, code in ipairs(codes) do
        local pattern = CODE128_PATTERNS[code + 1]
        for i = 1, #pattern do
            modules = modules + tonumber(pattern:sub(i, i))
        end
    end
    local module_w = width / modules
    local pos = x
    for _, code in ipairs(codes) do
        local pattern = CODE128_PATTERNS[code + 1]
        local black = true
        for i = 1, #pattern do
            local mw = tonumber(pattern:sub(i, i)) * module_w
            if black then
                drawRect(bb, pos, y, math.max(1, mw), height)
            end
            pos = pos + mw
            black = not black
        end
    end
end

local function pickQuote(stats, lang)
    local seed = tonumber(os.date("%j", stats.end_ts - 1)) or 1
    seed = seed + math.floor((stats.total_seconds or 0) / 60) + (stats.book_count or 0) * 7
    local quotes = (lang == "en") and QUOTES_EN or QUOTES
    return quotes[(seed % #quotes) + 1]
end

-- 自定义标题渲染
-- 中文模式：墨 + 痕（同字号）+ ink stain（英文在痕下方左对齐）
-- 英文模式：Ink Stain 大字 + ink stain 小字副标题
local function drawCustomTitle(bb, x_right, y, scale, lang)
    if lang == "en" then
        -- 英文标题：Ink Stain
        local main_size = math.max(28, math.min(40, math.floor(38 * scale)))
        local sub_size = math.max(10, math.floor(main_size * 0.32))
        local main_w = TextWidget:new{ text = "Ink Stain", face = getFontFace(main_size), bold = true }
        main_w:updateSize()
        local sub_w = TextWidget:new{ text = "reading receipt", face = getFontFace(sub_size), bold = false }
        sub_w:updateSize()
        local gap = math.max(2, math.floor(3 * scale))
        local total_w = math.max(main_w:getSize().w, sub_w:getSize().w)
        local start_x = math.floor(x_right - total_w)
        main_w:paintTo(bb, start_x, y)
        local sub_y = y + main_w:getSize().h + math.max(1, math.floor(2 * scale))
        sub_w:paintTo(bb, start_x, sub_y)
        local total_h = main_w:getSize().h + math.max(1, math.floor(2 * scale)) + sub_w:getSize().h
        if main_w.free then main_w:free() end
        if sub_w.free then sub_w:free() end
        return { w = total_w, h = total_h }
    end

    -- 中文标题：墨 + 痕 + ink stain
    local cn_size = math.max(32, math.min(48, math.floor(42 * scale)))
    local en_size = math.max(10, math.floor(cn_size * 0.32))

    local mo_w = TextWidget:new{ text = "墨", face = getFontFace(cn_size), bold = true }
    mo_w:updateSize()
    local mo_w_w, mo_w_h = mo_w:getSize().w, mo_w:getSize().h

    local hen_w = TextWidget:new{ text = "痕", face = getFontFace(cn_size), bold = true }
    hen_w:updateSize()
    local hen_w_w, hen_w_h = hen_w:getSize().w, hen_w:getSize().h

    local en_w = TextWidget:new{ text = "ink stain", face = getFontFace(en_size), bold = false }
    en_w:updateSize()
    local en_w_w, en_w_h = en_w:getSize().w, en_w:getSize().h

    local gap = math.max(2, math.floor(3 * scale))
    -- 墨 痕 横排，ink stain 在痕下方左对齐
    local cn_total_w = mo_w_w + gap + hen_w_w
    local total_w = math.max(cn_total_w, mo_w_w + gap + en_w_w)
    local start_x = math.floor(x_right - total_w)

    -- 墨：左上
    mo_w:paintTo(bb, start_x, y)
    -- 痕：墨右侧，顶部对齐
    local hen_x = start_x + mo_w_w + gap
    hen_w:paintTo(bb, hen_x, y)
    -- ink stain：痕下方，与痕左对齐
    local en_y = y + mo_w_h + math.max(1, math.floor(2 * scale))
    en_w:paintTo(bb, hen_x, en_y)

    if mo_w.free then mo_w:free() end
    if hen_w.free then hen_w:free() end
    if en_w.free then en_w:free() end

    local total_h = mo_w_h + math.max(1, math.floor(2 * scale)) + en_w_h
    return { w = total_w, h = total_h }
end

function InkStain:buildPng(stats)
    _active_font_name = self.settings.font_name or ""
    local w, h = Screen:getWidth(), Screen:getHeight()
    if w > h then
        w, h = h, w
    end
    if w < 300 or h < 300 then
        w, h = 824, 1200
    end

    local bb = Blitbuffer.new(w, h, Screen.bb:getType())
    bb:fill(Blitbuffer.COLOR_WHITE)

    local lang = self.settings.wallpaper_lang or "zh"
    local T = getI18n(lang)

    local scale = math.min(w / 600, h / 800)
    local margin_x = math.max(20, math.floor(w * 0.05))
    local margin_y = math.max(18, math.floor(h * 0.035))
    local title_size = math.max(32, math.min(48, math.floor(42 * scale)))
    local large = math.max(20, math.min(30, math.floor(26 * scale)))
    local normal = math.max(11, math.min(15, math.floor(13 * scale)))
    local small = math.max(9, math.min(12, math.floor(10 * scale)))
    local tiny = math.max(8, math.min(10, math.floor(8 * scale)))
    local line_w = 1
    local content_w = w - margin_x * 2

    local y = margin_y
    local s
    local ok_title, title_result = pcall(drawCustomTitle, bb, w - margin_x, y, scale, lang)
    if ok_title and title_result then
        s = title_result
    else
        logger.warn("墨痕壁纸：自定义标题渲染失败，回退到普通标题", title_result)
        local fallback_title = (lang == "en") and "Ink Stain" or (self.settings.title or "墨痕")
        s = drawText(bb, fallback_title, w - margin_x, y, title_size, true, nil, "right")
    end
    drawText(bb, T.serial .. os.date("%m%d", stats.end_ts - 1), margin_x, y + math.floor(s.h * 0.25), large, true)
    y = y + s.h + math.max(4, math.floor(4 * scale))
    s = drawText(bb, T.period .. os.date("%Y.%m.%d", stats.start_ts) .. " - " .. os.date("%Y.%m.%d", stats.end_ts - 1), margin_x, y, small, false, content_w)
    y = y + s.h + math.max(2, math.floor(2 * scale))
    local source_key = stats.data_source_key or "koreader"
    local source_label
    if source_key == "miuread" then
        source_label = T.source_miuread
    elseif source_key == "both" then
        source_label = T.source_both
    else
        source_label = T.source_koreader
    end
    s = drawText(bb, T.device_source .. source_label, margin_x, y, small, false, content_w)
    y = y + s.h + math.max(4, math.floor(4 * scale))
    drawText(bb, T.duration .. formatDuration(stats.total_seconds, T), margin_x, y, normal, true, content_w * 0.55)
    local top_n = math.max(1, math.min(5, tonumber(self.settings.top_n) or DEFAULT_SETTINGS.top_n))
    s = drawText(bb, T.top_books .. tostring(top_n), w - margin_x, y, normal, true, nil, "right")
    y = y + s.h + math.max(8, math.floor(8 * scale))
    drawLine(bb, margin_x, y, w - margin_x, y, line_w)

    local table_header_y = y + math.max(8, math.floor(8 * scale))
    local x_no = margin_x
    local x_title = margin_x + math.floor(76 * scale)
    local x_qty = w - margin_x - math.floor(68 * scale)
    local x_unit = w - margin_x - math.floor(18 * scale)
    local title_w = math.max(120, x_qty - x_title - 20 * scale)
    drawText(bb, T.col_category, x_no, table_header_y, small, false)
    drawText(bb, T.col_qty, x_qty, table_header_y, small, false, nil, "center")
    drawText(bb, T.col_unit, x_unit, table_header_y, small, false, nil, "center")
    y = table_header_y + math.max(22, math.floor(22 * scale))
    drawLine(bb, margin_x, y, w - margin_x, y, line_w)

    local chart_h = math.max(68, math.floor(h * 0.115))
    local qr_size = math.max(36, math.floor(42 * scale))
    local footer_h = math.max(82, math.floor(qr_size + 48 * scale))
    local chart_shift_up = math.max(18, math.floor(20 * scale))
    local chart_top = h - footer_h - chart_h - math.max(28, math.floor(28 * scale)) - chart_shift_up
    local table_bottom = chart_top - math.max(44, math.floor(44 * scale))
    local rows_top = y + math.max(8, math.floor(8 * scale))
    local min_row_h = math.max(56, math.floor(58 * scale))
    local max_rows_by_height = math.max(1, math.floor((table_bottom - rows_top) / min_row_h))
    local visible_rows = math.min(#stats.books, tonumber(self.settings.top_n) or 5, 5, max_rows_by_height)
    local row_h = min_row_h

    y = rows_top
    if #stats.books == 0 then
        local msg
        if stats.error then
            msg = T.err_read .. truncate(stats.error, 28)
        elseif not stats.has_db then
            msg = T.err_no_db
        else
            msg = T.err_empty
        end
        drawBoxText(bb, msg, margin_x, y + 8 * scale, content_w, normal, true)
    else
        for i = 1, visible_rows do
            local book = stats.books[i]
            local no = string.format("NO.%02d", i)
            local progress_mode = self.settings.progress_mode or "total"
            local progress = "—"
            if progress_mode == "period" then
                -- 本期进度：本期阅读页数 / 总页数
                if book.pages and book.pages > 0 and book.read_pages and book.read_pages > 0 then
                    progress = string.format("%d%%", math.min(100, math.floor(book.read_pages * 100 / book.pages + 0.5)))
                end
            else
                -- 总进度：优先觅阅进度，其次全期最大阅读页 / 总页数
                if book.progress then
                    progress = string.format("%d%%", math.min(100, math.floor(book.progress + 0.5)))
                elseif book.pages and book.pages > 0 and book.max_page and book.max_page > 0 then
                    progress = string.format("%d%%", math.min(100, math.floor(book.max_page * 100 / book.pages + 0.5)))
                end
            end
            drawText(bb, no, x_no, y, normal, true)
            s = drawText(bb, truncate(book.title, 16), x_title, y, normal, true, title_w)
            local meta_y = y + math.max(s.h, 18)
            drawText(bb, T.author .. truncate(book.authors, 14), x_title, meta_y, tiny, false, title_w)
            drawText(bb, T.progress .. progress .. T.period_time .. formatDuration(book.seconds, T), x_title, meta_y + math.max(14, math.floor(14 * scale)), tiny, false, title_w)
            drawText(bb, "1", x_qty, y + math.floor(row_h * 0.1), normal, true, nil, "center")
            drawText(bb, T.unit_book, x_unit, y + math.floor(row_h * 0.1), normal, true, nil, "center")
            y = y + row_h
        end
        if #stats.books > visible_rows then
            drawText(bb, T.omitted_prefix .. tostring(#stats.books - visible_rows) .. T.omitted, x_title, math.min(y, table_bottom - 18 * scale), tiny, false, title_w)
        end
    end
    drawLine(bb, margin_x, table_bottom, w - margin_x, table_bottom, line_w)

    local chart_w = content_w - 10 * scale
    local chart_x = margin_x + 5 * scale
    drawText(bb, T.daily_avg .. formatDuration(stats.total_seconds / math.max(1, stats.days), T), margin_x, chart_top - math.max(24, math.floor(24 * scale)), normal, true)
    drawText(bb, T.total .. formatDuration(stats.total_seconds, T), w - margin_x, chart_top - math.max(24, math.floor(24 * scale)), normal, true, nil, "right")
    drawLine(bb, chart_x, chart_top, chart_x, chart_top + chart_h, line_w)
    drawLine(bb, chart_x, chart_top + chart_h, chart_x + chart_w, chart_top + chart_h, line_w)

    local max_seconds = 1
    for _, item in ipairs(stats.daily) do
        if item.seconds > max_seconds then max_seconds = item.seconds end
    end
    local points = {}
    local count = #stats.daily
    local label_step = math.max(1, math.ceil(count / 7))
    for i, item in ipairs(stats.daily) do
        local x = chart_x + (count == 1 and chart_w / 2 or (i - 1) * chart_w / (count - 1))
        local yy = chart_top + chart_h - (item.seconds / max_seconds) * (chart_h - 16 * scale)
        table.insert(points, { x = x, y = yy, label = item.label, seconds = item.seconds, index = i })
    end
    for i = 1, #points - 1 do
        drawLine(bb, points[i].x, points[i].y, points[i + 1].x, points[i + 1].y, 2 * scale)
    end
    for _, p in ipairs(points) do
        drawRect(bb, p.x - 2 * scale, p.y - 2 * scale, 5 * scale, 5 * scale)
        if p.seconds == max_seconds and p.seconds > 0 then
            drawText(bb, tostring(math.floor(p.seconds / 60 + 0.5)) .. T.min_suffix, p.x, p.y - 18 * scale, tiny, false, nil, "center")
        end
        if count <= 10 or p.index == 1 or p.index == count or (p.index - 1) % label_step == 0 then
            drawText(bb, p.label, p.x, chart_top + chart_h + 10 * scale, tiny, false, nil, "center")
        end
    end

    local footer_y = chart_top + chart_h + math.max(26, math.floor(26 * scale))
    local qr_path = (self.path or "") .. "/assets/github_qr.png"
    if not drawImage(bb, qr_path, margin_x, footer_y, qr_size) then
        drawPseudoQR(bb, margin_x, footer_y, qr_size, os.date("%Y%m%d", stats.end_ts - 1))
    end
    local barcode_y = footer_y
    local x = margin_x + qr_size + 18 * scale
    local barcode_right = w - margin_x
    local barcode_h = math.max(30, math.floor(34 * scale))
    local barcode_data = os.date("%Y%m%d", stats.end_ts - 1) .. "-" .. tostring(math.floor((stats.total_seconds or 0) / 60)) .. "-" .. tostring(stats.book_count or 0)
    drawBarcode128(bb, barcode_data, x, barcode_y, barcode_right - x, barcode_h)

    local bottom_y = footer_y + math.max(qr_size, barcode_h) + math.max(8, math.floor(8 * scale))
    if bottom_y > h - margin_y - 14 * scale then
        bottom_y = h - margin_y - 14 * scale
    end
    drawText(bb, pickQuote(stats, lang), margin_x, bottom_y, tiny, false, content_w * 0.56)
    drawText(bb, "Design by Estela-Zelin84", w - margin_x, bottom_y, tiny, true, nil, "right")

    return bb
end

function InkStain:writeWallpaper(stats)
    if not ensureDir(self.output_dir) then
        return nil, _("无法创建壁纸输出目录。")
    end
    cleanupImageFilesInDir(self.output_dir, self.output_file)
    cleanupImageFilesInDir(self.legacy_output_dir)
    local bb = self:buildPng(stats)
    local ok = false
    if bb.writeToFile then
        local ok_call, ret = pcall(bb.writeToFile, bb, self.output_file, "png", nil, true)
        ok = ok_call and ret
    elseif bb.writePNG then
        local ok_call, ret = pcall(bb.writePNG, bb, self.output_file)
        ok = ok_call and ret
    end
    if bb.free then bb:free() end
    if not ok then
        return nil, _("写入 PNG 壁纸失败。")
    end
    return self.output_file
end

function InkStain:isUsingInkStainScreensaver()
    local screensaver_type = G_reader_settings:readSetting("screensaver_type")
    local screensaver_dir = G_reader_settings:readSetting("screensaver_dir") or ""
    local screensaver_document_cover = G_reader_settings:readSetting("screensaver_document_cover") or ""
    return screensaver_document_cover == self.output_file
        or screensaver_dir == self.output_dir
        or screensaver_dir:find("/inkstain", 1, true) ~= nil
        or (screensaver_type == "document_cover" and screensaver_document_cover:find("/inkstain", 1, true) ~= nil)
end

function InkStain:backupScreensaverSettings()
    if self.settings.previous_screensaver and self.settings.previous_screensaver.version == 2 then
        return
    end
    local values = {}
    for _, key in ipairs(SCREENSAVER_SETTING_KEYS) do
        local has_key = true
        if G_reader_settings.has then
            has_key = G_reader_settings:has(key)
        end
        values[key] = {
            has = has_key,
            value = G_reader_settings:readSetting(key),
        }
    end
    self.settings.previous_screensaver = {
        version = 2,
        values = values,
    }
    self:saveSettings()
end

function InkStain:applyScreensaverSettings()
    if not self:isUsingInkStainScreensaver() then
        self:backupScreensaverSettings()
    end
    G_reader_settings:saveSetting("screensaver_type", "document_cover")
    G_reader_settings:saveSetting("screensaver_document_cover", self.output_file)
    G_reader_settings:makeTrue("screensaver_stretch_images")
    G_reader_settings:makeFalse("screensaver_show_message")
    G_reader_settings:saveSetting("screensaver_img_background", "white")
    if G_reader_settings.flush then
        G_reader_settings:flush()
    end
end

function InkStain:restorePreviousScreensaverSettings()
    local prev = self.settings.previous_screensaver
    if prev and prev.version == 2 and prev.values then
        for _, key in ipairs(SCREENSAVER_SETTING_KEYS) do
            local item = prev.values[key]
            if item and item.has then
                G_reader_settings:saveSetting(key, item.value)
            elseif G_reader_settings.delSetting then
                G_reader_settings:delSetting(key)
            end
        end
        self.settings.previous_screensaver = nil
        self:saveSettings()
    elseif prev then
        if prev.screensaver_type then
            G_reader_settings:saveSetting("screensaver_type", prev.screensaver_type)
        else
            G_reader_settings:saveSetting("screensaver_type", "disable")
        end
        if prev.screensaver_dir and prev.screensaver_dir ~= "" then
            G_reader_settings:saveSetting("screensaver_dir", prev.screensaver_dir)
        elseif G_reader_settings.delSetting then
            G_reader_settings:delSetting("screensaver_dir")
        end
        if prev.screensaver_show_message then
            G_reader_settings:makeTrue("screensaver_show_message")
        else
            G_reader_settings:makeFalse("screensaver_show_message")
        end
        if prev.screensaver_stretch_images then
            G_reader_settings:makeTrue("screensaver_stretch_images")
        else
            G_reader_settings:makeFalse("screensaver_stretch_images")
        end
        if prev.screensaver_img_background then
            G_reader_settings:saveSetting("screensaver_img_background", prev.screensaver_img_background)
        end
        self.settings.previous_screensaver = nil
        self:saveSettings()
    else
        G_reader_settings:saveSetting("screensaver_type", "disable")
        G_reader_settings:makeTrue("screensaver_show_message")
        if G_reader_settings.delSetting then
            G_reader_settings:delSetting("screensaver_dir")
        end
    end
    if G_reader_settings.flush then
        G_reader_settings:flush()
    end
end

function InkStain:shouldApplyInCurrentContext()
    return not (self.settings.menu_scope == "home" and self.ui and self.ui.document)
end

function InkStain:generate(quiet)
    local stats = self:readStats()
    local output, err = self:writeWallpaper(stats)
    if not output then
        if not quiet then
            UIManager:show(InfoMessage:new{
                text = T(_("墨痕壁纸生成失败：%1"), tostring(err)),
                timeout = 4,
            })
        end
        return false
    end

    if self.settings.auto_set_screensaver and self:shouldApplyInCurrentContext() then
        self:applyScreensaverSettings()
    end
    self.last_refresh_ts = os.time()

    if not quiet then
        UIManager:show(InfoMessage:new{
            text = T(_("墨痕壁纸已生成：\n%1"), output),
            timeout = 5,
        })
    end
    return true
end

function InkStain:onSuspend()
    if not self.settings.auto_refresh_on_suspend then return end
    if not self:shouldApplyInCurrentContext() then
        return
    end
    if not self:isUsingInkStainScreensaver() then
        return
    end
    local now = os.time()
    if self:isUsingInkStainScreensaver() and now - (self.last_refresh_ts or 0) < (self.settings.refresh_interval or 600) then
        return
    end
    self:generate(true)
end

function InkStain:toggleSetting(key)
    self.settings[key] = not self.settings[key]
    self:saveSettings()
end

function InkStain:setDays(days)
    self.settings.days = days
    self:saveSettings()
end

function InkStain:setTopN(top_n)
    self.settings.top_n = top_n
    self:saveSettings()
end

--- 设置自定义壁纸字体（弹出输入框，用户输入字体文件名）
function InkStain:setCustomFont()
    local current = self.settings.font_name or ""
    local hint = _("输入字体文件名（如 NotoSansCJKsc-Regular.otf）\n留空则使用内置汇文明朝体。\n字体文件需位于 KOReader 字体目录中。")
    local dialog
    dialog = InputDialog:new{
        title = _("壁纸字体"),
        input = current,
        input_hint = hint,
        description = _("当前：") .. (current ~= "" and current or _("内置字体")),
        buttons = {{
            {
                text = _("取消"),
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("内置字体"),
                callback = function()
                    self.settings.font_name = ""
                    self:saveSettings()
                    UIManager:close(dialog)
                    UIManager:show(InfoMessage:new{ text = _("已切换为内置字体。"), timeout = 3 })
                end,
            },
            {
                text = _("确认"),
                is_enter_default = true,
                callback = function()
                    local text = dialog:getInputText()
                    text = text and text:gsub("^%s+", ""):gsub("%s+$", "") or ""
                    if text == "" then
                        self.settings.font_name = ""
                        self:saveSettings()
                        UIManager:close(dialog)
                        UIManager:show(InfoMessage:new{ text = _("已切换为内置字体。"), timeout = 3 })
                    else
                        -- 提取文件名（防止用户输入了完整路径）
                        local basename = text:match("([^/]+)$") or text
                        self.settings.font_name = basename
                        self:saveSettings()
                        UIManager:close(dialog)
                        UIManager:show(InfoMessage:new{ text = _("壁纸字体已设置为：") .. basename, timeout = 3 })
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function InkStain:setScreensaverScope(scope)
    self.settings.menu_scope = scope
    self:saveSettings()
    UIManager:show(InfoMessage:new{
        text = _("锁屏使用范围已保存。"),
        timeout = 4,
    })
end

function InkStain:disableWallpaper()
    self.settings.auto_refresh_on_suspend = false
    self.settings.auto_set_screensaver = false
    self:saveSettings()

    if self:isUsingInkStainScreensaver() then
        self:restorePreviousScreensaverSettings()
    end

    UIManager:show(InfoMessage:new{
        text = _("墨痕壁纸已关闭，并已停止休眠前自动刷新。"),
        timeout = 4,
    })
end

function InkStain:enableFromNativeScreensaverMenu()
    self.settings.auto_set_screensaver = true
    self.settings.auto_refresh_on_suspend = true
    self:saveSettings()
    return self:generate(false)
end

function InkStain:restoreFromNativeScreensaverMenu()
    self:disableWallpaper()
end

local function compareVersions(v1, v2)
    v1 = tostring(v1 or ""):gsub("^v", "")
    v2 = tostring(v2 or ""):gsub("^v", "")
    local p1, p2 = {}, {}
    for num in v1:gmatch("%d+") do p1[#p1 + 1] = tonumber(num) end
    for num in v2:gmatch("%d+") do p2[#p2 + 1] = tonumber(num) end
    local max = math.max(#p1, #p2)
    for i = 1, max do
        local a, b = p1[i] or 0, p2[i] or 0
        if a < b then return -1 end
        if a > b then return 1 end
    end
    return 0
end

-- 计算文件 SHA256，多级回退：sha256sum / shasum / openssl 命令 / FFI OpenSSL
local function computeSHA256(filepath)
    filepath = tostring(filepath or "")
    if filepath == "" or lfs.attributes(filepath, "mode") ~= "file" then
        return nil
    end
    local f = io.popen("sha256sum '" .. filepath .. "' 2>/dev/null")
    if f then
        local output = f:read("*a")
        f:close()
        local hash = output:match("^(%x+)")
        if hash and #hash == 64 then return hash:lower() end
    end
    f = io.popen("shasum -a 256 '" .. filepath .. "' 2>/dev/null")
    if f then
        local output = f:read("*a")
        f:close()
        local hash = output:match("^(%x+)")
        if hash and #hash == 64 then return hash:lower() end
    end
    f = io.popen("openssl dgst -sha256 '" .. filepath .. "' 2>/dev/null")
    if f then
        local output = f:read("*a")
        f:close()
        local hash = output:match("=%s*(%x+)")
        if hash and #hash == 64 then return hash:lower() end
    end
    local ok, openssl = pcall(require, "ffi/openssl")
    if ok and openssl and openssl.digest then
        local file = io.open(filepath, "rb")
        if file then
            local content = file:read("*a")
            file:close()
            local ok_d, digest = pcall(openssl.digest, "sha256", content)
            if ok_d and digest then return tostring(digest):lower() end
        end
    end
    return nil
end

function InkStain:checkForUpdate()
    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr and NetworkMgr.willRereadConnect then
        NetworkMgr:willRereadConnect(function()
            self:doCheckForUpdate()
        end)
    else
        self:doCheckForUpdate()
    end
end

-- 仿照 MiuRead 插件：手动处理 HTTP 重定向，不依赖 ssl.https 的 redirect 参数
local function shellQuote(s)
    return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

local function httpGet(url, headers, timeout_connect, timeout_read)
    headers = headers or {}
    headers["User-Agent"] = headers["User-Agent"] or "KOReader-InkStain-Plugin"
    local current = url
    local max_redirects = 8
    for hop = 0, max_redirects do
        local chunks = {}
        if socketutil then
            socketutil:set_timeout(timeout_connect or 15, timeout_read or 45)
        end
        local transport
        if current:match("^https:") then
            transport = ok_https and https or (ok_http and http or nil)
        else
            transport = ok_http and http or nil
        end
        if not transport then
            if socketutil then socketutil:reset_timeout() end
            return nil, nil, "HTTP transport unavailable"
        end
        -- http.request{...} 返回 1, code, headers, status（成功）或 nil, err（失败）
        local called, req_ok, code, resp_headers = pcall(transport.request, {
            url = current,
            method = "GET",
            headers = headers,
            sink = ltn12.sink.table(chunks),
        })
        if socketutil then socketutil:reset_timeout() end
        if not called then
            return nil, nil, tostring(req_ok)
        end
        if not req_ok then
            return nil, nil, tostring(code)
        end
        code = tonumber(code)
        if not code then
            return table.concat(chunks), nil, resp_headers
        end
        -- 手动跟随重定向
        if code >= 300 and code < 400 and resp_headers then
            local location = nil
            for k, v in pairs(resp_headers) do
                if type(k) == "string" and k:lower() == "location" then
                    location = v
                    break
                end
            end
            if location and hop < max_redirects then
                if location:match("^https?://") then
                    current = location
                elseif location:sub(1, 1) == "/" then
                    local scheme, host = current:match("^(https?://[^/]+)")
                    current = scheme .. location
                else
                    local base = current:match("^(https?://.*/)")
                    current = (base or current) .. location
                end
            else
                return table.concat(chunks), code, resp_headers
            end
        else
            return table.concat(chunks), code, resp_headers
        end
    end
    return nil, nil, "too many redirects"
end

local function curlDownload(url, dest_path, extra_headers)
    local cmd = "curl -sL --fail --connect-timeout 20 --max-time 180"
    if extra_headers then
        for k, v in pairs(extra_headers) do
            cmd = cmd .. " -H " .. shellQuote(k .. ": " .. v)
        end
    end
    cmd = cmd .. " -o " .. shellQuote(dest_path) .. " " .. shellQuote(url) .. " 2>/dev/null"
    local ret = os.execute(cmd)
    return ret == 0 or ret == true
end

local function wgetDownload(url, dest_path, extra_headers)
    local cmd = "wget -q --connect-timeout=20 --timeout=180"
    if extra_headers then
        for k, v in pairs(extra_headers) do
            cmd = cmd .. " --header=" .. shellQuote(k .. ": " .. v)
        end
    end
    cmd = cmd .. " -O " .. shellQuote(dest_path) .. " " .. shellQuote(url) .. " 2>/dev/null"
    local ret = os.execute(cmd)
    return ret == 0 or ret == true
end

function InkStain:fetchJSON(urls)
    local headers = {
        ["Accept"] = "application/vnd.github.v3+json",
        ["User-Agent"] = "KOReader-InkStain-Plugin",
    }
    for _, url in ipairs(urls) do
        -- 优先：Lua HTTP（手动重定向，兼容所有设备）
        local ok, body, code = pcall(httpGet, url, headers, 15, 45)
        if ok and code == 200 and body and #body > 0 then
            return body
        end
        logger.info("墨痕壁纸：Lua HTTP 请求失败：", url, tostring(code))
        -- 回退：curl
        local tmp = os.tmpname()
        os.remove(tmp)
        if curlDownload(url, tmp, headers) and lfs.attributes(tmp, "size") and (lfs.attributes(tmp, "size") or 0) > 10 then
            local f = io.open(tmp, "rb")
            if f then
                body = f:read("*a")
                f:close()
            end
            os.remove(tmp)
            if body and #body > 0 then return body end
        end
        os.remove(tmp)
        -- 回退：wget
        tmp = os.tmpname()
        os.remove(tmp)
        if wgetDownload(url, tmp, headers) and lfs.attributes(tmp, "size") and (lfs.attributes(tmp, "size") or 0) > 10 then
            local f = io.open(tmp, "rb")
            if f then
                body = f:read("*a")
                f:close()
            end
            os.remove(tmp)
            if body and #body > 0 then return body end
        end
        os.remove(tmp)
        logger.info("墨痕壁纸：API 请求失败：", url)
    end
    return nil
end

function InkStain:doCheckForUpdate()
    UIManager:show(InfoMessage:new{
        text = _("正在检查更新…"),
        timeout = 1,
    })
    UIManager:scheduleIn(0.5, function()
        local api_urls = buildMirrorUrls(UPDATE_API)
        local json_str = self:fetchJSON(api_urls)
        if not json_str or #json_str == 0 then
            UIManager:show(InfoMessage:new{
                text = _("检查更新失败，请检查网络连接。"),
                timeout = 4,
            })
            return
        end
        local JSON = require("json")
        local release = JSON.decode(json_str)
        if not release or not release.tag_name then
            UIManager:show(InfoMessage:new{
                text = _("无法解析更新信息。"),
                timeout = 4,
            })
            return
        end
        local remote_version = release.tag_name:gsub("^v", "")
        if compareVersions(remote_version, PLUGIN_VERSION) <= 0 then
            UIManager:show(InfoMessage:new{
                text = T(_("当前版本 %1 已是最新。"), PLUGIN_VERSION),
                timeout = 3,
            })
            return
        end
        local download_url = nil
        local expected_hash = nil
        local sha256_url = nil
        local release_notes = release.body or ""
        if release.assets then
            for _, asset in ipairs(release.assets) do
                if asset.name and asset.name:match("%.zip$") and asset.name:match("inkstain") then
                    download_url = asset.browser_download_url
                    if asset.digest and asset.digest:match("^sha256:") then
                        expected_hash = asset.digest:gsub("^sha256:", ""):lower()
                    end
                elseif asset.name and asset.name:match("%.sha256$") and asset.name:match("inkstain") then
                    sha256_url = asset.browser_download_url
                end
            end
        end
        if not download_url then
            UIManager:show(InfoMessage:new{
                text = T(_("发现新版本 %1，但未找到下载文件。\n请前往 GitHub Releases 手动下载。"), remote_version),
                timeout = 6,
            })
            return
        end
        -- 若 API 未提供 digest，尝试下载 .sha256 附带文件获取哈希
        if not expected_hash and sha256_url then
            local tmp_dir = DataStorage:getDataDir() .. "/cache"
            if not lfs.attributes(tmp_dir, "mode") then ensureDir(tmp_dir) end
            local hash_tmp = tmp_dir .. "/inkstain_hash.txt"
            if self:downloadFile(buildMirrorUrls(sha256_url), hash_tmp) then
                local hash_file = io.open(hash_tmp, "r")
                if hash_file then
                    local content = hash_file:read("*a")
                    hash_file:close()
                    expected_hash = content:match("(%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x)")
                    if expected_hash then expected_hash = expected_hash:lower() end
                end
                os.remove(hash_tmp)
            end
        end
        local confirm_text = T(_("发现新版本 %1（当前 %2）。\n是否立即下载并更新？"), remote_version, PLUGIN_VERSION)
        if release_notes ~= "" then
            local truncated = release_notes:sub(1, 200)
            if #release_notes > 200 then
                truncated = truncated .. "…"
            end
            confirm_text = confirm_text .. "\n\n更新内容：\n" .. truncated
        end
        UIManager:show(ConfirmBox:new{
            text = confirm_text,
            ok_callback = function()
                self:downloadAndUpdate(buildMirrorUrls(download_url), remote_version, expected_hash)
            end,
        })
    end)
end

function InkStain:downloadFile(urls, dest_path)
    local headers = {
        ["User-Agent"] = "KOReader-InkStain-Plugin",
    }
    for _, url in ipairs(urls) do
        -- 优先：Lua HTTP（手动重定向，兼容所有设备）
        local ok, body, code = pcall(httpGet, url, headers, 20, 150)
        if ok and code == 200 and body and #body > 100 then
            local f = io.open(dest_path, "wb")
            if f then
                f:write(body)
                f:close()
                if lfs.attributes(dest_path, "size") and (lfs.attributes(dest_path, "size") or 0) > 100 then
                    return true
                end
            end
        end
        logger.info("墨痕壁纸：Lua HTTP 下载失败：", url, tostring(code))
        os.remove(dest_path)
        -- 回退：curl（原生支持重定向）
        if curlDownload(url, dest_path, headers) and lfs.attributes(dest_path, "size") and (lfs.attributes(dest_path, "size") or 0) > 100 then
            return true
        end
        os.remove(dest_path)
        -- 回退：wget
        if wgetDownload(url, dest_path, headers) and lfs.attributes(dest_path, "size") and (lfs.attributes(dest_path, "size") or 0) > 100 then
            return true
        end
        os.remove(dest_path)
        logger.info("墨痕壁纸：下载尝试失败：", url)
    end
    return false
end

function InkStain:extractUpdate(zip_path, plugin_dir)
    local Archiver = require("ffi/archiver")
    local arc = Archiver.Reader:new()
    if not arc:open(zip_path) then
        return false, "无法打开更新包: " .. tostring(arc.err)
    end
    -- Collect file entries and detect shared top-level directory
    local file_entries = {}
    local top_prefix = nil
    for entry in arc:iterate() do
        if entry.mode == "file" then
            file_entries[#file_entries + 1] = entry.path
            local prefix = entry.path:match("^([^/]+/)")
            if prefix then
                if top_prefix == nil then
                    top_prefix = prefix
                elseif top_prefix ~= prefix then
                    top_prefix = false
                end
            end
        end
    end
    if top_prefix == false then top_prefix = nil end
    -- Extract each file, stripping top-level dir if present
    for _, entry_path in ipairs(file_entries) do
        local dest_path = entry_path
        if top_prefix and dest_path:sub(1, #top_prefix) == top_prefix then
            dest_path = dest_path:sub(#top_prefix + 1)
        end
        if dest_path and dest_path ~= "" then
            local full_path = plugin_dir .. "/" .. dest_path
            local parent = full_path:match("^(.*)/[^/]+$")
            if parent and lfs.attributes(parent, "mode") ~= "directory" then
                ensureDir(parent)
            end
            if not arc:extractToPath(entry_path, full_path) then
                local err = tostring(arc.err)
                arc:close()
                return false, "解压失败: " .. entry_path .. ": " .. err
            end
        end
    end
    arc:close()
    return true
end

function InkStain:downloadAndUpdate(urls, version, expected_hash)
    local progress_msg = InfoMessage:new{
        text = _("正在下载更新…\n请耐心等待，包体约 10MB。"),
        timeout = 0,
    }
    UIManager:show(progress_msg)
    UIManager:scheduleIn(0.5, function()
        local tmp_dir = DataStorage:getDataDir() .. "/cache"
        if not lfs.attributes(tmp_dir, "mode") then
            ensureDir(tmp_dir)
        end
        local tmp_zip = tmp_dir .. "/inkstain_update.zip"
        local ok = self:downloadFile(urls, tmp_zip)
        UIManager:close(progress_msg)
        if not ok then
            os.remove(tmp_zip)
            UIManager:show(InfoMessage:new{
                text = _("下载失败，请检查网络连接。\n也可前往 GitHub Releases 手动下载。"),
                timeout = 6,
            })
            return
        end
        -- 哈希验证
        if expected_hash then
            UIManager:show(InfoMessage:new{
                text = _("下载完成，正在验证完整性…"),
                timeout = 1,
            })
            local actual_hash = computeSHA256(tmp_zip)
            if not actual_hash then
                logger.warn("墨痕壁纸：无法计算 SHA256，跳过验证")
            elseif actual_hash ~= expected_hash then
                logger.warn("墨痕壁纸：SHA256 验证失败", actual_hash, expected_hash)
                os.remove(tmp_zip)
                UIManager:show(InfoMessage:new{
                    text = _("更新包完整性验证失败！\n文件可能已损坏或被篡改，已自动删除。\n请稍后重试或手动下载。"),
                    timeout = 0,
                })
                return
            else
                logger.info("墨痕壁纸：SHA256 验证通过")
            end
        else
            logger.info("墨痕壁纸：未提供哈希值，跳过验证")
        end
        UIManager:show(InfoMessage:new{
            text = _("验证通过，正在安装…"),
            timeout = 1,
        })
        UIManager:scheduleIn(0.5, function()
            local plugin_dir = self.path or ""
            if plugin_dir == "" then
                os.remove(tmp_zip)
                UIManager:show(InfoMessage:new{
                    text = _("无法确定插件目录路径。"),
                    timeout = 4,
                })
                return
            end
            local install_ok, install_err = self:extractUpdate(tmp_zip, plugin_dir)
            if not install_ok then
                logger.warn("墨痕壁纸：archiver 解压失败，尝试系统 unzip：", install_err)
                local ok_sys = pcall(function()
                    os.execute("cd '" .. plugin_dir .. "' && unzip -o '" .. tmp_zip .. "' 2>/dev/null")
                end)
                install_ok = ok_sys
            end
            os.remove(tmp_zip)
            if not install_ok then
                UIManager:show(InfoMessage:new{
                    text = T(_("安装失败：%1\n请手动下载更新包。"), install_err or "未知错误"),
                    timeout = 6,
                })
                return
            end
            UIManager:show(InfoMessage:new{
                text = T(_("更新完成！\n版本 %1 已安装。\n请重启 KOReader 以生效。"), version),
                timeout = 0,
            })
        end)
    end)
end

function InkStain:addToMainMenu(menu_items)
    menu_items.inkstain_wallpaper = {
        text = _("墨痕壁纸"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("生成并设为休眠壁纸"),
                callback = function()
                    self.settings.auto_set_screensaver = true
                    self.settings.auto_refresh_on_suspend = true
                    self:saveSettings()
                    self:generate(false)
                end,
            },
            {
                text = _("关闭墨痕壁纸"),
                callback = function()
                    self:disableWallpaper()
                end,
                separator = true,
            },
            {
                text = _("仅生成壁纸"),
                callback = function()
                    self:generate(false)
                end,
            },
            {
                text = _("休眠前自动刷新"),
                checked_func = function()
                    return self.settings.auto_refresh_on_suspend
                end,
                callback = function()
                    self:toggleSetting("auto_refresh_on_suspend")
                end,
            },
            {
                text = _("自动设置 KOReader 休眠屏幕"),
                checked_func = function()
                    return self.settings.auto_set_screensaver
                end,
                callback = function()
                    self:toggleSetting("auto_set_screensaver")
                end,
            },
            {
                text = _("锁屏使用范围"),
                sub_item_table = {
                    {
                        text = _("只在主页使用"),
                        checked_func = function()
                            return self.settings.menu_scope == "home"
                        end,
                        callback = function()
                            self:setScreensaverScope("home")
                        end,
                    },
                    {
                        text = _("主页和阅读界面都使用"),
                        checked_func = function()
                            return self.settings.menu_scope == "both"
                        end,
                        callback = function()
                            self:setScreensaverScope("both")
                        end,
                    },
                },
            },
            {
                text = _("统计周期"),
                sub_item_table = {
                    {
                        text = _("今天"),
                        checked_func = function() return self.settings.days == 1 end,
                        callback = function() self:setDays(1) end,
                    },
                    {
                        text = _("最近 7 天"),
                        checked_func = function() return self.settings.days == 7 end,
                        callback = function() self:setDays(7) end,
                    },
                    {
                        text = _("最近 30 天"),
                        checked_func = function() return self.settings.days == 30 end,
                        callback = function() self:setDays(30) end,
                    },
                },
            },
            {
                text = _("书单数量"),
                sub_item_table = {
                    {
                        text = "Top 2",
                        checked_func = function() return self.settings.top_n == 2 end,
                        callback = function() self:setTopN(2) end,
                    },
                    {
                        text = "Top 3",
                        checked_func = function() return self.settings.top_n == 3 end,
                        callback = function() self:setTopN(3) end,
                    },
                    {
                        text = "Top 4",
                        checked_func = function() return self.settings.top_n == 4 end,
                        callback = function() self:setTopN(4) end,
                    },
                    {
                        text = "Top 5",
                        checked_func = function() return self.settings.top_n == 5 end,
                        callback = function() self:setTopN(5) end,
                    },
                },
            },
            {
                text = _("数据源"),
                sub_item_table = {
                    {
                        text = _("KOReader 阅读统计"),
                        checked_func = function() return (self.settings.data_source or "koreader") == "koreader" end,
                        callback = function()
                            self.settings.data_source = "koreader"
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{ text = _("数据源已切换为 KOReader 阅读统计。"), timeout = 3 })
                        end,
                    },
                    {
                        text = _("觅阅书架"),
                        checked_func = function() return self.settings.data_source == "miuread" end,
                        callback = function()
                            local miuread_path = DataStorage:getSettingsDir() .. "/miuread.lua"
                            if lfs.attributes(miuread_path, "mode") ~= "file" then
                                UIManager:show(InfoMessage:new{ text = _("未检测到觅阅插件数据。\n请先安装并使用觅阅插件。"), timeout = 5 })
                                return
                            end
                            self.settings.data_source = "miuread"
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{ text = _("数据源已切换为觅阅书架。"), timeout = 3 })
                        end,
                    },
                    {
                        text = _("两者合并"),
                        checked_func = function() return self.settings.data_source == "both" end,
                        callback = function()
                            self.settings.data_source = "both"
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{ text = _("数据源已切换为 KOReader + 觅阅合并。"), timeout = 3 })
                        end,
                    },
                },
            },
            {
                text = _("壁纸字体"),
                callback = function()
                    self:setCustomFont()
                end,
            },
            {
                text = _("进度模式"),
                sub_item_table = {
                    {
                        text = _("总进度"),
                        checked_func = function() return (self.settings.progress_mode or "total") == "total" end,
                        callback = function()
                            self.settings.progress_mode = "total"
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{ text = _("进度模式已切换为总进度（全期阅读位置）。"), timeout = 3 })
                        end,
                    },
                    {
                        text = _("本期进度"),
                        checked_func = function() return self.settings.progress_mode == "period" end,
                        callback = function()
                            self.settings.progress_mode = "period"
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{ text = _("进度模式已切换为本期进度（本期阅读页数占比）。"), timeout = 3 })
                        end,
                    },
                },
            },
            {
                text = _("壁纸语言"),
                sub_item_table = {
                    {
                        text = _("中文"),
                        checked_func = function() return (self.settings.wallpaper_lang or "zh") == "zh" end,
                        callback = function()
                            self.settings.wallpaper_lang = "zh"
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{ text = _("壁纸语言已切换为中文。"), timeout = 3 })
                        end,
                    },
                    {
                        text = _("English"),
                        checked_func = function() return self.settings.wallpaper_lang == "en" end,
                        callback = function()
                            self.settings.wallpaper_lang = "en"
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{ text = _("Wallpaper language switched to English."), timeout = 3 })
                        end,
                    },
                },
            },
            {
                text = _("显示输出路径"),
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = self.output_file,
                        timeout = 6,
                    })
                end,
            },
            {
                text = _("检查更新"),
                separator = true,
                callback = function()
                    self:checkForUpdate()
                end,
            },
            {
                text = T(_("关于（v%1）"), PLUGIN_VERSION),
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = _("墨痕壁纸 v") .. PLUGIN_VERSION .. "\nDesign by Estela-Zelin84",
                        timeout = 6,
                    })
                end,
            },
        },
    }
end

return InkStain

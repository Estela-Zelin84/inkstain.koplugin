--[[--
KOReader 阅迹壁纸。

本插件根据 KOReader 内置阅读统计数据库生成“阅读账单”风格休眠壁纸。
输出格式为 PNG，使用 KOReader 自己的文字渲染组件绘制，避免 SVG 文本不显示。
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local InfoMessage = require("ui/widget/infomessage")
local RenderImage = require("ui/renderimage")
local SQ3 = require("lua-ljsqlite3/init")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local Screen = Device.screen

local DEFAULT_SETTINGS = {
    days = 7,
    top_n = 4,
    min_minutes = 1,
    title = "阅读账单",
    auto_set_screensaver = true,
    auto_refresh_on_suspend = true,
    refresh_interval = 10 * 60,
    menu_scope = "home",
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

local ReadTrace = WidgetContainer:extend{
    name = "readtrace",
    is_doc_only = false,
    settings_key = "readtrace_wallpaper",
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

local function formatDuration(seconds)
    seconds = tonumber(seconds) or 0
    local minutes = math.floor(seconds / 60 + 0.5)
    local hours = math.floor(minutes / 60)
    local mins = minutes % 60
    if hours > 0 then
        return string.format("%d小时%d分钟", hours, mins)
    end
    return string.format("%d分钟", mins)
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

function ReadTrace:init()
    self.settings = copyDefaults(G_reader_settings:readSetting(self.settings_key, {}))
    self.output_dir = DataStorage:getDataDir() .. "/screensaver/readtrace_png"
    self.output_file = self.output_dir .. "/readtrace_wallpaper.png"
    self.legacy_output_dir = DataStorage:getDataDir() .. "/screensaver/readtrace"
    self.db_location = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    _G.ReadTraceWallpaper = self
end

function ReadTrace:saveSettings()
    G_reader_settings:saveSetting(self.settings_key, self.settings)
    if G_reader_settings.flush then
        G_reader_settings:flush()
    end
end

function ReadTrace:getRange()
    local days = tonumber(self.settings.days) or DEFAULT_SETTINGS.days
    if days < 1 then days = 1 end
    local today = dayStart()
    local start_ts = today - (days - 1) * 86400
    local end_ts = today + 86400
    return start_ts, end_ts, days
end

function ReadTrace:readStats()
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
            FROM page_stat
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
            FROM page_stat
            WHERE start_time >= %d AND start_time < %d;
        ]], start_ts, end_ts)
        local total_seconds, book_count = conn:rowexec(total_sql)
        result.total_seconds = tonumber(total_seconds) or 0
        result.book_count = tonumber(book_count) or 0

        local min_seconds = math.max(0, tonumber(self.settings.min_minutes) or 0) * 60
        local top_n = math.max(1, math.min(4, tonumber(self.settings.top_n) or DEFAULT_SETTINGS.top_n))
        local books_sql = string.format([[
            SELECT b.title,
                   ifnull(b.authors, ''),
                   sum(p.duration) AS seconds,
                   count(DISTINCT p.page) AS read_pages,
                   max(ifnull(b.pages, 0)) AS pages,
                   max(p.start_time) AS last_time
            FROM page_stat p
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
            for i, title in ipairs(titles) do
                table.insert(result.books, {
                    title = title ~= "" and title or "未命名书籍",
                    authors = authors[i] ~= "" and authors[i] or "未知作者",
                    seconds = tonumber(seconds[i]) or 0,
                    read_pages = tonumber(read_pages[i]) or 0,
                    pages = tonumber(pages[i]) or 0,
                })
            end
        end
    end)

    conn:close()
    if not ok_query then
        result.error = tostring(err)
        logger.warn("阅迹壁纸：读取统计数据失败：", err)
    end
    return result
end

local function drawText(bb, text, x, y, size, bold, max_width, align, color)
    local widget = TextWidget:new{
        text = tostring(text or ""),
        face = Font:getFace("cfont", math.max(8, math.floor(size))),
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
        face = Font:getFace("cfont", math.max(8, math.floor(size))),
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

local function pickQuote(stats)
    local seed = tonumber(os.date("%j", stats.end_ts - 1)) or 1
    seed = seed + math.floor((stats.total_seconds or 0) / 60) + (stats.book_count or 0) * 7
    return QUOTES[(seed % #QUOTES) + 1]
end

function ReadTrace:buildPng(stats)
    local w, h = Screen:getWidth(), Screen:getHeight()
    if w > h then
        w, h = h, w
    end
    if w < 300 or h < 300 then
        w, h = 824, 1200
    end

    local bb = Blitbuffer.new(w, h, Screen.bb:getType())
    bb:fill(Blitbuffer.COLOR_WHITE)

    local scale = math.min(w / 600, h / 800)
    local margin_x = math.max(20, math.floor(w * 0.05))
    local margin_y = math.max(18, math.floor(h * 0.035))
    local title_size = math.max(18, math.min(28, math.floor(25 * scale)))
    local large = math.max(15, math.min(22, math.floor(19 * scale)))
    local normal = math.max(11, math.min(15, math.floor(13 * scale)))
    local small = math.max(9, math.min(12, math.floor(10 * scale)))
    local tiny = math.max(8, math.min(10, math.floor(8 * scale)))
    local line_w = 1
    local content_w = w - margin_x * 2

    local y = margin_y
    local s
    s = drawText(bb, self.settings.title or "阅读账单", w - margin_x, y, title_size, true, nil, "right")
    drawText(bb, "单号：" .. os.date("%m%d", stats.end_ts - 1), margin_x, y + math.floor(s.h * 0.25), large, true)
    y = y + s.h + math.max(4, math.floor(4 * scale))
    s = drawText(bb, "时间：" .. os.date("%Y.%m.%d", stats.start_ts) .. " - " .. os.date("%Y.%m.%d", stats.end_ts - 1), margin_x, y, small, false, content_w)
    y = y + s.h + math.max(2, math.floor(2 * scale))
    s = drawText(bb, "设备：KOReader    来源：阅读统计", margin_x, y, small, false, content_w)
    y = y + s.h + math.max(4, math.floor(4 * scale))
    drawText(bb, "时长：" .. formatDuration(stats.total_seconds), margin_x, y, normal, true, content_w * 0.55)
    local top_n = math.max(1, math.min(4, tonumber(self.settings.top_n) or DEFAULT_SETTINGS.top_n))
    s = drawText(bb, "书单：Top " .. tostring(top_n), w - margin_x, y, normal, true, nil, "right")
    y = y + s.h + math.max(8, math.floor(8 * scale))
    drawLine(bb, margin_x, y, w - margin_x, y, line_w)

    local table_header_y = y + math.max(8, math.floor(8 * scale))
    local x_no = margin_x
    local x_title = margin_x + math.floor(76 * scale)
    local x_qty = w - margin_x - math.floor(68 * scale)
    local x_unit = w - margin_x - math.floor(18 * scale)
    local title_w = math.max(120, x_qty - x_title - 20 * scale)
    drawText(bb, "品类", x_no, table_header_y, small, false)
    drawText(bb, "数量", x_qty, table_header_y, small, false, nil, "center")
    drawText(bb, "单位", x_unit, table_header_y, small, false, nil, "center")
    y = table_header_y + math.max(22, math.floor(22 * scale))
    drawLine(bb, margin_x, y, w - margin_x, y, line_w)

    local chart_h = math.max(68, math.floor(h * 0.115))
    local footer_h = math.max(96, math.floor(h * 0.13))
    local chart_shift_up = math.max(18, math.floor(20 * scale))
    local chart_top = h - footer_h - chart_h - math.max(28, math.floor(28 * scale)) - chart_shift_up
    local table_bottom = chart_top - math.max(44, math.floor(44 * scale))
    local rows_top = y + math.max(8, math.floor(8 * scale))
    local min_row_h = math.max(56, math.floor(58 * scale))
    local max_rows_by_height = math.max(1, math.floor((table_bottom - rows_top) / min_row_h))
    local visible_rows = math.min(#stats.books, tonumber(self.settings.top_n) or 4, 4, max_rows_by_height)
    local row_h = min_row_h

    y = rows_top
    if #stats.books == 0 then
        local msg
        if stats.error then
            msg = "读取统计失败：" .. truncate(stats.error, 28)
        elseif not stats.has_db then
            msg = "未找到 KOReader 阅读统计数据库，请先启用“阅读统计”。"
        else
            msg = "本周期暂无可显示的阅读记录。"
        end
        drawBoxText(bb, msg, margin_x, y + 8 * scale, content_w, normal, true)
    else
        for i = 1, visible_rows do
            local book = stats.books[i]
            local no = string.format("NO.%02d", i)
            local progress = "—"
            if book.pages and book.pages > 0 and book.read_pages then
                progress = string.format("%d%%", math.min(100, math.floor(book.read_pages * 100 / book.pages + 0.5)))
            end
            drawText(bb, no, x_no, y, normal, true)
            s = drawText(bb, truncate(book.title, 16), x_title, y, normal, true, title_w)
            local meta_y = y + math.max(s.h, 18)
            drawText(bb, "作者：" .. truncate(book.authors, 14), x_title, meta_y, tiny, false, title_w)
            drawText(bb, "进度：" .. progress .. "  本期：" .. formatDuration(book.seconds), x_title, meta_y + math.max(14, math.floor(14 * scale)), tiny, false, title_w)
            drawText(bb, "1", x_qty, y + math.floor(row_h * 0.1), normal, true, nil, "center")
            drawText(bb, "本", x_unit, y + math.floor(row_h * 0.1), normal, true, nil, "center")
            y = y + row_h
        end
        if #stats.books > visible_rows then
            drawText(bb, "另有 " .. tostring(#stats.books - visible_rows) .. " 本因屏幕高度省略", x_title, math.min(y, table_bottom - 18 * scale), tiny, false, title_w)
        end
    end
    drawLine(bb, margin_x, table_bottom, w - margin_x, table_bottom, line_w)

    local chart_w = content_w - 10 * scale
    local chart_x = margin_x + 5 * scale
    drawText(bb, "日均：" .. formatDuration(stats.total_seconds / math.max(1, stats.days)), margin_x, chart_top - math.max(24, math.floor(24 * scale)), normal, true)
    drawText(bb, "合计：" .. formatDuration(stats.total_seconds), w - margin_x, chart_top - math.max(24, math.floor(24 * scale)), normal, true, nil, "right")
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
            drawText(bb, tostring(math.floor(p.seconds / 60 + 0.5)) .. "分", p.x, p.y - 18 * scale, tiny, false, nil, "center")
        end
        if count <= 10 or p.index == 1 or p.index == count or (p.index - 1) % label_step == 0 then
            drawText(bb, p.label, p.x, chart_top + chart_h + 10 * scale, tiny, false, nil, "center")
        end
    end

    local footer_y = chart_top + chart_h + math.max(26, math.floor(26 * scale))
    local qr_size = math.max(36, math.floor(42 * scale))
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
    drawText(bb, pickQuote(stats), margin_x, bottom_y, tiny, false, content_w * 0.56)
    drawText(bb, "Design by Estela-Zelin84", w - margin_x, bottom_y, tiny, true, nil, "right")

    return bb
end

function ReadTrace:writeWallpaper(stats)
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

function ReadTrace:isUsingReadTraceScreensaver()
    local screensaver_type = G_reader_settings:readSetting("screensaver_type")
    local screensaver_dir = G_reader_settings:readSetting("screensaver_dir") or ""
    local screensaver_document_cover = G_reader_settings:readSetting("screensaver_document_cover") or ""
    return screensaver_document_cover == self.output_file
        or screensaver_dir == self.output_dir
        or screensaver_dir:find("/readtrace", 1, true) ~= nil
        or (screensaver_type == "document_cover" and screensaver_document_cover:find("/readtrace", 1, true) ~= nil)
end

function ReadTrace:backupScreensaverSettings()
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

function ReadTrace:applyScreensaverSettings()
    if not self:isUsingReadTraceScreensaver() then
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

function ReadTrace:restorePreviousScreensaverSettings()
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

function ReadTrace:shouldApplyInCurrentContext()
    return not (self.settings.menu_scope == "home" and self.ui and self.ui.document)
end

function ReadTrace:generate(quiet)
    local stats = self:readStats()
    local output, err = self:writeWallpaper(stats)
    if not output then
        if not quiet then
            UIManager:show(InfoMessage:new{
                text = T(_("阅迹壁纸生成失败：%1"), tostring(err)),
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
            text = T(_("阅迹壁纸已生成：\n%1"), output),
            timeout = 5,
        })
    end
    return true
end

function ReadTrace:onSuspend()
    if not self.settings.auto_refresh_on_suspend then return end
    if not self:shouldApplyInCurrentContext() then
        return
    end
    if not self:isUsingReadTraceScreensaver() then
        return
    end
    local now = os.time()
    if self:isUsingReadTraceScreensaver() and now - (self.last_refresh_ts or 0) < (self.settings.refresh_interval or 600) then
        return
    end
    self:generate(true)
end

function ReadTrace:toggleSetting(key)
    self.settings[key] = not self.settings[key]
    self:saveSettings()
end

function ReadTrace:setDays(days)
    self.settings.days = days
    self:saveSettings()
end

function ReadTrace:setTopN(top_n)
    self.settings.top_n = top_n
    self:saveSettings()
end

function ReadTrace:setScreensaverScope(scope)
    self.settings.menu_scope = scope
    self:saveSettings()
    UIManager:show(InfoMessage:new{
        text = _("锁屏使用范围已保存。"),
        timeout = 4,
    })
end

function ReadTrace:disableWallpaper()
    self.settings.auto_refresh_on_suspend = false
    self.settings.auto_set_screensaver = false
    self:saveSettings()

    if self:isUsingReadTraceScreensaver() then
        self:restorePreviousScreensaverSettings()
    end

    UIManager:show(InfoMessage:new{
        text = _("阅迹壁纸已关闭，并已停止休眠前自动刷新。"),
        timeout = 4,
    })
end

function ReadTrace:enableFromNativeScreensaverMenu()
    self.settings.auto_set_screensaver = true
    self.settings.auto_refresh_on_suspend = true
    self:saveSettings()
    return self:generate(false)
end

function ReadTrace:restoreFromNativeScreensaverMenu()
    self:disableWallpaper()
end

function ReadTrace:addToMainMenu(menu_items)
    menu_items.readtrace_wallpaper = {
        text = _("阅迹壁纸"),
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
                text = _("关闭阅迹壁纸"),
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
        },
    }
end

return ReadTrace

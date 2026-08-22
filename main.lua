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
local i18n = require("i18n")

local Updater = require("updater")
local PLUGIN_VERSION = "3.1.0"

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
    show_stains = false,  -- 墨水污渍效果（默认关闭，防止低性能设备卡顿）
    bg_mode = "white",  -- "white" 白底 / "image" 自定义图片
    bg_image_path = "",  -- 自定义背景图片路径
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

local function formatDuration(seconds, T)
    seconds = tonumber(seconds) or 0
    local minutes = math.floor(seconds / 60 + 0.5)
    local hours = math.floor(minutes / 60)
    local mins = minutes - hours * 60
    if mins >= 60 then
        hours = hours + 1
        mins = mins - 60
    end
    if not T then
        -- 回退：无翻译函数时使用简写格式
        if hours > 0 then
            return string.format("%dh%dm", hours, mins)
        end
        return string.format("%dm", mins)
    end
    if hours > 0 then
        return string.format("%d%s%d%s", hours, T("hr"), mins, T("min"))
    end
    return string.format("%d%s", mins, T("min"))
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

    -- OTA updater initialization (modeled on miuread)
    self.updater = Updater:new(PLUGIN_VERSION, self.path)
    self._auto_update_check_running = false
    local update_state = self.updater:startup()
    if update_state == "updated" then
        UIManager:scheduleIn(1, function()
            UIManager:show(InfoMessage:new{
                text = _("更新完成，当前运行版本 ") .. PLUGIN_VERSION,
                timeout = 4,
            })
        end)
    elseif update_state == "mismatch" then
        UIManager:scheduleIn(1, function()
            UIManager:show(InfoMessage:new{
                text = _("更新文件已替换，但当前运行版本与目标版本不一致。\n\n请完整退出并重新启动 KOReader。"),
                timeout = 0,
            })
        end)
    end
    -- Schedule auto-update check after 5 seconds
    UIManager:scheduleIn(5.0, function()
        self:maybeAutoCheckUpdate(false)
    end)
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

--- 从 miuread.lua 获取书架进度信息
-- 觅阅通过 KOReader 打开书籍，阅读统计已写入 statistics.sqlite3，
-- 这里只需获取觅阅书架的进度（progress_local_percent）来补充 KOReader 统计结果
-- 数据来源（按优先级）：
--   1. shelf_cache.books（云端书架-书籍）
--   2. shelf_cache.mp（云端书架-公众号/漫画）
--   3. library（本地书库）：用户下载到本地的书籍元数据
-- 进度存储在 sessions[bookId] 中，优先级：
--   pending.percent > progress_local_percent > verified_local_percent > row.progress
function InkStain:readMiureadProgress()
    local miuread_path = DataStorage:getSettingsDir() .. "/miuread.lua"
    local result = {
        progress_map = {},        -- 原始标题 -> 进度
        normalized_map = {},      -- 规范化标题 -> 进度（用于模糊匹配）
        has_miuread = lfs.attributes(miuread_path, "mode") == "file",
        book_count = 0,
    }
    if not result.has_miuread then
        return result
    end
    local ok, LuaSettings = pcall(require, "luasettings")
    if not ok then
        logger.warn("墨痕壁纸：无法加载 luasettings，不能读取觅阅数据")
        return result
    end

    local ok_open, miuread_db = pcall(LuaSettings.open, LuaSettings, miuread_path)
    if not ok_open or not miuread_db then
        logger.warn("墨痕壁纸：无法打开觅阅设置文件", tostring(miuread_db or "unknown"))
        return result
    end

    local shelf = miuread_db:readSetting("shelf_cache", nil)
    local library = miuread_db:readSetting("library", nil)
    local sessions = miuread_db:readSetting("sessions", nil)
    -- 仅读取，不调用 close()/flush()，避免重写觅阅设置文件造成数据竞争

    if type(sessions) ~= "table" then sessions = {} end
    if type(library) ~= "table" then library = {} end

    -- 辅助：规范化书名用于模糊匹配（去空格、去标点、统一大小写等）
    local function normalizeTitle(t)
        if not t then return "" end
        t = tostring(t)
        -- 去除所有空白字符
        t = t:gsub("%s+", "")
        -- 去除常见标点
        t = t:gsub("[%p%c　]", "")
        -- 全角转半角（常见符号）
        t = t:gsub("：", ":"):gsub("（", "("):gsub("）", ")")
        t = t:gsub("【", "["):gsub("】", "]"):gsub("《", ""):gsub("》", "")
        t = t:gsub("「", ""):gsub("」", ""):gsub("『", ""):gsub("』", "")
        return t:lower()
    end

    -- 辅助：从 session + row 中提取进度（与觅阅 local_progress 逻辑一致）
    local function getProgress(session, row)
        session = type(session) == "table" and session or {}
        row = type(row) == "table" and row or {}
        -- 与觅阅 local_progress 逻辑一致，优先级从高到低：
        -- pending.percent > progress_local_percent > verified_local_percent
        --  > progress_upload_percent > progress_remote_percent > row.progress
        local pending = type(session.pending) == "table" and session.pending or {}
        local pending_progress = type(session.pending_progress) == "table" and session.pending_progress or {}
        local p = tonumber(pending.percent
            or pending_progress.percent
            or session.progress_local_percent
            or session.verified_local_percent
            or session.progress_upload_percent
            or session.progress_remote_percent
            or row.progress or 0) or 0
        return p
    end

    -- 辅助：将一本书加入进度表
    local function addBook(title, progress)
        if not title or title == "" or not progress or progress <= 0 then return end
        local p = math.min(100, math.max(0, progress))
        -- 精确标题映射
        if not result.progress_map[title] then
            result.progress_map[title] = p
            result.book_count = result.book_count + 1
        end
        -- 规范化标题映射（取最高进度）
        local norm = normalizeTitle(title)
        if norm ~= "" then
            if not result.normalized_map[norm] or result.normalized_map[norm] < p then
                result.normalized_map[norm] = p
            end
        end
    end

    -- 1. 从 shelf_cache（云端书架）读取
    local shelf_book_count = 0
    if type(shelf) == "table" then
        -- 收集所有书架分组：books（书籍）+ mp（公众号/漫画）
        local groups = {}
        if type(shelf.books) == "table" then
            table.insert(groups, shelf.books)
        end
        if type(shelf.mp) == "table" then
            table.insert(groups, shelf.mp)
        end
        -- 兼容旧格式：shelf 本身就是数组
        if #groups == 0 and #shelf > 0 and type(shelf[1]) == "table" and shelf[1].title then
            table.insert(groups, shelf)
        end

        for _, group in ipairs(groups) do
            for _, row in ipairs(group) do
                if type(row) == "table" then
                    local book_id = tostring(row.bookId or row.book_id or "")
                    local session = (book_id ~= "") and (sessions[book_id] or {}) or {}
                    local title = row.title or ""
                    local progress = getProgress(session, row)
                    addBook(title, progress)
                    shelf_book_count = shelf_book_count + 1
                end
            end
        end
    end

    -- 2. 从 library（本地书库）读取
    --    补充 shelf_cache 中没有的本地下载书籍，或 stream 模式下书架不完整的情况
    local library_book_count = 0
    for id, row in pairs(library) do
        if type(row) == "table" then
            local book_id = tostring(row.book_id or id or "")
            local session = (book_id ~= "") and (sessions[book_id] or {}) or {}
            local title = row.title or ""
            local progress = getProgress(session, row)
            -- 仅在精确标题未命中时补充（shelf 数据更权威）
            if title ~= "" and progress > 0 and not result.progress_map[title] then
                addBook(title, progress)
                library_book_count = library_book_count + 1
            end
        end
    end

    logger.info("墨痕壁纸：觅阅数据读取完成，书架", shelf_book_count,
        "本，本地库补充", library_book_count, "本，有效进度", result.book_count, "条")
    logger.dbg("墨痕壁纸：觅阅进度表", result.progress_map)
    return result
end

--- 匹配书名获取进度（精确匹配 + 规范化匹配 + 前缀匹配）
local function matchProgress(progress_data, title)
    if not title or title == "" then return nil end
    if not progress_data then return nil end

    local progress_map = progress_data.progress_map or progress_data
    local normalized_map = progress_data.normalized_map or nil

    -- 1. 精确匹配
    if progress_map[title] then
        return progress_map[title]
    end

    -- 2. 规范化匹配（去空格、标点后对比）
    if normalized_map then
        local function normalize(t)
            if not t then return "" end
            t = tostring(t):gsub("%s+", ""):gsub("[%p%c　]", "")
            t = t:gsub("：", ":"):gsub("（", "("):gsub("）", ")")
            t = t:gsub("【", "["):gsub("】", "]"):gsub("《", ""):gsub("》", "")
            t = t:gsub("「", ""):gsub("」", ""):gsub("『", ""):gsub("』", "")
            return t:lower()
        end
        local norm = normalize(title)
        if norm ~= "" and normalized_map[norm] then
            return normalized_map[norm]
        end
    end

    -- 3. 前缀/包含模糊匹配
    for shelf_title, shelf_progress in pairs(progress_map) do
        if shelf_title and title then
            local st, tt = tostring(shelf_title), tostring(title)
            -- 前缀匹配
            if #st >= 2 and #tt >= 2 then
                if st:sub(1, #tt) == tt or tt:sub(1, #st) == st then
                    return shelf_progress
                end
                -- 互相包含（短标题在长标题中）
                local short = #st < #tt and st or tt
                local long = #st >= #tt and st or tt
                if #short >= 3 and long:find(short, 1, true) then
                    return shelf_progress
                end
            end
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

        local matched = 0
        if source == "miuread" then
            -- 觅阅数据源：KOReader 统计提供基础数据（书单/时长/页数），觅阅提供进度
            result.data_source_key = "miuread"
            for _, b in ipairs(result.books) do
                local found = matchProgress(miuread_data, b.title)
                if found and found > 0 then
                    b.progress = found
                    b.source = "miuread"
                    matched = matched + 1
                end
            end
        elseif source == "both" then
            -- 两者合并：优先使用觅阅进度（progress_local_percent），更准确
            -- 觅阅进度不可用时，回退到 max_page/pages 计算
            result.data_source_key = "both"
            for _, b in ipairs(result.books) do
                local found = matchProgress(miuread_data, b.title)
                if found and found > 0 then
                    b.progress = found
                    matched = matched + 1
                end
            end
        end
        logger.info("墨痕壁纸：觅阅进度匹配", matched, "/", #result.books, "本")
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

-- 伪随机数生成器（基于种子，保证同一天污渍一致）
local function seededRandom(seed)
    local state = seed % 2147483647
    if state <= 0 then state = state + 2147483646 end
    return function()
        state = (state * 16807) % 2147483647
        return (state - 1) / 2147483646
    end
end

-- 墨水污渍效果（墨点聚集版）
-- 用大量小墨点聚集形成自然的污渍形态，全部是 1-3px 小方块，性能好
local function drawInkStains(bb, w, h, seed, intensity)
    intensity = intensity or 1.0
    local rand = seededRandom(seed)
    local scale = math.min(w / 600, h / 800) * intensity

    -- 在指定区域内生成一团墨点
    local function makeStainCluster(cx, cy, radius, density)
        for i = 1, density do
            -- 极坐标随机分布，越靠近中心越密集
            local angle = rand() * math.pi * 2
            local r_norm = rand()
            -- 用平方根让点更集中在中心（高斯近似）
            local dist = math.sqrt(r_norm) * radius
            local px = cx + math.cos(angle) * dist
            local py = cy + math.sin(angle) * dist

            -- 点的大小：中心大，边缘小
            local size_factor = 1 - dist / radius
            local size = 1
            if size_factor > 0.7 then
                size = 2 + math.floor(rand() * 2) -- 2-3px
            elseif size_factor > 0.4 then
                size = 1 + math.floor(rand() * 2) -- 1-2px
            else
                size = 1
            end
            size = math.max(1, math.floor(size * scale))

            if px >= 0 and px < w and py >= 0 and py < h then
                drawRect(bb, px, py, size, size, Blitbuffer.COLOR_BLACK)
            end
        end
    end

    -- 4-5 个主要污渍团
    local stain_count = 4 + math.floor(rand() * 2)
    for s = 1, stain_count do
        local cx, cy
        local region = math.floor(rand() * 6)
        if region == 0 then
            cx = rand() * w * 0.18
            cy = rand() * h * 0.12
        elseif region == 1 then
            cx = w * 0.82 + rand() * w * 0.18
            cy = rand() * h * 0.15
        elseif region == 2 then
            cx = rand() * w * 0.15
            cy = h * 0.78 + rand() * h * 0.22
        elseif region == 3 then
            cx = w * 0.82 + rand() * w * 0.18
            cy = h * 0.72 + rand() * h * 0.28
        elseif region == 4 then
            cx = rand() * w * 0.05
            cy = h * 0.35 + rand() * h * 0.3
        else
            cx = w * 0.95 + rand() * w * 0.05
            cy = h * 0.3 + rand() * h * 0.4
        end

        local radius = math.max(10, (25 + rand() * 35) * scale)
        local density = math.floor(80 + rand() * 80) -- 每团 80-160 个点
        makeStainCluster(cx, cy, radius, density)

        -- 每团旁边加 2-3 个小副团
        local sub_clusters = 2 + math.floor(rand() * 2)
        for sc = 1, sub_clusters do
            local angle = rand() * math.pi * 2
            local dist = radius * (0.9 + rand() * 1.3)
            local scx = cx + math.cos(angle) * dist
            local scy = cy + math.sin(angle) * dist
            local sr = radius * (0.25 + rand() * 0.35)
            local sd = math.floor(20 + rand() * 25)
            makeStainCluster(scx, scy, sr, sd)
        end

        -- 飞溅小点（更远更散）
        local splash = 15 + math.floor(rand() * 15)
        for sp = 1, splash do
            local angle = rand() * math.pi * 2
            local dist = radius * (1.3 + rand() * 2.2)
            local sx = cx + math.cos(angle) * dist
            local sy = cy + math.sin(angle) * dist
            local ss = math.max(1, math.floor(rand() * 2 + 0.5))
            if sx >= 0 and sx < w and sy >= 0 and sy < h then
                drawRect(bb, sx, sy, ss, ss, Blitbuffer.COLOR_BLACK)
            end
        end
    end

    -- 全图稀疏散点
    local dust = 30 + math.floor(rand() * 30)
    for d = 1, dust do
        local dx = rand() * w
        local dy = rand() * h
        drawRect(bb, dx, dy, 1, 1, Blitbuffer.COLOR_BLACK)
    end
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

local function pickQuote(stats, T)
    local seed = tonumber(os.date("%j", stats.end_ts - 1)) or 1
    seed = seed + math.floor((stats.total_seconds or 0) / 60) + (stats.book_count or 0) * 7
    local quotes = i18n.getQuotes(T)
    return quotes[(seed % #quotes) + 1]
end

-- 自定义标题渲染
-- 中文模式：墨 + 痕（同字号）+ ink stain（英文在痕下方左对齐）
-- 英文模式：Ink Stain 大字 + ink stain 小字副标题
local function drawCustomTitle(bb, x_right, y, scale, lang, T)
    if lang == "en" then
        -- 英文标题：Ink Stain
        local main_size = math.max(28, math.min(40, math.floor(38 * scale)))
        local sub_size = math.max(10, math.floor(main_size * 0.32))
        local main_text = T("title_cn1") .. " " .. T("title_cn2")
        local main_w = TextWidget:new{ text = main_text, face = getFontFace(main_size), bold = true }
        main_w:updateSize()
        local sub_w = TextWidget:new{ text = T("title_en"), face = getFontFace(sub_size), bold = false }
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

    local mo_w = TextWidget:new{ text = T("title_cn1"), face = getFontFace(cn_size), bold = true }
    mo_w:updateSize()
    local mo_w_w, mo_w_h = mo_w:getSize().w, mo_w:getSize().h

    local hen_w = TextWidget:new{ text = T("title_cn2"), face = getFontFace(cn_size), bold = true }
    hen_w:updateSize()
    local hen_w_w, hen_w_h = hen_w:getSize().w, hen_w:getSize().h

    local en_w = TextWidget:new{ text = T("title_en"), face = getFontFace(en_size), bold = false }
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

    -- 自定义背景图片
    local bg_mode = self.settings.bg_mode or "white"
    if bg_mode == "image" and self.settings.bg_image_path and self.settings.bg_image_path ~= "" then
        local bg_path = self.settings.bg_image_path
        if lfs.attributes(bg_path, "mode") == "file" then
            -- cover 模式：等比例缩放填满屏幕，居中裁剪
            local ok, img_bb = pcall(RenderImage.renderImageFile, RenderImage, bg_path, false, w, h)
            if ok and img_bb then
                local iw = img_bb:getWidth()
                local ih = img_bb:getHeight()
                local scale = math.max(w / iw, h / ih)
                local draw_w = math.floor(iw * scale)
                local draw_h = math.floor(ih * scale)
                local draw_x = math.floor((w - draw_w) / 2)
                local draw_y = math.floor((h - draw_h) / 2)
                -- 重新按目标尺寸缩放
                if img_bb.free then img_bb:free() end
                local ok2, scaled_bb = pcall(RenderImage.renderImageFile, RenderImage, bg_path, false, draw_w, draw_h)
                if ok2 and scaled_bb then
                    pcall(bb.blitFrom, bb, scaled_bb, draw_x, draw_y, 0, 0, math.min(draw_w, w - draw_x), math.min(draw_h, h - draw_y))
                    if scaled_bb.free then scaled_bb:free() end
                end
            end
        end
    end

    -- 墨水污渍效果
    if self.settings.show_stains then
        -- 用日期作为种子，同一天的污渍一致
        local stain_seed = os.date("%Y%m%d") + (stats.total_seconds or 0) % 1000
        drawInkStains(bb, w, h, stain_seed, 1.0)
    end

    local lang = self.settings.wallpaper_lang or "zh"
    local T = i18n.loadLang(self.path, lang)

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
    local ok_title, title_result = pcall(drawCustomTitle, bb, w - margin_x, y, scale, lang, T)
    if ok_title and title_result then
        s = title_result
    else
        logger.warn("墨痕壁纸：自定义标题渲染失败，回退到普通标题", title_result)
        local fallback_title = (lang == "en") and "Ink Stain" or (self.settings.title or "墨痕")
        s = drawText(bb, fallback_title, w - margin_x, y, title_size, true, nil, "right")
    end
    drawText(bb, T("serial") .. os.date("%m%d", stats.end_ts - 1), margin_x, y + math.floor(s.h * 0.25), large, true)
    y = y + s.h + math.max(4, math.floor(4 * scale))
    s = drawText(bb, T("period") .. os.date("%Y.%m.%d", stats.start_ts) .. " - " .. os.date("%Y.%m.%d", stats.end_ts - 1), margin_x, y, small, false, content_w)
    y = y + s.h + math.max(2, math.floor(2 * scale))
    local source_key = stats.data_source_key or "koreader"
    local source_label
    if source_key == "miuread" then
        source_label = T("source_miuread")
    elseif source_key == "both" then
        source_label = T("source_both")
    else
        source_label = T("source_koreader")
    end
    s = drawText(bb, T("device_source") .. source_label, margin_x, y, small, false, content_w)
    y = y + s.h + math.max(4, math.floor(4 * scale))
    drawText(bb, T("duration") .. formatDuration(stats.total_seconds, T), margin_x, y, normal, true, content_w * 0.55)
    local top_n = math.max(1, math.min(5, tonumber(self.settings.top_n) or DEFAULT_SETTINGS.top_n))
    s = drawText(bb, T("top_books") .. tostring(top_n), w - margin_x, y, normal, true, nil, "right")
    y = y + s.h + math.max(8, math.floor(8 * scale))
    drawLine(bb, margin_x, y, w - margin_x, y, line_w)

    local table_header_y = y + math.max(8, math.floor(8 * scale))
    local x_no = margin_x
    local x_title = margin_x + math.floor(76 * scale)
    local x_qty = w - margin_x - math.floor(68 * scale)
    local x_unit = w - margin_x - math.floor(18 * scale)
    local title_w = math.max(120, x_qty - x_title - 20 * scale)
    drawText(bb, T("col_category"), x_no, table_header_y, small, false)
    drawText(bb, T("col_qty"), x_qty, table_header_y, small, false, nil, "center")
    drawText(bb, T("col_unit"), x_unit, table_header_y, small, false, nil, "center")
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
            msg = T("err_read") .. truncate(stats.error, 28)
        elseif not stats.has_db then
            msg = T("err_no_db")
        else
            msg = T("err_empty")
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
            drawText(bb, T("author") .. truncate(book.authors, 14), x_title, meta_y, tiny, false, title_w)
            drawText(bb, T("progress") .. progress .. T("period_time") .. formatDuration(book.seconds, T), x_title, meta_y + math.max(14, math.floor(14 * scale)), tiny, false, title_w)
            drawText(bb, "1", x_qty, y + math.floor(row_h * 0.1), normal, true, nil, "center")
            drawText(bb, T("unit_book"), x_unit, y + math.floor(row_h * 0.1), normal, true, nil, "center")
            y = y + row_h
        end
        if #stats.books > visible_rows then
            drawText(bb, T("omitted_prefix") .. tostring(#stats.books - visible_rows) .. T("omitted"), x_title, math.min(y, table_bottom - 18 * scale), tiny, false, title_w)
        end
    end
    drawLine(bb, margin_x, table_bottom, w - margin_x, table_bottom, line_w)

    local chart_w = content_w - 10 * scale
    local chart_x = margin_x + 5 * scale
    drawText(bb, T("daily_avg") .. formatDuration(stats.total_seconds / math.max(1, stats.days), T), margin_x, chart_top - math.max(24, math.floor(24 * scale)), normal, true)
    drawText(bb, T("total") .. formatDuration(stats.total_seconds, T), w - margin_x, chart_top - math.max(24, math.floor(24 * scale)), normal, true, nil, "right")
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
            drawText(bb, tostring(math.floor(p.seconds / 60 + 0.5)) .. T("min_suffix"), p.x, p.y - 18 * scale, tiny, false, nil, "center")
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
    drawText(bb, pickQuote(stats, T), margin_x, bottom_y, tiny, false, content_w * 0.56)
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
    -- Cancel any running update task on suspend (modeled on miuread)
    if self.updater then
        self.updater:cancel("device suspended")
        self._auto_update_check_running = false
    end
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

--- 设置自定义壁纸字体（文件选择器）
function InkStain:setCustomFont()
    local PathChooser = require("ui/widget/pathchooser")
    -- 默认从 KOReader 字体目录开始
    local start_dir = FontList.fontdir or "/"
    if self.settings.font_name and self.settings.font_name ~= "" then
        -- 如果已有字体，尝试找到它的目录
        local font_file = FontList.fontdir .. "/" .. self.settings.font_name
        if lfs.attributes(font_file, "mode") == "file" then
            start_dir = FontList.fontdir
        end
    end

    local path_chooser = PathChooser:new{
        title = _("选择字体文件"),
        select_file = true,
        select_directory = false,
        show_files = true,
        detailed_file_info = true,
        path = start_dir,
        file_filter = function(filename)
            local lower = filename:lower()
            return lower:match("%.ttf$") or lower:match("%.otf$") or lower:match("%.ttc$")
        end,
        onConfirm = function(path)
            if path and lfs.attributes(path, "mode") == "file" then
                local basename = path:match("([^/]+)$") or path
                -- 尝试加载验证
                local ok_face, _ = pcall(Font.getFace, Font, basename, 24)
                if not ok_face then
                    -- 如果文件名加载失败，试试完整路径
                    ok_face, _ = pcall(Font.getFace, Font, path, 24)
                end
                if ok_face then
                    self.settings.font_name = basename
                    self:saveSettings()
                    UIManager:show(InfoMessage:new{ text = _("壁纸字体已设置为：") .. basename, timeout = 3 })
                else
                    UIManager:show(InfoMessage:new{ text = _("字体加载失败，请选择有效字体文件。"), timeout = 4 })
                end
            end
        end,
    }
    UIManager:show(path_chooser)
end

--- 设置自定义背景图片（文件选择器）
function InkStain:setCustomBgImage()
    local PathChooser = require("ui/widget/pathchooser")
    local current_dir = "/"
    if self.settings.bg_image_path and self.settings.bg_image_path ~= "" then
        local dir = self.settings.bg_image_path:match("^(.+)/[^/]+$")
        if dir and lfs.attributes(dir, "mode") == "directory" then
            current_dir = dir
        end
    end

    local path_chooser = PathChooser:new{
        title = _("选择背景图片"),
        select_file = true,
        select_directory = false,
        show_files = true,
        detailed_file_info = true,
        path = current_dir,
        file_filter = function(filename)
            local lower = filename:lower()
            return lower:match("%.png$") or lower:match("%.jpg$") or lower:match("%.jpeg$")
        end,
        onConfirm = function(path)
            if path and lfs.attributes(path, "mode") == "file" then
                self.settings.bg_image_path = path
                self.settings.bg_mode = "image"
                self:saveSettings()
                UIManager:show(InfoMessage:new{ text = _("背景图片已设置。"), timeout = 3 })
            end
        end,
    }
    UIManager:show(path_chooser)
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

-- ===== OTA Update (modeled on miuread updater architecture) =====

function InkStain:_updatePreferences()
    self.settings = self.settings or {}
    local defaults = {
        auto_check = true,
        interval = Updater.AUTO_UPDATE_INTERVAL,
        last_attempt_at = 0,
        last_success_at = 0,
        last_prompted_version = "",
        restart_mode = "ask",
    }
    if type(self.settings.update) ~= "table" then
        self.settings.update = {}
    end
    for k, v in pairs(defaults) do
        if self.settings.update[k] == nil then
            self.settings.update[k] = v
        end
    end
    return self.settings, self.settings.update
end

function InkStain:_saveUpdatePreferences(update)
    self.settings.update = update or {}
    self:saveSettings()
end

function InkStain:_updateIntervalLabel(seconds)
    seconds = tonumber(seconds) or Updater.AUTO_UPDATE_INTERVAL
    if seconds <= 86400 then return "每天" end
    if seconds <= 3 * 86400 then return "每 3 天" end
    return "每 7 天"
end

function InkStain:updateFrequencyMenu()
    local values = { { 86400, "每天" }, { 3 * 86400, "每 3 天" }, { 7 * 86400, "每 7 天" } }
    local rows = {}
    for _, entry in ipairs(values) do
        local seconds, label = entry[1], entry[2]
        rows[#rows + 1] = {
            text = label,
            radio = true,
            checked_func = function()
                local _, u = self:_updatePreferences()
                return tonumber(u.interval) == seconds
            end,
            callback = function()
                local _, u = self:_updatePreferences()
                u.interval = seconds
                self:_saveUpdatePreferences(u)
                UIManager:show(InfoMessage:new{ text = _("更新检查频率已设为") .. label, timeout = 2 })
            end,
        }
    end
    return rows
end

function InkStain:updateRestartMenu()
    local choices = {
        { "ask", "安装后询问（推荐）" },
        { "auto", "安装后自动重启" },
        { "never", "稍后手动重启" },
    }
    local rows = {}
    for _, entry in ipairs(choices) do
        local mode, label = entry[1], entry[2]
        rows[#rows + 1] = {
            text = label,
            radio = true,
            checked_func = function()
                local _, u = self:_updatePreferences()
                return (u.restart_mode or "ask") == mode
            end,
            callback = function()
                local _, u = self:_updatePreferences()
                u.restart_mode = mode
                self:_saveUpdatePreferences(u)
                UIManager:show(InfoMessage:new{ text = label, timeout = 2 })
            end,
        }
    end
    return rows
end

function InkStain:updateSettingsMenu()
    local _, update = self:_updatePreferences()
    local Config = Updater.Config
    return {
        {
            text = _("自动检查更新"),
            checked_func = function()
                local _, u = self:_updatePreferences()
                return u.auto_check ~= false
            end,
            keep_menu_open = true,
            callback = function()
                local _, u = self:_updatePreferences()
                u.auto_check = u.auto_check == false
                self:_saveUpdatePreferences(u)
            end,
        },
        {
            text = _("检查频率 · ") .. self:_updateIntervalLabel(update.interval),
            sub_item_table_func = function() return self:updateFrequencyMenu() end,
        },
        {
            text = _("安装完成后 · ..."),
            sub_item_table_func = function() return self:updateRestartMenu() end,
        },
        {
            text = _("检查") .. tostring(Config.UPDATE_CHANNEL_LABEL) .. _("更新"),
            callback = function() self:checkForUpdate(false) end,
        },
        {
            text = _("当前运行版本 · ") .. tostring(PLUGIN_VERSION),
            enabled = false,
        },
        {
            text = _("更新通道 · ") .. tostring(Config.UPDATE_CHANNEL_LABEL),
            enabled = false,
        },
        {
            text = _("当前版本 · GPL-3.0"),
            enabled = false,
        },
    }
end

function InkStain:_restartKOReader(source)
    if self._koreader_restart_requested then return true end
    local Device = require("device")
    if Device and Device.isAndroid and Device:isAndroid() then
        UIManager:show(InfoMessage:new{
            text = _("Android 设备不支持自动重启，请手动退出并重新打开 KOReader。"),
            timeout = 5,
        })
        return false
    end
    if Device and type(Device.canRestart) == "function" and not Device:canRestart() then
        UIManager:show(InfoMessage:new{
            text = _("当前设备不支持自动重启，请手动退出并重新打开 KOReader。"),
            timeout = 5,
        })
        return false
    end
    self._koreader_restart_requested = true
    self:saveSettings()
    if Device and Device.saveSettings then pcall(Device.saveSettings, Device) end
    local Event = require("ui/event")
    UIManager:broadcastEvent(Event:new("Restart"))
    if tonumber(UIManager._exit_code) ~= 85 then
        UIManager:quit(85)
    end
    return true
end

function InkStain:_showUpdateCompleteDialog(version, allow_restart)
    local dialog
    local buttons = {}
    if allow_restart ~= false then
        buttons[#buttons + 1] = {
            {
                text = _("立即重启 KOReader"),
                callback = function()
                    self:_restartKOReader("update-confirmed")
                end,
            },
        }
    end
    buttons[#buttons + 1] = {
        {
            text = _("稍后重启"),
            callback = function()
                UIManager:close(dialog)
                UIManager:show(InfoMessage:new{
                    text = _("新版本将在下次启动 KOReader 时生效"),
                    timeout = 3,
                })
            end,
        },
    }
    dialog = ConfirmBox:new{
        text = _("更新文件已安装：") .. tostring(version) .. ".\n\n"
            .. _("当前仍在运行 ") .. tostring(PLUGIN_VERSION)
            .. _("，重启 KOReader 后才会切换到新版本。"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function InkStain:_afterUpdateInstalled(manifest)
    local _, update = self:_updatePreferences()
    local version = tostring(manifest and manifest.version or "新版本")
    if update.restart_mode == "never" then
        self:_showUpdateCompleteDialog(version, false)
    elseif update.restart_mode == "auto" then
        UIManager:show(InfoMessage:new{
            text = _("更新完成，正在重启 KOReader"),
            timeout = 3,
        })
        UIManager:scheduleIn(0.35, function()
            self:_restartKOReader("update-auto")
        end)
    else
        self:_showUpdateCompleteDialog(version, true)
    end
end

function InkStain:_presentUpdate(manifest, automatic)
    if manifest.current then
        if not automatic then
            UIManager:show(InfoMessage:new{
                text = _("当前已是最新版本\n\n当前版本：") .. tostring(PLUGIN_VERSION),
                timeout = 3,
            })
        end
        return
    end
    -- Auto-check: skip if already prompted for this version
    local _, update = self:_updatePreferences()
    if automatic and tostring(update.last_prompted_version or "") == tostring(manifest.version or "") then
        return
    end
    update.last_prompted_version = tostring(manifest.version or "")
    self:_saveUpdatePreferences(update)

    local text = _("发现") .. tostring(Updater.Config.UPDATE_CHANNEL_LABEL)
        .. _("版本 ") .. tostring(manifest.version)
    local notes = tostring(manifest.summary or "")
    if notes == "" then notes = tostring(manifest.notes or "") end
    if notes ~= "" then text = text .. "\n\n更新内容\n" .. notes end
    text = text .. "\n\n是否下载并安装"

    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = _("下载并安装"),
        ok_callback = function()
            local NetworkMgr = require("ui/network/manager")
            if NetworkMgr and not NetworkMgr:isConnected() then
                if NetworkMgr.willRereadConnect then
                    NetworkMgr:willRereadConnect(function()
                        self:_downloadAndUpdate(manifest)
                    end)
                else
                    UIManager:show(InfoMessage:new{ text = _("当前网络不可用"), timeout = 3 })
                end
                return
            end
            self:_downloadAndUpdate(manifest)
        end,
    })
end

function InkStain:_downloadAndUpdate(manifest)
    UIManager:show(InfoMessage:new{
        text = _("正在后台下载并校验安装包……"),
        timeout = 0,
    })
    UIManager:scheduleIn(0.5, function()
        local ok, result = pcall(function()
            return self.updater:download(manifest)
        end)
        if not ok or not result or result == "" then
            UIManager:show(InfoMessage:new{
                text = _("更新下载失败：\n") .. tostring(result or "后台下载失败"),
                timeout = 5,
            })
            return
        end
        local path = tostring(result)
        UIManager:show(InfoMessage:new{
            text = _("安装包校验完成，正在安装……"),
            timeout = 1,
        })
        UIManager:scheduleIn(0.5, function()
            local install_ok, install_err = self.updater:install(path, manifest)
            if install_ok then
                self:_afterUpdateInstalled(manifest)
            else
                UIManager:show(InfoMessage:new{
                    text = _("更新失败：\n") .. tostring(install_err),
                    timeout = 0,
                })
            end
        end)
    end)
end

function InkStain:_runUpdateCheck(automatic, on_done)
    UIManager:scheduleIn(0.5, function()
        local ok, manifest = pcall(function()
            return self.updater:check()
        end)
        if ok and type(manifest) == "table" then
            if on_done then on_done(manifest, nil) end
        else
            if on_done then on_done(nil, tostring(manifest or "无法读取更新清单")) end
        end
    end)
end

function InkStain:maybeAutoCheckUpdate(force)
    local _, update = self:_updatePreferences()
    if not force and update.auto_check == false then return false end
    if self._auto_update_check_running then return false end
    local now = os.time()
    local interval = math.max(21600, tonumber(update.interval) or Updater.AUTO_UPDATE_INTERVAL)
    local last = tonumber(update.last_attempt_at) or 0
    if not force and now - last < interval then return false end
    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr and not NetworkMgr:isConnected() then return false end
    self._auto_update_check_running = true
    update.last_attempt_at = now
    self:_saveUpdatePreferences(update)
    self:_runUpdateCheck(true, function(manifest, err)
        self._auto_update_check_running = false
        local _, fresh = self:_updatePreferences()
        if manifest then
            fresh.last_success_at = os.time()
            self:_saveUpdatePreferences(fresh)
            self:_presentUpdate(manifest, true)
        else
            fresh.last_attempt_at = os.time() - math.max(0, interval - Updater.AUTO_UPDATE_RETRY_INTERVAL)
            self:_saveUpdatePreferences(fresh)
        end
    end)
    return true
end

function InkStain:checkForUpdate(automatic)
    if automatic then return self:maybeAutoCheckUpdate(true) end
    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr and not NetworkMgr:isConnected() then
        if NetworkMgr.willRereadConnect then
            NetworkMgr:willRereadConnect(function()
                self:_manualCheckUpdate()
            end)
        else
            UIManager:show(InfoMessage:new{ text = _("当前网络不可用"), timeout = 3 })
        end
        return false
    end
    self:_manualCheckUpdate()
    return true
end

function InkStain:_manualCheckUpdate()
    UIManager:show(InfoMessage:new{
        text = _("正在后台检查") .. tostring(Updater.Config.UPDATE_CHANNEL_LABEL) .. _("版本……"),
        timeout = 2,
    })
    self:_runUpdateCheck(false, function(manifest, err)
        local _, update = self:_updatePreferences()
        update.last_attempt_at = os.time()
        if manifest then update.last_success_at = os.time() end
        self:_saveUpdatePreferences(update)
        if not manifest then
            UIManager:show(InfoMessage:new{
                text = _("检查更新失败：\n") .. tostring(err),
                timeout = 5,
            })
            return
        end
        self:_presentUpdate(manifest, false)
    end)
end

function InkStain:addToMainMenu(menu_items)
    menu_items.inkstain_wallpaper = {
        text = _("墨痕壁纸"),
        sorting_hint = "more_tools",
        sub_item_table = {
            -- ===== 操作区 =====
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
            -- ===== 数据与统计 =====
            {
                text = _("数据与统计"),
                sub_item_table = {
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
                            {
                                text = _("最近一个季度"),
                                checked_func = function() return self.settings.days == 90 end,
                                callback = function() self:setDays(90) end,
                            },
                            {
                                text = _("最近半年"),
                                checked_func = function() return self.settings.days == 180 end,
                                callback = function() self:setDays(180) end,
                            },
                            {
                                text = _("最近一年"),
                                checked_func = function() return self.settings.days == 365 end,
                                callback = function() self:setDays(365) end,
                            },
                            {
                                text = _("最近 10 年"),
                                checked_func = function() return self.settings.days == 3650 end,
                                callback = function() self:setDays(3650) end,
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
                },
            },
            -- ===== 外观设置 =====
            {
                text = _("外观设置"),
                sub_item_table = {
                    {
                        text = _("背景模式"),
                        sub_item_table = {
                            {
                                text = _("纯白背景"),
                                checked_func = function() return (self.settings.bg_mode or "white") == "white" end,
                                callback = function()
                                    self.settings.bg_mode = "white"
                                    self:saveSettings()
                                    UIManager:show(InfoMessage:new{ text = _("已切换为纯白背景。"), timeout = 2 })
                                end,
                            },
                            {
                                text = _("自定义图片"),
                                checked_func = function() return self.settings.bg_mode == "image" end,
                                callback = function()
                                    if not self.settings.bg_image_path or self.settings.bg_image_path == "" then
                                        self:setCustomBgImage()
                                    else
                                        self.settings.bg_mode = "image"
                                        self:saveSettings()
                                        UIManager:show(InfoMessage:new{ text = _("已切换为自定义图片背景。"), timeout = 2 })
                                    end
                                end,
                            },
                        },
                    },
                    {
                        text = _("选择背景图片"),
                        callback = function()
                            self:setCustomBgImage()
                        end,
                    },
                    {
                        text = _("清除背景图片"),
                        callback = function()
                            self.settings.bg_image_path = ""
                            self.settings.bg_mode = "white"
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{ text = _("已清除背景图片。"), timeout = 3 })
                        end,
                    },
                    {
                        text = _("墨水污渍效果"),
                        checked_func = function() return self.settings.show_stains end,
                        callback = function()
                            self:toggleSetting("show_stains")
                            UIManager:show(InfoMessage:new{
                                text = self.settings.show_stains and _("墨水污渍效果已开启。") or _("墨水污渍效果已关闭。"),
                                timeout = 2,
                            })
                        end,
                    },
                    {
                        text = _("壁纸字体"),
                        sub_item_table = {
                            {
                                text = _("选择字体文件"),
                                callback = function()
                                    self:setCustomFont()
                                end,
                            },
                            {
                                text = _("恢复内置字体"),
                                callback = function()
                                    self.settings.font_name = ""
                                    self:saveSettings()
                                    UIManager:show(InfoMessage:new{ text = _("已切换为内置字体。"), timeout = 3 })
                                end,
                            },
                        },
                    },
                    {
                        text = _("壁纸语言"),
                        sub_item_table = {
                            {
                                text = _("简体中文"),
                                checked_func = function() return (self.settings.wallpaper_lang or "zh") == "zh" end,
                                callback = function()
                                    self.settings.wallpaper_lang = "zh"
                                    self:saveSettings()
                                    i18n.clearCache()
                                    UIManager:show(InfoMessage:new{ text = _("壁纸语言已切换为简体中文。"), timeout = 3 })
                                end,
                            },
                            {
                                text = _("繁體中文（香港）"),
                                checked_func = function() return self.settings.wallpaper_lang == "zh-HK" end,
                                callback = function()
                                    self.settings.wallpaper_lang = "zh-HK"
                                    self:saveSettings()
                                    i18n.clearCache()
                                    UIManager:show(InfoMessage:new{ text = _("壁紙語言已切換為繁體中文（香港）。"), timeout = 3 })
                                end,
                            },
                            {
                                text = _("English"),
                                checked_func = function() return self.settings.wallpaper_lang == "en" end,
                                callback = function()
                                    self.settings.wallpaper_lang = "en"
                                    self:saveSettings()
                                    i18n.clearCache()
                                    UIManager:show(InfoMessage:new{ text = _("Wallpaper language switched to English."), timeout = 3 })
                                end,
                            },
                        },
                    },
                },
            },
            -- ===== 通用设置 =====
            {
                text = _("通用设置"),
                sub_item_table = {
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
                        text = _("显示输出路径"),
                        callback = function()
                            UIManager:show(InfoMessage:new{
                                text = self.output_file,
                                timeout = 6,
                            })
                        end,
                    },
                },
            },
            -- ===== 关于与更新 =====
            {
                text = _("检查更新"),
                separator = true,
                sub_item_table_func = function() return self:updateSettingsMenu() end,
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

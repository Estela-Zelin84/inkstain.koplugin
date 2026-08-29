--[[--
KOReader 墨痕壁纸。

本插件根据 KOReader 内置阅读统计数据库生成“墨痕账单”风格休眠壁纸。
输出格式为 PNG，使用 KOReader 自己的文字渲染组件绘制，避免 SVG 文本不显示。
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device = require("device")
local FontList = require("fontlist")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = ffiutil.template

-- 懒加载模块：仅在首次使用时 require，减少启动开销
local Updater -- 延迟到首次 OTA 操作时加载
local i18n    -- 延迟到首次生成壁纸时加载
local ConfirmBox
local InfoMessage
local Font
local RenderImage
local SQ3
local TextBoxWidget
local TextWidget
local PathChooser
local Event
local NetworkMgr
local LuaSettings
local util

local PLUGIN_VERSION = "3.6.2"

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
    low_memory_mode = false,  -- 轻量模式：降低分辨率、跳过重计算（低内存设备推荐）
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
    api_version = 2,
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
    if not util then util = require("util") end
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
    if not util then util = require("util") end
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
    -- 字体复制：仅在目标文件不存在时执行（首次安装）
    -- 分块复制（每块 64KB），避免一次性读取 24MB 字体文件导致低内存设备 OOM
    local font_src = (self.path or "") .. "/assets/" .. PLUGIN_FONT_NAME
    local font_dest = FontList.fontdir .. "/" .. PLUGIN_FONT_NAME
    if lfs.attributes(font_src, "mode") == "file" and not lfs.attributes(font_dest, "mode") then
        local CHUNK_SIZE = 64 * 1024  -- 64KB
        local src_f = io.open(font_src, "rb")
        if src_f then
            local dest_f = io.open(font_dest, "wb")
            if dest_f then
                while true do
                    local chunk = src_f:read(CHUNK_SIZE)
                    if not chunk then break end
                    dest_f:write(chunk)
                end
                dest_f:close()
                logger.info("墨痕壁纸：已复制字体到", font_dest)
            else
                logger.warn("墨痕壁纸：字体目标文件无法写入", font_dest)
            end
            src_f:close()
        end
    end
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    _G.InkStainWallpaper = self

    -- OTA：延迟到首次菜单访问时初始化，避免启动时加载 updater.lua（含 SHA-256 等重模块）
    self._updater_initialized = false
    self._auto_update_check_running = false
    self._auto_update_check_task = nil
    -- 从设置中恢复上次刷新时间戳，避免重启后首次休眠强制生成
    self.last_refresh_ts = tonumber(self.settings.last_refresh_ts) or 0
    -- 周期刷新定时器：唤醒时按 refresh_interval 静默刷新壁纸
    -- 替代原休眠前生成模式，彻底解决休眠/唤醒卡顿
    self._periodic_timer_running = false
    self._periodic_refresh_generation = 0
    self:_schedulePeriodicRefresh()
    -- 3.5.8：移除 init 中的 _scheduleAutoUpdateCheck 调用。
    -- 启动后立即调度 OTA 检查会导致 ssl.https/json/sha256 等重模块在
    -- UI 尚未稳定时加载，造成启动卡顿。OTA 检查改为仅在用户主动操作时触发。
end

function InkStain:saveSettings()
    G_reader_settings:saveSetting(self.settings_key, self.settings)
    if G_reader_settings.flush then
        G_reader_settings:flush()
    end
end

--- 周期性静默刷新壁纸（设备唤醒时按 refresh_interval 执行）
--  替代原休眠前生成模式，避免休眠/唤醒时的卡顿感
function InkStain:_stopPeriodicRefresh()
    self._periodic_refresh_generation = (tonumber(self._periodic_refresh_generation) or 0) + 1
    self._periodic_timer_running = false
end

function InkStain:_schedulePeriodicRefresh()
    if self._periodic_timer_running then return end
    if not self.settings.auto_refresh_on_suspend then return end
    if not self.settings.auto_set_screensaver then return end
    local interval = self.settings.refresh_interval or 600
    local generation = tonumber(self._periodic_refresh_generation) or 0
    self._periodic_timer_running = true
    UIManager:scheduleIn(interval, function()
        if generation ~= (tonumber(self._periodic_refresh_generation) or 0) then return end
        self._periodic_timer_running = false
        if not self.settings.auto_refresh_on_suspend then return end
        if not self.settings.auto_set_screensaver then return end
        if not self:shouldApplyInCurrentContext() then
            self:_schedulePeriodicRefresh()
            return
        end
        local now = os.time()
        if now - (self.last_refresh_ts or 0) < interval then
            self:_schedulePeriodicRefresh()
            return
        end
        -- 3.5.8：用 nextTick 延迟生成，避免阻塞 UI 线程
        UIManager:nextTick(function()
            if generation ~= (tonumber(self._periodic_refresh_generation) or 0) then return end
            self:generate(true)
        end)
        self:_schedulePeriodicRefresh()
    end)
end

--- 设备唤醒时重新调度周期刷新。
function InkStain:onResume()
    self:_schedulePeriodicRefresh()
    -- 3.5.8：移除 onResume 中的 _scheduleAutoUpdateCheck 调用。
    -- 唤醒后立即调度 OTA 检查会加载重模块，造成唤醒后卡顿。
end

--- 懒加载 OTA 模块：首次调用时 require pluginota.updater 并执行 startup() 确认
--  全程 pcall 保护，任何加载失败都不会导致闪退，只会禁用 OTA 功能
--  使用 socket+ssl 内置库做 HTTPS，避免 os.execute("curl") fork 子进程导致低内存设备 OOM 闪退
--- 懒加载 OTA 模块：首次调用时 require pluginota.updater 并执行 startup() 确认
--  全程 pcall 保护，任何加载失败都不会导致闪退，只会禁用 OTA 功能
--  使用框架内置 curl 下载，不加载 ssl.https 原生库（避免原生库加载导致进程崩溃）
function InkStain:_ensureUpdater()
    if self._updater_initialized then return self.ota end
    self._updater_initialized = true -- 标记为已尝试，避免反复重试

    -- 第一步：加载 OTA 配置
    local ok_config, OtaConfig = pcall(require, "ota_config")
    if not ok_config or type(OtaConfig) ~= "table" then
        logger.warn("[InkStain] OTA config load failed:", OtaConfig)
        self._ota_error = _("更新配置加载失败。")
        return nil
    end

    -- 第二步：加载 pluginota.updater（框架内置 json/sha256，使用 curl 下载）
    local ok_updater, Updater = pcall(require, "pluginota.updater")
    if not ok_updater or type(Updater) ~= "table" then
        logger.warn("[InkStain] OTA updater load failed:", Updater)
        self._ota_error = _("更新模块加载失败：") .. tostring(Updater or "未知错误")
        return nil
    end

    -- 第三步：构造 Updater 实例
    local ota, err = Updater:new{
        plugin_root = self.path,
        plugin_dir = OtaConfig.plugin_dir,
        plugin_id = OtaConfig.plugin_id,
        repo = OtaConfig.repo,
        channel = OtaConfig.channel,
        channel_tag = OtaConfig.channel_tag,
        github_mirrors = OtaConfig.github_mirrors,
        connect_timeout = 5,
        total_timeout = 15,
        download_timeout = 180,
    }
    if not ota then
        logger.warn("[InkStain] OTA initialization failed:", err)
        self._ota_error = _("更新初始化失败：") .. tostring(err or "未知错误")
        return nil
    end
    self.ota = ota
    self._ota_config = OtaConfig

    -- 第四步：跨重启 pending 状态确认（也做 pcall 保护）
    local ok_startup, update_state = pcall(function() return self.ota:startup() end)
    if not ok_startup then
        logger.warn("[InkStain] OTA startup check failed:", update_state)
        return self.ota -- startup 失败不影响 OTA 主体功能
    end
    if update_state == "updated" then
        if not InfoMessage then InfoMessage = require("ui/widget/infomessage") end
        UIManager:scheduleIn(1, function()
            UIManager:show(InfoMessage:new{
                text = _("更新完成，当前运行版本 ") .. PLUGIN_VERSION,
                timeout = 4,
            })
        end)
    elseif update_state == "mismatch" then
        if not InfoMessage then InfoMessage = require("ui/widget/infomessage") end
        UIManager:scheduleIn(1, function()
            UIManager:show(InfoMessage:new{
                text = _("更新文件已替换，但当前运行版本与目标版本不一致。\n\n请完整退出并重新启动 KOReader。"),
                timeout = 0,
            })
        end)
    end
    return self.ota
end

--- 获取或创建 Async worker 实例（子进程隔离，防止 OTA 崩溃影响主线程）
function InkStain:_getOtaAsync()
    if self._ota_async then return self._ota_async end
    local ok_async, Async = pcall(require, "async")
    if not ok_async or type(Async) ~= "table" then
        logger.warn("[InkStain] async module unavailable:", Async)
        return nil
    end
    local DataStorage = require("datastorage")
    local temp_dir = DataStorage:getDataDir() .. "/inkstain_ota"
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs and type(lfs.mkdir) == "function" then
        pcall(lfs.mkdir, temp_dir)
    end
    self._ota_async = Async:new(temp_dir, { poll_interval = 0.3 })
    return self._ota_async
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
-- 进度存储在 sessions[bookId] 中，优先级（对齐觅阅 v4.9.0 local_progress + 书架展示逻辑）：
--   pending.percent > pending_progress.progress > progress_local_percent
--   > local_position_snapshot.progress(safe) > verified_local_percent
--   > progress_upload_percent > progress_remote_percent > row.progress
--- 从 miuread.lua 读取微信读书阅读时长统计（云端同步数据）
-- 数据来源：觅阅插件的 home_weread_stats_cache（从微信读书 API 拉取后本地缓存）
-- 返回：{ has_data, total_seconds, daily = { date -> seconds }, books = { title, seconds } }
function InkStain:readMiureadReadStats()
    local miuread_path = DataStorage:getSettingsDir() .. "/miuread.lua"
    local result = {
        has_data = false,
        total_seconds = 0,
        daily = {},          -- { "2026-08-27" -> seconds }
        books = {},          -- { { title, seconds } }
        read_days = 0,
    }
    if lfs.attributes(miuread_path, "mode") ~= "file" then
        return result
    end
    if not LuaSettings then LuaSettings = require("luasettings") end
    local ok_open, miuread_db = pcall(LuaSettings.open, LuaSettings, miuread_path)
    if not ok_open or not miuread_db then
        return result
    end

    local cache = miuread_db:readSetting("home_weread_stats_cache", nil)
    if type(cache) ~= "table" then
        return result
    end

    -- 缓存中按周期（weekly/monthly/annually/overall）存储
    -- 根据当前设置的天数选择最合适的周期
    local days = tonumber(self.settings.days) or DEFAULT_SETTINGS.days
    local period_data = nil

    -- 优先选择匹配的周期
    local weekly = type(cache.weekly) == "table" and cache.weekly or nil
    local monthly = type(cache.monthly) == "table" and cache.monthly or nil
    local annually = type(cache.annually) == "table" and cache.annually or nil
    local overall = type(cache.overall) == "table" and cache.overall or nil

    if days <= 7 and weekly and weekly.daily then
        period_data = weekly
    elseif days <= 31 and monthly and monthly.daily then
        period_data = monthly
    elseif annually and annually.daily then
        period_data = annually
    else
        period_data = overall
    end

    if not period_data then
        return result
    end

    result.has_data = true
    result.total_seconds = tonumber(period_data.total_seconds) or 0
    result.read_days = tonumber(period_data.read_days) or 0

    -- 解析每日数据（readTimes 格式：timestamp -> seconds）
    local read_times = type(period_data.readTimes) == "table" and period_data.readTimes or {}
    local daily_arr = type(period_data.daily) == "table" and period_data.daily or {}

    -- 从 daily 数组解析（更直观的格式）
    local function normalized_timestamp(key)
        local stamp = tonumber(key)
        if not stamp then return nil end
        -- 微信读书的时间戳可能是毫秒
        if stamp > 10000000000 then stamp = math.floor(stamp / 1000) end
        return stamp
    end

    if #daily_arr > 0 then
        for _, item in ipairs(daily_arr) do
            if type(item) == "table" then
                local stamp = normalized_timestamp(item.stamp)
                local secs = tonumber(item.seconds) or 0
                if stamp and secs >= 0 then
                    local date_str = os.date("%Y-%m-%d", stamp)
                    result.daily[date_str] = (result.daily[date_str] or 0) + secs
                end
            end
        end
    end

    -- 从 readTimes 解析（补充 daily 没有的数据）
    for key, value in pairs(read_times) do
        local stamp = normalized_timestamp(key)
        local secs = tonumber(value) or 0
        if stamp and secs >= 0 then
            local date_str = os.date("%Y-%m-%d", stamp)
            if not result.daily[date_str] then
                result.daily[date_str] = secs
            end
        end
    end

    -- 解析书籍排行 readLongest
    local rank = type(period_data.readLongest) == "table" and period_data.readLongest or {}
    for _, item in ipairs(rank) do
        if type(item) == "table" then
            local book_info = type(item.book) == "table" and item.book
                or (type(item.albumInfo) == "table" and item.albumInfo or nil)
            local title = tostring((book_info and book_info.title) or item.title or item.bookTitle or "")
            local secs = tonumber(item.readTime) or 0
            if title ~= "" and secs > 0 then
                table.insert(result.books, { title = title, seconds = secs })
            end
        end
    end

    return result
end

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
    if not LuaSettings then LuaSettings = require("luasettings") end
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

    -- 辅助：从 session + row 中提取进度
    -- 对齐觅阅 v4.9.0 的 local_progress() 与书架展示 _decorate_rows() 逻辑：
    --   1. session.pending.percent          — 觅阅 local_progress 首选
    --   2. session.pending_progress.progress — 待上传进度快照（注意是 .progress 非 .percent）
    --   3. session.progress_local_percent    — 本地阅读进度（书架展示首选）
    --   4. session.local_position_snapshot.progress (safe) — 本地位置快照
    --   5. session.verified_local_percent    — 云端验证进度
    --   6. session.progress_upload_percent   — 上传中进度
    --   7. session.progress_remote_percent   — 远端进度
    --   8. row.progress                      — 书架/书库条目自带进度
    local function getProgress(session, row)
        session = type(session) == "table" and session or {}
        row = type(row) == "table" and row or {}
        local pending = type(session.pending) == "table" and session.pending or {}
        local pending_progress = type(session.pending_progress) == "table" and session.pending_progress or {}
        local snapshot = type(session.local_position_snapshot) == "table" and session.local_position_snapshot or {}
        -- local_position_snapshot 仅在 safe=true 时才采用（与觅阅书架展示一致）
        local snapshot_progress = (snapshot.safe == true) and tonumber(snapshot.progress) or nil
        local p = tonumber(pending.percent
            or pending_progress.progress
            or session.progress_local_percent
            or snapshot_progress
            or session.verified_local_percent
            or session.progress_upload_percent
            or session.progress_remote_percent
            or row.progress or 0) or 0
        -- 觅阅 book() 中 finished=true 或 progress>=100 均视为读完
        if row.finished == true or (tonumber(row.progress or 0) or 0) >= 100 then
            p = 100
        end
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
                    -- 跳过流式加载占位条目（觅阅 stream 模式下未加载完的书目）
                    if row._stream_placeholder == true then
                        -- 占位条目跳过，等待后续加载完成后再读取
                    else
                        local book_id = tostring(row.bookId or row.book_id or "")
                        local session = (book_id ~= "") and (sessions[book_id] or {}) or {}
                        -- 觅阅 v4.9.0 的 book() 会从 row.bookInfo 或 row.book 中提取嵌套字段
                        local info = type(row.bookInfo) == "table" and row.bookInfo
                            or (type(row.book) == "table" and row.book or nil)
                        local title = (info and info.title) or row.title or ""
                        local progress = getProgress(session, row)
                        addBook(title, progress)
                        shelf_book_count = shelf_book_count + 1
                    end
                end
            end
        end
    end

    -- 2. 从 library（本地书库）读取
    --    补充 shelf_cache 中没有的本地下载书籍，或 stream 模式下书架不完整的情况
    --    觅阅 v4.9.0 的 LocalMetadata 会从 KOReader sidecar 中提取进度（percent_finished）
    --    并存入 library 条目的 progress 字段，这里一并读取
    local library_book_count = 0
    for id, row in pairs(library) do
        if type(row) == "table" then
            local book_id = tostring(row.book_id or id or "")
            local session = (book_id ~= "") and (sessions[book_id] or {}) or {}
            -- 觅阅 v4.9.0 的 book() 会从 row.bookInfo 或 row.book 中提取嵌套字段
            local info = type(row.bookInfo) == "table" and row.bookInfo
                or (type(row.book) == "table" and row.book or nil)
            local title = (info and info.title) or row.title or ""
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

    if not SQ3 then SQ3 = require("lua-ljsqlite3/init") end
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
            local last_times = book_rows[6] or {}
            local max_pages_col = book_rows[7] or {}
            for i, title in ipairs(titles) do
                table.insert(result.books, {
                    title = title ~= "" and title or "未命名书籍",
                    authors = authors[i] ~= "" and authors[i] or "未知作者",
                    seconds = tonumber(seconds[i]) or 0,
                    read_pages = tonumber(read_pages[i]) or 0,
                    pages = tonumber(pages[i]) or 0,
                    max_page = tonumber(max_pages_col[i]) or 0,
                    last_time = tonumber(last_times[i]) or 0,
                    source = "koreader",
                })
            end
        end

        -- 按书名去重聚合：同一本书可能在 KOReader 中有多个 id（多副本/反复导入）
        -- 合并规则：时长相加、页数取最大、进度页取最大、最后阅读时间取最新
        do
            local dedup = {}
            local order = {}
            for _, b in ipairs(result.books) do
                local key = b.title
                if dedup[key] then
                    local existing = dedup[key]
                    existing.seconds = existing.seconds + b.seconds
                    existing.read_pages = existing.read_pages + b.read_pages
                    existing.pages = math.max(existing.pages, b.pages)
                    existing.max_page = math.max(existing.max_page, b.max_page)
                    -- 保留最新的 last_time（SQL 已经按 seconds+last_time 排序，
                    -- 这里简单比较即可，不影响最终排序）
                    if b.last_time and (not existing.last_time or b.last_time > existing.last_time) then
                        existing.last_time = b.last_time
                    end
                else
                    dedup[key] = b
                    order[#order + 1] = key
                end
            end
            -- 重建 books 数组（保持原排序的总时长优先逻辑，
            -- 但合并后需要重新按总时长排序，因为合并后顺序可能变化）
            result.books = {}
            for _, key in ipairs(order) do
                result.books[#result.books + 1] = dedup[key]
            end
            -- 重新按阅读时长降序排列
            table.sort(result.books, function(a, b)
                if a.seconds ~= b.seconds then
                    return a.seconds > b.seconds
                end
                return (a.last_time or 0) > (b.last_time or 0)
            end)
            -- 更新 book_count（去重后的真实数量）
            result.book_count = #result.books
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

        -- 读取微信读书云端阅读时长统计
        local weread_stats = self:readMiureadReadStats()

        local matched = 0
        if source == "miuread" then
            -- 觅阅数据源：使用微信读书云端统计（时长/书单/每日数据）+ 觅阅进度
            result.data_source_key = "miuread"
            if weread_stats.has_data then
                -- 用微信读书云端数据替换总时长和每日数据
                result.total_seconds = weread_stats.total_seconds
                result.read_days = weread_stats.read_days or result.read_days
                -- 替换每日数据
                if weread_stats.daily and next(weread_stats.daily) then
                    for _, item in ipairs(result.daily) do
                        item.seconds = weread_stats.daily[item.date] or 0
                    end
                end
                -- 替换书单用微信读书 readLongest 排行
                if #weread_stats.books > 0 then
                    result.books = {}
                    local top_n = math.max(1, math.min(5, tonumber(self.settings.top_n) or DEFAULT_SETTINGS.top_n))
                    for i, book in ipairs(weread_stats.books) do
                        if i > top_n then break end
                        local found_progress = matchProgress(miuread_data, book.title)
                        table.insert(result.books, {
                            title = book.title,
                            authors = "",
                            seconds = book.seconds,
                            read_pages = 0,
                            pages = 0,
                            max_page = 0,
                            last_time = 0,
                            progress = found_progress and found_progress or 0,
                            source = "miuread",
                        })
                    end
                    result.book_count = #weread_stats.books
                end
                -- 进度匹配
                for _, b in ipairs(result.books) do
                    local found = matchProgress(miuread_data, b.title)
                    if found and found > 0 then
                        b.progress = found
                        b.source = "miuread"
                        matched = matched + 1
                    end
                end
            else
                -- 没有微信读书数据时回退到本地统计 + 觅阅进度
                for _, b in ipairs(result.books) do
                    local found = matchProgress(miuread_data, b.title)
                    if found and found > 0 then
                        b.progress = found
                        b.source = "miuread"
                        matched = matched + 1
                    end
                end
            end
        elseif source == "both" then
            -- 混合模式：时长取本地和云端的较大值（微信读书云端可能包含其他设备）
            -- 进度优先用觅阅的，书单以本地为主
            result.data_source_key = "both"
            if weread_stats.has_data and weread_stats.total_seconds > result.total_seconds then
                result.total_seconds = weread_stats.total_seconds
                -- 每日数据也合并：取较大值
                if weread_stats.daily and next(weread_stats.daily) then
                    for _, item in ipairs(result.daily) do
                        local wr_secs = weread_stats.daily[item.date] or 0
                        if wr_secs > item.seconds then
                            item.seconds = wr_secs
                        end
                    end
                end
            end
            for _, b in ipairs(result.books) do
                local found = matchProgress(miuread_data, b.title)
                if found and found > 0 then
                    b.progress = found
                    matched = matched + 1
                end
            end
        end
        logger.info("墨痕壁纸：觅阅进度匹配", matched, "/", #result.books, "本",
            weread_stats.has_data and ("（微信读书时长" .. tostring(math.floor(weread_stats.total_seconds / 60)) .. "分钟）") or "")
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
    if not Font then Font = require("ui/font") end
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
        local ok_builtin, face_builtin = pcall(Font.getFace, Font, PLUGIN_FONT_NAME, sz)
        if ok_builtin and face_builtin then return face_builtin end
    end
    -- 最终回退到系统字体
    local ok_sys, face_sys = pcall(Font.getFace, Font, "cfont", sz)
    if ok_sys and face_sys then return face_sys end
    -- 极端情况：返回 nil 让调用方处理
    return nil
end

local function drawText(bb, text, x, y, size, bold, max_width, align, color)
    if not TextWidget then TextWidget = require("ui/widget/textwidget") end
    local face = getFontFace(size)
    if not face then
        -- 字体加载失败，返回空尺寸，避免崩溃
        return { w = 0, h = 0 }
    end
    local widget = TextWidget:new{
        text = tostring(text or ""),
        face = face,
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
    if not RenderImage then RenderImage = require("ui/renderimage") end
    local ok, image = pcall(RenderImage.renderImageFile, RenderImage, path, false, size, size)
    if ok and image then
        local ok_blit = pcall(bb.blitFrom, bb, image, math.floor(x), math.floor(y), 0, 0, image:getWidth(), image:getHeight())
        if image.free then image:free() end
        return ok_blit
    end
    return false
end

local function drawBoxText(bb, text, x, y, width, size, bold, align)
    if not TextBoxWidget then TextBoxWidget = require("ui/widget/textboxwidget") end
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
    if not TextWidget then TextWidget = require("ui/widget/textwidget") end
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

    -- 轻量模式：降低分辨率以减少内存占用
    if self.settings.low_memory_mode then
        w = math.floor(w * 0.6)
        h = math.floor(h * 0.6)
    end

    local bb = Blitbuffer.new(w, h, Screen.bb:getType())
    bb:fill(Blitbuffer.COLOR_WHITE)

    -- 自定义背景图片
    local bg_mode = self.settings.bg_mode or "white"
    if bg_mode == "image" and self.settings.bg_image_path and self.settings.bg_image_path ~= "" then
        local bg_path = self.settings.bg_image_path
        if lfs.attributes(bg_path, "mode") == "file" then
            if not RenderImage then RenderImage = require("ui/renderimage") end
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

    -- 墨水污渍效果（轻量模式下跳过，减少绘制开销）
    if self.settings.show_stains and not self.settings.low_memory_mode then
        -- 用日期作为种子，同一天的污渍一致
        local stain_seed = os.date("%Y%m%d") + (stats.total_seconds or 0) % 1000
        drawInkStains(bb, w, h, stain_seed, 1.0)
    end

    local lang = self.settings.wallpaper_lang or "zh"
    -- 3.5.9：用 dofile 加载插件本地 i18n.lua，避免 require("i18n") 命中
    -- KOReader 自带的 i18n 模块（缺少 loadLang/getQuotes 导致崩溃）
    if not i18n then
        local ok_i18n, mod = pcall(dofile, self.path .. "/i18n.lua")
        if ok_i18n and type(mod) == "table" then
            i18n = mod
        else
            logger.warn("[InkStain] i18n.lua 加载失败:", mod)
        end
    end
    local T
    if i18n and i18n.loadLang then
        T = i18n.loadLang(self.path, lang)
    end
    if not T then
        -- 回退：空翻译函数，返回空字符串
        T = function() return "" end
    end

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
    -- 轻量模式：跳过 QR 图片文件加载，直接用伪二维码绘制（减少 I/O 和内存）
    if not self.settings.low_memory_mode and drawImage(bb, qr_path, margin_x, footer_y, qr_size) then
        -- QR 图片加载成功
    else
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
    if not InfoMessage then InfoMessage = require("ui/widget/infomessage") end
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
    -- 持久化到设置，重启后仍能识别上次刷新时间，避免重启后首次休眠强制生成
    self.settings.last_refresh_ts = self.last_refresh_ts
    self:saveSettings()

    if not quiet then
        UIManager:show(InfoMessage:new{
            text = T(_("墨痕壁纸已生成：\n%1"), output),
            timeout = 5,
        })
    end
    return true
end

function InkStain:onSuspend()
    -- 休眠时取消尚未开始/正在执行的自动更新检查，避免网络任务跨越休眠。
    self:_cancelAutoUpdateCheck("suspend")
    -- 3.5.8：休眠时绝不生成壁纸——同步 generate() 会阻塞休眠流程，
    -- 导致设备"卡死"无法唤醒。壁纸应由 onCloseDocument / 周期定时器负责更新。
    -- 休眠时只做最轻量的事：确保屏保设置指向正确的文件。
    if not self.settings.auto_set_screensaver then return end
    if not self:shouldApplyInCurrentContext() then return end
    -- 确保屏保设置指向正确的文件（不做任何生成）
    if not self:isUsingInkStainScreensaver() then
        self:applyScreensaverSettings()
    end
end

--- 关闭文档后生成壁纸（此时阅读统计已更新，且不影响休眠响应速度）
function InkStain:onCloseDocument()
    -- 3.5.8：移除 _scheduleAutoUpdateCheck 调用——每次关闭文档都触发 OTA 检查
    -- 会导致频繁加载 OTA 模块（ssl.https/json/sha256），造成卡顿。
    -- OTA 自动检查仅在 init 时延迟调度一次，不在阅读过程中反复触发。
    if not self.settings.auto_refresh_on_suspend then return end
    if not self.settings.auto_set_screensaver then return end
    local now = os.time()
    -- 关闭文档时的刷新间隔短一些（300 秒），避免频繁翻页关闭时重复生成
    if now - (self.last_refresh_ts or 0) < 300 then return end
    -- 3.5.8：延迟 0.5 秒生成，避免阻塞文档关闭动画
    -- 使用 generation 机制确保旧任务可被取消
    self._periodic_refresh_generation = (tonumber(self._periodic_refresh_generation) or 0) + 1
    local gen = self._periodic_refresh_generation
    UIManager:scheduleIn(0.5, function()
        if gen ~= (tonumber(self._periodic_refresh_generation) or 0) then return end
        self:generate(true)
    end)
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
    if not InputDialog then InputDialog = require("ui/widget/inputdialog") end
    if not InfoMessage then InfoMessage = require("ui/widget/infomessage") end
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

--- 设置自定义背景图片（文件选择器）
function InkStain:setCustomBgImage()
    if not PathChooser then PathChooser = require("ui/widget/pathchooser") end
    if not InfoMessage then InfoMessage = require("ui/widget/infomessage") end
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
    if not InfoMessage then InfoMessage = require("ui/widget/infomessage") end
    UIManager:show(InfoMessage:new{
        text = _("锁屏使用范围已保存。"),
        timeout = 4,
    })
end

local function external_quiet(opts)
    return type(opts) == "table" and opts.quiet == true
end

--- Public API v1 ------------------------------------------------------------
-- MiuRead and other plugins should use these methods instead of changing
-- InkStain settings or KOReader screensaver keys directly.
function InkStain:getApiVersion()
    return self.api_version or 1
end

function InkStain:isEnabled()
    return self.settings and self.settings.auto_set_screensaver == true
end

function InkStain:isActive()
    return self:isUsingInkStainScreensaver() == true
end

function InkStain:getStatus()
    return {
        api_version = self:getApiVersion(),
        version = PLUGIN_VERSION,
        enabled = self:isEnabled(),
        active = self:isActive(),
        auto_refresh = self.settings and self.settings.auto_refresh_on_suspend == true,
        scope = self.settings and self.settings.menu_scope or "home",
        output_file = self.output_file,
    }
end

function InkStain:enable(opts)
    local quiet = external_quiet(opts)
    local previous_auto_set = self.settings.auto_set_screensaver
    local previous_auto_refresh = self.settings.auto_refresh_on_suspend

    self.settings.auto_set_screensaver = true
    self.settings.auto_refresh_on_suspend = true
    self:saveSettings()

    local ok = self:generate(true)
    if not ok then
        -- 开启失败时不要留下“设置显示已开启、实际没有壁纸”的半状态。
        self.settings.auto_set_screensaver = previous_auto_set
        self.settings.auto_refresh_on_suspend = previous_auto_refresh
        self:saveSettings()
        return false
    end

    self:_schedulePeriodicRefresh()
    if not quiet then
        if not InfoMessage then InfoMessage = require("ui/widget/infomessage") end
        UIManager:show(InfoMessage:new{
            text = _("墨痕壁纸已开启。"),
            timeout = 3,
        })
    end
    return true
end

function InkStain:disable(opts)
    local quiet = external_quiet(opts)
    local was_active = self:isUsingInkStainScreensaver()

    self.settings.auto_refresh_on_suspend = false
    self.settings.auto_set_screensaver = false
    self:_stopPeriodicRefresh()

    if was_active then
        self:restorePreviousScreensaverSettings()
    else
        -- 如果锁屏已被别的插件接管，不覆盖对方，只丢弃旧快照，避免下次
        -- 再开启/关闭时恢复到过期的屏保配置。
        self.settings.previous_screensaver = nil
        self:saveSettings()
    end

    if not quiet then
        if not InfoMessage then InfoMessage = require("ui/widget/infomessage") end
        UIManager:show(InfoMessage:new{
            text = _("墨痕壁纸已关闭。"),
            timeout = 3,
        })
    end
    return true
end

function InkStain:refresh(opts)
    return self:generate(external_quiet(opts))
end

--- 返回 InkStain 自己的完整设置树，供其他插件嵌入入口时使用。
-- 设置仍由 InkStain 自己维护，调用方无需复制任何选项。
function InkStain:getSettingsMenuItems()
    local holder = {}
    self:addToMainMenu(holder)
    local entry = holder.inkstain_wallpaper
    return entry and entry.sub_item_table or {}
end

--- Public API v2: return the plugin-owned settings tree.
-- Kept as a compatibility alias for external callers that used the earlier name.
function InkStain:getSettingsMenu()
    return self:getSettingsMenuItems()
end

--- Public API v2: open InkStain's own native KOReader settings UI.
-- External plugins should call this instead of copying/re-rendering our menu tree.
function InkStain:openSettings(opts)
    opts = type(opts) == "table" and opts or {}

    if self._settings_menu_container and UIManager:isWidgetShown(self._settings_menu_container) then
        return true
    end

    local ok_center, CenterContainer = pcall(require, "ui/widget/container/centercontainer")
    local ok_touch, TouchMenu = pcall(require, "ui/widget/touchmenu")
    if not ok_center or not CenterContainer or not ok_touch or not TouchMenu then
        logger.warn("[InkStain] native settings UI unavailable", tostring(CenterContainer), tostring(TouchMenu))
        return false, _("当前 KOReader 无法打开墨痕设置界面。")
    end

    local items = self:getSettingsMenuItems()
    if type(items) ~= "table" or #items == 0 then
        return false, _("墨痕设置为空。")
    end

    -- TouchMenu expects each tab to be both an item table and carry an icon.
    -- Use a fresh array so opening the standalone UI never mutates the menu tree
    -- registered with KOReader's own main menu.
    local tab = { icon = "appbar.tools" }
    for i, item in ipairs(items) do tab[i] = item end

    local container = CenterContainer:new{
        covers_header = true,
        ignore = "height",
        dimen = Screen:getSize(),
    }
    local menu = TouchMenu:new{
        width = Screen:getWidth(),
        last_index = 1,
        tab_item_table = { tab },
        show_parent = container,
    }

    menu.close_callback = function()
        if self._settings_menu_container == container then
            self._settings_menu_container = nil
        end
        if UIManager:isWidgetShown(container) then
            UIManager:close(container)
        end
        if type(opts.on_close) == "function" then
            pcall(opts.on_close)
        end
    end

    container[1] = menu
    self._settings_menu_container = container
    UIManager:show(container)
    return true
end

function InkStain:disableWallpaper()
    return self:disable({ quiet = false, source = "inkstain" })
end

function InkStain:enableFromNativeScreensaverMenu()
    return self:enable({ quiet = false, source = "native_screensaver" })
end

function InkStain:restoreFromNativeScreensaverMenu()
    return self:disable({ quiet = false, source = "native_screensaver" })
end

-- ===== OTA Update (基于 pluginota 通用框架) =====

-- 默认自动检查间隔（秒）
local OTA_DEFAULT_INTERVAL = 7 * 86400 -- 7 天
local OTA_MIN_INTERVAL = 21600 -- 最短 6 小时（防止过于频繁）

function InkStain:_updatePreferences()
    self.settings = self.settings or {}
    local defaults = {
        auto_check = false,
        interval = OTA_DEFAULT_INTERVAL,
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
    seconds = tonumber(seconds) or OTA_DEFAULT_INTERVAL
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
                if not InfoMessage then InfoMessage = require("ui/widget/infomessage") end
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
                if not InfoMessage then InfoMessage = require("ui/widget/infomessage") end
                UIManager:show(InfoMessage:new{ text = label, timeout = 2 })
            end,
        }
    end
    return rows
end

function InkStain:updateSettingsMenu()
    local _, update = self:_updatePreferences()
    local channel_label = "稳定版"
    -- 安全地读取 OTA 配置（纯 Lua 文件，不加载 C 扩展），用于显示通道名称
    if not self._ota_config_cache then
        local ok, cfg = pcall(require, "ota_config")
        if ok and type(cfg) == "table" then
            self._ota_config_cache = cfg
        end
    end
    if self._ota_config_cache and self._ota_config_cache.channel == "beta" then
        channel_label = "测试版"
    end
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
                if u.auto_check then
                    self:_scheduleAutoUpdateCheck(2)
                else
                    self:_cancelAutoUpdateCheck("disabled")
                end
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
        -- 暂时隐藏检查更新入口（OTA 崩溃问题待排查）
        -- {
        --     text = _("检查") .. channel_label .. _("更新"),
        --     callback = function() self:checkForUpdate(false) end,
        -- },
        {
            text = _("手动下载地址"),
            callback = function()
                if not InfoMessage then InfoMessage = require("ui/widget/infomessage") end
                local repo_url = "github.com/Estela-Zelin84/inkstain.koplugin/releases"
                UIManager:show(InfoMessage:new{
                    text = _("手动下载最新版：\n\n") .. repo_url .. "\n\n"
                        .. _("下载后将 inkstain.koplugin 文件夹复制到 KOReader 插件目录即可。"),
                    timeout = 0,
                })
            end,
        },
        {
            text = _("当前运行版本 · ") .. tostring(PLUGIN_VERSION),
            enabled = false,
        },
        {
            text = _("更新通道 · ") .. channel_label,
            enabled = false,
        },
        {
            text = _("基于 Plugin OTA 框架"),
            enabled = false,
        },
    }
end

function InkStain:_restartKOReader(source)
    if self._koreader_restart_requested then return true end
    if not InfoMessage then InfoMessage = require("ui/widget/infomessage") end
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
    if not Event then Event = require("ui/event") end
    UIManager:broadcastEvent(Event:new("Restart"))
    if tonumber(UIManager._exit_code) ~= 85 then
        UIManager:quit(85)
    end
    return true
end

function InkStain:_showUpdateCompleteDialog(version, allow_restart)
    if not ConfirmBox then ConfirmBox = require("ui/widget/confirmbox") end
    if not InfoMessage then InfoMessage = require("ui/widget/infomessage") end
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
        if not InfoMessage then InfoMessage = require("ui/widget/infomessage") end
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
    self:_ensureUpdater()
    if not self.ota then return end
    if not ConfirmBox then ConfirmBox = require("ui/widget/confirmbox") end
    if not InfoMessage then InfoMessage = require("ui/widget/infomessage") end
    if manifest.current then
        if not automatic then
            UIManager:show(InfoMessage:new{
                text = _("当前已是最新版本\n\n当前版本：") .. tostring(PLUGIN_VERSION),
                timeout = 3,
            })
        end
        return
    end
    -- 自动检查：同一版本只提示一次
    local _, update = self:_updatePreferences()
    if automatic and tostring(update.last_prompted_version or "") == tostring(manifest.version or "") then
        return
    end
    update.last_prompted_version = tostring(manifest.version or "")
    self:_saveUpdatePreferences(update)

    local channel_label = "稳定版"
    if self._ota_config and self._ota_config.channel == "beta" then
        channel_label = "测试版"
    end
    local text = _("发现") .. channel_label .. _("版本 ") .. tostring(manifest.version)
    local notes = tostring(manifest.summary or "")
    if notes == "" then notes = tostring(manifest.notes or "") end
    if notes ~= "" then text = text .. "\n\n更新内容\n" .. notes end
    text = text .. "\n\n是否下载并安装"

    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = _("下载并安装"),
        ok_callback = function()
            if not NetworkMgr then NetworkMgr = require("ui/network/manager") end
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
    self:_ensureUpdater()
    if not self.ota then
        if not InfoMessage then InfoMessage = require("ui/widget/infomessage") end
        UIManager:show(InfoMessage:new{
            text = self._ota_error or _("更新功能不可用"),
            timeout = 5,
        })
        return
    end
    if not InfoMessage then InfoMessage = require("ui/widget/infomessage") end
    UIManager:show(InfoMessage:new{
        text = _("正在后台下载并校验安装包……"),
        timeout = 0,
    })

    -- 使用 Async 子进程执行 download + install：完全隔离，防止崩溃影响主进程
    local async = self:_getOtaAsync()
    if not async then
        -- 子进程不可用时回退到主线程 pcall
        logger.warn("[InkStain] OTA async unavailable for download, falling back to main thread")
        UIManager:scheduleIn(0.5, function()
            self:_doDownloadAndInstallInMainThread(manifest)
        end)
        return
    end

    local plugin_path = self.path
    local ok_started = async:run("ota_download_install", function()
        -- 子进程内执行下载和安装
        local Updater = require("pluginota.updater")
        local OtaConfig = require("ota_config")
        local ota, err = Updater:new{
            plugin_root = plugin_path,
            plugin_dir = OtaConfig.plugin_dir,
            plugin_id = OtaConfig.plugin_id,
            repo = OtaConfig.repo,
            channel = OtaConfig.channel,
            channel_tag = OtaConfig.channel_tag,
            github_mirrors = OtaConfig.github_mirrors,
            connect_timeout = 5,
            total_timeout = 20,
            download_timeout = 180,
        }
        if not ota then
            return { success = false, phase = "init", error = err }
        end
        local package_path, dl_err = ota:download(manifest)
        if not package_path then
            return { success = false, phase = "download", error = dl_err }
        end
        local installed, inst_err = ota:install(package_path, manifest)
        if installed then
            return { success = true, phase = "install" }
        end
        return { success = false, phase = "install", error = inst_err }
    end, function(result)
        self:_handleDownloadInstallResult(result, manifest)
    end, 240) -- 下载+安装给 240 秒超时

    if not ok_started then
        -- 启动子进程失败，回退到主线程
        logger.warn("[InkStain] OTA async download start failed, falling back")
        UIManager:scheduleIn(0.5, function()
            self:_doDownloadAndInstallInMainThread(manifest)
        end)
    end
end

--- 主线程回退版下载安装（子进程不可用时使用）
function InkStain:_doDownloadAndInstallInMainThread(manifest)
    local ok_dl, package_path, download_err = pcall(function() return self.ota:download(manifest) end)
    if not ok_dl then
        logger.warn("[InkStain] OTA download crashed:", package_path)
        if not InfoMessage then InfoMessage = require("ui/widget/infomessage") end
        UIManager:show(InfoMessage:new{
            text = _("更新下载失败：\n") .. tostring(package_path or "未知错误"),
            timeout = 5,
        })
        return
    end
    if not package_path then
        if not InfoMessage then InfoMessage = require("ui/widget/infomessage") end
        UIManager:show(InfoMessage:new{
            text = _("更新下载失败：\n") .. tostring(download_err or "下载失败"),
            timeout = 5,
        })
        return
    end
    UIManager:show(InfoMessage:new{
        text = _("安装包校验完成，正在安装……"),
        timeout = 1,
    })
    UIManager:scheduleIn(0.5, function()
        local ok_inst, install_ok, install_err = pcall(function() return self.ota:install(package_path, manifest) end)
        if not ok_inst then
            logger.warn("[InkStain] OTA install crashed:", install_ok)
            if not InfoMessage then InfoMessage = require("ui/widget/infomessage") end
            UIManager:show(InfoMessage:new{
                text = _("更新失败：\n") .. tostring(install_ok or "未知错误"),
                timeout = 0,
            })
            return
        end
        if install_ok then
            self:_afterUpdateInstalled(manifest)
        else
            if not InfoMessage then InfoMessage = require("ui/widget/infomessage") end
            UIManager:show(InfoMessage:new{
                text = _("更新失败：\n") .. tostring(install_err),
                timeout = 0,
            })
        end
    end)
end

--- 统一处理下载安装结果（兼容子进程和主线程）
function InkStain:_handleDownloadInstallResult(result, manifest)
    if not InfoMessage then InfoMessage = require("ui/widget/infomessage") end

    if result.ok and result.value and type(result.value) == "table" and result.value.success then
        self:_afterUpdateInstalled(manifest)
        return
    end

    local err_msg = "未知错误"
    local phase = ""
    if result.value and type(result.value) == "table" then
        if result.value.error then err_msg = tostring(result.value.error) end
        if result.value.phase then phase = tostring(result.value.phase) end
    elseif result.error then
        err_msg = tostring(result.error)
    end

    logger.warn("[InkStain] OTA download/install failed:", phase, err_msg)

    local phase_text = ""
    if phase == "download" then
        phase_text = _("更新下载失败：\n")
    elseif phase == "install" then
        phase_text = _("更新失败：\n")
    else
        phase_text = _("更新失败：\n")
    end

    UIManager:show(InfoMessage:new{
        text = phase_text .. err_msg,
        timeout = 0,
    })
end

function InkStain:_cancelAutoUpdateCheck(reason)
    if self._auto_update_check_task then
        pcall(UIManager.unschedule, UIManager, self._auto_update_check_task)
        self._auto_update_check_task = nil
    end
    if reason then
        logger.info("[InkStain] OTA scheduled check cancelled:", tostring(reason))
    end
end

function InkStain:_scheduleAutoUpdateCheck(delay)
    local _, update = self:_updatePreferences()
    if update.auto_check == false then return false end
    if self._auto_update_check_running or self._auto_update_check_task then return false end

    local interval = math.max(OTA_MIN_INTERVAL, tonumber(update.interval) or OTA_DEFAULT_INTERVAL)
    local last = tonumber(update.last_attempt_at) or 0
    if os.time() - last < interval then return false end

    local task
    task = function()
        if self._auto_update_check_task ~= task then return end
        self._auto_update_check_task = nil
        -- 自动检查只在主页执行，不在阅读过程中突然联网或弹出更新提示。
        if self.ui and self.ui.document then return end
        self:maybeAutoCheckUpdate(false)
    end
    self._auto_update_check_task = task
    UIManager:scheduleIn(tonumber(delay) or 8, task)
    return true
end

function InkStain:maybeAutoCheckUpdate(force)
    local _, update = self:_updatePreferences()
    if not force and update.auto_check == false then return false end
    if self._auto_update_check_running then return false end

    local now = os.time()
    local interval = math.max(OTA_MIN_INTERVAL, tonumber(update.interval) or OTA_DEFAULT_INTERVAL)
    local last = tonumber(update.last_attempt_at) or 0
    if not force and now - last < interval then return false end

    if not NetworkMgr then NetworkMgr = require("ui/network/manager") end
    if NetworkMgr and not NetworkMgr:isConnected() then return false end

    -- 只加载 ota_config（纯 Lua，安全），不加载 pluginota
    local ok_cfg, OtaConfig = pcall(require, "ota_config")
    if not ok_cfg or type(OtaConfig) ~= "table" then return false end

    self._auto_update_check_running = true
    update.last_attempt_at = now
    self:_saveUpdatePreferences(update)

    -- 自动检查也用安全的 curl 方式（不加载 OTA 重模块）
    UIManager:scheduleIn(0.1, function()
        local ok, manifest = self:_doSafeAutoCheck(OtaConfig)
        self._auto_update_check_running = false
        self:_finishAutoCheckSafe(ok, manifest, interval, OtaConfig)
    end)

    return true
end

--- 安全自动检查内部实现（纯 curl + 字符串匹配）
function InkStain:_doSafeAutoCheck(OtaConfig)
    local channel_tag = OtaConfig.channel_tag or (OtaConfig.channel == "beta" and "beta-channel" or "stable-channel")
    local manifest_url = "https://github.com/" .. OtaConfig.repo .. "/releases/download/" .. channel_tag .. "/update.json"

    local DataStorage = require("datastorage")
    local temp_dir = DataStorage:getDataDir() .. "/inkstain_ota"
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs and type(lfs.mkdir) == "function" then
        pcall(lfs.mkdir, temp_dir)
    end
    local temp_file = temp_dir .. "/auto_check_" .. tostring(os.time()) .. ".json"

    local cmd = "curl -L --fail --silent --connect-timeout 4 --max-time 12 -o "
        .. "'" .. temp_file .. "' '" .. manifest_url .. "' 2>/dev/null"

    local rc = os.execute(cmd)
    if rc ~= true and rc ~= 0 then
        os.remove(temp_file)
        return false, nil
    end

    local f = io.open(temp_file, "r")
    local raw = f and f:read("*a") or ""
    if f then f:close() end
    os.remove(temp_file)

    if raw == "" then return false, nil end

    local version = raw:match('"version"%s*:%s*"([^"]+)"')
    if not version then return false, nil end

    if not self:_versionIsNewer(version, PLUGIN_VERSION) then
        return true, nil -- 成功但无新版本
    end

    -- 有新版本，构造 manifest
    local manifest = {
        version = version,
        package_url = raw:match('"package_url"%s*:%s*"([^"]+)"'),
        sha256 = raw:match('"sha256"%s*:%s*"([^"]+)"'),
        size = tonumber(raw:match('"size"%s*:%s*(%d+)')),
        notes = raw:match('"notes"%s*:%s*"([^"]+)"') or "",
        summary = raw:match('"summary"%s*:%s*"([^"]+)"') or "",
        name = raw:match('"name"%s*:%s*"([^"]+)"') or "",
        channel = OtaConfig.channel,
    }
    return true, manifest
end

--- 安全版自动检查收尾
function InkStain:_finishAutoCheckSafe(ok, manifest, interval, OtaConfig)
    local _, fresh = self:_updatePreferences()
    if ok and type(manifest) == "table" then
        fresh.last_success_at = os.time()
        self:_saveUpdatePreferences(fresh)
        self:_presentUpdateSafe(manifest, OtaConfig, true)
        return true
    end
    if not ok then
        logger.warn("[InkStain] OTA auto-check failed")
    end
    -- 失败后最早 6 小时再尝试
    fresh.last_attempt_at = os.time() - math.max(0, interval - OTA_MIN_INTERVAL)
    self:_saveUpdatePreferences(fresh)
    return false
end

function InkStain:checkForUpdate(automatic)
    -- 最外层 pcall 兜底：任何 Lua 级别的错误都不会导致闪退
    local ok, result = pcall(function()
        if automatic then return self:maybeAutoCheckUpdate(true) end
        -- 手动检查：不调用 _ensureUpdater()，直接走安全路径
        if not InfoMessage then InfoMessage = require("ui/widget/infomessage") end
        if not NetworkMgr then NetworkMgr = require("ui/network/manager") end
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
    end)
    if not ok then
        logger.warn("[InkStain] checkForUpdate crashed:", result)
        local ok2, InfoMessage2 = pcall(require, "ui/widget/infomessage")
        if ok2 and InfoMessage2 then
            pcall(function()
                UIManager:show(InfoMessage2:new{
                    text = _("检查更新失败：\n") .. tostring(result or "未知错误"),
                    timeout = 5,
                })
            end)
        end
        return false
    end
    return result
end

function InkStain:_manualCheckUpdate()
    -- 注意：这里不调用 _ensureUpdater()，避免在主线程加载 pluginota 重模块
    -- 只用 ota_config（纯 Lua 表）+ curl 检查，绝对安全
    if not InfoMessage then InfoMessage = require("ui/widget/infomessage") end

    -- 只加载 ota_config（纯 Lua 配置，无 C 扩展，安全）
    local ok_cfg, OtaConfig = pcall(require, "ota_config")
    if not ok_cfg or type(OtaConfig) ~= "table" then
        UIManager:show(InfoMessage:new{
            text = _("更新配置加载失败。"),
            timeout = 5,
        })
        return
    end

    local channel_label = OtaConfig.channel == "beta" and "测试版" or "稳定版"
    local channel_tag = OtaConfig.channel_tag or (OtaConfig.channel == "beta" and "beta-channel" or "stable-channel")
    local repo = OtaConfig.repo or ""
    if repo == "" then
        UIManager:show(InfoMessage:new{ text = _("更新配置无效"), timeout = 3 })
        return
    end

    UIManager:show(InfoMessage:new{
        text = _("正在后台检查") .. channel_label .. _("版本……"),
        timeout = 2,
    })

    -- 用 UIManager:scheduleIn 延迟执行，让提示先显示出来
    UIManager:scheduleIn(0.3, function()
        self:_doSafeCheckUpdate(OtaConfig, channel_label, channel_tag, repo)
    end)
end

--- 安全检查更新：只用 curl + 字符串匹配，不加载任何 OTA 重模块
--- 这是防止崩溃的核心：主线程只跑纯 Lua + 外部 curl 命令
function InkStain:_doSafeCheckUpdate(OtaConfig, channel_label, repo)
    if not InfoMessage then InfoMessage = require("ui/widget/infomessage") end

    local channel_tag = OtaConfig.channel_tag or (OtaConfig.channel == "beta" and "beta-channel" or "stable-channel")
    local manifest_url = "https://github.com/" .. OtaConfig.repo .. "/releases/download/" .. channel_tag .. "/update.json"

    -- 使用临时文件保存结果
    local DataStorage = require("datastorage")
    local temp_dir = DataStorage:getDataDir() .. "/inkstain_ota"
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs and type(lfs.mkdir) == "function" then
        pcall(lfs.mkdir, temp_dir)
    end
    local temp_file = temp_dir .. "/update_check_" .. tostring(os.time()) .. ".json"

    -- curl 命令（和 pluginota 框架用的一样，但通过 os.execute 外部调用）
    local cmd = "curl -L --fail --silent --show-error --connect-timeout 5 --max-time 20 -o "
        .. "'" .. temp_file .. "' '" .. manifest_url .. "' 2>/dev/null"

    -- os.execute 的返回值：0 表示成功
    local rc = os.execute(cmd)
    local success = (rc == true or rc == 0)

    local _, update = self:_updatePreferences()
    update.last_attempt_at = os.time()

    if not success then
        os.remove(temp_file)
        self:_saveUpdatePreferences(update)
        UIManager:show(InfoMessage:new{
            text = _("检查更新失败：\n无法连接到更新服务器"),
            timeout = 5,
        })
        return
    end

    -- 读取文件内容
    local f = io.open(temp_file, "r")
    local raw = f and f:read("*a") or ""
    if f then f:close() end
    os.remove(temp_file)

    if raw == "" then
        self:_saveUpdatePreferences(update)
        UIManager:show(InfoMessage:new{
            text = _("检查更新失败：\n服务器返回空数据"),
            timeout = 5,
        })
        return
    end

    -- 用简单字符串匹配提取 version 和 sha256（不用 json 库，避免加载 C 扩展）
    local version = raw:match('"version"%s*:%s*"([^"]+)"')
    local package_url = raw:match('"package_url"%s*:%s*"([^"]+)"')
    local sha256 = raw:match('"sha256"%s*:%s*"([^"]+)"')
    local size = raw:match('"size"%s*:%s*(%d+)')
    local notes = raw:match('"notes"%s*:%s*"([^"]+)"')
    local summary = raw:match('"summary"%s*:%s*"([^"]+)"')
    local name = raw:match('"name"%s*:%s*"([^"]+)"')

    if not version then
        self:_saveUpdatePreferences(update)
        UIManager:show(InfoMessage:new{
            text = _("检查更新失败：\n无法解析更新信息"),
            timeout = 5,
        })
        return
    end

    update.last_success_at = os.time()
    self:_saveUpdatePreferences(update)

    -- 比较版本
    local current = PLUGIN_VERSION
    local is_newer = self:_versionIsNewer(version, current)

    if not is_newer then
        UIManager:show(InfoMessage:new{
            text = _("当前已是最新版本\n\n当前版本：") .. tostring(current),
            timeout = 3,
        })
        return
    end

    -- 有新版本，构造 manifest 表并显示更新确认
    local manifest = {
        version = version,
        package_url = package_url,
        sha256 = sha256,
        size = tonumber(size),
        notes = notes or "",
        summary = summary or "",
        name = name or "",
        channel = OtaConfig.channel,
    }

    self:_presentUpdateSafe(manifest, OtaConfig, false)
end

--- 简单语义化版本比较（纯 Lua，不依赖任何外部模块）
function InkStain:_versionIsNewer(new_ver, old_ver)
    local function parse(v)
        local major, minor, patch = tostring(v or ""):match("^v?(%d+)%.(%d+)%.(%d+)")
        if not major then return nil end
        return tonumber(major), tonumber(minor), tonumber(patch)
    end
    local n1, n2, n3 = parse(new_ver)
    local o1, o2, o3 = parse(old_ver)
    if not n1 or not o1 then
        return tostring(new_ver) ~= tostring(old_ver)
    end
    if n1 ~= o1 then return n1 > o1 end
    if n2 ~= o2 then return n2 > o2 end
    return n3 > o3
end

--- 安全版更新确认（不加载 OTA 模块，只显示信息）
function InkStain:_presentUpdateSafe(manifest, OtaConfig, automatic)
    if not ConfirmBox then ConfirmBox = require("ui/widget/confirmbox") end
    if not InfoMessage then InfoMessage = require("ui/widget/infomessage") end

    if manifest.current then
        if not automatic then
            UIManager:show(InfoMessage:new{
                text = _("当前已是最新版本\n\n当前版本：") .. tostring(PLUGIN_VERSION),
                timeout = 3,
            })
        end
        return
    end

    -- 自动检查：同一版本只提示一次
    local _, update = self:_updatePreferences()
    if automatic and tostring(update.last_prompted_version or "") == tostring(manifest.version or "") then
        return
    end
    update.last_prompted_version = tostring(manifest.version or "")
    self:_saveUpdatePreferences(update)

    local channel_label = OtaConfig.channel == "beta" and "测试版" or "稳定版"
    local text = _("发现") .. channel_label .. _("版本 ") .. tostring(manifest.version)
    local notes = tostring(manifest.summary or "")
    if notes == "" then notes = tostring(manifest.notes or "") end
    -- 处理转义的换行符
    notes = notes:gsub("\\n", "\n")
    if notes ~= "" then text = text .. "\n\n更新内容\n" .. notes end
    text = text .. "\n\n是否下载并安装"

    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = _("下载并安装"),
        ok_callback = function()
            if not NetworkMgr then NetworkMgr = require("ui/network/manager") end
            if NetworkMgr and not NetworkMgr:isConnected() then
                if NetworkMgr.willRereadConnect then
                    NetworkMgr:willRereadConnect(function()
                        self:_downloadAndUpdateSafe(manifest, OtaConfig)
                    end)
                else
                    UIManager:show(InfoMessage:new{ text = _("当前网络不可用"), timeout = 3 })
                end
                return
            end
            self:_downloadAndUpdateSafe(manifest, OtaConfig)
        end,
    })
end

--- 安全版下载更新：在 Async 子进程中加载完整 OTA 模块并执行下载安装
function InkStain:_downloadAndUpdateSafe(manifest, OtaConfig)
    if not InfoMessage then InfoMessage = require("ui/widget/infomessage") end
    UIManager:show(InfoMessage:new{
        text = _("正在后台下载并校验安装包……"),
        timeout = 0,
    })

    -- 使用 Async 子进程：完整 OTA 模块只在子进程中加载
    local async = self:_getOtaAsync()
    if not async then
        -- 子进程不可用时，尝试在主线程用 pcall 加载（风险较高但至少能用）
        logger.warn("[InkStain] OTA async unavailable, trying main thread pcall")
        UIManager:scheduleIn(0.5, function()
            self:_ensureUpdater()
            if self.ota then
                self:_doDownloadAndInstallInMainThread(manifest)
            else
                UIManager:show(InfoMessage:new{
                    text = self._ota_error or _("更新功能不可用"),
                    timeout = 5,
                })
            end
        end)
        return
    end

    local plugin_path = self.path
    local ok_started = async:run("ota_download_install", function()
        -- 子进程内加载 OTA 模块（完全隔离，崩溃不影响主进程）
        local Updater = require("pluginota.updater")
        local ota, err = Updater:new{
            plugin_root = plugin_path,
            plugin_dir = OtaConfig.plugin_dir,
            plugin_id = OtaConfig.plugin_id,
            repo = OtaConfig.repo,
            channel = OtaConfig.channel,
            channel_tag = OtaConfig.channel_tag,
            github_mirrors = OtaConfig.github_mirrors,
            connect_timeout = 5,
            total_timeout = 20,
            download_timeout = 180,
        }
        if not ota then
            return { success = false, phase = "init", error = err }
        end
        local package_path, dl_err = ota:download(manifest)
        if not package_path then
            return { success = false, phase = "download", error = dl_err }
        end
        local installed, inst_err = ota:install(package_path, manifest)
        if installed then
            return { success = true, phase = "install" }
        end
        return { success = false, phase = "install", error = inst_err }
    end, function(result)
        self:_handleDownloadInstallResult(result, manifest)
    end, 240)

    if not ok_started then
        -- 启动子进程失败，回退到主线程 pcall
        logger.warn("[InkStain] OTA async download start failed, falling back")
        UIManager:scheduleIn(0.5, function()
            self:_ensureUpdater()
            if self.ota then
                self:_doDownloadAndInstallInMainThread(manifest)
            else
                UIManager:show(InfoMessage:new{
                    text = self._ota_error or _("更新功能不可用"),
                    timeout = 5,
                })
            end
        end)
    end
end

function InkStain:addToMainMenu(menu_items)
    -- 菜单构建时预加载 InfoMessage（回调中大量使用）
    if not InfoMessage then InfoMessage = require("ui/widget/infomessage") end
    menu_items.inkstain_wallpaper = {
        text = _("墨痕壁纸"),
        sorting_hint = "tools",
        sub_item_table = {
            -- ===== 操作区 =====
            {
                text = _("生成并设为休眠壁纸"),
                callback = function()
                    self:enable({ quiet = false, source = "inkstain_menu" })
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
                                    if not i18n then i18n = dofile(self.path .. "/i18n.lua") end
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
                                    if not i18n then i18n = dofile(self.path .. "/i18n.lua") end
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
                                    if not i18n then i18n = dofile(self.path .. "/i18n.lua") end
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
                            if self.settings.auto_refresh_on_suspend and self.settings.auto_set_screensaver then
                                self:_schedulePeriodicRefresh()
                            end
                        end,
                    },
                    {
                        text = _("自动设置 KOReader 休眠屏幕"),
                        checked_func = function()
                            return self.settings.auto_set_screensaver
                        end,
                        callback = function()
                            if self:isEnabled() then
                                self:disable({ quiet = false, source = "inkstain_menu" })
                            else
                                self:enable({ quiet = false, source = "inkstain_menu" })
                            end
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
                        text = _("轻量模式（低内存设备）"),
                        checked_func = function() return self.settings.low_memory_mode end,
                        callback = function()
                            self:toggleSetting("low_memory_mode")
                            UIManager:show(InfoMessage:new{
                                text = self.settings.low_memory_mode and
                                    _("轻量模式已开启：降低分辨率并跳过墨水点，适合低内存设备。") or
                                    _("轻量模式已关闭。"),
                                timeout = 3,
                            })
                        end,
                    },
                    {
                        text = _("软件更新"),
                        sub_item_table_func = function()
                            return self:updateSettingsMenu()
                        end,
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
            -- ===== 关于 =====
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

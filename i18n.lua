--[[--
墨痕壁纸 i18n 模块。

仿照 ZenUI 插件的语言包方案，使用标准 gettext .po 文本文件，
运行时纯 Lua 解析，无需编译 .mo。

用法：
    local i18n = require("i18n")
    local T = i18n.loadLang(plugin_path, "en")
    -- T("serial") → "No. "
    -- T("quote_1") → "A reader lives a thousand lives before he dies."
--]]--

local logger = require("logger")

local i18n = {}

-- 缓存：已加载的翻译表
local _cache = {}

--- 转义 .po 文件中的转义字符
local function unescape(s)
    return s:gsub("\\n", "\n")
            :gsub("\\t", "\t")
            :gsub('\\"', '"')
            :gsub("\\\\", "\\")
end

--- 解析 .po 文件，返回翻译表
-- @param path .po 文件路径
-- @return translations table [msgid] = msgstr, or nil on failure
local function parsePO(path)
    local f = io.open(path, "r")
    if not f then return nil end

    local translations = {}
    local id, str
    local in_id, in_str = false, false
    local count = 0

    local function flush()
        if id and id ~= "" and str and str ~= "" then
            translations[id] = str
            count = count + 1
        end
        id, str = nil, nil
        in_id, in_str = false, false
    end

    for line in f:lines() do
        line = line:match("^%s*(.-)%s*$")
        if line == "" then
            flush()
        elseif line:match("^#") then
            -- 注释行，跳过
        elseif line:match('^msgid%s+"') then
            flush()
            id = unescape(line:match('^msgid%s+"(.*)"') or "")
            in_id = true; in_str = false
        elseif line:match('^msgstr%s+"') then
            str = unescape(line:match('^msgstr%s+"(.*)"') or "")
            in_str = true; in_id = false
        elseif line:match('^"') then
            local cont = unescape(line:match('^"(.*)"') or "")
            if in_id and id then id = id .. cont end
            if in_str and str then str = str .. cont end
        end
    end
    flush()
    f:close()

    if count == 0 then return nil end
    return translations
end

--- 加载指定语言的翻译表
-- @param plugin_path 插件目录路径
-- @param lang 语言代码（"zh" / "en" 等）
-- @return 翻译函数 T(msgid) -> msgstr
function i18n.loadLang(plugin_path, lang)
    lang = lang or "zh"

    -- 检查缓存
    if _cache[lang] then
        return _cache[lang]
    end

    local locales_dir = (plugin_path or "") .. "/locales/"

    -- 尝试加载 .po 文件
    local po_path = locales_dir .. lang .. ".po"
    local translations = parsePO(po_path)

    if not translations then
        -- 回退到中文
        if lang ~= "zh" then
            po_path = locales_dir .. "zh.po"
            translations = parsePO(po_path)
        end
    end

    if not translations then
        logger.warn("墨痕壁纸 i18n：无法加载语言包", lang)
        translations = {}
    else
        local count = 0
        for _ in pairs(translations) do count = count + 1 end
        logger.info("墨痕壁纸 i18n：已加载", lang, count, "条翻译")
    end

    -- 构建翻译对象（可像函数一样调用，同时暴露原始翻译表）
    local T_obj = setmetatable({
        _translations = translations,
    }, {
        __call = function(self, msgid)
            return translations[msgid] or ""
        end
    })

    _cache[lang] = T_obj
    return T_obj
end

--- 清除缓存（语言切换时调用）
function i18n.clearCache()
    _cache = {}
end

--- 获取格言列表
-- @param T 翻译函数
-- @return 格言数组
function i18n.getQuotes(T)
    local quotes = {}
    for i = 1, 50 do
        local q = T("quote_" .. tostring(i))
        if q and q ~= "" then
            table.insert(quotes, q)
        else
            break
        end
    end
    if #quotes == 0 then
        -- 回退：至少返回一条
        quotes = { T("quote_1") }
    end
    return quotes
end

return i18n

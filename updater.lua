--[[--
OTA update module for inkstain.koplugin.

Architecture completely modeled on miuread's updater.lua:
  - Manifest-based update checking (JSON manifest, not GitHub API)
  - Multi-mirror download with automatic GitHub mirror expansion
  - SHA-256 + size dual verification (pure Lua SHA-256, no external commands)
  - Stage → Backup → Replace → Verify → Rollback installation strategy
  - Cross-restart pending state confirmation via G_reader_settings
  - Artifact cleanup (stage/backup/package temp files)
  - Channel validation (stable channel matching)
  - Manifest text cleaning (full-width→half-width punctuation, UTF-8 validation)
  - Safe relative path checking for delete_list (directory traversal prevention)
  - semver version comparison with pre-release support
  - Atomic file writes (write .tmp → rename, with .previous fallback)
--]]--

local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local ltn12 = require("ltn12")
local bit = require("bit")
local ok_socketutil, socketutil = pcall(require, "socketutil")
local ok_http, http = pcall(require, "socket.http")
local ok_https, https = pcall(require, "ssl.https")
local ok_socket, socket = pcall(require, "socket")

-- ===== Configuration (modeled on miuread config.lua) =====

local Config = {
    PLUGIN_DIR       = "inkstain.koplugin",
    UPDATE_CHANNEL   = "stable",
    UPDATE_CHANNEL_LABEL = "正式通道",
    UPDATE_MANIFEST  = "https://github.com/Estela-Zelin84/inkstain.koplugin/releases/download/stable-channel/update.json",
    UPDATE_MANIFESTS = {
        "https://github.com/Estela-Zelin84/inkstain.koplugin/releases/download/stable-channel/update.json",
    },
    GITHUB_MIRRORS = {
        "https://ghfast.top/",
        "https://gh-proxy.com/",
        "https://ghproxy.net/",
    },
    AUTO_UPDATE_INTERVAL       = 24 * 60 * 60,   -- 86400 seconds
    AUTO_UPDATE_RETRY_INTERVAL = 6 * 60 * 60,    -- 21600 seconds
}

-- ===== Pure Lua SHA-256 (ported from miuread digests.lua) =====

local Digests = {}
do
    local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
    local lshift, rshift, rol, ror = bit.lshift, bit.rshift, bit.rol, bit.ror

    local function u32(x) return band(x, 0xffffffff) end

    local function plus(...)
        local v = 0
        for i = 1, select("#", ...) do v = u32(v + select(i, ...)) end
        return v
    end

    local function be32(s, p)
        local a, b, c, d = s:byte(p, p + 3)
        return bor(lshift(a, 24), lshift(b, 16), lshift(c, 8), d)
    end

    local function behex(x)
        return string.format("%02x%02x%02x%02x",
            band(rshift(x, 24), 255), band(rshift(x, 16), 255),
            band(rshift(x, 8), 255), band(x, 255))
    end

    local H = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
        0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
        0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
        0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
        0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    }

    function Digests.sha256(input)
        local s = tostring(input or "")
        local bits = #s * 8
        local pad = (56 - (#s + 1) % 64) % 64
        s = s .. string.char(128) .. string.rep("\0", pad)
            .. string.char(0, 0, 0, 0,
                band(rshift(bits, 24), 255), band(rshift(bits, 16), 255),
                band(rshift(bits, 8), 255), band(bits, 255))
        local h = {
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        }
        for pos = 1, #s, 64 do
            local w = {}
            for j = 0, 15 do w[j] = be32(s, pos + j * 4) end
            for j = 16, 63 do
                local x = bxor(ror(w[j - 15], 7), ror(w[j - 15], 18), rshift(w[j - 15], 3))
                local y = bxor(ror(w[j - 2], 17), ror(w[j - 2], 19), rshift(w[j - 2], 10))
                w[j] = plus(w[j - 16], x, w[j - 7], y)
            end
            local a, b, c, d, e, f, g, q =
                h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
            for j = 0, 63 do
                local s1 = bxor(ror(e, 6), ror(e, 11), ror(e, 25))
                local ch = bxor(band(e, f), band(bnot(e), g))
                local t1 = plus(q, s1, ch, H[j + 1], w[j])
                local s0 = bxor(ror(a, 2), ror(a, 13), ror(a, 22))
                local maj = bxor(band(a, b), band(a, c), band(b, c))
                local t2 = plus(s0, maj)
                q, g, f, e, d, c, b, a =
                    g, f, e, plus(d, t1), c, b, a, plus(t1, t2)
            end
            h[1], h[2], h[3], h[4] =
                plus(h[1], a), plus(h[2], b), plus(h[3], c), plus(h[4], d)
            h[5], h[6], h[7], h[8] =
                plus(h[5], e), plus(h[6], f), plus(h[7], g), plus(h[8], q)
        end
        local out = {}
        for i = 1, 8 do out[i] = behex(h[i]) end
        return table.concat(out)
    end
end

-- ===== Utility functions (ported from miuread util.lua) =====

local U = {}

function U.copy(v, seen)
    if type(v) ~= "table" then return v end
    seen = seen or {}
    if seen[v] then return seen[v] end
    local o = {}
    seen[v] = o
    for k, x in pairs(v) do o[U.copy(k, seen)] = U.copy(x, seen) end
    return o
end

function U.merge(a, b)
    local o = U.copy(a or {})
    for k, v in pairs(b or {}) do
        if type(v) == "table" and type(o[k]) == "table" then
            o[k] = U.merge(o[k], v)
        else
            o[k] = U.copy(v)
        end
    end
    return o
end

-- UTF-8 validation
local function utf8_sequence_length(first)
    if not first then return 0 end
    if first < 0x80 then return 1 end
    if first >= 0xC2 and first <= 0xDF then return 2 end
    if first >= 0xE0 and first <= 0xEF then return 3 end
    if first >= 0xF0 and first <= 0xF4 then return 4 end
    return 0
end

local function utf8_char_end(value, index)
    local first = value:byte(index)
    local length = utf8_sequence_length(first)
    if length == 0 then return index, false end
    if length == 1 then return index, true end
    if index + length - 1 > #value then return index, false end
    local second = value:byte(index + 1)
    if not second or second < 0x80 or second > 0xBF then return index, false end
    if length >= 3 then
        if first == 0xE0 and second < 0xA0 then return index, false end
        if first == 0xED and second > 0x9F then return index, false end
        local third = value:byte(index + 2)
        if not third or third < 0x80 or third > 0xBF then return index, false end
    end
    if length == 4 then
        if first == 0xF0 and second < 0x90 then return index, false end
        if first == 0xF4 and second > 0x8F then return index, false end
        local fourth = value:byte(index + 3)
        if not fourth or fourth < 0x80 or fourth > 0xBF then return index, false end
    end
    return index + length - 1, true
end

function U.is_valid_utf8(value)
    value = tostring(value or "")
    local index = 1
    while index <= #value do
        local ending, valid = utf8_char_end(value, index)
        if not valid then return false, index end
        index = ending + 1
    end
    return true
end

function U.utf8_truncate(value, max_chars, ellipsis)
    value = tostring(value or "")
    max_chars = math.max(0, math.floor(tonumber(max_chars) or 0))
    ellipsis = ellipsis == nil and "…" or tostring(ellipsis)
    if max_chars == 0 then return value == "" and "" or ellipsis end
    local index, count, last_end = 1, 0, 0
    while index <= #value and count < max_chars do
        local ending = utf8_char_end(value, index)
        count = count + 1
        last_end = ending
        index = ending + 1
    end
    if index > #value then return value end
    return value:sub(1, last_end) .. ellipsis
end

function U.contains_replacement_char(value)
    return tostring(value or ""):find("\239\191\189", 1, true) ~= nil
end

function U.replacement_char_count(value)
    local text = tostring(value or "")
    local _, count = text:gsub("\239\191\189", "")
    return count
end

function U.first_line(s, n)
    local v = tostring(s or ""):match("^[^\r\n]*") or ""
    return U.utf8_truncate(v, n or 240)
end

function U.id_name(s)
    local v = tostring(s or ""):gsub("[^%w%._%-]", "_")
    return v ~= "" and v or "unknown"
end

function U.shell_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

function U.redact_url(value)
    local text = tostring(value or "")
    local sensitive = { uid = true, token = true, ticket = true, session = true,
        sk = true, access_token = true, refresh_token = true }
    text = text:gsub("([?&])([^=&#%s]+)=([^&#%s]*)", function(prefix, name, content)
        if sensitive[tostring(name):lower()] then return prefix .. name .. "=***" end
        return prefix .. name .. "=" .. content
    end)
    return text
end

-- File operations
local function raw_file_exists(p)
    local f = io.open(p, "rb")
    if not f then return false end
    f:close()
    return true
end

function U.file_exists(p) return raw_file_exists(p) end

function U.read_file(p, b)
    local f, e = io.open(p, b and "rb" or "r")
    if not f then return nil, e end
    local d = f:read("*a")
    f:close()
    return d
end

function U.file_size(p)
    local f = io.open(p, "rb")
    if not f then return nil end
    local n = f:seek("end")
    f:close()
    return n
end

function U.mkdir(p)
    if not p or p == "" then return false end
    if lfs.attributes(p, "mode") == "directory" then return true end
    local parent = p:match("^(.*)/[^/]+$")
    if parent and parent ~= "" and parent ~= p then U.mkdir(parent) end
    local ok = lfs.mkdir(p)
    return ok or lfs.attributes(p, "mode") == "directory"
end

function U.atomic_write(p, d, b)
    local parent = p:match("^(.*)/[^/]+$")
    if parent then U.mkdir(parent) end
    local payload = d or ""
    local t = p .. ".tmp-" .. tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999))
    local f, e = io.open(t, b and "wb" or "w")
    if not f then return nil, e end
    local ok, er = f:write(payload)
    local flushed, flush_error = f:flush()
    f:close()
    if not ok or flushed == nil then os.remove(t); return nil, er or flush_error end
    if U.file_size(t) ~= #payload then os.remove(t); return nil, "temporary file size mismatch" end
    local r, re = os.rename(t, p)
    if r then return true end
    -- Fallback: rename old file aside, then rename temp into place
    if U.file_exists(p) then
        local previous = p .. ".previous-" .. tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999))
        os.rename(p, previous)
        r, re = os.rename(t, p)
        if not r then
            os.rename(previous, p)
            os.remove(t)
            return nil, re
        end
        os.remove(previous)
    else
        os.remove(t)
        return nil, re
    end
    return true
end

function U.remove_tree(p)
    p = tostring(p or "")
    if p == "" then return true end
    local mode
    if type(lfs.symlinkattributes) == "function" then mode = lfs.symlinkattributes(p, "mode") end
    if not mode then mode = lfs.attributes(p, "mode") end
    if mode == "file" or mode == "link" then
        local ok, err = os.remove(p)
        if ok or not lfs.attributes(p, "mode") then return true end
        return nil, err
    end
    if mode ~= "directory" then return true end
    local ok, iter, state = pcall(lfs.dir, p)
    if not ok or type(iter) ~= "function" then return nil, tostring(iter or state or "无法读取目录") end
    for x in iter, state do
        if x ~= "." and x ~= ".." then
            local removed, err = U.remove_tree(p .. "/" .. x)
            if not removed then return nil, err end
        end
    end
    local removed, err = lfs.rmdir(p)
    if removed or lfs.attributes(p, "mode") ~= "directory" then return true end
    return nil, err
end

function U.list(p)
    local o = {}
    if lfs.attributes(p, "mode") ~= "directory" then return o end
    for x in lfs.dir(p) do
        if x ~= "." and x ~= ".." then o[#o + 1] = p .. "/" .. x end
    end
    table.sort(o)
    return o
end

function U.copy_file(a, b)
    local d, e = U.read_file(a, true)
    if not d then return nil, e end
    return U.atomic_write(b, d, true)
end

function U.copy_tree(a, b)
    local m = lfs.attributes(a, "mode")
    if m == "file" then return U.copy_file(a, b) end
    if m ~= "directory" then return nil, "source missing" end
    U.mkdir(b)
    for x in lfs.dir(a) do
        if x ~= "." and x ~= ".." then
            local ok, e = U.copy_tree(a .. "/" .. x, b .. "/" .. x)
            if not ok then return nil, e end
        end
    end
    return true
end

-- semver comparison (ported from miuread util.lua)
local function semver_parse(value)
    local major, minor, patch, pre = tostring(value or ""):match("^v?(%d+)%.(%d+)%.(%d+)(.*)$")
    if not major then return nil end
    local out = { major = tonumber(major), minor = tonumber(minor), patch = tonumber(patch), pre = {} }
    pre = tostring(pre or ""):gsub("^[%-+]", "")
    if pre ~= "" then
        pre = pre:match("^[^+]+") or pre
        for part in pre:gmatch("[^%.]+") do
            local number = part:match("^%d+$") and tonumber(part) or nil
            out.pre[#out.pre + 1] = number or tostring(part):lower()
        end
    end
    return out
end

function U.semver_compare(a, b)
    local x, y = semver_parse(a), semver_parse(b)
    if not x or not y then
        return tostring(a) == tostring(b) and 0 or (tostring(a) > tostring(b) and 1 or -1)
    end
    for _, key in ipairs({ "major", "minor", "patch" }) do
        if x[key] ~= y[key] then return x[key] > y[key] and 1 or -1 end
    end
    if #x.pre == 0 and #y.pre == 0 then return 0 end
    if #x.pre == 0 then return 1 end
    if #y.pre == 0 then return -1 end
    for index = 1, math.max(#x.pre, #y.pre) do
        local p, q = x.pre[index], y.pre[index]
        if p == nil then return -1 end
        if q == nil then return 1 end
        if p ~= q then
            if type(p) == "number" and type(q) == "number" then return p > q and 1 or -1 end
            if type(p) == "number" then return -1 end
            if type(q) == "number" then return 1 end
            return tostring(p) > tostring(q) and 1 or -1
        end
    end
    return 0
end

function U.semver_newer(a, b) return U.semver_compare(a, b) > 0 end

-- ===== HTTP layer (simplified from miuread http.lua) =====
-- Manual redirect handling, curl/wget fallback for download.

local HttpClient = {}
HttpClient.__index = HttpClient

local function hget(headers, name)
    local target = tostring(name):lower()
    for k, v in pairs(headers or {}) do
        if type(k) == "string" and k:lower() == target then return v end
    end
end

local function absolute(base, loc)
    loc = tostring(loc or "")
    if loc:match("^https?://") then return loc end
    local scheme, host = tostring(base):match("^(https?)://([^/]+)")
    if not scheme then return loc end
    if loc:sub(1, 1) == "/" then return scheme .. "://" .. host .. loc end
    local dir = tostring(base):match("^(https?://.*/)") or (scheme .. "://" .. host .. "/")
    return dir .. loc
end

local function clock_now()
    if ok_socket and socket and type(socket.gettime) == "function" then
        return socket.gettime()
    end
    return os.time()
end

local function command_ok(rc)
    return rc == true or rc == 0
end

local function curl_download(url, path)
    local cmd = "curl -L --fail --silent --show-error --connect-timeout 20 --max-time 180 -o "
        .. U.shell_quote(path) .. " " .. U.shell_quote(url) .. " 2>/dev/null"
    logger.info("[InkStain][Updater] curl fallback download", url)
    return command_ok(os.execute(cmd))
end

function HttpClient:new()
    return setmetatable({ user_agent = "KOReader-InkStain-Plugin" }, self)
end

function HttpClient:_request_once(opt)
    local redirects = tonumber(opt.redirects) or 8
    local current = assert(opt.url, "url required")
    local method = opt.method or "GET"
    local headers = {}
    for k, v in pairs(opt.headers or {}) do headers[k] = v end
    headers["User-Agent"] = headers["User-Agent"] or self.user_agent
    headers["Accept"] = headers["Accept"] or "*/*"

    for hop = 0, redirects do
        local chunks = {}
        if socketutil then
            socketutil:set_timeout((opt.timeout and opt.timeout[1]) or 15, (opt.timeout and opt.timeout[2]) or 45)
        end
        local transport
        if current:match("^https:") then
            transport = ok_https and https or (ok_http and http or nil)
        else
            transport = ok_http and http or nil
        end
        if not transport or type(transport.request) ~= "function" then
            if socketutil then socketutil:reset_timeout() end
            return nil, nil, nil, current, "HTTP transport unavailable"
        end
        local called, req_ok, code, resp_headers = pcall(transport.request, {
            url = current,
            method = method,
            headers = headers,
            sink = ltn12.sink.table(chunks),
        })
        if socketutil then socketutil:reset_timeout() end
        if not called then
            return nil, nil, nil, current, tostring(req_ok)
        end
        if not req_ok then
            return nil, nil, nil, current, tostring(code)
        end
        code = tonumber(code)
        local text = table.concat(chunks)
        if not code then
            return text, nil, resp_headers, current
        end
        -- Manual redirect following
        if code >= 300 and code < 400 and resp_headers then
            local location = hget(resp_headers, "location")
            if location and hop < redirects then
                current = absolute(current, location)
                if code == 303 then method = "GET" end
            else
                return text, code, resp_headers, current
            end
        else
            return text, code, resp_headers, current
        end
    end
    return nil, nil, nil, current, "too many redirects"
end

function HttpClient:request(opt)
    opt = opt or {}
    local retries = tonumber(opt.retries)
    if retries == nil then retries = 2 end
    retries = math.max(0, math.min(5, retries))
    local last_text, last_code, last_headers, last_url, last_error
    for attempt = 1, retries + 1 do
        local text, code, headers, url, err = self:_request_once(opt)
        last_text, last_code, last_headers, last_url, last_error = text, code, headers, url, err
        if code and code >= 200 and code < 300 then
            return text, code, headers, url
        end
        -- Transient status codes warrant retry
        local transient = code and (code == 408 or code == 500 or code == 502 or code == 503 or code == 504)
        if code and not transient then return text, code, headers, url end
        if code and transient and attempt > retries then return text, code, headers, url end
        if not code and attempt > retries then
            return nil, nil, nil, url or opt.url, tostring(err or "network request failed")
        end
        logger.warn("[InkStain][Updater] retry", "attempt=", tostring(attempt),
            "url=", U.redact_url(url or opt.url), "status=", tostring(code or err or "network"))
        if ok_socket and socket and type(socket.sleep) == "function" then
            socket.sleep(math.min(2.5, 0.35 * (2 ^ (attempt - 1))))
        end
    end
    return last_text, last_code, last_headers, last_url, last_error
end

function HttpClient:get_json(url, opt)
    opt = opt or {}
    opt.url = url
    opt.method = "GET"
    local text, code, headers, final_url, err = self:request(opt)
    if not code or code < 200 or code >= 300 then
        -- Fallback to curl for JSON fetch
        local tmp = os.tmpname()
        os.remove(tmp)
        if curl_download(url, tmp) then
            local raw = U.read_file(tmp, true)
            os.remove(tmp)
            if raw and #raw > 0 then
                local JSON = require("json")
                local ok, data = pcall(JSON.decode, raw)
                if ok and type(data) == "table" then return data end
            end
        end
        os.remove(tmp)
        return nil, tostring(err or ("HTTP " .. tostring(code)))
    end
    text = text or ""
    local JSON = require("json")
    local ok, data = pcall(JSON.decode, text)
    if not ok then return nil, "invalid JSON from " .. U.redact_url(final_url) end
    return data
end

function HttpClient:download(url, opt)
    opt = opt or {}
    opt.url = url
    opt.method = "GET"
    if opt.retries == nil then opt.retries = 2 end
    local body, code, headers, final = self:request(opt)
    if code and code >= 200 and code < 300 and type(body) == "string" and #body > 0 then
        return body
    end
    return nil, "download HTTP " .. tostring(code or "nil")
end

-- ===== Updater class (modeled on miuread updater.lua) =====

local Updater = {}
Updater.__index = Updater

function Updater:new(version, plugin_root)
    local DataStorage = require("datastorage")
    local updates_dir = DataStorage:getDataDir() .. "/cache/inkstain_updates"
    U.mkdir(updates_dir)
    return setmetatable({
        http = HttpClient:new(),
        version = version,
        plugin_root = plugin_root,
        updates_dir = updates_dir,
    }, self)
end

-- ===== Manifest URL management with mirror expansion =====

local function valid_https(url)
    return type(url) == "string" and url:match("^https://") ~= nil
end

local function append_unique(out, seen, value)
    if valid_https(value) and not seen[value] then
        seen[value] = true
        out[#out + 1] = value
    end
end

local function is_github_resource(url)
    if type(url) ~= "string" then return false end
    return url:match("^https://github%.com/")
        or url:match("^https://api%.github%.com/")
        or url:match("^https://raw%.githubusercontent%.com/")
        or url:match("^https://objects%.githubusercontent%.com/")
end

local function with_github_mirrors(url, out, seen)
    append_unique(out, seen, url)
    if not is_github_resource(url) then return end
    for _, prefix in ipairs(Config.GITHUB_MIRRORS or {}) do
        if valid_https(prefix) then
            if prefix:sub(-1) ~= "/" then prefix = prefix .. "/" end
            append_unique(out, seen, prefix .. url)
        end
    end
end

function Updater:manifest_urls()
    local out, seen = {}, {}
    local configured = Config.UPDATE_MANIFESTS
    if type(configured) == "table" then
        for _, url in ipairs(configured) do with_github_mirrors(url, out, seen) end
    else
        with_github_mirrors(Config.UPDATE_MANIFEST, out, seen)
    end
    return out
end

function Updater:manifest_url()
    return self:manifest_urls()[1]
end

local function collect_table_urls(value, out, seen)
    if type(value) ~= "table" then return end
    for _, url in ipairs(value) do with_github_mirrors(url, out, seen) end
end

local function package_urls(manifest)
    local out, seen = {}, {}
    if type(manifest) ~= "table" then return out end
    with_github_mirrors(manifest.package_url or manifest.url, out, seen)
    collect_table_urls(manifest.package_urls, out, seen)
    collect_table_urls(manifest.mirror_urls, out, seen)
    collect_table_urls(manifest.mirrors, out, seen)
    return out
end

-- ===== Manifest validation and text cleaning =====

local function clean_notes(value)
    local text = tostring(value or "")
    if not U.is_valid_utf8(text) or U.contains_replacement_char(text) then return nil end
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    text = text:gsub("•", "-"):gsub("●", "-"):gsub("▪", "-"):gsub("◦", "-")
    text = text:gsub("：", ":"):gsub("，", ","):gsub("。", "."):gsub("、", ",")
    text = text:gsub("“", ""):gsub("”", ""):gsub("‘", ""):gsub("’", "")
    text = text:gsub("—", "-"):gsub("–", "-"):gsub("·", "-")
    text = text:gsub("[%z\1-\8\11\12\14-\31]", "")
    if not U.is_valid_utf8(text) or U.contains_replacement_char(text) then return nil end
    local lines = {}
    for line in text:gmatch("[^\n]+") do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" then
            lines[#lines + 1] = line
            if #lines >= 4 then break end
        end
    end
    return table.concat(lines, "\n")
end

local function clean_manifest_text(m)
    local notes = m and m.notes ~= nil and clean_notes(m.notes) or nil
    local summary = m and m.summary ~= nil and clean_notes(m.summary) or nil
    local name = m and m.name ~= nil and clean_notes(m.name) or nil
    if m and m.notes ~= nil and notes == nil then return nil, "更新说明包含损坏的 UTF-8 文本" end
    if m and m.summary ~= nil and summary == nil then return nil, "更新摘要包含损坏的 UTF-8 文本" end
    if m and m.name ~= nil and name == nil then return nil, "更新名称包含损坏的 UTF-8 文本" end
    if summary == "" then summary = nil end
    return { notes = notes or "", summary = summary or notes or "", name = name }
end

local function validate_manifest(m)
    if type(m) ~= "table" or type(m.version) ~= "string" or m.version == "" then
        return nil, "更新清单缺少版本号"
    end
    local expected_channel = tostring(Config.UPDATE_CHANNEL or "stable")
    local manifest_channel = tostring(m.channel or "")
    if manifest_channel == "" and expected_channel == "stable" then manifest_channel = "stable" end
    if manifest_channel ~= expected_channel then
        return nil, "更新清单通道不匹配：当前为" .. expected_channel .. "，清单为"
            .. (manifest_channel ~= "" and manifest_channel or "未标记")
    end
    if m.package_type ~= nil and tostring(m.package_type) ~= "full" then
        return nil, "更新清单不是全量包"
    end
    if #package_urls(m) == 0 then return nil, "更新清单缺少安装包地址" end
    local expected = tostring(m.sha256 or ""):lower():gsub("%s+", "")
    if expected == "" then return nil, "更新清单缺少 SHA-256" end
    return true
end

-- ===== Artifact management =====

local function update_artifact_kind(path)
    local name = tostring(path or ""):match("([^/]+)$") or ""
    if name:match("^stage%-") then return "stage" end
    if name:match("^backup%-") then return "backup" end
    if name:match("^inkstain%-.+%.zip$") then return "package" end
    return nil
end

local function path_inside(root, path)
    root = tostring(root or ""):gsub("/+$", "")
    path = tostring(path or "")
    return root ~= "" and path:sub(1, #root + 1) == root .. "/"
end

function Updater:_remove_download(path)
    if not path_inside(self.updates_dir, path) or update_artifact_kind(path) ~= "package" then return false end
    local removed, err = U.remove_tree(path)
    if not removed then
        logger.warn("[InkStain][Updater] unable to remove update package", tostring(path), tostring(err))
        return false
    end
    return true
end

function Updater:_cleanup_update_artifacts(protected)
    protected = type(protected) == "table" and protected or {}
    local removed = { stage = 0, backup = 0, package = 0 }
    for _, path in ipairs(U.list(self.updates_dir)) do
        local kind = update_artifact_kind(path)
        if kind and not protected[path] then
            local ok, err = U.remove_tree(path)
            if ok then
                removed[kind] = removed[kind] + 1
            else
                logger.warn("[InkStain][Updater] artifact cleanup failed", tostring(path), tostring(err))
            end
        end
    end
    if removed.stage + removed.backup + removed.package > 0 then
        logger.info("[InkStain][Updater] artifacts cleaned",
            "stage=", tostring(removed.stage),
            "backup=", tostring(removed.backup),
            "package=", tostring(removed.package))
    end
    return removed
end

-- ===== Pending state management (via G_reader_settings) =====

local UPDATE_STATE_KEY = "inkstain_update_state"

local function read_update_state()
    if not G_reader_settings then return {} end
    return G_reader_settings:readSetting(UPDATE_STATE_KEY, {}) or {}
end

local function save_update_state(v)
    if not G_reader_settings then return end
    G_reader_settings:saveSetting(UPDATE_STATE_KEY, v or {})
    if G_reader_settings.flush then G_reader_settings:flush() end
end

-- ===== Check for updates =====

function Updater:check()
    local urls = self:manifest_urls()
    if #urls == 0 then return nil, "更新地址未配置" end
    local errors = {}
    local fallback
    for _, url in ipairs(urls) do
        local ok, m = pcall(function()
            return self.http:get_json(url, { retries = 1, redirects = 8, timeout = { 15, 45 } })
        end)
        if ok and type(m) == "table" then
            local valid, reason = validate_manifest(m)
            if valid then
                local cleaned, text_error = clean_manifest_text(m)
                if not cleaned then
                    fallback = fallback or U.copy(m)
                    fallback.notes = "更新说明显示异常 可继续下载安装"
                    fallback.summary = fallback.notes
                    fallback.name = tostring(m.name or "")
                    errors[#errors + 1] = text_error
                    logger.warn("[InkStain][Updater] manifest text rejected", url,
                        "replacement_chars=", tostring(U.replacement_char_count(m.notes or "")),
                        "reason=", tostring(text_error))
                else
                    m.notes = cleaned.notes
                    m.summary = cleaned.summary
                    if cleaned.name ~= nil then m.name = cleaned.name end
                    logger.info("[InkStain][Updater] manifest loaded", url,
                        "version=", tostring(m.version), "notes_utf8_valid=true")
                    if not U.semver_newer(m.version, self.version) then
                        return { current = true, version = m.version, name = m.name, notes = m.notes }
                    end
                    return m
                end
            else
                errors[#errors + 1] = reason
            end
        else
            errors[#errors + 1] = tostring(m or "无法读取更新清单")
            logger.warn("[InkStain][Updater] manifest failed", url, tostring(m))
        end
    end
    if fallback then
        if not U.semver_newer(fallback.version, self.version) then
            return { current = true, version = fallback.version, name = fallback.name, notes = fallback.notes }
        end
        return fallback
    end
    return nil, errors[#errors] or "无法读取更新清单"
end

-- ===== Download with SHA-256 + size verification =====

local function file_bytes(path)
    local data = U.read_file(path, true)
    if type(data) ~= "string" then return nil end
    return data
end

local function download_one(self, url, path)
    os.remove(path)
    local ok, data = pcall(function()
        return self.http:download(url, { retries = 2, redirects = 10, timeout = { 20, 150 } })
    end)
    if ok and type(data) == "string" and #data > 0 then
        local wrote, err = U.atomic_write(path, data, true)
        if not wrote then return nil, err or "无法保存更新包" end
        return true
    end
    logger.warn("[InkStain][Updater] Lua download unavailable or empty; using curl", url, tostring(data))
    if curl_download(url, path) then
        local raw = file_bytes(path)
        if type(raw) == "string" and #raw > 0 then return true end
    end
    return nil, tostring(data or "下载失败")
end

function Updater:download(manifest)
    local pending = read_update_state()
    if pending.pending then error("上次更新尚未确认，请完整重启 KOReader 后再更新") end
    self:_cleanup_update_artifacts()
    local urls = package_urls(manifest)
    if #urls == 0 then error("更新包地址无效") end
    local p = self.updates_dir .. "/inkstain-" .. U.id_name(manifest.version) .. ".zip"
    local expected = tostring(manifest.sha256 or ""):lower():gsub("%s+", "")
    if expected == "" then error("更新清单缺少 SHA-256") end
    local expected_size = tonumber(manifest.size or manifest.bytes or manifest.package_size)
    local last_error = "下载失败"

    for index, url in ipairs(urls) do
        local downloaded, err = download_one(self, url, p)
        local raw = downloaded and file_bytes(p) or nil
        if type(raw) == "string" and #raw > 0 then
            if expected_size and expected_size > 0 and #raw ~= expected_size then
                last_error = "更新包大小不符"
                logger.warn("[InkStain][Updater] size mismatch", url,
                    "expected=", tostring(expected_size), "actual=", tostring(#raw))
            else
                local actual = Digests.sha256(raw):lower()
                if actual == expected then
                    logger.info("[InkStain][Updater] package downloaded",
                        "source=", tostring(index), "bytes=", tostring(#raw),
                        "version=", tostring(manifest.version))
                    return p
                end
                last_error = "更新包校验失败"
                logger.warn("[InkStain][Updater] sha256 mismatch", url)
            end
        else
            last_error = err or "更新包下载失败或文件为空"
        end
        os.remove(p)
    end
    error(last_error)
end

-- ===== Install: stage → backup → replace → verify → rollback =====

local function safe_relative(rel)
    if type(rel) ~= "string" or rel == "" or rel:sub(1, 1) == "/" or rel:find("\\", 1, true) then return nil end
    for part in rel:gmatch("[^/]+") do
        if part == ".." or part == "." or part == "" then return nil end
    end
    return rel
end

function Updater:install(path, manifest)
    local pending = read_update_state()
    if pending.pending then
        self:_remove_download(path)
        return nil, "上次更新尚未确认，请完整重启 KOReader 后再更新"
    end
    self:_cleanup_update_artifacts({ [path] = true })

    local stamp = tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999))
    local stage = self.updates_dir .. "/stage-" .. stamp
    local unpacked = stage .. "/unpacked"
    local backup = self.updates_dir .. "/backup-" .. stamp
    U.remove_tree(stage)
    U.remove_tree(backup)
    U.mkdir(unpacked)

    local function fail(message)
        U.remove_tree(stage)
        U.remove_tree(backup)
        self:_remove_download(path)
        return nil, message
    end

    -- Step 1: Unzip
    local rc = os.execute("unzip -q " .. U.shell_quote(path) .. " -d " .. U.shell_quote(unpacked) .. " 2>/dev/null")
    if not command_ok(rc) then
        -- Fallback: try KOReader's Archiver
        local Archiver = require("ffi/archiver")
        local arc = Archiver.Reader:new()
        if arc:open(path) then
            for entry in arc:iterate() do
                if entry.mode == "file" then
                    local dest = unpacked .. "/" .. entry.path
                    local parent = dest:match("^(.*)/[^/]+$")
                    if parent then U.mkdir(parent) end
                    arc:extractToPath(entry.path, dest)
                end
            end
            arc:close()
        else
            return fail("解压更新包失败")
        end
    end

    -- Step 2: Validate package structure
    local incoming = unpacked .. "/" .. Config.PLUGIN_DIR
    if not U.file_exists(incoming .. "/main.lua") or not U.file_exists(incoming .. "/_meta.lua") then
        return fail("更新包缺少 " .. Config.PLUGIN_DIR .. " 或插件文件不完整")
    end

    -- Step 3: Verify version and channel from incoming files
    local incoming_main = U.read_file(incoming .. "/main.lua", true) or ""
    local incoming_version = incoming_main:match('PLUGIN_VERSION%s*=%s*["\']([^"\']+)["\']')
    local incoming_updater = U.read_file(incoming .. "/updater.lua", true) or ""
    local incoming_channel = incoming_updater:match('UPDATE_CHANNEL%s*=%s*["\']([^"\']+)["\']') or "stable"
    if tostring(incoming_version or "") ~= tostring(manifest.version or "") then
        return fail("更新包版本与清单不一致")
    end
    if tostring(incoming_channel) ~= tostring(Config.UPDATE_CHANNEL or "stable") then
        return fail("更新包通道不匹配，已拒绝安装")
    end

    -- Step 4: Verify single root directory
    local roots = U.list(unpacked)
    if #roots ~= 1 or roots[1] ~= incoming then
        return fail("更新包根目录必须只包含 " .. Config.PLUGIN_DIR)
    end

    -- Step 5: Backup current plugin
    local ok, e = U.copy_tree(self.plugin_root, backup)
    if not ok then return fail("备份当前插件失败：" .. tostring(e)) end

    -- Step 6: Rollback helper
    local function rollback(message)
        U.remove_tree(self.plugin_root)
        local restored, re = U.copy_tree(backup, self.plugin_root)
        U.remove_tree(stage)
        self:_remove_download(path)
        if not restored then
            return nil, tostring(message) .. "；回滚也失败：" .. tostring(re) .. "；备份已保留在 " .. tostring(backup)
        end
        U.remove_tree(backup)
        return nil, tostring(message) .. "；已恢复旧版本"
    end

    -- Step 7: Replace plugin tree
    U.remove_tree(self.plugin_root)
    local moved = os.rename(incoming, self.plugin_root)
    if not moved then
        local copied, ce = U.copy_tree(incoming, self.plugin_root)
        if not copied then return rollback("安装新文件失败：" .. tostring(ce)) end
    end

    -- Step 8: Verify installation
    if not U.file_exists(self.plugin_root .. "/main.lua") or not U.file_exists(self.plugin_root .. "/_meta.lua") then
        return rollback("安装后的插件文件不完整")
    end

    -- Step 9: Process delete_list (compat with old manifests)
    if type(manifest.delete_list) == "table" then
        for _, rel in ipairs(manifest.delete_list) do
            rel = safe_relative(rel)
            if not rel then return rollback("delete_list 包含不安全路径") end
            local target = self.plugin_root .. "/" .. rel
            local removed = U.remove_tree(target)
            if removed == false then return rollback("无法删除旧文件：" .. rel) end
        end
    end

    -- Step 10: Persist pending state
    U.remove_tree(stage)
    save_update_state({
        pending = true,
        expected = manifest.version,
        backup = backup,
        package = path,
        installed_at = os.time(),
    })
    logger.info("[InkStain][Updater] update installed",
        "version=", tostring(manifest.version),
        "backup=", tostring(backup),
        "package=", tostring(path))
    return true
end

-- ===== Startup confirmation (cross-restart pending state check) =====

function Updater:startup()
    local s = read_update_state()
    if not s.pending then
        self:_cleanup_update_artifacts()
        return nil
    end

    -- Version matches: update was confirmed by restart
    if tostring(s.expected) == tostring(self.version) then
        if s.backup then U.remove_tree(s.backup) end
        if s.package then self:_remove_download(s.package) end
        save_update_state({})
        self:_cleanup_update_artifacts()
        logger.info("[InkStain][Updater] update confirmed; rollback files removed",
            "version=", tostring(self.version))
        return "updated"
    end

    -- Version mismatch: files replaced but still running old code
    local protected = {}
    if type(s.backup) == "string" and s.backup ~= "" then protected[s.backup] = true end
    if type(s.package) == "string" and s.package ~= "" then protected[s.package] = true end
    self:_cleanup_update_artifacts(protected)
    logger.warn("[InkStain][Updater] update still pending",
        "expected=", tostring(s.expected),
        "running=", tostring(self.version))
    return "mismatch"
end

-- ===== Cancel (for suspend/resume handling) =====

function Updater:cancel(reason)
    logger.info("[InkStain][Updater] cancelled", tostring(reason or "unknown"))
end

-- ===== Export Config for external access =====

Updater.Config = Config
Updater.AUTO_UPDATE_INTERVAL = Config.AUTO_UPDATE_INTERVAL
Updater.AUTO_UPDATE_RETRY_INTERVAL = Config.AUTO_UPDATE_RETRY_INTERVAL

return Updater

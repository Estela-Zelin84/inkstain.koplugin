-- Subprocess async worker (ported from miuread/async.lua)
-- Runs blocking I/O (HTTP, download) in a forked subprocess so the UI thread
-- never blocks. The UI thread polls isSubProcessDone every poll_interval seconds.

local FFIUtil = require("ffi/util")
local Json = require("json") -- inkstain json.lua wrapper
local UIManager = require("ui/uimanager")
local logger = require("logger")

local Async = {}
Async.__index = Async

function Async:new(temp_dir, options)
    options = options or {}
    return setmetatable({
        temp_dir = temp_dir,
        job = nil,
        poll = nil,
        poll_interval = tonumber(options.poll_interval) or 0.30,
        allow_android = options.allow_android == true,
        disable_fallback = options.disable_fallback == true,
    }, self)
end

function Async:is_android()
    return type(FFIUtil.isAndroid) == "function" and FFIUtil.isAndroid() == true
end

function Async:available()
    local android = self:is_android()
    return type(FFIUtil.runInSubProcess) == "function"
        and type(FFIUtil.isSubProcessDone) == "function"
        and (self.allow_android or not android)
end

function Async:busy()
    return self.job ~= nil
end

function Async:_schedule()
    if self.poll then return end
    local task
    task = function()
        if self.poll ~= task then return end
        self.poll = nil
        self:_check()
    end
    self.poll = task
    UIManager:scheduleIn(self.poll_interval, task)
end

function Async:_check()
    local j = self.job
    if not j then return end

    -- Timeout check
    if os.time() - j.started > j.timeout then
        pcall(FFIUtil.terminateSubProcess, j.pid)
        j.timedout = true
    end

    local ok, done = pcall(FFIUtil.isSubProcessDone, j.pid, false)
    if ok and not done and not j.timedout then
        self:_schedule()
        return
    end

    -- Read result from temp file
    local f = io.open(j.path, "rb")
    local raw = f and f:read("*a") or nil
    if f then f:close() end
    os.remove(j.path)
    os.remove(j.path .. ".tmp")
    self.job = nil

    local result
    if j.timedout then
        result = { ok = false, error = "worker timeout" }
    elseif not raw or raw == "" then
        result = { ok = false, error = "worker returned no result" }
    else
        local good, decoded = pcall(Json.decode, raw)
        if good and type(decoded) == "table" then
            result = decoded
        else
            result = { ok = false, error = "worker result decode failed" }
        end
    end

    if j.callback then
        local cb_ok, cb_err = pcall(j.callback, result)
        if not cb_ok then
            logger.warn("[InkStain][Async] callback error:", tostring(cb_err))
        end
    end
end

function Async:cancel(reason)
    if self.poll then
        UIManager:unschedule(self.poll)
        self.poll = nil
    end
    if not self.job then return end
    local job = self.job
    job.callback = nil
    if job.pid then pcall(FFIUtil.terminateSubProcess, job.pid) end
    if job.path then os.remove(job.path); os.remove(job.path .. ".tmp") end
    self.job = nil
    logger.info("[InkStain][Async] cancelled:", tostring(reason or "unknown"))
end

function Async:run(label, fn, callback, timeout)
    if self.job then
        return false, "worker busy"
    end

    if not self:available() then
        if self.disable_fallback then
            return false, "worker unavailable"
        end
        -- Fallback: run synchronously (still blocks UI, but at least works)
        logger.warn("[InkStain][Async] subprocess unavailable, running synchronously:", label)
        local ok, x = pcall(fn)
        local result = ok and { ok = true, value = x } or { ok = false, error = tostring(x) }
        if callback then callback(result) end
        return true
    end

    local path = self.temp_dir .. "/worker-" .. tostring(os.time()) .. "-"
        .. tostring(math.random(10000, 99999)) .. ".json"

    local child = function()
        local ok, x = pcall(fn)
        local res = ok and { ok = true, value = x } or { ok = false, error = tostring(x) }
        local encoded = Json.encode(res)
        -- Atomic write: write to .tmp then rename
        local tmp = path .. ".tmp"
        local f = io.open(tmp, "wb")
        if f then
            f:write(encoded)
            f:close()
            os.rename(tmp, path)
        end
    end

    local ok, pid, err = pcall(FFIUtil.runInSubProcess, child, false, false)
    if not ok or not pid then
        return false, tostring(err or pid or "fork failed")
    end

    self.job = {
        pid = pid,
        path = path,
        label = label,
        callback = callback,
        started = os.time(),
        timeout = timeout or 70,
    }
    self:_schedule()
    return true
end

return Async

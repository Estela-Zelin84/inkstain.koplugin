-- JSON compatibility wrapper (ported from miuread/json.lua)
-- Tries require("json") first, then falls back to require("rapidjson").
-- Normalizes encode/decode vs stringify/parse API differences.

local ok, engine = pcall(require, "json")
if not ok then ok, engine = pcall(require, "rapidjson") end
if not ok then error("InkStain requires KOReader JSON support (json or rapidjson)") end

local Json = {}

function Json.encode(value)
    if engine.encode then return engine.encode(value) end
    if engine.stringify then return engine.stringify(value) end
    error("JSON encoder unavailable")
end

function Json.decode(value)
    if engine.decode then return engine.decode(value) end
    if engine.parse then return engine.parse(value) end
    error("JSON decoder unavailable")
end

return Json

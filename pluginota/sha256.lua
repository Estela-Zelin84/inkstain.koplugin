-- Streaming SHA-256 for Lua 5.1 / LuaJIT (KOReader).
-- Portions derived from the MiuRead updater digest helper; AGPL-3.0-only.
local bit = require("bit")

local band, bxor, bnot = bit.band, bit.bxor, bit.bnot
local rshift, ror = bit.rshift, bit.ror
local bor, lshift = bit.bor, bit.lshift

local UINT32 = 4294967296

local function u32(x)
    return band(x, 0xffffffff)
end

local function plus(...)
    local value = 0
    for i = 1, select("#", ...) do
        value = u32(value + select(i, ...))
    end
    return value
end

local function be32(s, pos)
    local a, b, c, d = s:byte(pos, pos + 3)
    return bor(lshift(a, 24), lshift(b, 16), lshift(c, 8), d)
end

local function behex(x)
    return string.format(
        "%02x%02x%02x%02x",
        band(rshift(x, 24), 255),
        band(rshift(x, 16), 255),
        band(rshift(x, 8), 255),
        band(x, 255)
    )
end

local function be64_from_bytes(byte_count)
    local bit_count = byte_count * 8
    local hi = math.floor(bit_count / UINT32)
    local lo = bit_count - hi * UINT32
    return string.char(
        band(rshift(hi, 24), 255),
        band(rshift(hi, 16), 255),
        band(rshift(hi, 8), 255),
        band(hi, 255),
        band(rshift(lo, 24), 255),
        band(rshift(lo, 16), 255),
        band(rshift(lo, 8), 255),
        band(lo, 255)
    )
end

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local INITIAL = {
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
}

local function compress(h, block)
    local w = {}
    for i = 0, 15 do
        w[i] = be32(block, 1 + i * 4)
    end
    for i = 16, 63 do
        local s0 = bxor(ror(w[i - 15], 7), ror(w[i - 15], 18), rshift(w[i - 15], 3))
        local s1 = bxor(ror(w[i - 2], 17), ror(w[i - 2], 19), rshift(w[i - 2], 10))
        w[i] = plus(w[i - 16], s0, w[i - 7], s1)
    end

    local a, b, c, d = h[1], h[2], h[3], h[4]
    local e, f, g, q = h[5], h[6], h[7], h[8]

    for i = 0, 63 do
        local s1 = bxor(ror(e, 6), ror(e, 11), ror(e, 25))
        local ch = bxor(band(e, f), band(bnot(e), g))
        local t1 = plus(q, s1, ch, K[i + 1], w[i])
        local s0 = bxor(ror(a, 2), ror(a, 13), ror(a, 22))
        local maj = bxor(band(a, b), band(a, c), band(b, c))
        local t2 = plus(s0, maj)
        q, g, f, e, d, c, b, a = g, f, e, plus(d, t1), c, b, a, plus(t1, t2)
    end

    h[1], h[2], h[3], h[4] = plus(h[1], a), plus(h[2], b), plus(h[3], c), plus(h[4], d)
    h[5], h[6], h[7], h[8] = plus(h[5], e), plus(h[6], f), plus(h[7], g), plus(h[8], q)
end

local Context = {}
Context.__index = Context

function Context:update(data)
    if self.finished then return nil, "SHA-256 context is already finalized" end
    data = tostring(data or "")
    if data == "" then return true end

    self.total_bytes = self.total_bytes + #data
    local input = self.buffer .. data
    local full = #input - (#input % 64)
    for pos = 1, full, 64 do
        compress(self.h, input:sub(pos, pos + 63))
    end
    self.buffer = input:sub(full + 1)
    return true
end

function Context:final()
    if self.digest then return self.digest end

    local zeros = (56 - ((self.total_bytes + 1) % 64)) % 64
    local tail = self.buffer .. string.char(0x80) .. string.rep("\0", zeros) .. be64_from_bytes(self.total_bytes)
    for pos = 1, #tail, 64 do
        compress(self.h, tail:sub(pos, pos + 63))
    end

    local out = {}
    for i = 1, 8 do out[i] = behex(self.h[i]) end
    self.digest = table.concat(out)
    self.finished = true
    self.buffer = ""
    return self.digest
end

local Sha256 = {}

function Sha256.new()
    return setmetatable({
        h = { unpack(INITIAL) },
        buffer = "",
        total_bytes = 0,
        finished = false,
    }, Context)
end

function Sha256.sha256(input)
    local context = Sha256.new()
    context:update(input)
    return context:final()
end

function Sha256.file(path, chunk_size)
    local handle, err = io.open(path, "rb")
    if not handle then return nil, err end

    local context = Sha256.new()
    chunk_size = tonumber(chunk_size) or 256 * 1024
    while true do
        local chunk = handle:read(chunk_size)
        if not chunk then break end
        local ok, update_err = context:update(chunk)
        if not ok then
            handle:close()
            return nil, update_err
        end
    end
    handle:close()
    return context:final()
end

return Sha256

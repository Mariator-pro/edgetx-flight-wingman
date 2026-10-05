-- =====================================================================
-- qr.lua  --  Minimal QR encoder for the position code in the Tools script.
-- =====================================================================
-- SD card path: /SCRIPTS/GPSHOMER/qr.lua
--
-- One symbol shape only: version 3 (29x29), ECC level L, byte mode, single
-- block, fixed data mask 2. That holds 53 bytes, enough for a map URL with
-- six decimals. Loaded on demand; the widget never needs it.
--
-- XOR runs off a nibble table (plain arithmetic, no bitwise operators needed).
-- A full encode is about 120,000 Lua instructions -- fine for a tool screen
-- built once, too slow to repeat per frame (the caller caches it). Widgets may
-- run only 20,000 per call: they use newJob/step, which spread the tables and
-- the encoding over many calls of a few thousand instructions each.
-- =====================================================================
-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 Mariator-pro
--
-- This program is free software; you can redistribute it and/or modify
-- it under the terms of the GNU General Public License version 2 as
-- published by the Free Software Foundation.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
-- =====================================================================

local M = {}

local SIZE     = 29     -- version 3
local DATA_CW  = 55     -- data codewords at ECC level L
local ECC_CW   = 15     -- error correction codewords
local MASK     = 2      -- data mask: invert where column % 3 == 0
local ALIGN    = 22     -- centre of the single alignment pattern

M.SIZE     = SIZE
M.CAPACITY = DATA_CW - 2   -- bytes: 55 codewords less mode/count/terminator

local floor = math.floor

-- ---------------------------------------------------------------------------
-- XOR without bit operators
-- ---------------------------------------------------------------------------

-- The tables are built on first use (see INIT below), not at load.
local XOR4 = {}
local function xorRow(a)
  local row = {}
  for b = 0, 15 do
    local r = 0
    for i = 0, 3 do
      local p = 2 ^ i
      if (floor(a / p) % 2) ~= (floor(b / p) % 2) then r = r + p end
    end
    row[b] = r
  end
  XOR4[a] = row
end

-- Bytes: two nibble lookups. The hot path in Reed-Solomon.
local function xorByte(a, b)
  return XOR4[floor(a / 16)][floor(b / 16)] * 16 + XOR4[a % 16][b % 16]
end

-- Any width, for the Galois field build and the 15-bit format string.
local function xorN(a, b)
  local r, mul = 0, 1
  while a > 0 or b > 0 do
    r   = r + XOR4[a % 16][b % 16] * mul
    a   = floor(a / 16)
    b   = floor(b / 16)
    mul = mul * 16
  end
  return r
end

-- ---------------------------------------------------------------------------
-- GF(256) tables and the generator polynomial, built once on first use
-- ---------------------------------------------------------------------------

local EXP, LOG = {}, {}
local gfX
-- Powers from..to; from = 0 starts over.
local function buildGF(from, to)
  if from == 0 then gfX = 1 end
  for i = from, to do
    EXP[i] = gfX
    LOG[gfX] = i
    gfX = gfX * 2
    if gfX > 255 then gfX = xorN(gfX, 285) end   -- 0x11D
  end
end

local function gmul(a, b)
  if a == 0 or b == 0 then return 0 end
  return EXP[(LOG[a] + LOG[b]) % 255]
end

-- Product of (x - a^i) for i = 0..ECC_CW-1, coefficients highest power first.
local GEN
local function buildGen()
  GEN = { 1 }
  for i = 0, ECC_CW - 1 do
    GEN[#GEN + 1] = 0
    local prev = 0
    for j = 1, #GEN do
      local cur = GEN[j]
      GEN[j] = xorByte(cur, gmul(prev, EXP[i]))
      prev = cur
    end
  end
end

-- Table build in slices (four XOR rows each, GF in halves, then the generator).
local tablesReady = false
local INIT = {}
for a0 = 0, 15, 4 do
  INIT[#INIT + 1] = function() for a = a0, a0 + 3 do xorRow(a) end end
end
INIT[#INIT + 1] = function() buildGF(0, 127) end
INIT[#INIT + 1] = function() buildGF(128, 254) end
INIT[#INIT + 1] = function() buildGen(); tablesReady = true end

-- ---------------------------------------------------------------------------
-- Data codewords
-- ---------------------------------------------------------------------------

-- Bit stream -> codewords: mode 0100, 8-bit length, payload, terminator, pad.
local function dataCodewords(text)
  local bits = {}
  local function push(value, count)
    for i = count - 1, 0, -1 do
      bits[#bits + 1] = floor(value / 2 ^ i) % 2
    end
  end

  push(4, 4)            -- byte mode
  push(#text, 8)        -- character count (versions 1..9)
  for i = 1, #text do push(string.byte(text, i), 8) end
  push(0, math.min(4, DATA_CW * 8 - #bits))        -- terminator
  while #bits % 8 ~= 0 do bits[#bits + 1] = 0 end  -- to a whole codeword

  local cw = {}
  for i = 1, #bits, 8 do
    local byte = 0
    for j = 0, 7 do byte = byte * 2 + bits[i + j] end
    cw[#cw + 1] = byte
  end
  local pad, other = 236, 17                       -- 0xEC / 0x11, alternating
  while #cw < DATA_CW do
    cw[#cw + 1] = pad
    pad, other  = other, pad
  end
  return cw
end

-- Reed-Solomon remainder of the data codewords over GEN, for data codewords
-- from..to (rem starts as ECC_CW zeros).
local function eccSlice(data, rem, from, to)
  for i = from, to do
    local factor = xorByte(data[i], rem[1])
    table.remove(rem, 1)
    rem[ECC_CW] = 0
    for j = 1, ECC_CW do
      rem[j] = xorByte(rem[j], gmul(GEN[j + 1], factor))
    end
  end
end

-- ---------------------------------------------------------------------------
-- Matrix
-- ---------------------------------------------------------------------------

-- m and fn are 0-based [row][col]; fn marks the function patterns, which carry
-- no data and are never masked.
local function newMatrix()
  local m, fn = {}, {}
  for r = 0, SIZE - 1 do
    m[r], fn[r] = {}, {}
    for c = 0, SIZE - 1 do m[r][c], fn[r][c] = 0, false end
  end
  return m, fn
end

local function setFn(m, fn, r, c, v)
  if r < 0 or c < 0 or r >= SIZE or c >= SIZE then return end
  m[r][c]  = v
  fn[r][c] = true
end

-- 7x7 finder plus the one-module separator around it.
local function finder(m, fn, r0, c0)
  for dr = -1, 7 do
    for dc = -1, 7 do
      local ring = math.max(math.abs(dr - 3), math.abs(dc - 3))
      local dark = (ring ~= 2 and ring <= 3) and 1 or 0
      setFn(m, fn, r0 + dr, c0 + dc, dark)
    end
  end
end

local function finders(m, fn)
  finder(m, fn, 0, 0)
  finder(m, fn, 0, SIZE - 7)
  finder(m, fn, SIZE - 7, 0)
end

-- Timing lines, alignment pattern and dark module.
local function otherPatterns(m, fn)
  for i = 8, SIZE - 9 do                       -- timing lines
    local dark = (i % 2 == 0) and 1 or 0
    setFn(m, fn, 6, i, dark)
    setFn(m, fn, i, 6, dark)
  end

  for dr = -2, 2 do                            -- alignment pattern
    for dc = -2, 2 do
      local ring = math.max(math.abs(dr), math.abs(dc))
      setFn(m, fn, ALIGN + dr, ALIGN + dc, (ring ~= 1) and 1 or 0)
    end
  end

  setFn(m, fn, SIZE - 8, 8, 1)                 -- dark module
end

-- 15-bit format string: 5 data bits (ECC level + mask) plus BCH(15,5), masked.
local function formatBits()
  local data = 8 + MASK      -- 01 = level L, then the mask number
  local rem  = data
  for _ = 1, 10 do
    rem = rem * 2
    if rem >= 1024 then rem = xorN(rem, 1335) end   -- 0x537
  end
  return xorN(data * 1024 + rem, 21522)             -- 0x5412
end

local function placeFormat(m, fn)
  local bits = formatBits()
  for i = 0, 14 do
    local bit = floor(bits / 2 ^ i) % 2
    -- copy around the top-left finder
    if i < 6 then
      setFn(m, fn, i, 8, bit)
    elseif i < 8 then
      setFn(m, fn, i + 1, 8, bit)
    elseif i == 8 then
      setFn(m, fn, 8, 7, bit)        -- column 6 is the timing line, so skip it
    else
      setFn(m, fn, 8, 14 - i, bit)
    end
    -- second copy, split over the other two finders
    if i < 8 then
      setFn(m, fn, 8, SIZE - 1 - i, bit)
    else
      setFn(m, fn, SIZE - 15 + i, 8, bit)
    end
  end
end

-- Zigzag placement, two columns at a time from the bottom right, skipping the
-- vertical timing line. The mask is applied here: it covers every non-function
-- module, and the zigzag visits exactly those (cells past the last bit stay 0
-- and are masked all the same). st = { col, bit } carries on over calls; pairs
-- limits the column pairs per call. Returns true when done.
local function placeData(m, fn, cw, st, pairs)
  local bit, total = st.bit, #cw * 8
  local col = st.col
  while col > 0 and pairs > 0 do
    pairs = pairs - 1
    if col == 6 then col = 5 end
    for vert = 0, SIZE - 1 do
      for j = 0, 1 do
        local c       = col - j
        local upward  = (floor((col + 1) / 2) % 2) == 0
        local r       = upward and (SIZE - 1 - vert) or vert
        if not fn[r][c] then
          local v = 0
          if bit < total then
            local byte = cw[floor(bit / 8) + 1]
            v = floor(byte / 2 ^ (7 - bit % 8)) % 2
            bit = bit + 1
          end
          if c % 3 == 0 then v = 1 - v end      -- mask 2
          m[r][c] = v
        end
      end
    end
    col = col - 2
  end
  st.col, st.bit = col, bit
  return col <= 0
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

local ECC_SLICE   = 10   -- data codewords per step
local PLACE_PAIRS = 2    -- column pairs per step

-- Encoder job for step(), or nil and a reason when the text does not fit.
function M.newJob(text)
  if type(text) ~= "string" or #text == 0 then return nil, "empty" end
  if #text > M.CAPACITY then return nil, "too long" end
  return { text = text, phase = "init", init = 1 }
end

-- One slice of work (at most about 8,000 Lua instructions, so a widget keeps
-- most of its 20,000 per call for drawing). Returns the code
-- { size, rows } once finished, nil before.
function M.step(job)
  local p = job.phase
  if p == "init" then
    if tablesReady then
      job.phase = "data"
    else
      INIT[job.init]()
      job.init = job.init + 1
    end
  elseif p == "data" then
    job.data = dataCodewords(job.text)
    job.rem = {}
    for i = 1, ECC_CW do job.rem[i] = 0 end
    job.next, job.phase = 1, "ecc"
  elseif p == "ecc" then
    local to = math.min(job.next + ECC_SLICE - 1, DATA_CW)
    eccSlice(job.data, job.rem, job.next, to)
    job.next = to + 1
    if job.next > DATA_CW then
      for i = 1, ECC_CW do job.data[DATA_CW + i] = job.rem[i] end
      job.phase = "matrix"
    end
  elseif p == "matrix" then
    job.m, job.fn = newMatrix()
    job.phase = "patterns"
  elseif p == "patterns" then
    finders(job.m, job.fn)
    job.phase = "format"
  elseif p == "format" then
    otherPatterns(job.m, job.fn)
    placeFormat(job.m, job.fn)
    job.place, job.phase = { col = SIZE - 1, bit = 0 }, "place"
  elseif p == "place" then
    if placeData(job.m, job.fn, job.data, job.place, PLACE_PAIRS) then job.phase = "rows" end
  elseif p == "rows" then
    local rows = {}
    for r = 0, SIZE - 1 do
      local cells = {}
      for c = 0, SIZE - 1 do cells[c + 1] = job.m[r][c] end
      rows[r + 1] = table.concat(cells)
    end
    job.code, job.phase = { size = SIZE, rows = rows }, "done"
    job.data, job.rem, job.m, job.fn, job.place = nil, nil, nil, nil, nil
  end
  return job.code
end

-- Whole encode in one call. Returns { size, rows } with one "0"/"1" string per
-- row (1-based), or nil and a reason when the text does not fit.
function M.encode(text)
  local job, why = M.newJob(text)
  if not job then return nil, why end
  local code
  repeat code = M.step(job) until code
  return code
end

-- Dark runs per row as { row, firstCol, length } with 1-based coordinates.
-- Drawing one rectangle per run instead of per module keeps the redraw cheap.
function M.runs(code)
  local out = {}
  for r = 1, code.size do
    local row, c = code.rows[r], 1
    while true do
      local s, e = string.find(row, "1+", c)
      if not s then break end
      out[#out + 1] = { r, s, e - s + 1 }
      c = e + 1
    end
  end
  return out
end

return M

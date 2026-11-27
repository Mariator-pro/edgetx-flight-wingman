-- =====================================================================
-- switches.lua  --  Switch page data for Flight Wingman (no lcd.*).
-- =====================================================================
-- SD card path: /SCRIPTS/WINGMAN/switches.lua
--
-- Loaded by the Wingman core only while the switch page is open. Reads the
-- radio's toggle switches, the channel each one drives (simple mixes only),
-- the special functions on each position and, from the modes the FC sent
-- (stored per model), which modes each position switches on.
-- =====================================================================
-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 Mariator-pro
-- =====================================================================

local M = {}

local LETTERS   = "ABCDEFGHIJKL"   -- SA.., hardware switch index = letter index
local CHANNELS  = 16               -- CRSF carries 16 channels
local MAX_INPUTS = 32              -- input sources are 1..32 in the source list
local MAX_SF    = 64
local ROW_SLOTS = 4                -- two cards left, two right
local BUTTONS   = 6                -- customisable switches SW1..SW6
local BUTTON_ROW = 3               -- button cards per row

-- Card slots per radio as seen by the pilot: shoulder switches on top, front
-- switches below, each side from the outside in. Other radios: alphabetical.
local MK3 = { { "SF", "SE", "SG", "SH" }, { "SA", "SB", "SC", "SD" } }
local LAYOUTS = {
  { "^tx16s", MK3 },   -- TX16S and TX16S MK3
  { "^tx15",  { { "SE", false, false, "SF" }, { "SA", "SB", "SC", "SD" } } },
}

-- Special function types (EdgeTX Functions enum) as short names; nil: generic.
local SF_NAMES = { [0] = "Override", "Trainer", "Trim", "Reset", "Set timer", "GVar", "Volume", "Failsafe",
  "Range check", "Bind", "Sound", "Play", "Say", "Script", "Music", "Music pause", "Vario", "Haptic", "Logs",
  "Backlight", "Screenshot", "Racing mode", "Touch off", "Screen", "Amp off", "LED" }
local SF_OVERRIDE, SF_RESET, SF_SET_TIMER, SF_GVAR = 0, 3, 4, 5
local SF_PLAY, SF_SAY, SF_SCRIPT, SF_LED = 11, 12, 13, 25
local TIMERS = 3

-- Short name of a special function with its main target ("Reset T1", "Play: armed").
function M.sfName(cf)
  local f, p = cf.func, cf.param or 0
  local base = SF_NAMES[f] or "Function"
  if f == SF_RESET then
    if p < TIMERS then return "Reset T" .. (p + 1) end
    if p == TIMERS then return "Reset flight" end
    if p == TIMERS + 1 then return "Reset telem" end
    if p == TIMERS + 2 then return "Reset trims" end
    return "Reset sensor"
  end
  if f == SF_SET_TIMER then return "Set T" .. (p + 1) end
  if f == SF_OVERRIDE then return "Override CH" .. (p + 1) end
  if f == SF_GVAR then return "GVar " .. (p + 1) end
  if (f == SF_PLAY or f == SF_SCRIPT or f == SF_LED) and cf.name and cf.name ~= "" then
    return base .. ": " .. cf.name
  end
  if f == SF_SAY and getSourceName then
    local n = getSourceName(p)
    if n and n ~= "" then return "Say: " .. string.gsub(n, "^[\128-\255]+", "") end
  end
  return base
end

-- Fallback position marks when the radio's own names are not available.
local SYMBOLS = { "^", "-", "v" }

-- Toggle switches and customisable switches (buttons, n 1..6, only with a type
-- set in the model) of the radio: { key = "SA", id = source index, name = shown
-- name (a custom name), button = n, pos = { { idx, sym, s } } } with the switch
-- position index, its mark and the stick value -100/0/100.
local function addSwitch(out, key, id, k, button)
  local sw = { key = key, id = id, name = key, button = button, pos = {} }
  for p = 1, 3 do
    local idx = 3 * k + p   -- position index: switch * 3 + up/mid/down, from 1
    local n = getSwitchName and getSwitchName(idx)
    if n then
      local base = string.gsub(n, "[\128-\255%-]+$", "")
      if base ~= "" then sw.name = base end
      local sym = string.sub(n, #base + 1)
      sw.pos[#sw.pos + 1] = { idx = idx, sym = (sym ~= "") and sym or SYMBOLS[p], s = (p - 2) * 100 }
    end
  end
  if #sw.pos > 0 then out[#out + 1] = sw end
end

function M.scan()
  local out = {}
  if not getFieldInfo then return out end
  for k = 1, #LETTERS do
    local key = "S" .. string.sub(LETTERS, k, k)
    local fi = getFieldInfo(string.lower(key))
    if fi and fi.id then addSwitch(out, key, fi.id, k - 1) end
  end
  -- Buttons by name; their switch index counts from SA's source index.
  local first = getFieldInfo("sa")
  for n = 1, BUTTONS do
    local fi = first and first.id and getFieldInfo("sw" .. n)
    if fi and fi.id and fi.id > first.id then addSwitch(out, "SW" .. n, fi.id, fi.id - first.id, n) end
  end
  return out
end

-- The one mix line of a channel that takes a switch: weight and offset applied
-- to the switch value (-100/0/100), through an input with a single line too.
local function plainNumber(v) return type(v) == "number" and v > -1024 and v < 1024 end

-- Mix lines of all channels, read once: { [ch] = { { mix, input, inputs } } }
-- with the first line of the input a mix takes and that input's line count.
function M.mixLines()
  local out = {}
  if not (model and model.getMixesCount) then return out end
  for ch = 0, CHANNELS - 1 do
    local t = {}
    for i = 0, (model.getMixesCount(ch) or 0) - 1 do
      local l = model.getMix(ch, i)
      if l then
        local e = { mix = l }
        if l.source and l.source >= 1 and l.source <= MAX_INPUTS and model.getInput and model.getInputsCount then
          e.inputs = model.getInputsCount(l.source - 1) or 0
          e.input = e.inputs > 0 and model.getInput(l.source - 1, 0) or nil
        end
        t[#t + 1] = e
      end
    end
    out[ch] = t
  end
  return out
end

-- Channel use of a switch: { ch = 1.., simple = { w1, o1, w2, o2 } or nil, out =
-- the channel's output stage, name = mix line name } from the line hit that
-- takes it on channel ch (0..) with the lines t. An output curve makes the
-- channel custom.
local function chanInfo(sw, ch, hit, t)
  local l, inp = hit.mix, hit.input
  local c = { ch = ch + 1, name = (l.name ~= "") and l.name or nil }
  local simple = #t == 1 and (l.switch or 0) == 0 and plainNumber(l.weight) and plainNumber(l.offset)
  if simple and l.source ~= sw.id then
    simple = inp and inp.source == sw.id and (inp.switch or 0) == 0 and hit.inputs == 1
      and plainNumber(inp.weight) and plainNumber(inp.offset)
  end
  local o = simple and model.getOutput and model.getOutput(ch)
  if o and o.curve then simple = false end
  if simple then
    c.simple = { l.weight, l.offset, inp and l.source ~= sw.id and inp.weight or 100,
                 inp and l.source ~= sw.id and inp.offset or 0 }
    c.out = o or nil
  end
  return c
end

-- Channel use of all switches in one pass over the mix lines: { [sw] = chanInfo }
-- from the first channel with a line that takes the switch (as source or one of
-- its positions as condition, also through the line's input), the last such
-- line there. Switches no channel takes are missing.
function M.channels(sws, lines)
  local bySrc, byPos = {}, {}
  for _, sw in ipairs(sws) do
    bySrc[sw.id] = sw
    for _, p in ipairs(sw.pos) do byPos[p.idx] = sw end
  end
  local found = {}   -- sw -> { ch, line }
  local function mark(sw, ch, e)
    if not sw then return end
    local f = found[sw]
    if not f then found[sw] = { ch, e } elseif f[1] == ch then f[2] = e end
  end
  for ch = 0, CHANNELS - 1 do
    for _, e in ipairs(lines[ch] or {}) do
      local l, inp = e.mix, e.input
      if l.source then mark(bySrc[l.source], ch, e) end
      mark(byPos[math.abs(l.switch or 0)], ch, e)
      if inp then
        if inp.source then mark(bySrc[inp.source], ch, e) end
        mark(byPos[math.abs(inp.switch or 0)], ch, e)
      end
    end
  end
  local out = {}
  for sw, f in pairs(found) do out[sw] = chanInfo(sw, f[1], f[2], lines[f[1]]) end
  return out
end

-- Special functions per position index: { [idx] = { "Reset T1", ... } }.
function M.functions()
  local out = {}
  if not (model and model.getCustomFunction) then return out end
  for i = 0, MAX_SF - 1 do
    local cf = model.getCustomFunction(i)
    if cf and cf.active ~= 0 and (cf.switch or 0) > 0 then
      local t = out[cf.switch] or {}
      t[#t + 1] = M.sfName(cf)
      out[cf.switch] = t
    end
  end
  return out
end

-- Card rows for the radio, ROW_SLOTS per row: a known radio only its toggle
-- switches in their slots, others alphabetically; never the buttons (their own
-- page, buttonRows).
-- radio: getVersion's radio name.
function M.rows(sws, radio)
  local byKey = {}
  for _, sw in ipairs(sws) do byKey[sw.key] = sw end
  local layout
  for _, l in ipairs(LAYOUTS) do
    if radio and string.find(radio, l[1]) then layout = l[2]; break end
  end
  local rows = {}
  if layout then
    for _, r in ipairs(layout) do
      local row, any = {}, false
      for i = 1, ROW_SLOTS do
        local sw = r[i] and byKey[r[i]]
        row[i] = sw or false
        if sw then any = true end
      end
      if any then rows[#rows + 1] = row end
    end
    return rows
  end
  local row
  for _, sw in ipairs(sws) do
    if not sw.button and not string.find(sw.name, "^SW%d") then
      if not row or #row == ROW_SLOTS then row = {}; rows[#rows + 1] = row end
      row[#row + 1] = sw
    end
  end
  return rows
end

-- Button rows, BUTTON_ROW per row in the radio's order (SW1..SW3 over
-- SW4..SW6), a button without a type in its slot as false; nil without any.
function M.buttonRows(sws)
  local byN, any = {}, false
  for _, sw in ipairs(sws) do
    if sw.button then byN[sw.button], any = sw, true end
  end
  if not any then return nil end
  local rows = {}
  for r = 0, BUTTONS / BUTTON_ROW - 1 do
    local row, used = {}, false
    for i = 1, BUTTON_ROW do
      row[i] = byN[r * BUTTON_ROW + i] or false
      used = used or row[i] ~= false
    end
    if used then rows[#rows + 1] = row end
  end
  return rows
end

-- Static part, read when the page opens, one step per call (each a few
-- thousand instructions: the widget shares its budget with drawing): the
-- switches, the mix lines, the special functions. b holds the steps' results;
-- returns the static data once all are in, else nil.
function M.buildStep(b, radio)
  if not b.sws then b.sws = M.scan(); return nil end
  if not b.lines then b.lines = M.mixLines(); return nil end
  local sf, chans = M.functions(), M.channels(b.sws, b.lines)
  for _, sw in ipairs(b.sws) do
    sw.chan = chans[sw]
    for _, p in ipairs(sw.pos) do
      p.sf = sf[p.idx] and table.concat(sf[p.idx], ", ") or nil
      -- A leading "Play: " becomes the speaker glyph on the card.
      if p.sf and string.sub(p.sf, 1, 6) == "Play: " then p.sf, p.play = string.sub(p.sf, 7), true end
    end
  end
  return { rows = M.rows(b.sws, radio), buttons = M.buttonRows(b.sws) }
end

-- Card rows of a page: 1 the toggle switches, 2 the buttons.
local function pageRows(static, page)
  return page == 2 and static.buttons or static.rows
end

-- What the view of a page depends on besides the stored modes: every switch
-- value and the channel it drives. A new view is built only when this changes.
function M.stateKey(static, page)
  local t = {}
  for _, row in ipairs(pageRows(static, page)) do
    for _, sw in ipairs(row) do
      if sw then
        t[#t + 1] = getValue(sw.id) or 0
        if sw.chan then t[#t + 1] = getValue("ch" .. sw.chan.ch) or 0 end
      end
    end
  end
  return table.concat(t, ",")
end

-- Channel value -100..100 in µs as the FC sees it over CRSF (±100 % = ±512 µs).
local function us(pct) return 1500 + pct * 5.12 end

-- The ranges grouped by AUX channel, built once per ranges table.
local byAuxOf, byAux
local function rangesOn(ranges, aux)
  if byAuxOf ~= ranges then
    byAuxOf, byAux = ranges, {}
    for _, r in ipairs(ranges) do
      local l = byAux[r.aux] or {}
      l[#l + 1] = r
      byAux[r.aux] = l
    end
  end
  return byAux[aux] or {}
end

-- A mix result in % (-100..100) through the channel's output stage as EdgeTX
-- applies it: subtrim within the limits, scaled to the limits (from the subtrim,
-- or from 0 when symmetrical), limited, then reversed. Limits and subtrim in 0.1 %.
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
function M.outPct(o, v)
  v = clamp(v, -100, 100)
  if not o then return v end
  local lp, ln = (o.max or 1000) / 10, (o.min or -1000) / 10
  local ofs = clamp((o.offset or 0) / 10, ln, lp)
  local sym = (o.symetrical or 0) == 1
  if v > 0 then v = v * (sym and lp or lp - ofs) / 100
  elseif v < 0 then v = v * (sym and -ln or ofs - ln) / 100 end
  ofs = clamp(ofs + v, ln, lp)
  if (o.revert or 0) == 1 then ofs = -ofs end
  return ofs
end

-- Names of the modes whose range holds this µs value on AUX aux, "A, B".
local function modesAt(ranges, aux, v)
  local t = {}
  for _, r in ipairs(rangesOn(ranges, aux)) do
    if v >= r.lo and v < r.hi then t[#t + 1] = r.name end
  end
  return table.concat(t, ", ")
end

-- µs the FC sees for a switch position on a simple mix (c from channels).
local function positionUs(c, p)
  local s = c.simple
  return us(M.outPct(c.out, (p.s * s[3] / 100 + s[4]) * s[1] / 100 + s[2]))
end

-- Position index of the one switch position that arms the model according to
-- the FC's ranges; nil when none or several do (simple mixes only).
function M.armPosition(ranges)
  local arm = {}
  for _, r in ipairs(ranges) do
    if r.name == "ARM" then arm[#arm + 1] = r end
  end
  local sws, found = M.scan(), nil
  local chans = M.channels(sws, M.mixLines())
  for _, sw in ipairs(sws) do
    local c = chans[sw]
    if c and c.simple and c.ch >= 5 then
      for _, p in ipairs(sw.pos) do
        if modesAt(arm, c.ch - 4, positionUs(c, p)) ~= "" then
          if found then return nil end
          found = p.idx
        end
      end
    end
  end
  return found
end

local MONTHS ={ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
-- "2026-10-15" as "15 Oct".
local function dayText(d)
  local y, m, day = string.match(d or "", "^(%d+)-(%d+)-(%d+)$")
  if not y then return nil end
  return tonumber(day) .. " " .. (MONTHS[tonumber(m)] or m)
end

-- Source line above the cards from the stored modes (nil: none stored yet).
function M.sourceText(modes)
  if not modes then return nil end
  if modes.fw == "AP" then return "Modes not readable (ArduPilot)" end
  local t = "Modes from FC"
  local d = dayText(modes.date)
  if d then t = t .. " " .. d end
  local fw = modes.fw or ""
  if modes.version and modes.version ~= "" then fw = fw .. " " .. modes.version end
  if fw ~= "" then t = t .. ", " .. fw end
  return t
end

-- Live view of a page (1 switches, 2 buttons): { src, modes, page, cols (cards
-- per row), more (a button page exists), rows = { { card | false, ... } } }. A
-- card: { name, tag, tagShort, key, pos = { { sym, modes, sf, cur } } }; modes
-- only with FC modes (not ArduPilot), on a custom mix only for the current
-- position. Cards of old (the last view of the same page) whose switch and
-- channel did not move are taken over, so the widget keeps what it measured on them.
function M.view(static, modes, old, page)
  page = (page == 2 and static.buttons) and 2 or 1
  local ranges = modes and modes.fw ~= "AP" and modes.ranges or nil
  if old and (old.modes ~= modes or old.page ~= page) then old = nil end
  local rows = {}
  for r, row in ipairs(pageRows(static, page)) do
    local out = {}
    for i, sw in ipairs(row) do
      if not sw then out[i] = false else
        local v = getValue(sw.id) or 0
        local curS = (v < -512) and -100 or (v > 512) and 100 or 0
        local c = sw.chan
        local live = c and getValue("ch" .. c.ch)
        -- The live channel value counts only where it picks the current modes.
        local key = curS .. "," .. ((ranges and c and c.ch >= 5) and tostring(live) or "")
        local prev = old and old.rows[r] and old.rows[r][i]
        if prev and prev.key == key then out[i] = prev else
        local card = { name = sw.name, pos = {}, key = key }
        local aux = c and c.ch >= 5 and c.ch - 4 or nil
        if c and ranges and not c.simple then
          card.tag, card.tagShort = "custom mix", "custom"
        elseif c then
          local mid = aux and ("AUX" .. aux) or nil
          if not ranges and c.name then mid = c.name end
          card.tag = "CH" .. c.ch .. (mid and (" " .. mid) or "")
          card.tagShort = mid or ("CH" .. c.ch)
        else
          local anySf = false
          for _, p in ipairs(sw.pos) do anySf = anySf or p.sf ~= nil end
          card.tag = anySf and "EdgeTX" or "not used"
          card.tagShort = card.tag
        end
        for _, p in ipairs(sw.pos) do
          local cur = p.s == curS
          local m
          if ranges and aux then
            if cur and type(live) == "number" then
              m = modesAt(ranges, aux, 1500 + live / 2)   -- ±1024 = ±512 µs
            elseif c.simple then
              m = modesAt(ranges, aux, positionUs(c, p))
            end
          end
          card.pos[#card.pos + 1] = { sym = p.sym, modes = (m ~= "") and m or nil, sf = p.sf, play = p.play, cur = cur }
        end
        out[i] = card
        end
      end
    end
    rows[r] = out
  end
  return { src = M.sourceText(modes), modes = modes, rows = rows, page = page,
           cols = page == 2 and BUTTON_ROW or ROW_SLOTS, more = static.buttons ~= nil }
end

return M

-- =====================================================================
-- core.lua  --  Shared logic core for GPS Homer.
-- =====================================================================
-- SD card path: /SCRIPTS/GPSHOMER/core.lua
--
-- Single source of truth for thresholds, sensor names, sounds and the whole
-- runtime logic. Loaded (via loadScript()/loadfile) by ALL consumers and must
-- always be installed alongside them:
--   * the telemetry widget  /WIDGETS/GPSHOMER/main.lua      (display only)
--   * the function script    /SCRIPTS/FUNCTIONS/gpshom.lua  (voice events only)
--   * the settings tool      /SCRIPTS/TOOLS/FLIGHTBAG.lua  (configuration)
--
-- "core does everything except drawing": the hardware glue (getValue / playFile
-- / getTime) lives here exactly once; there are NO lcd.* calls and NO
-- mutable module state (the caller owns its state, so multiple widget instances
-- never collide). The pure math functions are desktop-testable.
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
-- Single source of the version: the settings tool reads VERSION, API and
-- CONFIG_PATH as text from the head of this file (keep them near the top).
M.VERSION = "1.0.0"
M.API     = { 1, 0 }
M.CONFIG_PATH = "/SCRIPTS/GPSHOMER/config.lua"
-- API is the interface version for scripts that load this core: { breaking, additive }.
-- Adding an exported function or field bumps the second number; changing or
-- removing one bumps the first and resets the second. Fixes and internal
-- changes leave it alone. A loader accepts the same first and at least its second.

-- ---------------------------------------------------------------------------
-- Declarations (single source of truth)
-- ---------------------------------------------------------------------------

-- Telemetry sensor names (Betaflight + ELRS over CRSF). Hard-coded (no
-- auto-discovery in V1); the widget/tool never name a sensor themselves.
M.SENSORS = {
  gps  = "GPS",
  sats = "Sats",
  gspd = "GSpd",
  hdg  = "Hdg",
  alt  = "Alt",    -- altitude; GAlt (GPS altitude) is preferred when discovered
  galt = "GAlt",
  fm   = "FM",     -- flight mode text; carries the armed state (optional)
  yaw  = "Yaw",    -- nose direction from the FC attitude (CRSF only, optional)
  roll = "Roll",
  pitch = "Ptch",  -- attitude for an artificial horizon (CRSF only, optional)
}

-- Event sounds. Folder fixed (folder upper, files lower, as in the repo);
-- per event the config may hold a file name or `false` (that event muted).
-- Absolute path bypasses EdgeTX's per-language resolution so the pilot's own
-- voice plays regardless of locale.

M.COMPASS_PATH = "/SCRIPTS/GPSHOMER/compass.lua"   -- compass drawing for the widgets
M.SOUND_DIR = "/SOUNDS/en/SCRIPTS/GPSHOMER/"
M.SOUNDS = {
  ready = "gpsready.wav", -- "ready to fly" (stable fix, home not set yet)
  fix  = "gpsfix.wav",   -- "home set"
  lost = "gpslost.wav",  -- "GPS lost"
  rec  = "gpsrec.wav",   -- "GPS recovered"
  alt  = "altitude.wav", -- "maximum altitude"
  dist = "distance.wav", -- "maximum distance"
}

-- Factory defaults for the event sounds, frozen BEFORE any config overlay so the
-- tool can offer a true "Default" per event and applyConfigOverrides stays
-- idempotent regardless of call order.
M.SOUND_DEFAULTS = { ready = M.SOUNDS.ready, fix = M.SOUNDS.fix, lost = M.SOUNDS.lost, rec = M.SOUNDS.rec,
                     alt = M.SOUNDS.alt, dist = M.SOUNDS.dist }
M.SOUND_KEYS     = { "ready", "fix", "lost", "rec", "alt", "dist" }

-- Tunable parameters. HOME_MIN_SATS and the two HAPTIC values are pilot-editable
-- (via the tool / config.lua); the rest are fixed core constants (PC edit only).
-- Times are in SECONDS (converted to ms at each comparison), TICK_MS is in ms.
M.PARAMS = {
  HOME_MIN_SATS  = 6,      -- FR-6: min. sats for the home set   (config: homeMinSats)
  AUDIO           = true,  -- Play announcements at all (false = every sound off; config: audio)
  HAPTIC          = false, -- Vibrate alongside an event sound (opt-in; config: haptic)
  HAPTIC_STRENGTH = 2,     -- Pulse-length tier: 1 = soft, 2 = normal, 3 = strong
  UNITS           = "metric", -- display units: "metric" (m, km/h) or "imperial" (ft, mph); the radio's setting, see below
  MAX_ALT         = 0,     -- announce once above this altitude over home, 0 = off (sensor units); config: maxAlt
  MAX_ALT_HYST    = 10,    -- must drop this far below MAX_ALT before it can announce again
  MAX_DIST        = 0,     -- announce once farther than this from home, 0 = off (m or ft per UNITS); config: maxDist
  MAX_DIST_HYST   = 100,   -- must come this much closer than MAX_DIST before it can announce again
  DOP_POLL_T      = 1,     -- MSP request interval on the ground (s)
  DOP_STALE_T     = 3,     -- a DOP older than this is not shown (s)
  DOP_GIVE_UP_T   = 10,    -- no reply at all this long after the first request on this link: give up (s)
  COURSE_MIN_SPD = 6,      -- FR-10: km/h below which the GPS course is not usable
  COURSE_HYST    = 1,      -- km/h either side of COURSE_MIN_SPD before the course flips
  COURSE_HOLD_T  = 1,      -- speed must stay beyond the hysteresis band this long (s)
  YAW_LEARN_SPD  = 25,     -- yaw offset: learnt only at this speed or more (km/h)
  YAW_LEARN_T    = 2,      -- ... over a window this long (s)
  YAW_LEARN_TURN = 10,     -- ... in which course and yaw change by at most this (deg)
  YAW_LEARN_ROLL = 10,     -- ... and the roll stays below this (deg)
  YAW_OFFSET_T   = 60,     -- a learnt offset holds this long (s; gyro drift without compass)
  HOME_STABLE_T  = 3,      -- fix must stay ok this long for "ready" / home set without FM (s)
  MOVE_LOCK_T    = 1,      -- moving this long before home is set locks home (no FM only) (s)
  HOME_NEAR_M    = 15,     -- closer than this: "at home", no arrow / bearing (m)
  FLOWN_STEP_M   = 10,     -- flown distance counts a move only once this far from the last counted point (m)
  FLOWN_JUMP_M   = 1000,   -- a step longer than this is a GPS glitch and not counted (m)
  TRACK_STEP_M   = 20,     -- flight track: a point once this far from the last one (m)
  TRACK_MAX      = 50,     -- flight track: points kept, the oldest go first (about the last 1 km)
  FIX_LOSS_T     = 3,      -- NFR-4: fix-loss debounce (s)
  AHEAD_DEG      = 15,     -- |rel| <= this -> "ahead"
  BEHIND_DEG     = 165,    -- |rel| >= this -> "behind"
  TICK_MS        = 100,    -- NFR-1: 10 Hz update throttle (ms)
}

-- playHaptic pulse length per strength tier, and pulses per event: GPS lost
-- fires twice to feel clearly stronger than the two "good news" events.
M.HAPTIC_DUR    = { [1] = 15, [2] = 30, [3] = 50 }
M.HAPTIC_PULSES = { ready = 1, fix = 1, lost = 2, rec = 1, alt = 2, dist = 2 }

-- Editable ranges: the SINGLE source for both the on-radio editor and the
-- runtime clamp in normalizeConfig, so they can never drift apart.
M.LIMITS = {
  homeMinSats     = { min = 4, max = 20, step = 1 },
  hapticStrength  = { min = 1, max = 3,  step = 1 },
  maxAlt          = { min = 0, max = 500, step = 10 },
  maxDist         = { min = 0, max = 5000, step = 100 },
}

-- Display units follow the radio's system setting (Units: metric / imperial).
do
  local ok, gs = pcall(getGeneralSettings)
  if ok and type(gs) == "table" and type(gs.imperial) == "number" and gs.imperial ~= 0 then
    M.PARAMS.UNITS = "imperial"
  end
end

M.CONFIG_SCHEMA_VERSION = 1

-- Flight log: the last position of the three most recent flights, written
-- when a flight ends and read back by the tool. Separate from the config so the
-- editor can rewrite settings without touching the log, and the other way
-- round. The map URL plus six decimals stays inside the QR capacity.
M.FLIGHTS_PATH           = "/SCRIPTS/GPSHOMER/flights.lua"
M.FLIGHTS_SCHEMA_VERSION = 1
M.FLIGHTS_MAX            = 3
M.MAP_URL                = "https://maps.google.com/?q="

-- Snapshot of the factory defaults for the overridable params, taken before
-- any config overlay. This is what the tool reads for "Reset to defaults" and
-- what normalizeConfig falls back to (PARAMS is already overlaid by then).
M.DEFAULTS = {
  homeMinSats    = M.PARAMS.HOME_MIN_SATS,
  audio          = M.PARAMS.AUDIO,
  haptic         = M.PARAMS.HAPTIC,
  hapticStrength = M.PARAMS.HAPTIC_STRENGTH,
  maxAlt         = M.PARAMS.MAX_ALT,
  maxDist        = M.PARAMS.MAX_DIST,
}
local DEFAULTS = M.DEFAULTS

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Two-argument atan: EdgeTX's Lua may or may not accept math.atan(y, x), so
-- probe once (atan(1, -1) > 1.5 only with the two-argument form) and fall back
-- to a quadrant-correct implementation on top of the one-argument atan.
local atan2
do
  local ok, v = pcall(function() return math.atan(1, -1) end)
  local twoArg = ok and type(v) == "number" and v > 1.5
  if twoArg then
    atan2 = function(y, x) return math.atan(y, x) end
  else
    atan2 = function(y, x)
      if x > 0 then return math.atan(y / x) end
      if x < 0 then
        if y >= 0 then return math.atan(y / x) + math.pi end
        return math.atan(y / x) - math.pi
      end
      if y > 0 then return math.pi / 2 end
      if y < 0 then return -math.pi / 2 end
      return 0
    end
  end
end
M.atan2 = atan2

-- Clamp n into [lo, hi]; a non-number falls back.
local function clampNum(n, lo, hi, fallback)
  if type(n) ~= "number" then return fallback end
  if n < lo then return lo elseif n > hi then return hi end
  return n
end

-- A boolean is kept as is; anything else falls back.
local function boolOr(v, fallback)
  if type(v) == "boolean" then return v end
  return fallback
end

-- True unless fstat positively says the file is gone. fstat is absent on the
-- desktop and pcall-guarded, so "unknown" keeps the custom name.
local function soundFileExists(name)
  if not fstat then return true end
  local ok, info = pcall(fstat, M.SOUND_DIR .. name)
  return not ok or info ~= nil
end

-- Sound override helper: a string is a custom file name (dropped to the default
-- when the file no longer exists on the card, so the event still sounds), `false`
-- means the pilot muted this event, and anything else (nil/garbage) falls back
-- to the default so playFile can never receive junk.
local function soundOr(v)
  if type(v) == "string" then
    local name = string.match(v, "[^/]+$")
    if name and soundFileExists(name) then return name end
    return nil
  end
  if v == false then return false end
  return nil
end

-- getTime() ticks are 10 ms; work in ms so the SECONDS params scale cleanly.
local function nowMs()
  return getTime() * 10
end

-- getFieldInfo is nil for a sensor that was never discovered; getValue would give 0.
local function sensorExists(name)
  local ok, info = pcall(getFieldInfo, name)
  return ok and info ~= nil
end

-- Existence per sensor, re-checked at most every `interval` (same unit as `now`).
-- names = { key = "SensorName", ... }; returns the cached { key = true/false }.
local function sensorsPresent(state, names, now, interval)
  if state.sensorCheckAt == nil or now - state.sensorCheckAt >= interval then
    state.sensorCheckAt = now
    local has = {}
    for key, name in pairs(names) do has[key] = sensorExists(name) end
    state.sensorsPresent = has
  end
  return state.sensorsPresent
end

-- Value of a present sensor, nil when absent (display shows "--", not a fake 0).
local function readPresent(has, names, key)
  if not has[key] then return nil end
  local ok, v = pcall(getValue, names[key])
  if ok then return v end
  return nil
end

local SENSOR_CHECK_MS = 1000   -- sensor existence is model config, 1 s cache is plenty

-- getValue() returns 0 for undiscovered sensors, indistinguishable from a real
-- zero; pcall-guarded so a broken API call never crashes the widget.
local function safeGet(name)
  local ok, v = pcall(getValue, name)
  if ok then return v end
  return nil
end

-- True while EdgeTX receives telemetry (any protocol).
local function linkUp()
  return getRSSI() ~= 0
end

-- Debounced loss: true once the link has been down for `grace` (same unit as `now`).
-- state.linkLostSince is nil while the link is up.
local function linkLost(state, up, now, grace)
  if up then
    state.linkLostSince = nil
    return false
  end
  state.linkLostSince = state.linkLostSince or now
  return now - state.linkLostSince >= grace
end

-- ---------------------------------------------------------------------------
-- Validation (pure)
-- ---------------------------------------------------------------------------

-- A usable GPS reading: a table with numeric lat/lon inside the valid ranges;
-- 0/0 ("null island") is what a GPS without a fix reports and is rejected.
function M.validGps(t)
  if type(t) ~= "table" then return false end
  local lat, lon = t.lat, t.lon
  if type(lat) ~= "number" or type(lon) ~= "number" then return false end
  if lat < -90 or lat > 90 then return false end
  if lon < -180 or lon > 180 then return false end
  if lat == 0 and lon == 0 then return false end
  return true
end

-- A number inside [lo, hi], else nil (discarded sample).
function M.validRange(v, lo, hi)
  if type(v) ~= "number" then return nil end
  if v < lo or v > hi then return nil end
  return v
end

-- ---------------------------------------------------------------------------
-- Geometry (pure)
-- ---------------------------------------------------------------------------

-- Great-circle distance in metres (haversine, spherical earth).
function M.haversine(lat1, lon1, lat2, lon2)
  local R    = 6371000
  local rad  = math.rad
  local dLat = rad(lat2 - lat1)
  local dLon = rad(lon2 - lon1)
  local a    = math.sin(dLat / 2) ^ 2
             + math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.sin(dLon / 2) ^ 2
  return R * 2 * atan2(math.sqrt(a), math.sqrt(1 - a))
end

-- Initial bearing from (lat, lon) to home, 0..360 with 0 = North.
function M.bearingTo(lat, lon, homeLat, homeLon)
  local rad  = math.rad
  local dLon = rad(homeLon - lon)
  local y    = math.sin(dLon) * math.cos(rad(homeLat))
  local x    = math.cos(rad(lat)) * math.sin(rad(homeLat))
             - math.sin(rad(lat)) * math.cos(rad(homeLat)) * math.cos(dLon)
  return (math.deg(atan2(y, x)) + 360) % 360
end

-- Home direction relative to the nose: -180..+180, positive = right.
function M.relAngle(bearing, course)
  return ((bearing - course + 540) % 360) - 180
end

-- Eight compass sectors, 45 deg each, centred on the cardinal directions.
local SECTORS = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
function M.sectorOf(bearing)
  return SECTORS[math.floor((bearing % 360 + 22.5) / 45) % 8 + 1]
end

-- The GPS course is only meaningful above a minimum ground speed. Debounced so
-- the arrow does not flicker while hovering near the threshold: it turns on
-- once the speed has stayed >= COURSE_MIN_SPD + COURSE_HYST for COURSE_HOLD_T,
-- off once it has stayed < COURSE_MIN_SPD - COURSE_HYST that long; inside the
-- band (or before the hold elapses) the last decision holds.
function M.updateCourseValid(state, gspd, now)
  local P, want = M.PARAMS, nil
  gspd = gspd or 0
  if gspd >= P.COURSE_MIN_SPD + P.COURSE_HYST then want = true
  elseif gspd < P.COURSE_MIN_SPD - P.COURSE_HYST then want = false end
  if want == nil or want == state.courseValid then
    state.courseSince = nil
  else
    state.courseSince = state.courseSince or now
    if now - state.courseSince >= P.COURSE_HOLD_T * 1000 then
      state.courseValid, state.courseSince = want, nil
    end
  end
  return state.courseValid
end

-- Nose below COURSE_MIN_SPD: while flying fast and straight, the offset between
-- the FC's yaw and the GPS course is learnt (circular mean over a calm window;
-- turns, sideways flight and strong crosswind are left out). Hovering, yaw minus
-- that offset stands in for the course, so the arrow stays nose-relative. Works
-- with or without a compass: only the yaw change since the window counts.
local function angDiff(a, b) return math.abs(M.relAngle(a, b)) end
function M.learnYawOffset(state, gspd, hdg, yaw, roll, now)
  local P, w = M.PARAMS, state.yawWin
  if not (gspd and hdg and yaw and roll) or gspd < P.YAW_LEARN_SPD or math.abs(roll) >= P.YAW_LEARN_ROLL then
    state.yawWin = nil
    return
  end
  if w and (angDiff(hdg, w.hdg) > P.YAW_LEARN_TURN or angDiff(yaw, w.yaw) > P.YAW_LEARN_TURN) then w = nil end
  if not w then
    w = { t = now, hdg = hdg, yaw = yaw, s = 0, c = 0 }
    state.yawWin = w
  end
  local d = math.rad(yaw - hdg)
  w.s, w.c = w.s + math.sin(d), w.c + math.cos(d)
  if now - w.t >= P.YAW_LEARN_T * 1000 then
    state.yawOffset, state.yawOffsetAt = (math.deg(atan2(w.s, w.c)) + 360) % 360, now
    state.yawWin = nil
  end
end

-- Nose for the display: the GPS course while it is valid, else yaw minus the
-- learnt offset while that is fresh. Returns valid, course, estimated.
function M.noseOf(state, now)
  if M.updateCourseValid(state, state.lastGspd, now) then return true, state.lastHdg or 0, false end
  local yaw = state.lastYaw
  if yaw and state.yawOffsetAt and now - state.yawOffsetAt <= M.PARAMS.YAW_OFFSET_T * 1000 then
    return true, (yaw - state.yawOffset + 360) % 360, true
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Config overlay (pure: no file I/O, directly unit-testable)
-- ---------------------------------------------------------------------------

-- Normalise a parsed config table into a copy (never touches PARAMS; the only
-- I/O is one fstat per custom sound): values clamped to LIMITS, wrong types
-- replaced by the factory default, a sound is a file name, false (muted) or nil
-- (default). Unknown entries are kept as they are, so a setting written by a
-- newer version survives a save through this one. The ONE place that decides
-- what a config value means: the runtime overlay and the settings tool both go
-- through here, so they can never disagree on a hand-edited file.
function M.normalizeConfig(cfg)
  local out = {}
  if type(cfg) == "table" then for k, v in pairs(cfg) do out[k] = v end end
  local L = M.LIMITS
  out.homeMinSats    = clampNum(out.homeMinSats,
                         L.homeMinSats.min, L.homeMinSats.max, DEFAULTS.homeMinSats)
  out.audio          = boolOr(out.audio, DEFAULTS.audio)
  out.haptic         = boolOr(out.haptic, DEFAULTS.haptic)
  out.hapticStrength = clampNum(out.hapticStrength,
                         L.hapticStrength.min, L.hapticStrength.max, DEFAULTS.hapticStrength)
  out.units          = nil   -- now the radio's setting; dropped from older configs
  out.maxAlt         = clampNum(out.maxAlt, L.maxAlt.min, L.maxAlt.max, DEFAULTS.maxAlt)
  out.maxDist        = clampNum(out.maxDist, L.maxDist.min, L.maxDist.max, DEFAULTS.maxDist)
  local snd, sounds = (type(out.sounds) == "table") and out.sounds or {}, {}
  for k, v in pairs(snd) do sounds[k] = v end
  for _, k in ipairs(M.SOUND_KEYS) do sounds[k] = soundOr(snd[k]) end
  out.sounds = sounds
  if type(out.generation) ~= "number" then out.generation = 0 end
  return out
end

-- Overlay a parsed config table onto PARAMS/SOUNDS. DEFAULTS / SOUND_DEFAULTS
-- are left untouched (the tool's Reset relies on that snapshot guarantee).
function M.applyConfigOverrides(cfg)
  local n = M.normalizeConfig(cfg)
  M.PARAMS.HOME_MIN_SATS   = n.homeMinSats
  M.PARAMS.AUDIO           = n.audio
  M.PARAMS.HAPTIC          = n.haptic
  M.PARAMS.HAPTIC_STRENGTH = n.hapticStrength
  M.PARAMS.MAX_ALT         = n.maxAlt
  M.PARAMS.MAX_DIST        = n.maxDist
  for _, k in ipairs(M.SOUND_KEYS) do
    local v = n.sounds[k]
    if v == nil then v = M.SOUND_DEFAULTS[k] end
    M.SOUNDS[k] = v
  end
end


-- ---------------------------------------------------------------------------
-- Files and the flight log
-- ---------------------------------------------------------------------------

-- Reads a whole file in blocks (the "a" format is not on every build), or nil.
function M.readFile(path)
  local ok, f = pcall(io.open, path, "r")
  if not ok or not f then return nil end
  local parts = {}
  while true do
    local rok, chunk = pcall(io.read, f, 4096)
    if not rok or not chunk or chunk == "" then break end
    parts[#parts + 1] = chunk
  end
  pcall(io.close, f)
  return table.concat(parts)
end

-- io.open "w" does NOT truncate on some EdgeTX/SD builds, so a shorter write
-- would leave the old tail behind -- pad with trailing newlines (valid after
-- the returned table) up to the old length. Pcall-wrapped so a full or
-- read-only SD card never raises.
function M.writeFile(path, content)
  local old = M.readFile(path)
  if old and #old > #content then
    content = content .. string.rep("\n", #old - #content)
  end
  local ok, f = pcall(io.open, path, "w")
  if not ok or not f then return false end
  local wok = pcall(io.write, f, content)
  pcall(io.close, f)
  return wok == true
end

-- Logged flights, newest first. A missing, unparsable or foreign-schema file
-- reads as an empty log: it is a convenience, never flight critical. Loaded as
-- text only like the config (see loadConfig).
function M.readFlights()
  local chunk = loadScript and loadScript(M.FLIGHTS_PATH, "tx")
  if not chunk then return {} end
  local ok, result = pcall(chunk)
  if not ok or type(result) ~= "table" then return {} end
  if result.schemaVersion ~= M.FLIGHTS_SCHEMA_VERSION then return {} end
  local out = {}
  for _, e in ipairs(result.flights or {}) do
    if type(e) == "table" and type(e.lat) == "number" and type(e.lon) == "number" then
      out[#out + 1] = { lat   = e.lat,
                        lon   = e.lon,
                        date  = tostring(e.date  or ""),
                        time  = tostring(e.time  or ""),
                        model = tostring(e.model or "") }
    end
  end
  return out
end

local function writeFlights(flights)
  local out = { "-- GPS Homer flight log (auto-generated).",
                "return {",
                "  schemaVersion = " .. M.FLIGHTS_SCHEMA_VERSION .. ",",
                "  flights = {" }
  for _, e in ipairs(flights) do
    out[#out + 1] = string.format("    { lat = %.6f, lon = %.6f, date = %q, time = %q, model = %q },",
                                  e.lat, e.lon, e.date, e.time, e.model)
  end
  out[#out + 1] = "  },"
  out[#out + 1] = "}"
  return M.writeFile(M.FLIGHTS_PATH, table.concat(out, "\n") .. "\n")
end

-- Empties the log. The file stays (an empty one reads as no flights), so the
-- tool never has to delete a file to undo a log.
function M.clearFlights()
  return writeFlights({})
end

-- ---------------------------------------------------------------------------
-- Config file: load, save, defaults, resets, reload. Written by the settings
-- tool; the file is OPTIONAL, without it (or with a broken one) the defaults
-- stay in force (the config is not flight critical).
-- ---------------------------------------------------------------------------

local function quoteString(s)
  s = string.gsub(s, "\\", "\\\\")
  s = string.gsub(s, '"', '\\"')
  s = string.gsub(s, "\n", "\\n")
  return '"' .. s .. '"'
end

-- Lua source for a value; string keys sorted so the file is stable.
local function serialize(value, indent)
  local t = type(value)
  if t == "number" or t == "boolean" then return tostring(value) end
  if t == "string" then return quoteString(value) end
  if t ~= "table" then return "nil" end
  local nextIndent, parts, n = indent .. "  ", {}, #value
  for i = 1, n do parts[#parts + 1] = nextIndent .. serialize(value[i], nextIndent) end
  local keys = {}
  for k in pairs(value) do
    if not (type(k) == "number" and k >= 1 and k <= n and math.floor(k) == k) then
      keys[#keys + 1] = k
    end
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, k in ipairs(keys) do
    local keyStr = (type(k) == "string") and ("[" .. quoteString(k) .. "]") or ("[" .. tostring(k) .. "]")
    parts[#parts + 1] = nextIndent .. keyStr .. " = " .. serialize(value[k], nextIndent)
  end
  if #parts == 0 then return "{}" end
  return "{\n" .. table.concat(parts, ",\n") .. ",\n" .. indent .. "}"
end

-- Returns the normalised config, or nil plus "missing" | "parse" | "schema"
-- (and a detail text). Text only, no .luac (mode "tx"): the radio would prefer
-- a compiled copy with the same 2 s FAT timestamp over a newer file.
function M.loadConfig()
  local ok, f = pcall(io.open, M.CONFIG_PATH, "r")
  if not ok or not f then return nil, "missing" end
  pcall(io.close, f)
  local cok, chunk, err = pcall(loadScript, M.CONFIG_PATH, "tx")
  if not cok or not chunk then return nil, "parse", tostring(err or chunk) end
  local pok, result = pcall(chunk)
  if not pok then return nil, "parse", tostring(result) end
  if type(result) ~= "table" then return nil, "parse", "not a table" end
  if result.schemaVersion ~= M.CONFIG_SCHEMA_VERSION then
    return nil, "schema", tostring(result.schemaVersion)
  end
  return M.normalizeConfig(result)
end

-- Writes the config with a raised generation (the reload sentinel). True on success.
function M.saveConfig(cfg)
  cfg.schemaVersion = M.CONFIG_SCHEMA_VERSION
  cfg.generation    = (cfg.generation or 0) + 1
  return M.writeFile(M.CONFIG_PATH, "-- GPS Homer configuration (auto-generated).\nreturn "
                                    .. serialize(cfg, "") .. "\n")
end

-- Factory settings as a fresh table.
function M.defaultConfig()
  local cfg = M.normalizeConfig({})
  cfg.schemaVersion = M.CONFIG_SCHEMA_VERSION
  return cfg
end

-- Factory settings that keep the shared ones (audio, haptic): those are set once
-- for all scripts in the settings tool and no project reset touches them.
local function freshKeepingShared()
  local cfg = M.loadConfig() or M.defaultConfig()
  local fresh = M.defaultConfig()
  fresh.audio, fresh.haptic, fresh.hapticStrength = cfg.audio, cfg.haptic, cfg.hapticStrength
  fresh.generation = cfg.generation
  return fresh
end

-- Settings back to factory values; the flight log stays. True on success.
function M.resetSettings()
  return M.saveConfig(freshKeepingShared())
end

-- Settings back to factory values and the flight log emptied. True on success.
function M.factoryReset()
  local ok = M.saveConfig(freshKeepingShared())
  return M.clearFlights() and ok
end

-- Re-reads the config at most every CONFIG_POLL_MS and applies it when its
-- generation changed (or it appeared / went away), so a change made in the
-- settings tool takes effect without a model reload.
local CONFIG_POLL_MS = 5000
local configGen, configPollAt
function M.pollConfig(now)
  now = now or getTime() * 10
  if configPollAt and now - configPollAt < CONFIG_POLL_MS then return end
  configPollAt = now
  local cfg, kind = M.loadConfig()
  -- damaged or wrong version: defaults stay in use, but it is a setup error
  M.configDamaged = (kind == "parse" or kind == "schema")
  local gen = cfg and cfg.generation or false
  if gen ~= configGen then
    configGen = gen
    M.applyConfigOverrides(cfg or {})
  end
end
pcall(M.pollConfig, 0)

-- Prepends one position and keeps the newest FLIGHTS_MAX. Date, time and model
-- name are best effort: the radio clock may be unset and the host tests have
-- neither call. Returns true when the file was written.
function M.logFlight(lat, lon)
  local entry = { lat = lat, lon = lon, date = "", time = "", model = "" }

  local ok, dt = pcall(function() return getDateTime() end)
  if ok and type(dt) == "table" and dt.year then
    entry.date = string.format("%04d-%02d-%02d", dt.year, dt.mon, dt.day)
    entry.time = string.format("%02d:%02d", dt.hour, dt.min)
  end
  local mok, info = pcall(function() return model.getInfo() end)
  if mok and type(info) == "table" and info.name then entry.model = tostring(info.name) end

  local flights = M.readFlights()
  table.insert(flights, 1, entry)
  while #flights > M.FLIGHTS_MAX do table.remove(flights) end

  return writeFlights(flights)
end

-- Coordinate for display: decimal degrees with five places (about 1 m), the
-- form map apps take. EdgeTX Lua numbers carry about 7 digits, so a sixth place
-- would only show noise. Shared, so the widget's end screen and the tool's flight
-- log read identically.
function M.formatCoord(v)
  return string.format("%.5f", v)
end

-- Map link for a position, short enough for the QR symbol the tool draws.
function M.mapUrl(lat, lon)
  return string.format("%s%.6f,%.6f", M.MAP_URL, lat, lon)
end

-- ---------------------------------------------------------------------------
-- Telemetry I/O -- the single place that reads all sensors raw.
-- ---------------------------------------------------------------------------

-- The sensors the script cannot work without (the GPS frame).
-- Alt is optional: without it there is no altitude and no Max altitude warning.
local REQUIRED = { "gps", "sats", "gspd", "hdg" }

-- Setup errors that need no telemetry, one text each (the settings tool lists
-- them; a widget only shows that there is one): required sensors not
-- discovered in the model. state as kept by update; without it a fresh one.
function M.setupErrors(state)
  state = state or M.newState()
  local out = {}
  if M.configDamaged then out[1] = "Settings file damaged" end   -- defaults in use
  -- The compass drawing (also loaded by other widgets) ships with the core.
  local ok, st = pcall(function() return fstat and fstat(M.COMPASS_PATH) end)
  if fstat and ok and not st then
    out[#out + 1] = "Compass file missing"
    out[#out + 1] = "Reinstall GPS Homer"
  end
  local has = sensorsPresent(state, M.SENSORS, nowMs(), SENSOR_CHECK_MS)
  local missing = {}
  for _, k in ipairs(REQUIRED) do
    if not has[k] then missing[#missing + 1] = M.SENSORS[k] end
  end
  if #missing > 0 then
    out[#out + 1] = "Missing sensors: " .. table.concat(missing, ", ")
    out[#out + 1] = "Check sensors config"
  end
  return out
end

-- Disarmed marker in the FM text: Betaflight appends * ! ?, ArduPilot *,
-- INAV sends OK / WAIT / !ERR. "!FS!" (failsafe) is armed despite its "!".
local INAV_DISARMED = { OK = true, WAIT = true, ["!ERR"] = true }
local function fmDisarmed(fm)
  if fm == "!FS!" then return false end
  if INAV_DISARMED[fm] then return true end
  local last = string.sub(fm, -1)
  return last == "*" or last == "!" or last == "?"
end

-- armed, known. Known only once a disarmed marker was seen on this link
-- (state.disarmSeen): some setups never send one, and a text without a marker
-- alone proves nothing. Clear state.disarmSeen when the flight ends.
local function armedFromFM(state, fm)
  if type(fm) ~= "string" or fm == "" then return false, false end
  if fmDisarmed(fm) then
    state.disarmSeen = true
    return false, true
  end
  if not state.disarmSeen then return false, false end
  return true, true
end
M.armedFromFM = armedFromFM

-- Flight phases, word for word the same in every script. They pick the page:
-- WAITING (no link) -> PRE (link up) -> FLIGHT (armed, or the app's preflight
-- check met for PRE_HOLD_T without a break) -> ENDED (link lost LINK_LOSS_T)
-- -> WAITING after ENDED_HOLD_T. No way back from FLIGHT to PRE (a disarm keeps
-- FLIGHT). A loss in PRE goes straight to WAITING (no flight). A loss while
-- armed is a link failure: back within ENDED_HOLD_T, the same flight goes on.
-- Display only: logic that needs the real armed state reads armedFromFM.
-- Times in ms. Returns the phase and an event: "new" (a new flight starts in
-- PRE), "lost" (PRE -> WAITING), "end" (FLIGHT -> ENDED, s.linkFailure tells
-- why), "resume" (link back after a failure) or "over" (ENDED_HOLD_T without
-- link), else nil.
local LINK_LOSS_T, ENDED_HOLD_T, PRE_HOLD_T = 1500, 30000, 15000
local function flightPhase(s, up, armed, ready, now)
  local phase, event = s.phase or "WAITING", nil
  local lost = linkLost(s, up, now, LINK_LOSS_T)
  if up then s.armedBeforeLoss = armed == true end
  if phase == "WAITING" then
    if up then phase, event = "PRE", "new" end
  elseif phase == "ENDED" then
    if up and s.linkFailure then
      phase, event = "FLIGHT", "resume"
    elseif up then
      phase, event = "PRE", "new"
    elseif now - s.endedAt >= ENDED_HOLD_T then
      phase, event = "WAITING", "over"
    end
    if phase ~= "ENDED" then s.linkFailure = nil end
  elseif phase == "FLIGHT" then
    if lost then
      phase, event, s.endedAt, s.linkFailure = "ENDED", "end", now, s.armedBeforeLoss
    end
  elseif lost then
    phase, event = "WAITING", "lost"
  elseif up then
    if not ready then s.readySince = nil elseif not s.readySince then s.readySince = now end
    if armed or (s.readySince and now - s.readySince >= PRE_HOLD_T) then phase = "FLIGHT" end
  end
  if phase ~= "PRE" then s.readySince = nil end
  s.phase = phase
  return phase, event
end
M.flightPhase = flightPhase
M.LINK_LOSS_T, M.ENDED_HOLD_T, M.PRE_HOLD_T = LINK_LOSS_T, ENDED_HOLD_T, PRE_HOLD_T

-- DOP quality: 0 good, 1 fair, 2 poor (nil DOP: 0). PDOP includes the vertical
-- part and runs about 1.5 to 2 times HDOP.
local DOP_STAGES = { HDOP = { good = 1.5, fair = 2.5 }, PDOP = { good = 2.5, fair = 4.0 } }
function M.dopStage(dop, kind)
  if not dop then return 0 end
  local s = DOP_STAGES[kind] or DOP_STAGES.PDOP
  if dop < s.good then return 0 end
  return (dop < s.fair) and 1 or 2
end

-- Preflight check of the GPS: fix "nofix" / "settling" / "ready" as status
-- text and level (0 ok, 1 warning), plus the DOP stage. Met with both at 0.
local GPS_STATUS = { nofix = { "NO FIX", 1 }, settling = { "FIX SETTLING", 1 }, ready = { "GPS READY", 0 } }
function M.preflight(fix, dop, dopKind)
  local st = GPS_STATUS[fix] or GPS_STATUS.nofix
  return { text = st[1], level = st[2], dopStage = M.dopStage(dop, dopKind) }
end

-- Flight controller firmware from a disarmed flight-mode text, for the DOP
-- source: "BF", "INAV", "AP" (ArduPilot) or nil when the text does not tell.
-- Betaflight appends "*", "!" or "?" to its own short list of names; "!" and
-- "?" only it uses. INAV sends "OK", "WAIT" or "!ERR". ArduPilot (RC_OPTIONS
-- bit 12, or ELRS MAVLink mode) appends "*" to its own mode names. The two
-- lists split Betaflight's names by whether ArduPilot uses them too (INAV never
-- appends "*", so it does not matter here). Shared names (ACRO, ALTH, POSH, and
-- Betaflight's STAB/MANU up to 4.5) stay nil.
local BF_NAMES_NOT_AP  = { ANGL = true, HOR = true, AIR = true, RTH = true, PASS = true, PHFL = true, CHIR = true }
local BF_NAMES_ALSO_AP = { ACRO = true, ALTH = true, POSH = true, STAB = true, MANU = true }
function M.fcFromFM(v)
  if type(v) ~= "string" or #v < 2 then return nil end
  if INAV_DISARMED[v] then return "INAV" end
  local last, name = string.sub(v, -1), string.sub(v, 1, -2)
  if (last == "!" or last == "?") and v ~= "!FS!" then return "BF" end
  if last ~= "*" then return nil end
  if BF_NAMES_NOT_AP[name] then return "BF" end
  if BF_NAMES_ALSO_AP[name] then return nil end
  return "AP"
end

-- Rescue / failsafe / landing from the same text: "RTH" = GPS rescue flying
-- (armed, no marker; "RTH*" is only the switch on the ground), INAV "WRTH" =
-- RTH at the end of a mission, ArduPilot "RTL " (trailing space), "SRTL",
-- "ARTL", "QRTL"; "!FS!" = failsafe (rescue or landing, the text does not tell
-- which; ArduPilot has no failsafe text); "LAND" = INAV fixed-wing autoland or
-- ArduPilot Copter Land, ArduPilot Plane "ALND", "QLND", "L2QL". Returns "RTH",
-- "FS", "LAND" or nil.
local ALERTS = {
  RTH = "RTH", WRTH = "RTH", ["RTL "] = "RTH", SRTL = "RTH", ARTL = "RTH", QRTL = "RTH",
  ["!FS!"] = "FS",
  LAND = "LAND", ALND = "LAND", QLND = "LAND", L2QL = "LAND",
}
function M.alertFromFM(v)
  return ALERTS[v]
end

-- ---------------------------------------------------------------------------
-- MSP over CRSF: the widget asks the FC for MSP_RAW_GPS while disarmed and
-- takes the DOP from the reply (Betaflight: PDOP, INAV: HDOP, both x100).
-- Every request makes ELRS switch its telemetry ratio to 1:2 for about 5 s,
-- which halves the stick packet rate; hence ground only.
-- ---------------------------------------------------------------------------
local MSP_REQ, MSP_RESP     = 0x7A, 0x7B
local ADDR_FC, ADDR_RADIO   = 0xC8, 0xEA
M.MSP_RAW_GPS = 106

-- CRSF payload of an MSPv1 request without data: destination, origin, status
-- (version 1, start flag, sequence 0..15), size 0, command. The MSP checksum is
-- not sent over CRSF.
function M.mspRequest(seq, cmd)
  return { ADDR_FC, ADDR_RADIO, 0x30 + seq % 16, 0, cmd }
end

-- DOP from a popped MSP_RESP payload (MSPv1, single chunk: the 18-byte
-- MSP_RAW_GPS reply always fits one frame). Returns nil for a frame that is not
-- this reply, false for a firmware that predates the field, 0 while there is no
-- fix yet (normal right after power-up), else the DOP.
function M.parseRawGpsDop(data)
  if type(data) ~= "table" or data[1] ~= ADDR_RADIO or data[2] ~= ADDR_FC then return nil end
  local status = data[3] or 0
  local start  = math.floor(status / 16) % 2 == 1
  if status >= 128 or not start or math.floor(status / 32) % 4 ~= 1 then return nil end
  if data[5] ~= M.MSP_RAW_GPS then return nil end
  local size = data[4] or 0
  if size < 18 or #data < 5 + 18 then return false end
  local dop = data[22] + data[23] * 256
  if data[6] == 0 then return 0 end
  return dop / 100
end

-- Fix type from the same reply: "NONE", "2D" or "3D"; nil for any other frame.
-- Betaflight sends only fix yes/no (with u-blox set for a 3D fix only), INAV
-- 0/1/2 for none/2D/3D, so the firmware decides what 1 means.
function M.parseRawGpsFix(data, fcKind)
  if M.parseRawGpsDop(data) == nil then return nil end
  local f = data[6]
  if f == 0 then return "NONE" end
  if fcKind == "INAV" and f == 1 then return "2D" end
  return "3D"
end

-- HDOP from an ArduPilot passthrough frame (0x80, legacy 0x7F): ArduPilot sends
-- them with RC_OPTIONS bit 8, the ELRS TX module in MAVLink mode always. Value
-- 0x5002 (GPS status): fix in bits 4-5, HDOP in dm as 7 bits x 10^bit 6.
-- Returns the HDOP, or nil when the frame carries none (or no 2D/3D fix). The
-- saturated 0xFF (127 x 10 dm) is what an unknown HDOP turns into (MAVLink eph
-- 65535), so it counts as none.
local function gpsStatusHdop(v)
  if math.floor(v / 16) % 4 < 2 then return nil end
  if math.floor(v / 64) % 256 == 0xFF then return nil end
  local dm = (math.floor(v / 128) % 128) * (math.floor(v / 64) % 2 == 1 and 10 or 1)
  if dm == 0 then return nil end
  return dm / 10
end
local function u32(d, i) return d[i] + d[i + 1] * 256 + d[i + 2] * 65536 + d[i + 3] * 16777216 end
-- The 0x5002 value of a passthrough frame, or nil.
local function passthroughGpsStatus(cmd, data)
  if (cmd ~= 0x80 and cmd ~= 0x7F) or type(data) ~= "table" then return nil end
  if data[1] == 0xF0 and #data >= 7 and data[2] + data[3] * 256 == 0x5002 then
    return u32(data, 4)
  elseif data[1] == 0xF2 and #data >= 8 then
    for i = 0, math.min(data[2] or 0, 9) - 1 do
      local p = 3 + 6 * i
      if #data >= p + 5 and data[p] + data[p + 1] * 256 == 0x5002 then
        return u32(data, p + 2)
      end
    end
  end
  return nil
end
function M.parsePassthroughHdop(cmd, data)
  local v = passthroughGpsStatus(cmd, data)
  return v and gpsStatusHdop(v)
end
-- Fix type from the same value (bits 4-5: no GPS, no fix, 2D, 3D or better):
-- "NONE", "2D" or "3D"; nil without a 0x5002 value.
local PT_FIX = { [0] = "NONE", [1] = "NONE", [2] = "2D", [3] = "3D" }
function M.parsePassthroughFix(cmd, data)
  local v = passthroughGpsStatus(cmd, data)
  return v and PT_FIX[math.floor(v / 16) % 4]
end

-- One CRSF frame, popped by the caller (the caller drains the queue once per
-- cycle so other consumers in the same script get the frames too): MSP replies
-- and ArduPilot passthrough HDOP. Taken on the ground before the first flight
-- (as of the last tick) and while a reply is still due after arming.
function M.handleFrame(state, cmd, data, now)
  local P = M.PARAMS
  if not state.useMsp then return end
  now = now or nowMs()
  local late = state.dopWaiting and now - state.dopSentAt < P.DOP_STALE_T * 1000
  if not (state.dopGround or late) then return end
  if cmd == MSP_RESP then
    local dop = M.parseRawGpsDop(data)
    if dop ~= nil then
      state.dopWaiting = false
      state.dopAnswered = true
      if dop == false then state.dopGaveUp = true end   -- only a missing field gives up
      if dop and dop > 0 then state.dop, state.dopAt = dop, now end
      -- Read in readSnapshot: the FM text may tell the firmware only after this frame.
      state.fixReply, state.fix, state.fixAt = data, nil, now
    end
  else
    local hdop = M.parsePassthroughHdop(cmd, data)
    if hdop then state.dop, state.dopAt, state.fcKind = hdop, now, "AP" end
    local fix = M.parsePassthroughFix(cmd, data)
    if fix then state.fixReply, state.fix, state.fixAt, state.fcKind = nil, fix, now, "AP" end
  end
end

-- One DOP step per tick: send the next MSP request when due. Requests stop when
-- no reply came DOP_GIVE_UP_T after the first one on this link, or after a reply
-- without the DOP field (ArduPilot does not answer MSP, older firmware lacks the
-- field); a reply without a fix keeps asking. Returns the last DOP while it is
-- fresh, else nil.
local function pollDop(state, ground, now)
  local P = M.PARAMS
  state.dopGround = ground
  -- Frames of this cycle were handed over before, so a passthrough frame that
  -- just came in already counts. ArduPilot answers no MSP: no requests (and no
  -- telemetry boost) at all.
  if state.dopFirstAt and not state.dopAnswered and now - state.dopFirstAt >= P.DOP_GIVE_UP_T * 1000 then
    state.dopGaveUp, state.dopWaiting = true, false
  end
  local active = ground and not state.dopGaveUp and state.fcKind ~= "AP"
  if active and crossfireTelemetryPush
     and (state.dopSentAt == nil or now - state.dopSentAt >= P.DOP_POLL_T * 1000)
     and crossfireTelemetryPush() then   -- nil: no CRSF module, false: buffer busy
    crossfireTelemetryPush(MSP_REQ, M.mspRequest(state.dopSeq, M.MSP_RAW_GPS))
    state.dopSeq, state.dopSentAt, state.dopWaiting = (state.dopSeq + 1) % 16, now, true
    state.dopFirstAt = state.dopFirstAt or now
  end
  if state.dopAt and now - state.dopAt <= P.DOP_STALE_T * 1000 then return state.dop end
  return nil
end

-- Read + validate every sensor. Invalid samples become nil so evaluate() keeps
-- the last valid value. sensorMissing distinguishes "sensor never discovered"
-- (no GPS telemetry configured) from "0 satellites" / a momentary bad value.
function M.readSnapshot(state, now)
  local S       = M.SENSORS
  local has     = sensorsPresent(state, S, now, SENSOR_CHECK_MS)
  local rawGps  = safeGet(S.gps)
  local gps     = M.validGps(rawGps) and { lat = rawGps.lat, lon = rawGps.lon } or nil
  local sats    = M.validRange(safeGet(S.sats), 0, 99)
  local gspd    = M.validRange(safeGet(S.gspd), 0, 500)
  local hdg     = M.validRange(safeGet(S.hdg),  0, 360)
  -- Altitude: GAlt when the radio discovered it (EdgeTX names the GPS altitude
  -- so on some setups), else Alt; neither -> nil, never a misleading 0.
  local rawAlt  = readPresent(has, S, "galt")
  if rawAlt == nil then rawAlt = readPresent(has, S, "alt") end
  local alt     = M.validRange(rawAlt, -500, 10000)
  -- Attitude in rad (-pi..pi; older firmware 0..2pi) -> yaw 0..360, roll and pitch -180..180.
  local yaw     = M.validRange(readPresent(has, S, "yaw"), -7, 7)
  local roll    = M.validRange(readPresent(has, S, "roll"), -7, 7)
  local pitch   = M.validRange(readPresent(has, S, "pitch"), -7, 7)
  yaw   = yaw and (math.deg(yaw) % 360)
  roll  = roll and (math.deg(roll) + 540) % 360 - 180
  pitch = pitch and (math.deg(pitch) + 540) % 360 - 180

  local telem = linkUp()

  local sensorMissing = false
  for _, k in ipairs(REQUIRED) do
    if not has[k] then sensorMissing = true end
  end

  local fm = readPresent(has, S, "fm")
  local armed, armedKnown = armedFromFM(state, fm)

  -- Pitch nose up positive. Betaflight and INAV send nose down positive, ArduPilot
  -- nose up; the firmware from the first FM text that tells, unknown counts as Betaflight.
  if pitch then
    state.attFc = state.attFc or state.fcKind or M.fcFromFM(fm)
    if state.attFc ~= "AP" then pitch = -pitch end
  end

  -- DOP only for a caller that asked for it (the widget) and only on the ground
  -- before the first flight: after a landing ALT and DIST stay (finding the
  -- model), and ELRS is not switched to 1:2 again.
  -- The firmware is remembered from the first text that tells (Betaflight shows
  -- "!" or "?" right after power-up, before the fix or during the boot grace).
  local dop, fix
  if state.useMsp then
    if not state.fcKind then state.fcKind = M.fcFromFM(fm) end
    -- only with a known armed state, disarmed and before the flight page (only the
    -- preflight page shows the DOP; after arming the phase never returns to it)
    dop = pollDop(state, telem and armedKnown and not armed and state.phase ~= "FLIGHT", now)
    if state.fixAt and now - state.fixAt <= M.PARAMS.DOP_STALE_T * 1000 then
      fix = state.fixReply and M.parseRawGpsFix(state.fixReply, state.fcKind) or state.fix
    end
  end

  return {
    telem         = telem,
    gps           = gps,
    sats          = sats,
    gspd          = gspd,
    hdg           = hdg,
    alt           = alt,
    yaw           = yaw,
    roll          = roll,
    pitch         = pitch,
    armed         = armed,
    armedKnown    = armedKnown,
    fmText        = type(fm) == "string" and fm ~= "",   -- any FM text this sample
    alert         = M.alertFromFM(fm),
    homeReset     = fm == "HRST",   -- INAV: home moved to here by switch
    dop           = dop,
    -- Betaflight replies with PDOP, INAV and ArduPilot's passthrough carry HDOP
    dopKind       = (state.fcKind == "INAV" or state.fcKind == "AP") and "HDOP" or "PDOP",
    fix           = fix,   -- "NONE" / "2D" / "3D" from the same source as the DOP
    sensorMissing = sensorMissing,
  }
end

-- ---------------------------------------------------------------------------
-- State (caller-owned: no module state, one table per widget instance)
-- ---------------------------------------------------------------------------

-- Reset the whole per-flight state. Called for a fresh instance and on a
-- reconnect / ENDED-timeout (a reconnect counts as a new flight, FR-12). It does
-- NOT touch the flight phase (flightPhase owns it). Note this DROPS the last
-- position, so it must never run on the FLIGHT->ENDED transition (which freezes
-- the position for the ENDED screen).
function M.resetFlight(state)
  state.homeSet          = false
  state.homeLat          = nil
  state.homeLon          = nil
  state.homeAlt          = nil   -- altitude at home: ALT is shown relative to it
  state.groundLat        = nil   -- last position with a good fix while disarmed
  state.groundLon        = nil   -- (home at the arm edge, which a slow FM text
  state.groundAlt        = nil   --  reports late)
  state.lastHomeReset    = false -- last sample was INAV's "HRST" (edge detection)
  state.fixOkSince       = nil   -- fix stabilisation timer (nil = not started)
  state.fixLostSince     = nil   -- fix-loss debounce timer
  state.fixLost          = false
  state.ready            = false -- stable fix seen (READY screen) while home is unset
  state.homeLocked       = false -- moved before home was set (no FM): no home this flight
  state.moveSince        = nil   -- movement timer for the lock
  state.lastArmed        = nil   -- last armed state (nil = not seen yet; no edge)
  state.preReady         = false -- preflight check met on the last tick (for flightPhase)
  state.preHold          = nil   -- last online preflight values (sats, fixLost, DOP, fix)
  state.courseValid      = false -- debounced course validity (updateCourseValid)
  state.courseSince      = nil
  state.readyAnnounced   = false
  state.homeAnnounced    = false
  state.fixLostAnnounced = false
  state.flownM           = 0     -- distance flown this flight (m), for scripts that load the core
  state.track            = {}    -- flight track { lat, lon } for a search, oldest first
  state.flownLat         = nil   -- last point counted into flownM
  state.flownLon         = nil
  state.maxDistM         = nil   -- this flight's highest distance from home (m), altitude above
  state.maxAlt           = nil   -- home and ground speed (sensor units); for scripts that load
  state.maxGspd          = nil   -- the core
  state.altWarned        = false -- max-altitude announcement made, re-armed below MAX_ALT - MAX_ALT_HYST
  state.distWarned       = false -- max-distance announcement made, re-armed below MAX_DIST - MAX_DIST_HYST
  -- last valid telemetry holds (also the frozen ENDED position)
  state.lastLat  = nil
  state.lastLon  = nil
  state.lastSats = nil
  state.lastGspd = nil
  state.lastHdg  = nil
  state.lastAlt  = nil
  state.lastYaw  = nil
  state.lastRoll = nil
  state.yawWin      = nil   -- yaw offset learning window (learnYawOffset)
  state.yawOffset   = nil   -- learnt yaw minus course (deg) and when
  state.yawOffsetAt = nil
end

-- MSP polling starts anew with every link (a battery swap may bring another FC):
-- reset when the link is gone, so a request sent on the new link's first tick stays.
local function resetMsp(state)
  state.dop, state.dopAt = nil, nil   -- last DOP over MSP and when it came
  state.fix, state.fixAt = nil, nil   -- last fix type ("NONE" / "2D" / "3D") and when it came
  state.fixReply    = nil       -- or the MSP reply it is read from
  state.dopSentAt   = nil       -- last MSP request
  state.dopWaiting  = false     -- request sent, reply outstanding
  state.dopFirstAt  = nil       -- first request on this link
  state.dopAnswered = false     -- any reply on this link
  state.dopGaveUp   = false     -- no more requests on this link
  state.fcKind      = nil       -- "BF" / "INAV" / "AP" once the FM text or a passthrough frame told
  state.attFc       = nil       -- the same for the pitch sign, also without MSP
end

function M.newState()
  local s = {}
  M.resetFlight(s)
  resetMsp(s)
  s.phase = "WAITING"         -- flight phase (flightPhase); its link fields live here too
  s.dopSeq       = 0
  s.dopGround    = false      -- last tick was on the ground before the first flight (handleFrame)
  return s
end

-- ---------------------------------------------------------------------------
-- State machine (pure: mutates `state`, returns a result table; no I/O).
-- result.phase: the page (flightPhase: WAITING / PRE / FLIGHT / ENDED);
-- result.gpsState: ACQUIRING (no stable fix) / READY (stable fix, no home) /
-- HOME (home set). `now` is in ms.
-- ---------------------------------------------------------------------------
-- DOP and fix type only while disarmed and home not set yet (before the first flight).
local function setDop(result, snap)
  if snap.armedKnown and not snap.armed then
    if snap.dop then result.dop, result.dopKind = snap.dop, snap.dopKind end
    result.fix = snap.fix
  end
end

local function gpsStateOf(state)
  return state.homeSet and "HOME" or (state.ready and "READY" or "ACQUIRING")
end

-- Fix for the preflight check from an evaluate result: "ready" (stable fix),
-- "settling" (fix, not stable yet) or "nofix".
function M.fixState(r)
  if r.gpsState == "READY" or r.gpsState == "HOME" then return "ready" end
  return r.fixLost and "nofix" or "settling"
end

-- Preflight check met: fix ready and DOP good (DOP only known on the ground).
local function preflightMet(r)
  local pf = M.preflight(M.fixState(r), r.dop, r.dopKind)
  return pf.level == 0 and pf.dopStage == 0
end

-- End of an online tick: preflight check for flightPhase, and the preflight
-- values held for a dropout shorter than the link-loss time.
local function finishLive(state, result)
  state.preReady = preflightMet(result)
  state.preHold = { sats = result.sats, fixLost = result.fixLost, dop = result.dop,
                    dopKind = result.dopKind, fix = result.fix }
end

function M.evaluate(state, snap, now)
  local P      = M.PARAMS
  local result = {}

  -- Hold the last valid telemetry (frozen for the ENDED screen). Invalid samples
  -- arrive as nil and are ignored, so held values never regress to garbage.
  if snap.gps  then state.lastLat, state.lastLon = snap.gps.lat, snap.gps.lon end
  if snap.sats then state.lastSats = snap.sats end
  if snap.gspd then state.lastGspd = snap.gspd end
  if snap.hdg  then state.lastHdg  = snap.hdg  end
  if snap.alt  then state.lastAlt  = snap.alt  end
  if snap.yaw  then state.lastYaw  = snap.yaw  end
  if snap.roll then state.lastRoll = snap.roll end
  -- Attitude for an artificial horizon, the last values (kept across flights).
  state.attRoll, state.attPitch = snap.roll or state.attRoll, snap.pitch or state.attPitch
  result.roll, result.pitch = state.attRoll, state.attPitch

  -- Flight phase from the link, the armed state and the last tick's preflight
  -- check. A new flight (also after the end hold) starts from a clean state.
  local phase, event = flightPhase(state, snap.telem, snap.armed, state.preReady, now)
  if event == "end" or event == "lost" then resetMsp(state) end
  if event == "end" then
    -- Armed before the gap: link failure, the flight goes on when the link is
    -- back. Disarmed or unknown: the flight is over. Position frozen (FR-13).
    if not state.linkFailure then state.disarmSeen = nil end
    if state.homeSet and state.lastLat and state.lastLon then
      pcall(M.logFlight, state.lastLat, state.lastLon)
    end
  elseif event == "lost" then
    state.disarmSeen = nil   -- new flight, new proof needed
    M.resetFlight(state)     -- link gone before the flight page: nothing to show
  elseif event == "over" then
    state.disarmSeen = nil   -- hold elapsed: the flight's values stay until the next link
  elseif event == "new" then
    M.resetFlight(state)     -- a return of telemetry is a NEW flight (FR-12)
  end
  result.phase = phase

  -- ---- telemetry offline ----
  if not snap.telem then
    result.gpsState = gpsStateOf(state)
    local hold = phase == "PRE" and state.preHold   -- dropout shorter than the link-loss time
    if hold then
      result.sats, result.fixLost, result.dop, result.dopKind, result.fix =
        hold.sats, hold.fixLost, hold.dop, hold.dopKind, hold.fix
    end
    result.lastLat  = state.lastLat
    result.lastLon  = state.lastLon
    if phase == "ENDED" then
      result.flownM, result.maxDistM, result.track = state.flownM, state.maxDistM, state.track
      result.maxAlt, result.maxGspd  = state.maxAlt, state.maxGspd
    end
    return result
  end

  -- ---- telemetry online ----

  -- Current-sample fix validity: required sensors present, position plausible, and
  -- enough satellites -- all from THIS sample so a dropout breaks stabilisation.
  local fixOk = (not snap.sensorMissing)
            and snap.gps ~= nil
            and snap.sats ~= nil
            and snap.sats >= P.HOME_MIN_SATS

  -- INAV home reset: "HRST" comes for a few frames, act on its first one.
  local homeReset = snap.homeReset and not state.lastHomeReset and fixOk
  state.lastHomeReset = snap.homeReset or false

  -- ---- home not yet set (ACQUIRING / READY) ----
  if not state.homeSet then
    -- Stabilisation must be uninterrupted.
    if fixOk then
      if not state.fixOkSince then state.fixOkSince = now end
    else
      state.fixOkSince = nil
    end
    local fixStable = fixOk and (now - state.fixOkSince) >= P.HOME_STABLE_T * 1000

    local function setHome(lat, lon, alt)
      state.homeSet = true
      if lat then
        state.homeLat, state.homeLon, state.homeAlt = lat, lon, alt
      else
        state.homeLat, state.homeLon, state.homeAlt = snap.gps.lat, snap.gps.lon, state.lastAlt
      end
      if not state.homeAnnounced then
        result.homeSet      = true   -- one-shot event
        state.homeAnnounced = true
      end
    end

    -- With the armed state known, home is set exactly like Betaflight does it:
    -- at the disarmed -> armed edge, if the fix is good right then (no
    -- stabilisation). Arming without a fix just leaves home unset until the
    -- next edge on the ground. Without it, home is set at the first stable fix,
    -- unless the model already moved (then no home this flight).
    local armed, known = snap.armed, snap.armedKnown
    local canSetHome
    if known then
      if not armed and state.lastArmed == true then
        state.readyAnnounced = false     -- landed without home: announce ready again
      end
      canSetHome = not armed
    else
      if fixOk and snap.gspd and snap.gspd >= P.COURSE_MIN_SPD then
        if not state.moveSince then state.moveSince = now end
        if now - state.moveSince >= P.MOVE_LOCK_T * 1000 then state.homeLocked = true end
      else
        state.moveSince = nil
      end
      canSetHome = not state.homeLocked
    end

    -- "Ready to fly": once per stable fix while home could be set now; re-armed
    -- when the fix drops (and on disarm, above).
    if fixStable and canSetHome and not state.readyAnnounced then
      result.readyEvent    = true
      state.readyAnnounced = true
    end
    if not fixOk then state.readyAnnounced = false end

    if known then
      if armed and state.lastArmed == false and fixOk then
        -- The FM text can arrive up to 2 s late (ArduPilot), when the model
        -- may already fly: use the last position seen on the ground.
        setHome(state.groundLat, state.groundLon, state.groundAlt)
      elseif homeReset then
        setHome()
      end
      if not armed then
        if fixOk then
          state.groundLat, state.groundLon, state.groundAlt = snap.gps.lat, snap.gps.lon, state.lastAlt
        else
          state.groundLat, state.groundLon, state.groundAlt = nil, nil, nil
        end
      end
      state.lastArmed = armed
    elseif homeReset then
      setHome()
    elseif fixStable and canSetHome then
      setHome()
    end

    if not state.homeSet then
      -- READY (live view, no home elements) from the first stable fix; a fix
      -- loss falls back to ACQUIRING only after the same debounce ACTIVE uses.
      if fixStable then state.ready = true end
      if state.ready then
        if fixOk then
          state.fixLostSince = nil
        else
          if not state.fixLostSince then state.fixLostSince = now end
          if now - state.fixLostSince >= P.FIX_LOSS_T * 1000 then
            state.ready, state.fixLostSince = false, nil
          end
        end
      end
      result.gpsState      = gpsStateOf(state)
      result.noHome        = state.ready and not canSetHome   -- armed / locked: no home coming
      result.sats          = snap.sats or state.lastSats
      result.gspd          = state.lastGspd   -- no ALT without home: nothing to be relative to
      result.fixLost       = not fixOk
      M.learnYawOffset(state, state.lastGspd, state.lastHdg, state.lastYaw, state.lastRoll, now)
      result.courseValid, result.course, result.noseEstimated = M.noseOf(state, now)
      result.sensorMissing = snap.sensorMissing
      setDop(result, snap)
      finishLive(state, result)
      return result
    end
    state.fixLostSince = nil   -- clean slate for the ACTIVE debounce
  end

  -- ---- home set (HOME) ----

  -- Fix-loss debounce: display stays put with the last valid values; only the
  -- flag (and the one-shot events) flip once the loss/return is confirmed.
  if not fixOk then
    if not state.fixLostSince then state.fixLostSince = now end
    if not state.fixLost and (now - state.fixLostSince) >= P.FIX_LOSS_T * 1000 then
      state.fixLost = true
      if not state.fixLostAnnounced then
        result.fixLostEvent    = true    -- one-shot for the sound
        state.fixLostAnnounced = true
      end
    end
  else
    state.fixLostSince = nil
    if state.fixLost then
      state.fixLost          = false
      state.fixLostAnnounced = false   -- re-arm so a later loss re-announces
      result.fixRecovered    = true
    end
  end

  -- INAV home reset in flight: follow the FC, keep the altitude reference
  -- (INAV keeps its home altitude too) and announce the new home.
  if homeReset then
    state.homeLat, state.homeLon = snap.gps.lat, snap.gps.lon
    result.homeSet = true
  end

  -- Distance flown: summed in steps of at least FLOWN_STEP_M, so GPS jitter
  -- while standing still adds nothing. With FM only while armed: disarmed, the
  -- reference point follows the model, so carrying it back adds nothing. A glitch
  -- jump is skipped, and so is the jump back.
  -- Flight track for a search: a point every TRACK_STEP_M, like the distance only
  -- while armed when FM tells; the last TRACK_MAX points are kept.
  if fixOk and not (snap.armedKnown and not snap.armed) then
    local g, tr = snap.gps, state.track
    local last = tr[#tr]
    if not last or M.haversine(last[1], last[2], g.lat, g.lon) >= P.TRACK_STEP_M then
      tr[#tr + 1] = { g.lat, g.lon }
      if #tr > P.TRACK_MAX then table.remove(tr, 1) end
    end
  end

  if fixOk then
    local g = snap.gps
    if not state.flownLat or (snap.armedKnown and not snap.armed) then
      state.flownLat, state.flownLon = g.lat, g.lon
    else
      local d = M.haversine(state.flownLat, state.flownLon, g.lat, g.lon)
      if d >= P.FLOWN_STEP_M then
        if d <= P.FLOWN_JUMP_M then state.flownM = state.flownM + d end
        state.flownLat, state.flownLon = g.lat, g.lon
      end
    end
  end

  -- Derived display values from the last valid telemetry.
  local lat, lon = state.lastLat, state.lastLon
  if lat and lon and state.homeLat then
    result.distanceM     = M.haversine(lat, lon, state.homeLat, state.homeLon)
    result.bearingToHome = M.bearingTo(lat, lon, state.homeLat, state.homeLon)
    result.sector        = M.sectorOf(result.bearingToHome)
    M.learnYawOffset(state, state.lastGspd, state.lastHdg, state.lastYaw, state.lastRoll, now)
    -- GPS course (or the yaw estimate while hovering), for the compass ring
    result.courseValid, result.course, result.noseEstimated = M.noseOf(state, now)
    if result.courseValid then result.rel = M.relAngle(result.bearingToHome, result.course) end
    -- (Nearly) on the home point: any direction to it would be GPS noise.
    result.atHome = result.distanceM < P.HOME_NEAR_M
  end

  -- Flight maxima, like the flown distance only while armed when FM tells.
  local alt = state.lastAlt and state.homeAlt and state.lastAlt - state.homeAlt
  if not (snap.armedKnown and not snap.armed) then
    local d, g = result.distanceM, state.lastGspd
    if d and (not state.maxDistM or d > state.maxDistM) then state.maxDistM = d end
    if alt and (not state.maxAlt or alt > state.maxAlt) then state.maxAlt = alt end
    if g and (not state.maxGspd or g > state.maxGspd) then state.maxGspd = g end
    -- Max altitude: one announcement per climb above the limit.
    if P.MAX_ALT > 0 and alt then
      if not state.altWarned and alt > P.MAX_ALT then
        state.altWarned = true
        result.altEvent = true   -- one-shot for the sound
      elseif state.altWarned and alt < P.MAX_ALT - P.MAX_ALT_HYST then
        state.altWarned = false
      end
    end
    -- Max distance: the same, in display units (ft when imperial).
    if P.MAX_DIST > 0 and d then
      local du = P.UNITS == "imperial" and d * 3.28084 or d
      if not state.distWarned and du > P.MAX_DIST then
        state.distWarned = true
        result.distEvent = true
      elseif state.distWarned and du < P.MAX_DIST - P.MAX_DIST_HYST then
        state.distWarned = false
      end
    end
  end

  result.gpsState          = "HOME"
  result.sats              = snap.sats or state.lastSats
  result.alt               = alt
  result.gspd              = state.lastGspd
  result.lastLat           = lat
  result.lastLon           = lon
  result.flownM            = state.flownM
  result.track             = state.track
  result.maxDistM          = state.maxDistM
  result.maxAlt            = state.maxAlt
  result.maxGspd           = state.maxGspd
  result.altOver           = P.MAX_ALT > 0 and state.altWarned    -- over the limit (until the hysteresis)
  result.distOver          = P.MAX_DIST > 0 and state.distWarned
  result.fixLost           = state.fixLost   -- persistent flag: widget colours sats red
  result.alert             = snap.alert      -- "RTH" / "FS" from the FC, nil otherwise
  result.sensorMissing = snap.sensorMissing
  finishLive(state, result)
  return result
end

-- ---------------------------------------------------------------------------
-- Orchestration: one full cycle read -> evaluate -> event sounds.
-- ---------------------------------------------------------------------------

local function playSound(file)
  if playFile and type(file) == "string" and M.PARAMS.AUDIO ~= false then
    playFile(M.SOUND_DIR .. file)
  end
end

-- Vibrate alongside an event (HAPTIC_PULSES pulses). No-op when haptic is off
-- or the build lacks playHaptic (desktop tests / motorless radios).
local function eventHaptic(key)
  if not M.PARAMS.HAPTIC or not playHaptic then return end
  local dur    = M.HAPTIC_DUR[M.PARAMS.HAPTIC_STRENGTH] or M.HAPTIC_DUR[2]
  local pulses = M.HAPTIC_PULSES[key] or 1
  for i = 1, pulses do
    playHaptic(dur, (i < pulses) and dur or 0)   -- gap between pulses, none after the last
  end
end

-- Restarts the backlight timeout so a dark display lights up with a warning.
local function wakeDisplay()
  if lcd and lcd.resetBacklightTimeout then lcd.resetBacklightTimeout() end
end

-- Sound plus haptic cue for one event. A muted event (SOUNDS.key == false, or
-- all sounds off via AUDIO) skips playFile but still buzzes: haptic has its own
-- on/off setting.
local function announce(key)
  playSound(M.SOUNDS[key])
  eventHaptic(key)
end

function M.update(state, now)
  now = now or nowMs()
  M.pollConfig(now)
  local snap   = M.readSnapshot(state, now)
  local result = M.evaluate(state, snap, now)
  result.snapshot = snap

  -- Each event fires once per transition (evaluate guarantees the one-shot).
  -- A missing WAV plays silently, no error.
  if result.readyEvent   then announce("ready") end
  if result.homeSet      then announce("fix")  end
  if result.fixLostEvent then announce("lost"); wakeDisplay() end
  if result.fixRecovered then announce("rec")  end
  if result.altEvent     then announce("alt"); wakeDisplay() end
  if result.distEvent    then announce("dist"); wakeDisplay() end

  return result
end

return M

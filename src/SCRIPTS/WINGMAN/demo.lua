-- =====================================================================
-- demo.lua  --  Test data for the simulator (dev tool only).
-- =====================================================================
-- SD card path: /SCRIPTS/WINGMAN/demo.lua
--
-- With core.DEMO = true the core takes link, flight mode and the page values
-- from here. PAGE picks the page:
--   "flight": armed, 40 s loop of four 10 s states (normal, warning, critical,
--             return to home).
--   "pre":    disarmed, 40 s loop of four 10 s states (pack selection, GO,
--             CHECK with arming blocked, CHECK with critical values).
--   "post":   after unplugging, 40 s loop: 20 s a normal flight without alerts,
--             20 s a flight with limits reached and seven alerts (shows "+1").
--   "wait":   no telemetry, wait page with the mascot.
--   "search": 40 s loop, 25 s crashed with the link up (signal wanders), 15 s
--             link lost (the last position ages 20 times faster than real time).
-- =====================================================================
local PAGE = "post"
-- Wait page: setup error (GPS Homer missing, Link Sentinel too old) with the sad mascot.
local CORE_WARN = false

-- Flight page: course and bearing to home in degrees (north up), rel = home
-- relative to the course (positive = right).
-- Values near their widest (6S, long range, longest ELRS mode names) to check the layout.
local BATT = { name = "6S Li-Ion 8000mAh #12", cap = 8000, warn = 30, crit = 15 }
local STATES = {
  { pct = 100, volt = 25.2, cell = 4.20, left = 8000, used = 0, amps = 128.4,
    sats = 24, course = 300, rel = 35, dist = 12850, alt = 1250,
    range = 29, stage = 0, lq = 100, rssi = -79, ant = 1, tpwr = 1000,
    mode = "ACRO", modeName = "X100Hz Full", timer = 3417 },
  { pct = 28, volt = 21.0, cell = 3.50, left = 2240, used = 5760, amps = 99.9,
    sats = 8, course = 20, rel = 150, dist = 9999, alt = 888,
    range = 78, stage = 1, lq = 78, rssi = -101, ant = 2, tpwr = 250,
    mode = "ACRO", modeName = "333Hz Full", timer = 3541 },
  { pct = 11, volt = 20.1, cell = 3.35, left = 880, used = 7120, amps = 142.7,
    sats = 5, course = 250, rel = -110, dist = 15120, alt = 1064,
    range = 94, stage = 2, lq = 41, rssi = -113, ant = 1, tpwr = 1000,
    mode = "ACRO", modeName = "K1000 Full", timer = 3588 },
  { pct = 41, volt = 21.9, cell = 3.65, left = 3280, used = 4720, amps = 14.9,
    sats = 12, course = 210, rel = 0, dist = 10298, alt = 130,
    range = 66, stage = 0, lq = 92, rssi = -96, ant = 2, tpwr = 500,
    mode = "RTH", modeName = "F1000", alert = "RTH", timer = 2888 },
}

local function flight(w, t, core)
  local s = STATES[math.floor(t / 10) % #STATES + 1]
  w.linkUp, w.rssi = true, s.lq
  w.mode, w.alert, w.phase, w.armed = s.mode, s.alert, core.FLIGHT, true
  w.timerS = s.timer + math.floor(t % 10)
  return "flight", {
    batt = { name = BATT.name, cap = BATT.cap, warn = BATT.warn, crit = BATT.crit, pct = s.pct,
             volt = s.volt, cell = s.cell, left = s.left, used = s.used, amps = s.amps },
    gps  = { sats = s.sats, course = s.course, bearing = (s.course + s.rel) % 360, rel = s.rel,
             dist = s.dist, alt = s.alt, gpsState = "HOME", courseValid = true },
    link = { modLine = "NOMAD (v4.1.0)", range = s.range, stage = s.stage, mode = s.modeName, lq = s.lq,
             rssi = s.rssi, ant = s.ant, tpwr = s.tpwr },
  }
end

-- Preflight page: pack selection, ready, two CHECK states. Pack names without
-- the manufacturer; one long custom name to see it cut.
local PACKS = { { name = "6s Li-Ion 8000mAh", pos = 12, cycles = 8 },
                { name = "6s Li-Ion 8000mAh", pos = 3, cycles = 41 },
                { name = "Long range pack for the big wing", pos = 1, cycles = 120 },
                { name = "6s LiPo 1300mAh", pos = 2, cycles = 17 } }
local PRE = {
  { pct = 100, sats = 14, gps = "ready", dop = 1.4, fix = "3D", lq = 100, stage = 0, rssi = -42 },
  { pct = 100, sats = 14, gps = "ready", dop = 1.4, fix = "3D", lq = 100, stage = 0, rssi = -42 },
  { pct = 24, sats = 9, gps = "settling", dop = 3.1, fix = "3D", lq = 100, stage = 0, rssi = -45,
    blocked = true, reason = "RXLOSS, THROTTLE, ANGLE, ARM_SWITCH" },
  { pct = 12, sats = 4, gps = "nofix", fix = "NONE", lq = 38, stage = 2, rssi = -109, blocked = true },
}

local function pre(w, t, core)
  local i = math.floor(t / 10) % #PRE + 1
  local s, ts = PRE[i], t % 10
  w.linkUp, w.rssi, w.phase, w.armed = true, s.lq, core.PRE, false
  w.mode, w.alert, w.armBlocked = "ACRO", nil, s.blocked or false
  local cell = 3.30 + 0.90 * s.pct / 100
  local batt = { name = "6s Li-Ion 8000mAh #12", warn = BATT.warn, crit = BATT.crit, pct = s.pct,
                 cell = cell, volt = cell * 6 }
  if i == 1 then   -- selection: cursor steps down, then the confirm hold fills
    batt.packs = PACKS
    batt.cursor = math.min(3, 1 + math.floor(ts / 2))
    batt.hold = (ts >= 6) and math.min(1, (ts - 6) / 2) or 0
  end
  return "pre", {
    batt = batt,
    gps  = { sats = s.sats, state = s.gps, dop = s.dop, dopKind = "PDOP", fix = s.fix },
    link = { modLine = "NOMAD (v4.1.0)", lq = s.lq, stage = s.stage, mode = "X100Hz Full", rssi = s.rssi,
             tpwr = 1000 },
    armBlocked = s.blocked, armReason = s.reason, fcInfo = "BTFL 2025.12.4, STM32F7X2",
  }
end

-- Post-flight page: values near their widest, parallel packs in the second.
local POST = {
  { time = "04:52", batt = { name = "6s Li-Ion 4000mAh #3", used = 2720, start = 100, left = 32, volt = 22.3,
      cell = 3.72, maxA = 58.2, cycles = "42", warn = 30, crit = 15 },
    gps = { flown = 2310, maxDist = 412, maxAlt = 86, maxSpd = 94, lat = 47.26771, lon = 11.39436 },
    link = { modLine = "NOMAD (v4.1.0)", minLq = 87, maxRange = 58, maxTpwr = 250, mode = "250Hz",
      lqStage = 0, rangeStage = 0 },
    alerts = {} },
  { time = "57:31", batt = { name = "6s Li-Ion 8000mAh #1+2", used = 15200, start = 78, left = 5, volt = 20.9,
      cell = 3.48, maxA = 142.7, cycles = "118, 117", warn = 30, crit = 15 },
    gps = { flown = 14810, maxDist = 15120, maxAlt = 1250, maxSpd = 188, lat = -47.273110, lon = -111.401270 },
    link = { modLine = "NOMAD (v4.1.0)", minLq = 41, maxRange = 94, maxTpwr = 1000, mode = "X100Hz Full",
      lqStage = 2, rangeStage = 2 },
    alerts = { { t = 125, text = "GPS fix lost", level = 2 }, { t = 1920, text = "Link warning", level = 1 },
      { t = 2512, text = "Max altitude", level = 1 }, { t = 2958, text = "Battery 30 %", level = 1 },
      { t = 3044, text = "Link critical", level = 2 }, { t = 3302, text = "Return to home", level = 1 },
      { t = 3422, text = "Battery 15 %", level = 2 } } },
}

local function post(w, t, core)
  local i = math.floor(t / 20) % #POST + 1
  w.linkUp, w.rssi, w.mode, w.alert, w.phase, w.armed = false, 0, nil, nil, core.ENDED, false
  local v = {}
  for k, x in pairs(POST[i]) do v[k] = x end
  v.leftS = math.floor(core.ENDED_HOLD_T / 1000) - math.floor(t % 20)
  return "post", v
end

-- Search page: flight track in metres north, east of home; the last point is
-- the crash site.
local HOME_LAT, HOME_LON = 47.267634, 11.394319
local TRACK_M = { { 0, 0 }, { 55, 48 }, { 142, 72 }, { 225, 32 }, { 252, -55 },
                  { 218, -152 }, { 162, -188 }, { 123, -137 } }
local LOST_AT = 25

local track = {}
for i, p in ipairs(TRACK_M) do
  track[i] = { HOME_LAT + p[1] / 111320,
               HOME_LON + p[2] / (111320 * math.cos(math.rad(HOME_LAT))) }
end
local crash = track[#track]

local function search(w, t, core)
  local live = t < LOST_AT
  w.linkUp = live
  w.rssi = live and math.floor(62 + 6 * math.sin(t)) or 0
  w.mode = live and "ACRO" or nil
  w.phase = live and core.PRE or core.WAITING
  return "search", { homeLat = HOME_LAT, homeLon = HOME_LON, lat = crash[1], lon = crash[2],
                     track = track, course = 200, sats = 9, alt = 2, live = live,
                     ageS = live and 0 or math.floor((t - LOST_AT) * 20) }
end

return function(w, now, core, page)
  local t = (now / 100) % 40
  if (page or PAGE) == "wait" then
    w.linkUp, w.rssi, w.mode, w.phase = false, 0, nil, core.WAITING
    if CORE_WARN then w.err.gps, w.err.link = "missing", "version" end
    return "wait"
  end
  if (page or PAGE) == "search" then return search(w, t, core) end
  if (page or PAGE) == "pre" then return pre(w, t, core) end
  if (page or PAGE) == "post" then return post(w, t, core) end
  return flight(w, t, core)
end

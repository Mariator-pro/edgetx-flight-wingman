-- =====================================================================
-- core.lua  --  Logic core for Flight Wingman (no lcd.*).
-- =====================================================================
-- SD card path: /SCRIPTS/WINGMAN/core.lua
--
-- Loads the battery, link and GPS cores of the sibling projects, drives them
-- (one tick, one CRSF queue) and detects the flight phase.
-- =====================================================================

local M = {}
-- Single source of the version; the settings tool reads VERSION and API as
-- text from the head of this file (keep them near the top).
M.VERSION = "1.0.0"
M.API     = { 1, 0 }

-- Simulator test data for the flight, preflight or search page (/SCRIPTS/WINGMAN/demo.lua).
-- Must be false on the radio: it replaces link, mode and the page values.
M.DEMO = false

local TICK        = 10    -- getTime() units: 0.1 s
local MAX_POPS    = 20    -- CRSF frames drained per tick

-- Sibling cores and the interface version Wingman needs: same first number,
-- at least the second.
M.CORES = {
  lipo = { path = "/SCRIPTS/LIPONY/core.lua",   api = { 1, 0 } },
  link = { path = "/SCRIPTS/SNTNL/core.lua",    api = { 1, 0 } },
  gps  = { path = "/SCRIPTS/GPSHOMER/core.lua", api = { 1, 0 } },
}

-- Phases (flightPhase): no telemetry / preflight / flight / after unplugging.
M.WAITING, M.PRE, M.FLIGHT, M.ENDED = "WAITING", "PRE", "FLIGHT", "ENDED"

-- Returns the module, or nil plus "missing" / "version".
local function loadCore(c)
  local chunk = loadScript(c.path)
  if not chunk then return nil, "missing" end
  local ok, mod = pcall(chunk)
  if not ok or type(mod) ~= "table" then return nil, "missing" end
  local api = mod.API
  if type(api) ~= "table" or api[1] ~= c.api[1] or (api[2] or -1) < c.api[2] then
    return nil, "version"
  end
  return mod
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
-- Fresh state: loads the cores once and creates their contexts. err[name] tells
-- why a core is not available ("missing" / "version").
function M.new()
  local w = { phase = M.WAITING, fs = {}, mods = {}, err = {}, fm = {}, lastTick = 0 }
  for name, c in pairs(M.CORES) do
    w.mods[name], w.err[name] = loadCore(c)
  end
  local m = w.mods
  if m.lipo then
    w.lipo = m.lipo.newContext()
    m.lipo.pollConfig(w.lipo)
  end
  if m.link then w.link = m.link.newState() end
  if m.gps then
    w.gps = m.gps.newState()
    w.gps.useMsp = true
  end
  if M.DEMO then
    local chunk = loadScript("/SCRIPTS/WINGMAN/demo.lua")
    if chunk then w.demo = chunk() end
  end
  return w
end

local mspFrame   -- MSP reply handler, defined with the MSP functions below

-- One queue for all cores: each frame goes to every enabled core.
local function pollFrames(w, on)
  if not crossfireTelemetryPop then return end
  for _ = 1, MAX_POPS do
    local cmd, data = crossfireTelemetryPop()
    if cmd == nil then break end
    mspFrame(w, cmd, data)
    if on.link and w.link then w.mods.link.handleFrame(w.link, cmd, data) end
    if on.gps and w.gps then w.mods.gps.handleFrame(w.gps, cmd, data) end
  end
end

-- Flight mode text for display: without the disarm marker (Betaflight "*", "!",
-- "?"; ArduPilot " *") and trailing spaces. "!FS!" stays as it is.
function M.modeText(fm)
  if type(fm) ~= "string" or fm == "" then return nil end
  if fm ~= "!FS!" then fm = string.gsub(fm, "[%*!%?]$", "") end
  fm = string.gsub(fm, "%s+$", "")
  if fm == "" then return nil end
  return fm
end

-- Arming blocked: Betaflight appends "!", INAV sends "!ERR"; "!FS!" is failsafe.
function M.armBlockedFM(fm)
  if type(fm) ~= "string" or fm == "!FS!" then return false end
  return fm == "!ERR" or string.sub(fm, -1) == "!"
end

-- ---------------------------------------------------------------------------
-- MSP over CRSF: FC info once per link (firmware, version, board) and, while
-- arming is blocked, the reasons. One request at a time, never while the GPS
-- core waits for its own reply; only disarmed. Each request makes ELRS switch
-- telemetry to 1:2 for a few seconds.
-- ---------------------------------------------------------------------------
local MSP_REQ, MSP_RESP   = 0x7A, 0x7B
local ADDR_FC, ADDR_RADIO = 0xC8, 0xEA
M.MSP_FC_VARIANT, M.MSP_FC_VERSION, M.MSP_BOARD_INFO = 2, 3, 4
M.MSP_STATUS_EX, M.MSP2_INAV_STATUS = 150, 0x2000
local MSP_TIMEOUT  = 100   -- getTime units: 1 s for a reply
local MSP_GIVE_UP_T = 1000 -- no reply at all 10 s after the FC's first FM text: give up (ArduPilot never answers)
local REASON_EVERY = 200   -- 2 s between arming status polls

-- Arming-disable flag names, Betaflight bit 0 upwards (as its OSD); the last
-- flag the FC reports is always ARM_SWITCH.
local BF_ARMING = { "NOGYRO", "FAILSAFE", "RXLOSS", "NOT_DISARMED", "BOXFAILSAFE", "RUNAWAY", "CRASH",
  "THROTTLE", "ANGLE", "BOOTGRACE", "NOPREARM", "LOAD", "CALIB", "CLI", "CMS", "BST", "MSP", "PARALYZE",
  "GPS", "RESCUE_SW", "DSHOT_TELEM", "REBOOT_REQD", "DSHOT_BBANG", "NO_ACC_CAL", "MOTOR_PROTO",
  "FLIP_SWITCH", "ALT_HOLD_SW", "POS_HOLD_SW", "AUTOPILOT_SW" }
-- INAV arming flags by bit (bits below 6 are state, not reasons).
local INAV_ARMING = { [6] = "GEOZONE", [7] = "FAILSAFE", [8] = "NOT_LEVEL", [9] = "CALIBRATING",
  [10] = "OVERLOAD", [11] = "NAV_UNSAFE", [12] = "COMPASS_CAL", [13] = "ACC_CAL", [14] = "ARM_SWITCH",
  [15] = "HW_FAILURE", [16] = "BOXFAILSAFE", [18] = "RC_LINK", [19] = "THROTTLE", [20] = "CLI",
  [21] = "CMS", [22] = "OSD", [23] = "ROLLPITCH", [24] = "SERVO_TRIM", [25] = "OOM", [26] = "SETTINGS",
  [27] = "PWM_OUTPUT", [28] = "NOPREARM", [29] = "DSHOT_BEEPER", [30] = "LANDED" }

-- CRSF payload of an MSP request without data: MSPv1, or MSPv2 for a command
-- above 255 (status: version, start flag, sequence 0..15).
function M.mspRequest(seq, cmd)
  if cmd > 255 then
    return { ADDR_FC, ADDR_RADIO, 0x50 + seq % 16, 0, cmd % 256, math.floor(cmd / 256), 0, 0 }
  end
  return { ADDR_FC, ADDR_RADIO, 0x30 + seq % 16, 0, cmd }
end

-- First chunk of an MSP reply (v1 or v2): cmd and the payload bytes it holds
-- (a long reply's later chunks are not needed); nil for anything else.
function M.mspReply(data)
  if type(data) ~= "table" or data[1] ~= ADDR_RADIO or data[2] ~= ADDR_FC then return nil end
  local status = data[3] or 0
  if status >= 128 or math.floor(status / 16) % 2 ~= 1 then return nil end   -- error or not a start
  local version, cmd, first = math.floor(status / 32) % 4, nil, nil
  if version == 1 then
    cmd, first = data[5], 6
  elseif version == 2 then
    cmd, first = (data[5] or 0) + (data[6] or 0) * 256, 9
  else
    return nil
  end
  local p = {}
  for i = first, #data do p[#p + 1] = data[i] end
  return cmd, p
end

local function u32(p, i)
  if not p[i + 3] then return nil end
  return p[i] + p[i + 1] * 256 + p[i + 2] * 65536 + p[i + 3] * 16777216
end
local function ascii(p, i, n)
  local t = {}
  for k = i, i + n - 1 do
    local b = p[k]
    if not b then break end
    if b >= 32 and b < 127 then t[#t + 1] = string.char(b) end
  end
  return table.concat(t)
end

-- Arming reasons from a status reply as "A, B" (nil when none or unreadable):
-- Betaflight MSP_STATUS_EX, INAV MSP2_INAV_STATUS.
function M.armingReasons(cmd, p)
  local names = {}
  if cmd == M.MSP_STATUS_EX then
    local n = p[16]
    if not n then return nil end
    local count, flags = p[17 + n] or 32, u32(p, 18 + n)
    if not flags then return nil end
    for bit = 0, count - 1 do
      if math.floor(flags / 2 ^ bit) % 2 == 1 then
        names[#names + 1] = (bit == count - 1) and "ARM_SWITCH" or BF_ARMING[bit + 1] or ("FLAG " .. bit)
      end
    end
  elseif cmd == M.MSP2_INAV_STATUS then
    local flags = u32(p, 10)
    if not flags then return nil end
    for bit = 6, 31 do
      if math.floor(flags / 2 ^ bit) % 2 == 1 and INAV_ARMING[bit] then names[#names + 1] = INAV_ARMING[bit] end
    end
  else
    return nil
  end
  if #names == 0 then return nil end
  return table.concat(names, ", ")
end

-- Takes one popped frame; true when it was the awaited MSP reply.
mspFrame = function(w, cmd, data)
  local m = w.msp
  if not m or not m.waiting or cmd ~= MSP_RESP then return false end
  local rcmd, p = M.mspReply(data)
  if rcmd ~= m.waiting then return false end
  m.waiting, m.answered = nil, true
  if rcmd == M.MSP_FC_VARIANT then
    m.variant = ascii(p, 1, 4)
  elseif rcmd == M.MSP_FC_VERSION then
    local len = p[4]
    if len and len > 0 and p[4 + len] then
      m.version = ascii(p, 5, len)   -- newer Betaflight: version text
    elseif p[3] then
      m.version = string.format("%d.%d.%d", p[1], p[2], p[3])
    else
      m.version = ""
    end
  elseif rcmd == M.MSP_BOARD_INFO then
    local len = p[9]
    m.board = (len and len > 0 and p[9 + len]) and ascii(p, 10, len) or ascii(p, 1, 4)
  else
    m.reason = M.armingReasons(rcmd, p)
    m.reasonAt = getTime()
  end
  return true
end

-- FM text from the FC on this link, not a stale one from before the loss.
local function fmCurrent()
  if getSourceValue then
    local v, current = getSourceValue("FM")
    return v ~= nil and current == true
  end
  local fm = getValue("FM")
  return type(fm) == "string" and fm ~= ""
end

-- One MSP step per tick: drop a request after its timeout, then send the next
-- when the CRSF module takes one. Without any reply 10 s after the FC's first FM
-- text it gives up until the next link (a booting FC is still asked). Results:
-- w.fcInfo, w.armReason.
local function pollMsp(w, now, armed)
  if not w.linkUp or armed or not crossfireTelemetryPush then return end
  w.msp = w.msp or { seq = 0 }
  local m = w.msp
  if not m.fmAt and fmCurrent() then m.fmAt = now end
  if m.waiting and now - m.sentAt >= MSP_TIMEOUT then m.waiting = nil end
  if not w.armBlocked then m.reason, m.reasonAt = nil, nil end
  if m.waiting or (not m.answered and m.fmAt and now - m.fmAt >= MSP_GIVE_UP_T) then return end
  -- The GPS core asks for its PDOP every second on the ground: send only while
  -- its request is answered and its next one is at least 0.5 s away.
  local g = w.gps
  if g and g.dopWaiting then return end
  if g and g.dopGround and g.dopSentAt and now * 10 - g.dopSentAt > 500 then return end
  local cmd
  if not m.variant then cmd = M.MSP_FC_VARIANT
  elseif not m.version then cmd = M.MSP_FC_VERSION
  elseif not m.board then cmd = M.MSP_BOARD_INFO
  elseif w.armBlocked and (not m.reasonAt or now - m.reasonAt >= REASON_EVERY) then
    if m.variant == "BTFL" then cmd = M.MSP_STATUS_EX elseif m.variant == "INAV" then cmd = M.MSP2_INAV_STATUS end
  end
  if not cmd or not crossfireTelemetryPush() then return end   -- false: buffer busy
  crossfireTelemetryPush(MSP_REQ, M.mspRequest(m.seq, cmd))
  m.seq, m.waiting, m.sentAt = (m.seq + 1) % 16, cmd, now
  if cmd == M.MSP_STATUS_EX or cmd == M.MSP2_INAV_STATUS then m.reasonAt = now end
end

-- FC info line ("BTFL 4.5.1, SPEEDYBEEF405") once the variant is known.
local function fcInfoText(m)
  if not m or not m.variant or m.variant == "" then return nil end
  local t = m.variant
  if m.version and m.version ~= "" then t = t .. " " .. m.version end
  if m.board and m.board ~= "" then t = t .. ", " .. m.board end
  return t
end

-- Armed works without any sibling core (own armedFromFM). The phase comes from
-- flightPhase on its own state w.fs (w.phase is the page and may be overridden
-- below: calculating, setup error); w.preReady is the last tick's GO.
local function updatePhase(w, now)
  local up = linkUp()
  w.linkUp = up   -- packets arriving right now (no grace), e.g. for a heartbeat
  w.rssi = getRSSI()   -- 0..99, meaning differs per radio system (CRSF: LQ %, FrSky: dB)
  local armed = false
  if up then
    local fm = getValue("FM")
    w.mode = M.modeText(fm)
    -- Failsafe, rescue or landing from the mode text ("FS", "RTH", "LAND").
    local alertFromFM = w.mods.gps and w.mods.gps.alertFromFM
    w.alert = alertFromFM and alertFromFM(fm) or nil
    armed = armedFromFM(w.fm, fm)
    w.armBlocked = not armed and M.armBlockedFM(fm)
    pollMsp(w, now, armed)
    w.fcInfo = fcInfoText(w.msp)
    w.armReason = w.armBlocked and w.msp and w.msp.reason or nil
  end
  w.armed = armed
  local phase, event = flightPhase(w.fs, up, armed, w.preReady, now * 10)
  if event == "end" or event == "lost" then
    w.mode, w.alert, w.armBlocked = nil, nil, nil
    w.msp, w.fcInfo, w.armReason = nil, nil, nil   -- a new link may be another FC
  end
  -- Lost while armed (dropout at range): the FC stays armed and its text has no
  -- marker on the way back, so the proof is kept for the resumed flight.
  if event == "lost" or event == "over" or (event == "end" and not w.fs.linkFailure) then
    w.fm.disarmSeen = nil
  end
  if event == "resume" then w.resumed = true end
  w.phase = phase
  w.connected = phase == M.PRE or phase == M.FLIGHT   -- link up, short gaps included
end

-- Preflight page: status line per column ({ text, level }, level 0 ok, 1
-- warning, 2 critical), DOP stage, ready field "GO" / "CHECK" and the line next
-- to it. p = { batt, gps, link, armBlocked, armReason }; a module that is off is
-- nil and does not count. batt.packs set = selection open (no status line).
-- The checks come from the cores (mods = w.mods: preflight of each, lqLevel of
-- the link core for the LQ value).
function M.preflightStatus(p, mods)
  mods = mods or {}
  local s, check = {}, p.armBlocked or false
  local b, g, l = p.batt, p.gps, p.link
  if b and b.packs then
    check = true
  elseif b and mods.lipo then
    s.batt = mods.lipo.preflight(b.pct, b.warn, b.crit)
    check = check or s.batt.level > 0
  end
  if g and mods.gps then
    s.gps = mods.gps.preflight(g.state, g.dop, g.dopKind)
    s.dopStage = s.gps.dopStage
    check = check or s.gps.level > 0 or s.dopStage > 0
  end
  if l and mods.link then
    s.link = mods.link.preflight(l.stage, l.sensLimit)
    if mods.link.lqLevel and l.lq then s.lqLevel = mods.link.lqLevel(l.lq) end
    check = check or s.link.level > 0
  end
  s.ready = check and "CHECK" or "GO"
  if p.armBlocked then
    s.line = p.armReason and ("Arming blocked: " .. p.armReason) or "Arming blocked"
  elseif not check then
    s.line = "All modules ready"
  end
  return s
end

-- ---------------------------------------------------------------------------
-- Page data from the cores (without demo): preflight, flight, search and
-- post-flight views, alerts with their flight time. Only display values; all
-- judgement stays in the cores.
-- ---------------------------------------------------------------------------

-- Pack label "Tattu 4s LiPo 1500mAh #3" (parallel "#1+2") and, for an automatic
-- name, the same without the manufacturer ("4s LiPo 1500mAh #3") for a title that
-- is too narrow for the full one (nil when there is no shorter form).
local function packLabel(profile, instances)
  if not profile then return nil end
  local name = profile.name or "--"
  local short
  local mfr = profile.manufacturer
  if profile.nameAuto ~= false and type(mfr) == "string" and mfr ~= ""
     and string.sub(name, 1, #mfr + 1) == mfr .. " " then
    short = string.sub(name, #mfr + 2)
  end
  if type(instances) == "table" and #instances > 0 then
    local nums = {}
    for _, inst in ipairs(instances) do nums[#nums + 1] = tostring(inst.pos or "?") end
    local num = " #" .. table.concat(nums, "+")
    name, short = name .. num, short and short .. num
  end
  return name, short
end
M.packLabel = packLabel

local function lipoOn(w, on) return on.lipo ~= false and w.mods.lipo and w.lipo end
local function linkRes(w, on) return on.link ~= false and w.linkRes end
local function gpsRes(w, on) return on.gps ~= false and w.gpsRes end

-- Battery for the preflight page: the pack selection while it is open, else
-- the chosen pack; nil before either.
local function preBattery(w, now)
  local L, core = w.lipo, w.mods.lipo
  if L.pendingSelection then
    local packs = {}
    for _, item in ipairs(core.activeSelectionList(L)) do
      packs[#packs + 1] = { name = packLabel(item.profile), pos = item.pos, cycles = item.cycles or 0 }
    end
    return { packs = packs, cursor = L.popupCursor or 1,
             hold = L.confirmSince and math.min(1, (now - L.confirmSince) / 100) or 0 }
  end
  if not L.selectedProfile then return nil end
  local warn, crit = core.getThresholds(L)
  local cells = L.cells
  local name, short = packLabel(L.selectedProfile, L.selectedInstances)
  return { name = name, nameShort = short, pct = core.calculateRestPct(L),
           warn = warn, crit = crit, volt = L.voltage,
           cell = (L.voltage and cells and cells > 0) and L.voltage / cells or nil }
end

local function preGps(w, g)
  return { sats = g.sats, state = w.mods.gps.fixState(g), dop = g.dop, dopKind = g.dopKind, fix = g.fix }
end

local function linkView(w, r)
  local snap = r.snapshot or {}
  local lqLevel = w.mods.link and w.mods.link.lqLevel
  return { modLine = (w.link and w.link.modLine) or "LINK", lq = snap.rqly, stage = r.stage or 0, sensLimit = r.sensLimit,
           mode = r.modeName, rssi = r.linkRssi, tpwr = snap.tpwr, ant = snap.ant, range = r.rangePct,
           lqStage = (lqLevel and snap.rqly) and lqLevel(snap.rqly) or nil }
end

local function preView(w, on, now)
  local p = { armBlocked = w.armBlocked, armReason = w.armReason, fcInfo = w.fcInfo }
  if lipoOn(w, on) then p.batt = preBattery(w, now) end
  local g, r = gpsRes(w, on), linkRes(w, on)
  if g then p.gps = preGps(w, g) end
  if r and r.status == "running" then p.link = linkView(w, r) end
  return p
end

local function flightView(w, on)
  local v = {}
  if lipoOn(w, on) and w.lipo.selectedProfile then
    local L, core = w.lipo, w.mods.lipo
    local warn, crit = core.getThresholds(L)
    local cap = core.effectiveCapacityMah(L)
    local used = (L.capacity and L.startOffsetMah) and L.capacity + L.startOffsetMah or nil
    local name, short = packLabel(L.selectedProfile, L.selectedInstances)
    v.batt = { name = name, nameShort = short, pct = core.calculateRestPct(L),
               warn = warn, crit = crit, volt = L.voltage,
               cell = (L.voltage and L.cells and L.cells > 0) and L.voltage / L.cells or nil,
               vLevel = core.voltageLevel(L),   -- per-cell thresholds of the chemistry, as Lipo Nanny
               left = (cap and used) and math.max(0, cap - used) or nil, used = L.capacity, cap = cap,
               amps = L.current }
  end
  local g, r = gpsRes(w, on), linkRes(w, on)
  if g then
    local P = w.mods.gps.PARAMS
    v.gps = { sats = g.sats, course = g.course, bearing = g.bearingToHome, rel = g.rel, dist = g.distanceM,
              atHome = g.atHome, gpsState = g.gpsState, noHome = g.noHome, sector = g.sector,
              courseValid = g.courseValid, ahead = P.AHEAD_DEG, behind = P.BEHIND_DEG,
              alt = g.alt }
  end
  if r and r.status == "running" then v.link = linkView(w, r) end
  return v
end

-- Search view from the GPS core's own state: home, last position, link.
-- The last source is kept: the GPS core clears its position after its own end
-- hold, the search page stays until the next link.
local function searchFromGps(w, now)
  local st, g = w.gps, w.gpsRes or {}
  local src = w.searchSrc
  if st and st.homeLat and st.lastLat then
    src = { homeLat = st.homeLat, homeLon = st.homeLon, lat = st.lastLat, lon = st.lastLon, track = st.track or {},
            course = g.course, sats = g.sats, alt = g.alt }
    w.searchSrc = src
  elseif src and st and st.lastLat and w.linkUp then
    src.lat, src.lon = st.lastLat, st.lastLon   -- relinked as a new flight: live position, old home
  end
  if not src then return nil end
  src.live = w.linkUp
  src.ageS = (not w.linkUp and w.lostAt) and math.floor((now - w.lostAt) / 100) or 0
  return M.searchView(w.mods.gps, src)
end

-- Time of an alert: seconds since the first arming on this link (before that,
-- since the link came up). Timer 1 may count down, so it is not used here.
local function alertTime(w, now)
  return math.floor((now - (w.armedSince or w.linkSince or now)) / 100)
end

local function addAlert(w, now, text, level)
  w.alerts[#w.alerts + 1] = { t = alertTime(w, now), text = text, level = level }
end

-- Alerts on rising edges of the cores' warnings while linked.
local function recordAlerts(w, on, now)
  local a = w.alertSeen
  local L = lipoOn(w, on)
  if L and L.selectedProfile then
    local warn, crit = w.mods.lipo.getThresholds(L)
    if L.warnPlayed and not a.warn then addAlert(w, now, "Battery " .. warn .. " %", 1) end
    if L.critPlayed and not a.crit then addAlert(w, now, "Battery " .. crit .. " %", 2) end
    a.warn, a.crit = L.warnPlayed, L.critPlayed
  end
  local r = linkRes(w, on)
  local stage = r and r.status == "running" and r.stage or 0
  if stage > (a.stage or 0) then addAlert(w, now, (stage == 2) and "Link critical" or "Link warning", stage) end
  a.stage = stage
  local g = gpsRes(w, on)
  if g and g.fixLostEvent then addAlert(w, now, "GPS fix lost", 2) end
  if g and g.altEvent then addAlert(w, now, "Max altitude", 1) end
  if w.alert ~= a.alert then
    if w.alert == "FS" then addAlert(w, now, "Failsafe", 2)
    elseif w.alert == "RTH" then addAlert(w, now, "Return to home", 1) end
    a.alert = w.alert
  end
end

-- Timer as mm:ss, a countdown below zero with a minus.
local function mmss(s)
  if not s then return nil end
  local a = math.abs(s)
  return string.format("%s%02d:%02d", (s < 0) and "-" or "", math.floor(a / 60), a % 60)
end

-- Post-flight summary, refreshed every tick while the page shows: a value a
-- core forgets later (its own end hold) keeps the last one seen.
local function postView(w, on)
  local v, old = { time = mmss(w.lastTimerS), alerts = w.alerts }, w.postKeep or {}
  local L = lipoOn(w, on)
  if L and L.phase == "ENDED" and L.lastFlight then
    local lf, core = L.lastFlight, w.mods.lipo
    local cap, off = lf.effectiveCap, lf.startOffsetMah
    local warn, crit = core.getThresholds(L)
    local cycles = {}
    for _, inst in ipairs(lf.instances or {}) do cycles[#cycles + 1] = tostring(core.cyclesFor(L, inst.id)) end
    local name, short = packLabel(L.selectedProfile, lf.instances)
    v.batt = { name = name or lf.profileName, nameShort = short, used = lf.usedMah,
      start = (cap and cap > 0 and off) and math.floor(100 - off / cap * 100 + 0.5) or nil,
      left = (cap and cap > 0 and off) and math.max(0, math.floor((cap - lf.usedMah - off) / cap * 100 + 0.5)) or nil,
      cell = lf.lastVoltagePerCell, volt = (lf.lastVoltagePerCell and L.cells) and lf.lastVoltagePerCell * L.cells or nil,
      maxA = L.maxCurrent, cycles = (#cycles > 0) and table.concat(cycles, ", ") or nil, warn = warn, crit = crit }
  end
  local g = gpsRes(w, on)
  if g and g.flownM then
    v.gps = { flown = g.flownM, maxDist = g.maxDistM, maxAlt = g.maxAlt, maxSpd = g.maxGspd,
              lat = g.lastLat, lon = g.lastLon,
              coord = w.mods.gps.formatCoord or function(x) return string.format("%.5f", x) end }
  end
  local r = linkRes(w, on)
  if r and (r.minRqly or r.maxRangePct) then
    local lqLevel = w.mods.link and w.mods.link.lqLevel
    v.link = { modLine = (w.link and w.link.modLine) or "LINK", minLq = r.minRqly, maxRange = r.maxRangePct,
               maxTpwr = r.maxTpwr, mode = w.lastMode,
               lqStage = (lqLevel and r.minRqly) and lqLevel(r.minRqly) or nil,
               rangeStage = r.maxStage or 0 }   -- highest warning stage of the flight (link core)
  end
  v.batt, v.gps, v.link = v.batt or old.batt, v.gps or old.gps, v.link or old.link
  return v
end

-- Stick hold: aileron held full to one side (sign 1 right, -1 left) for a
-- second with the elevator centred, armed again only after the aileron came
-- back to the centre. Returns the hold 0..1 and true once complete.
local CLOSE_AIL, CLOSE_DEAD, CLOSE_HOLD = 700, 200, 100   -- stick units, getTime units
local function pollHold(w, now, sign)
  local ail, ele = getValue("ail") or 0, getValue("ele") or 0
  if math.abs(ail) < CLOSE_DEAD then w.closeArmed = true end
  if w.closeArmed and sign * ail > CLOSE_AIL and math.abs(ele) < CLOSE_DEAD then
    w.closeSince = w.closeSince or now
    if now - w.closeSince >= CLOSE_HOLD then
      w.closeSince, w.closeArmed = nil, false
      return 0, true
    end
  else
    w.closeSince = nil
  end
  return w.closeSince and math.min(1, (now - w.closeSince) / CLOSE_HOLD) or 0, false
end

-- The search page closes on the battery selection's confirm gesture (aileron
-- held right). w.searchClose: hold 0..1.
local function pollSearchClose(w, now)
  local done
  w.searchClose, done = pollHold(w, now, 1)
  if done then
    w.searching = nil
    if w.lipo then w.lipo.confirmArmed = false end   -- the same hold must not confirm a pack
  end
end

-- Pages from the cores. connected: link up (before the waiting overrides).
-- The search page is sticky (w.searching): it starts when the model comes to
-- rest far from home after a flight (disarmed far out, or the link lost with
-- the last position far out) and ends only on the close gesture or on arming.
local function buildPages(w, on, now, connected)
  w.flight, w.pre, w.search, w.post, w.waitSub, w.reviewHold = nil, nil, nil, nil, nil, nil
  w.preReady = false
  local disarmed = w.lastArmed and not w.armed   -- armed -> disarmed edge
  w.lastArmed = w.armed
  if connected then
    if not w.linked and w.resumed and w.phase == M.FLIGHT then   -- same flight after a dropout
      w.linked, w.lostAt = true, nil
    elseif not w.linked then   -- a new link (new pack): fresh alerts, no summary
      w.linked, w.linkSince, w.flown, w.lostAt, w.farOut = true, now, false, nil, nil
      w.alerts, w.alertSeen, w.postKeep, w.armedSince, w.reviewAt = {}, {}, nil, nil, nil
      if not w.searching then w.searchSrc = nil end
    end
    w.resumed = nil
    recordAlerts(w, on, now)
    if w.timerS then w.lastTimerS = w.timerS end
    local r = linkRes(w, on)
    if r and r.modeName then w.lastMode = r.modeName end
    local g = gpsRes(w, on)
    if g and g.atHome ~= nil then w.farOut = not g.atHome end   -- the GPS core forgets it once the link is gone
    if disarmed and w.flown and w.farOut then w.searching = true end   -- landed or crashed far out
  elseif w.linked then     -- link just lost: search when the last position is far out
    w.linked, w.lostAt = false, now
    if w.phase == M.ENDED and w.flown and w.farOut then w.searching = true end
  end

  if w.armed then
    w.armedSince = w.armedSince or now
    w.searching = nil   -- armed again: the flight page
  end
  if w.searching then
    w.search = searchFromGps(w, now)
    if w.search then return end
    w.searching = nil   -- nothing to show without a position
  end
  if w.phase == M.FLIGHT then
    w.flown = true
    w.flight = flightView(w, on)
  elseif w.phase == M.PRE then
    local L = lipoOn(w, on)
    local core = w.mods.lipo
    if L and core.isActive(L) and not L.selectedProfile and not L.pendingSelection then
      w.phase = M.WAITING   -- no page jump back: wait until the battery core knows
      w.waitSub = core.isUsbConnected(L) and "USB connected" or "Calculating..."
    else
      w.pre = preView(w, on, now)
      w.preStatus = M.preflightStatus(w.pre, w.mods)
      w.preReady  = w.preStatus.ready == "GO"   -- for flightPhase on the next tick
    end
  elseif w.phase == M.ENDED then
    w.post = postView(w, on)
    w.postKeep = w.post
  elseif w.phase == M.WAITING and w.postKeep then   -- aileron held left: the last summary for ENDED_HOLD_T again
    local done
    w.reviewHold, done = pollHold(w, now, -1)   -- 0..1 for the wait page's hint bar
    if done then w.reviewAt = now * 10 end
    if w.reviewAt and now * 10 - w.reviewAt < ENDED_HOLD_T then
      w.phase, w.post = M.ENDED, w.postKeep
    else
      w.reviewAt = nil
    end
  end
end

-- Search page data from a position source: home and model position (degrees),
-- track = { { lat, lon }, ... }, course (deg or nil), sats, alt (m), live
-- (position current) and ageS. n/e are metres north/east of home; geometry
-- from the GPS core.
function M.searchView(gps, src)
  local function offset(lat, lon)
    local d = gps.haversine(src.homeLat, src.homeLon, lat, lon)
    local b = math.rad(gps.bearingTo(src.homeLat, src.homeLon, lat, lon))
    return d * math.cos(b), d * math.sin(b), d
  end
  local v = { lat = src.lat, lon = src.lon, course = src.course, sats = src.sats,
              alt = src.alt, live = src.live, ageS = src.ageS, track = {} }
  v.n, v.e, v.distM = offset(src.lat, src.lon)
  v.bearing = gps.bearingTo(src.homeLat, src.homeLon, src.lat, src.lon)
  v.sector = gps.sectorOf(v.bearing)
  v.url = gps.mapUrl(src.lat, src.lon)
  v.maxM = v.distM
  for i, p in ipairs(src.track or {}) do
    local n, e, d = offset(p[1], p[2])
    v.track[i] = { n, e }
    if d > v.maxM then v.maxM = d end
  end
  return v
end

-- QR code of the map link as dark runs (w.qr). A widget may run only 20,000
-- Lua instructions per call and a whole encode needs about 120,000, so the
-- encoder works in steps (see stepQr). One code per search, from the position
-- when the search starts: the model lies still, and GPS jitter would otherwise
-- start a new code on every change of the last digit.
local function updateQr(w, v)
  if not w.qrUrl then
    if w.qrMod == nil then
      local chunk = loadScript("/SCRIPTS/GPSHOMER/qr.lua")
      w.qrMod = chunk and chunk() or false
    end
    w.qrUrl = v.url
    w.qrJob = w.qrMod and w.qrMod.newJob(v.url) or nil
  end
  v.qr = w.qr
end

-- One encoder step (at most about 8,000 instructions), the runs in a call of
-- their own.
local function stepQr(w)
  if w.qrCode then
    w.qr = { size = w.qrCode.size, runs = w.qrMod.runs(w.qrCode) }
    w.qrCode = nil
  elseif w.qrJob then
    w.qrCode = w.qrMod.step(w.qrJob)
    if w.qrCode then w.qrJob = nil end
  end
end

-- Forget the QR code when a search ends, so the next search encodes its own.
local function clearQr(w)
  w.qr, w.qrUrl, w.qrJob, w.qrCode = nil, nil, nil, nil
end

-- Timer 1 of the model in seconds, nil while it is switched off.
local function readTimer(w)
  w.timerS = nil
  local t = model.getTimer and model.getTimer(0)
  if t and t.mode ~= 0 then w.timerS = t.value end
end

-- Page data from the demo: ("flight", view), ("pre", preflight data), ("post", summary) or ("search", position source).
local function updateDemo(w, now)
  w.search, w.flight, w.pre, w.post = nil, nil, nil, nil
  local kind, data
  -- DEMO may name the page ("flight", "search"); true takes the demo's default.
  if w.demo then kind, data = w.demo(w, now, M, type(M.DEMO) == "string" and M.DEMO or nil) end
  local lqLevel = w.mods.link and w.mods.link.lqLevel
  if kind == "flight" then
    if lqLevel then data.link.lqStage = lqLevel(data.link.lq) end
    w.flight = data
  end
  if kind == "post" then w.post = data end
  if kind == "pre" then
    w.pre = data
    w.preStatus = M.preflightStatus(data, w.mods)
  end
  if kind ~= "search" or not w.mods.gps then clearQr(w); return end
  local v = M.searchView(w.mods.gps, data)
  updateQr(w, v)
  w.search = v
end

-- ---------------------------------------------------------------------------
-- Settings: module switches per model, { models = { [filename] = { gps = false } } }.
-- Only switched-off modules are stored; a missing file means all on. The path
-- is not written as `M.CONFIG_PATH = "..."` on purpose: the settings tool would
-- then ask to create the file.
-- ---------------------------------------------------------------------------
local CONFIG_PATH = "/SCRIPTS/WINGMAN/config.lua"
M.CONFIG_PATH = CONFIG_PATH
M.CONFIG_SCHEMA_VERSION = 1
M.MODULES = { "lipo", "link", "gps" }
local CONFIG_POLL = 500   -- getTime units: 5 s

M.MASCOTS = { "quad", "scout" }   -- wait page character, first = default

function M.defaultConfig()
  return { schemaVersion = M.CONFIG_SCHEMA_VERSION, generation = 0, models = {}, mascot = M.MASCOTS[1] }
end

-- Returns the config, or nil plus "parse" | "schema" (and a detail text).
-- Text only ("tx"): a compiled copy with the same FAT timestamp would win.
function M.loadConfig()
  local ok, f = pcall(io.open, CONFIG_PATH, "r")
  if not ok or not f then return M.defaultConfig() end
  pcall(io.close, f)
  local cok, chunk, err = pcall(loadScript, CONFIG_PATH, "tx")
  if not cok or not chunk then return nil, "parse", tostring(err or chunk) end
  local pok, cfg = pcall(chunk)
  if not pok or type(cfg) ~= "table" then return nil, "parse", tostring(cfg) end
  if cfg.schemaVersion ~= M.CONFIG_SCHEMA_VERSION then return nil, "schema", tostring(cfg.schemaVersion) end
  if type(cfg.generation) ~= "number" then cfg.generation = 0 end
  if type(cfg.models) ~= "table" then cfg.models = {} end
  if cfg.mascot ~= M.MASCOTS[2] then cfg.mascot = M.MASCOTS[1] end
  return cfg
end

local function serialize(v, indent)
  if type(v) == "string" then return string.format("%q", v) end
  if type(v) ~= "table" then return tostring(v) end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local inner, parts = indent .. "  ", {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = inner .. "[" .. serialize(k, inner) .. "] = " .. serialize(v[k], inner) .. ",\n"
  end
  return "{\n" .. table.concat(parts) .. indent .. "}"
end

-- Writes the config with a raised generation. True on success. io.open "w"
-- does not truncate on some builds: a shorter text is padded with newlines.
function M.saveConfig(cfg)
  cfg.schemaVersion = M.CONFIG_SCHEMA_VERSION
  cfg.generation = (cfg.generation or 0) + 1
  local text = "-- Wingman configuration (auto-generated).\nreturn " .. serialize(cfg, "") .. "\n"
  local ok, f = pcall(io.open, CONFIG_PATH, "r")
  if ok and f then
    local rok, old = pcall(io.read, f, 65536)
    pcall(io.close, f)
    if rok and old and #old > #text then text = text .. string.rep("\n", #old - #text) end
  end
  ok, f = pcall(io.open, CONFIG_PATH, "w")
  if not ok or not f then return false end
  local wok = pcall(io.write, f, text)
  pcall(io.close, f)
  return wok == true
end

-- Module switches of a model: { lipo = bool, link = bool, gps = bool }.
function M.modules(cfg, filename)
  local m = cfg and filename and cfg.models[filename] or {}
  local on = {}
  for _, k in ipairs(M.MODULES) do on[k] = m[k] ~= false end
  return on
end

-- Stores a model's switches; an all-on model is removed from the file.
function M.setModules(cfg, filename, on)
  local m
  for _, k in ipairs(M.MODULES) do
    if on[k] == false then m = m or {}; m[k] = false end
  end
  cfg.models[filename] = m
end

local function activeModel()
  local ok, info = pcall(model.getInfo)
  return ok and type(info) == "table" and info.filename or nil
end

-- Switches of the active model and the mascot, re-read every 5 s (a change in
-- the settings tool or a model switch applies without a reload). A damaged
-- file: all on, default mascot.
local function pollModules(w, now)
  if w.on and w.onAt and now - w.onAt < CONFIG_POLL then return w.on end
  w.onAt = now
  local cfg = M.loadConfig()
  w.on = M.modules(cfg, activeModel())
  w.mascot = cfg and cfg.mascot
  return w.on
end

-- Wingman's own setup errors: cores of switched-on modules that are missing or
-- too old, one text each for the settings tool. Without w (the tool) the cores
-- are loaded once to find out, with the active model's switches.
local CORE_NAMES = { { "lipo", "Lipo Nanny" }, { "link", "Link Sentinel" }, { "gps", "GPS Homer" } }
local CORE_ERR   = { missing = "core missing", version = "core too old" }
function M.setupErrors(w, on)
  on = on or M.modules(M.loadConfig(), activeModel())
  if not w then
    w = { err = {} }
    for name, c in pairs(M.CORES) do
      local _, e = loadCore(c)
      w.err[name] = e
    end
  end
  local out = {}
  for _, c in ipairs(CORE_NAMES) do
    local e = w.err[c[1]]
    if e and on[c[1]] ~= false then out[#out + 1] = c[2] .. " " .. (CORE_ERR[e] or e) end
  end
  return out
end

-- True when a switched-on module's own core reports a setup error (its
-- details are in that app's popup in the settings tool).
local function appSetupError(w, on)
  local m = w.mods
  if on.lipo ~= false and m.lipo then
    m.lipo.pollConfig(w.lipo)   -- throttled in the core; Wingman may not tick it
    if #m.lipo.setupErrors(w.lipo) > 0 then return true end
  end
  if on.link ~= false and m.link and #m.link.setupErrors(w.link) > 0 then return true end
  if on.gps ~= false and m.gps and #m.gps.setupErrors(w.gps) > 0 then return true end
  return false
end

-- Throttled cycle, safe to call from refresh and background. on = { lipo, link,
-- gps } (module switches; nil: the active model's settings). Results: w.phase, w.linkUp, w.rssi, w.mode, w.alert, w.armBlocked, w.timerS,
-- w.flight, w.pre with w.preStatus, w.search, w.setupError (any setup error, also an app's) with
-- w.setupErrors (Wingman's own texts), w.linkRes, w.gpsRes (nil while off or failing); the battery
-- values live on w.lipo.
function M.tick(w, on)
  local now = getTime()
  if w.lastTick ~= 0 and now - w.lastTick < TICK then
    -- Calls between ticks carry the QR encoding, so it never shares a call's
    -- instruction budget with the tick.
    if (w.qrJob or w.qrCode) and not pcall(stepQr, w) then w.qrJob, w.qrCode = nil, nil end
    return
  end
  w.lastTick = now
  on = on or pollModules(w, now)

  pcall(pollFrames, w, on)
  pcall(updatePhase, w, now)
  if not pcall(readTimer, w) then w.timerS = nil end

  -- With demo data the cores rest (no announcements from the simulator's sensors).
  local drive = not w.demo
  w.lipoOn = drive and on.lipo and w.lipo ~= nil and pcall(w.mods.lipo.tick, w.lipo)
  -- Pack selection by stick (the LiPo core's gestures), disarmed only.
  if w.lipoOn and not w.armed and not w.searching and w.lipo.pendingSelection and w.mods.lipo.pollSelectionSticks then
    pcall(w.mods.lipo.pollSelectionSticks, w.lipo)
  end
  local ok
  w.linkRes = nil
  if drive and on.link and w.link then
    ok, w.linkRes = pcall(w.mods.link.update, w.link)
    if not ok then w.linkRes = nil end
    -- Like link-sentinel's widget: a dropout shorter than the core's grace keeps
    -- the last running result, so the link column holds like battery and GPS.
    local r = w.linkRes
    if r and r.status == "running" then
      w.lastLinkRun = r
    elseif r and r.status == "no_link" and not r.linkLost and w.lastLinkRun then
      w.linkRes = w.lastLinkRun
    else
      w.lastLinkRun = nil
    end
  end
  w.gpsRes = nil
  if drive and on.gps and w.gps then
    ok, w.gpsRes = pcall(w.mods.gps.update, w.gps)
    if not ok then w.gpsRes = nil end
  end

  if w.demo then
    if not pcall(updateDemo, w, now) then w.search, w.flight = nil, nil end
  else
    if not pcall(buildPages, w, on, now, w.connected) then
      w.flight, w.pre, w.search, w.post = nil, nil, nil, nil
    end
    if w.search then
      pcall(pollSearchClose, w, now)
      if not w.searching then w.search = nil end   -- closed by the gesture just now
    end
    if w.search then
      if not pcall(updateQr, w, w.search) then clearQr(w) end
    else
      clearQr(w)
    end
  end
  w.setupErrors = M.setupErrors(w, on)
  if not w.appErrAt or now - w.appErrAt >= 100 then   -- setup changes slowly: once a second
    local appOk, appErr = pcall(appSetupError, w, on)
    w.appErr, w.appErrAt = appOk and appErr, now
  end
  w.setupError = #w.setupErrors > 0 or w.appErr
  if w.setupError then
    w.phase, w.flight, w.pre, w.search, w.post = M.WAITING, nil, nil, nil, nil
    clearQr(w)
  end
end

return M

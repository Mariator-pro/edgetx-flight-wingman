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
    w.imperial = m.gps.PARAMS.UNITS == "imperial"   -- the radio's units, read by the GPS core
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
  -- link core: module ping and the Max Power / Dynamic read after a new link
  if on.link and w.link then w.mods.link.pollModule(w.link) end
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
M.MSP_MODE_RANGES, M.MSP_BOXNAMES, M.MSP_BOXIDS = 34, 116, 119   -- switch page
local BOX_PAGE = 32   -- Betaflight sends names and ids in pages of 32 modes
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

-- CRSF payload of an MSP request: MSPv1, or MSPv2 for a command above 255 or
-- when v2 is set (status: version, start flag, sequence 0..15). data: optional
-- payload bytes (MSPv2 only). Long replies are asked as MSPv2: its 16-bit size
-- holds them (INAV cuts the MSPv1 size byte above 255).
function M.mspRequest(seq, cmd, v2, data)
  if cmd > 255 or v2 then
    local n = data and #data or 0
    local d = { ADDR_FC, ADDR_RADIO, 0x50 + seq % 16, 0, cmd % 256, math.floor(cmd / 256), n % 256, math.floor(n / 256) }
    for _, b in ipairs(data or {}) do d[#d + 1] = b end
    return d
  end
  return { ADDR_FC, ADDR_RADIO, 0x30 + seq % 16, 0, cmd }
end

-- One chunk of an MSP reply into rx (state per link): returns cmd and the whole
-- payload once the last chunk is in, else nil. The first chunk carries the
-- size (MSPv1 one byte, 0xFF plus 16 bits for a jumbo reply; MSPv2 16 bits),
-- later chunks only a status byte with the next sequence number; a gap, an
-- error or another sender drops the reply.
function M.mspChunk(rx, data)
  if type(data) ~= "table" or data[1] ~= ADDR_RADIO or data[2] ~= ADDR_FC then return nil end
  local status = data[3] or 0
  local seq, first = status % 16, nil
  if status >= 128 then rx.cmd = nil; return nil end
  if math.floor(status / 16) % 2 == 1 then
    local version = math.floor(status / 32) % 4
    if version == 1 then
      rx.cmd, rx.size, first = data[5], data[4] or 0, 6
      if rx.size == 255 then rx.size, first = (data[6] or 0) + (data[7] or 0) * 256, 8 end
    elseif version == 2 then
      rx.cmd, rx.size, first = (data[5] or 0) + (data[6] or 0) * 256, (data[7] or 0) + (data[8] or 0) * 256, 9
    else
      rx.cmd = nil
      return nil
    end
    rx.p = {}
  elseif rx.cmd and seq == (rx.seq + 1) % 16 then
    first = 4
  else
    rx.cmd = nil
    return nil
  end
  rx.seq = seq
  local p = rx.p
  for i = first, #data do
    if #p >= rx.size then break end
    p[#p + 1] = data[i]
  end
  if #p < rx.size then return nil end
  local cmd = rx.cmd
  rx.cmd = nil
  return cmd, p
end

-- A single-chunk reply: cmd and payload, nil for anything else.
function M.mspReply(data)
  return M.mspChunk({}, data)
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

-- Modes for the switch page from MSP_MODE_RANGES (4 bytes per slot: permanent
-- mode id, AUX index from 0, start and end step; step x 25 + 900 us, start =
-- end is an empty slot) and the names: per page the MSP_BOXIDS bytes and the
-- MSP_BOXNAMES text ("ARM;ANGLE;..."), same order. Returns { { name, aux, lo,
-- hi } } with aux from 1 and lo/hi in us; an id without a name as "MODE <id>".
function M.modeRanges(ranges, ids, names)
  local byId = {}
  for pg, idList in pairs(ids or {}) do
    local nm = {}
    for n in string.gmatch(names and names[pg] or "", "[^;]+") do nm[#nm + 1] = n end
    for i, id in ipairs(idList) do byId[id] = nm[i] end
  end
  local out = {}
  for i = 1, #ranges - 3, 4 do
    local id, aux, s, e = ranges[i], ranges[i + 1], ranges[i + 2], ranges[i + 3]
    if s < e then
      out[#out + 1] = { name = byId[id] or ("MODE " .. id), aux = aux + 1, lo = 900 + 25 * s, hi = 900 + 25 * e }
    end
  end
  return out
end

-- Takes one popped frame; true when it was (a chunk of) the awaited MSP reply.
mspFrame = function(w, cmd, data)
  local m = w.msp
  if not m or not m.waiting or cmd ~= MSP_RESP then return false end
  m.rx = m.rx or {}
  local rcmd, p = M.mspChunk(m.rx, data)
  if not rcmd then
    if m.rx.cmd == m.waiting then m.sentAt = getTime() end   -- a long reply is coming in
    return false
  end
  if rcmd ~= m.waiting then return false end
  m.waiting, m.answered = nil, true
  if rcmd == M.MSP_MODE_RANGES or rcmd == M.MSP_BOXIDS or rcmd == M.MSP_BOXNAMES then m.modeLost = 0 end
  local md = m.modes
  if rcmd == M.MSP_MODE_RANGES then md.ranges = p; return true end
  if rcmd == M.MSP_BOXIDS then md.ids[md.page] = p; return true end
  if rcmd == M.MSP_BOXNAMES then md.names[md.page] = ascii(p, 1, #p); return true end
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

-- Filename of the active model, nil when unknown.
local function activeModel()
  local ok, info = pcall(model.getInfo)
  return ok and type(info) == "table" and info.filename or nil
end

-- Switch page: the modes the FC sent, stored per model in the config
-- (modes[filename] = { fw, version, date, ranges }); written only when they
-- differ from the stored ones (the date alone does not count).
local function sameModes(a, b)
  if not a or not b or a.fw ~= b.fw or a.version ~= b.version then return false end
  local ra, rb = a.ranges or {}, b.ranges or {}
  if #ra ~= #rb then return false end
  for i, r in ipairs(ra) do
    local s = rb[i]
    if r.name ~= s.name or r.aux ~= s.aux or r.lo ~= s.lo or r.hi ~= s.hi then return false end
  end
  return true
end
local function today()
  local d = getDateTime and getDateTime()
  return (d and d.year) and string.format("%04d-%02d-%02d", d.year, d.mon, d.day) or nil
end
-- file: the model the read started on (default the active one).
local function storeModes(w, entry, file)
  if sameModes(w.modesEntry, entry) then return end
  entry.date = today()
  local cfg
  file, cfg = file or activeModel(), M.loadConfig()
  if not file or not cfg then return end   -- a damaged config stays untouched
  cfg.modes[file] = entry
  if M.saveConfig(cfg) then w.modesEntry = entry end
end

-- Next request of the mode read (ranges, then ids and names page by page;
-- Betaflight pages hold 32 modes), nil when all are in.
local function modesRequest(m)
  local md = m.modes
  if not md.ranges then return M.MSP_MODE_RANGES end
  local data = (m.variant == "BTFL") and { md.page } or nil
  if not md.ids[md.page] then return M.MSP_BOXIDS, data end
  if not md.names[md.page] then return M.MSP_BOXNAMES, data end
  if data and #md.ids[md.page] >= BOX_PAGE and md.page < 3 then
    md.page = md.page + 1
    return modesRequest(m)
  end
  return nil
end
local MODES_CMD = { [M.MSP_MODE_RANGES] = true, [M.MSP_BOXIDS] = true, [M.MSP_BOXNAMES] = true }
local MODES_TRIES = 3   -- mode requests lost in a row before the read gives up for this link

-- One MSP step per tick: drop a request after its timeout, then send the next
-- when the CRSF module takes one. Without any reply 10 s after the FC's first FM
-- text it gives up until the next link (a booting FC is still asked); with the
-- switch page on and an ArduPilot FM text it stores that the modes cannot be
-- read. Results: w.fcInfo, w.armReason, the stored modes (switch page on).
local function pollMsp(w, now, armed)
  if not w.linkUp or armed or not crossfireTelemetryPush then return end
  w.msp = w.msp or { seq = 0 }
  local m = w.msp
  if not m.fmAt and fmCurrent() then m.fmAt = now end
  if m.waiting and now - m.sentAt >= MSP_TIMEOUT then
    -- An FC that never answers a mode request: give up for this link, store nothing.
    if MODES_CMD[m.waiting] then
      m.modeLost = (m.modeLost or 0) + 1
      if m.modeLost >= MODES_TRIES then m.modesDone, m.modes = true, nil end
    end
    m.waiting = nil
  end
  if not w.armBlocked then m.reason, m.reasonAt = nil, nil end
  -- A mode reply takes several chunks; the GPS core's next PDOP request (every
  -- second on the ground) would cut it off at the FC, so it is paused meanwhile.
  local g, gm = w.gps, w.mods.gps
  if m.waiting and MODES_CMD[m.waiting] and g and gm and gm.mspPause then gm.mspPause(g, (now + MSP_TIMEOUT) * 10) end
  if m.waiting then return end
  if not m.answered and m.fmAt and now - m.fmAt >= MSP_GIVE_UP_T then
    if w.switchPage and (w.fcGuess == "AP" or (g and g.fcKind == "AP")) and not m.apStored then
      m.apStored = true
      storeModes(w, { fw = "AP" })
    end
    return
  end
  -- The GPS core asks for its PDOP every second on the ground: send only while
  -- its request is answered and its next one is at least 0.5 s away.
  if g and gm and gm.mspFree and not gm.mspFree(g, now * 10) then return end
  local cmd, data
  if not m.variant then cmd = M.MSP_FC_VARIANT
  elseif not m.version then cmd = M.MSP_FC_VERSION
  elseif not m.board then cmd = M.MSP_BOARD_INFO
  elseif w.armBlocked and (not m.reasonAt or now - m.reasonAt >= REASON_EVERY) then
    if m.variant == "BTFL" then cmd = M.MSP_STATUS_EX elseif m.variant == "INAV" then cmd = M.MSP2_INAV_STATUS end
  end
  if not cmd and w.switchPage and not m.modesDone and (m.variant == "BTFL" or m.variant == "INAV") then
    m.modes = m.modes or { ids = {}, names = {}, page = 0, file = activeModel() }
    cmd, data = modesRequest(m)
    if not cmd then
      m.modesDone = true
      storeModes(w, { fw = m.variant, version = m.version,
                      ranges = M.modeRanges(m.modes.ranges, m.modes.ids, m.modes.names) }, m.modes.file)
      m.modes = nil
    end
  end
  if not cmd or not crossfireTelemetryPush() then return end   -- false: buffer busy
  crossfireTelemetryPush(MSP_REQ, M.mspRequest(m.seq, cmd, MODES_CMD[cmd], data))
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
    local fcFromFM = w.mods.gps and w.mods.gps.fcFromFM
    w.fcGuess = (fcFromFM and fcFromFM(fm)) or w.fcGuess   -- firmware from the FM text (switch page)
    pollMsp(w, now, armed)
    w.fcInfo = fcInfoText(w.msp)
    w.armReason = w.armBlocked and w.msp and w.msp.reason or nil
  end
  local phase, event = flightPhase(w.fs, up, armed, w.preReady, now * 10)
  if event == "end" or event == "lost" then
    w.mode, w.alert, w.armBlocked = nil, nil, nil
    w.msp, w.fcInfo, w.armReason, w.fcGuess = nil, nil, nil, nil   -- a new link may be another FC
  end
  -- Lost while armed (dropout at range): the FC stays armed and its text has no
  -- marker on the way back, so the proof is kept for the resumed flight.
  if event == "lost" or event == "over" or (event == "end" and not w.fs.linkFailure) then
    w.fm.disarmSeen = nil
  end
  if event == "resume" then w.resumed = true end
  w.phase = phase
  w.connected = phase == M.PRE or phase == M.FLIGHT   -- link up, short gaps included
  -- A short dropout keeps the last armed state like every other value: no false
  -- disarm (that would open the search page far out before the end page).
  if up or not w.connected then w.armed = armed end
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

-- mAh left in the pack (capacity minus used, incl. the start offset).
local function leftMah(L, core)
  local cap = core.effectiveCapacityMah(L)
  local used = (L.capacity and L.startOffsetMah) and L.capacity + L.startOffsetMah or nil
  return cap, (cap and used) and math.max(0, cap - used) or nil
end

-- Sticks, read once per tick: w.ail, w.ele raw, w.stick, w.stickEle -1..1 for
-- the stick hint's knob. The knob and the gestures wait until the aileron
-- stayed in the centre for STICK_SEEN once (w.stickSeen: an untouched simulator
-- stick reads 0 on the first tick, then full left).
local CLOSE_AIL, CLOSE_DEAD, CLOSE_HOLD, CLOSE_SHOW = 922, 200, 100, 10   -- stick units (922: 90 %), getTime units
local STICK_SEEN = 50   -- getTime units
local function unit(v) return math.max(-1, math.min(1, v / 1024)) end
local function readStick(w, now)
  w.ail, w.ele = getValue("ail") or 0, getValue("ele") or 0
  if math.abs(w.ail) < CLOSE_DEAD then
    w.centreSince = w.centreSince or now
    if now - w.centreSince >= STICK_SEEN then w.stickSeen = true end
  else
    w.centreSince = nil
  end
  w.stick, w.stickEle = 0, 0
  if w.stickSeen then w.stick, w.stickEle = unit(w.ail), unit(w.ele) end
end

-- Battery for the preflight page: the pack selection while it is open (with
-- the sticks for the hint: stick aileron, ele elevator, -1..1, armed: a confirm
-- can start (the aileron was back in the centre, the elevator is centred),
-- eleArmed: the next cursor step can), else the chosen pack; nil before either.
local function preBattery(w, now)
  local L, core = w.lipo, w.mods.lipo
  if L.pendingSelection then
    local packs = {}
    for _, item in ipairs(core.activeSelectionList(L)) do
      packs[#packs + 1] = { name = packLabel(item.profile), pos = item.pos, cycles = item.cycles or 0 }
    end
    return { packs = packs, cursor = L.popupCursor or 1,
             hold = L.confirmSince and math.min(1, (now - L.confirmSince) / 100) or 0,
             stick = w.stick, ele = w.stickEle, eleArmed = L.stickArmed,
             armed = L.confirmArmed and math.abs(w.ele or 0) < CLOSE_DEAD }   -- the LiPo core's dead zone
  end
  if not L.selectedProfile then return nil end
  local warn, crit = core.getThresholds(L)
  local cells = L.cells
  local name, short = packLabel(L.selectedProfile, L.selectedInstances)
  return { name = name, nameShort = short, pct = core.calculateRestPct(L),
           warn = warn, crit = crit, volt = L.voltage,
           cell = (L.voltage and cells and cells > 0) and L.voltage / cells or nil,
           left = select(2, leftMah(L, core)), chem = L.selectedProfile.chemistry }
end

local function preGps(w, g)
  return { sats = g.sats, state = w.mods.gps.fixState(g), dop = g.dop, dopKind = g.dopKind, fix = g.fix,
           fixLost = g.fixLost }
end

local function linkView(w, r)
  local snap = r.snapshot or {}
  local dual = snap.rss2 ~= nil and snap.rss2 ~= 0
  return { modLine = (w.link and w.link.modLine) or "LINK", lq = snap.rqly, stage = r.stage or 0, sensLimit = r.sensLimit,
           mode = r.modeName, rssi = r.linkRssi, tpwr = snap.tpwr, range = r.rangePct,
           -- both antennas only from a dual-antenna receiver (2RSS 0: single antenna)
           rss1 = dual and snap.rss1 or nil, rss2 = dual and snap.rss2 or nil, rsnr = snap.rsnr,
           ant = snap.ant and snap.ant + 1,   -- ANT 0/1 -> antenna 1/2 like rss1/rss2
           -- "DYN" / "MAX" beside TX POWER, DYN: the range bar's lightened end in %
           pwrTag = r.pwrTag, reserve = r.pwrReservePct,
           warn = w.mods.link.warnPct(r.sensLimit),   -- stage 1 mark on the range bar, nil for an unknown mode
           lqCrit = w.mods.link.PARAMS.RQLY_THRESHOLD }  -- stage 2 mark on the preflight LQ bar
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
    local cap, left = leftMah(L, core)
    local name, short = packLabel(L.selectedProfile, L.selectedInstances)
    v.batt = { name = name, nameShort = short, pct = core.calculateRestPct(L),
               warn = warn, crit = crit, volt = L.voltage,
               cell = (L.voltage and L.cells and L.cells > 0) and L.voltage / L.cells or nil,
               chem = L.selectedProfile.chemistry,
               left = left, used = L.capacity, cap = cap,
               amps = L.current, timeLeft = L.timeLeftStr }   -- Lipo Nanny's estimate, every 2 s
  end
  local g, r = gpsRes(w, on), linkRes(w, on)
  if g then
    local P = w.mods.gps.PARAMS
    v.gps = { sats = g.sats, course = g.course, bearing = g.bearingToHome, rel = g.rel, dist = g.distanceM,
              atHome = g.atHome, gpsState = g.gpsState, noHome = g.noHome, sector = g.sector,
              courseValid = g.courseValid, estimated = g.noseEstimated, ahead = P.AHEAD_DEG, behind = P.BEHIND_DEG,
              alt = g.alt, altOver = g.altOver, distOver = g.distOver, fixLost = g.fixLost,
              pitch = g.pitch, roll = g.roll, gspd = g.gspd, vspd = g.vspd }   -- for the horizon
  end
  if r and r.status == "running" then v.link = linkView(w, r) end
  return v
end

-- Search view from the GPS core's own state: home, last position, link.
-- The last source is kept: a new link resets the GPS core's home, while the
-- search page stays until it is closed or the model is armed. The source table
-- lives as long as home and track, so searchView converts the track only once.
local function searchFromGps(w, now)
  local st, g = w.gps, w.gpsRes or {}
  local src = w.searchSrc
  if st and st.homeLat and st.lastLat then
    if not src or src.homeLat ~= st.homeLat or src.homeLon ~= st.homeLon or src.track ~= st.track then
      src = { homeLat = st.homeLat, homeLon = st.homeLon, track = st.track }
      w.searchSrc = src
    end
    src.lat, src.lon, src.course, src.sats, src.alt = st.lastLat, st.lastLon, g.course, g.sats, g.alt
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
    if a.warn == nil and L.warnPlayed then
      addAlert(w, now, "Battery not charged", 1)   -- already low when picked: no threshold was crossed
    else
      if L.warnPlayed and not a.warn then addAlert(w, now, "Battery " .. warn .. " %", 1) end
      if L.critPlayed and not a.crit then addAlert(w, now, "Battery " .. crit .. " %", 2) end
    end
    a.warn, a.crit = L.warnPlayed, L.critPlayed
  end
  local r = linkRes(w, on)
  local stage = r and r.status == "running" and r.stage or 0
  if stage > (a.stage or 0) then addAlert(w, now, (stage == 2) and "Link critical" or "Link warning", stage) end
  a.stage = stage
  local g = gpsRes(w, on)
  if g and g.fixLostEvent then addAlert(w, now, "GPS fix lost", 2) end
  if g and g.altEvent then addAlert(w, now, "Max altitude", 1) end
  if g and g.distEvent then addAlert(w, now, "Max distance", 1) end
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
  local v, old = { time = mmss(w.lastTimerS), timeS = w.lastTimerS, alerts = w.alerts }, w.postKeep or {}
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
      maxA = L.maxCurrent, cycles = (#cycles > 0) and table.concat(cycles, ", ") or nil, warn = warn, crit = crit,
      chem = L.selectedProfile and L.selectedProfile.chemistry }
  end
  local g = gpsRes(w, on)
  if g and g.flownM then
    v.gps = { flown = g.flownM, maxDist = g.maxDistM, maxAlt = g.maxAlt, maxSpd = g.maxGspd,
              lat = g.lastLat, lon = g.lastLon, altExceeded = g.altExceeded, distExceeded = g.distExceeded,
              coord = w.mods.gps.formatCoord or function(x) return string.format("%.5f", x) end }
  end
  local r = linkRes(w, on)
  if r and (r.minRqly or r.maxRangePct) then
    v.link = { modLine = (w.link and w.link.modLine) or "LINK", minLq = r.minRqly, maxRange = r.maxRangePct,
               maxTpwr = r.maxTpwr, mode = w.lastMode,
               rangeStage = r.maxStage or 0 }   -- highest warning stage of the flight (link core)
  end
  v.batt, v.gps, v.link = v.batt or old.batt, v.gps or old.gps, v.link or old.link
  return v
end

-- Stick hold: aileron held full to one side (sign 1 right, -1 left) for a
-- second, the other sticks free, armed again only after the aileron came
-- back to the centre. Returns the hold 0..1 and true once complete: the full
-- hold is returned at least once and kept CLOSE_SHOW before it completes, so
-- the bar is always seen full before the page changes. The gesture waits for
-- the stick seen in the centre (readStick).
local function pollHold(w, now, sign)
  local ail = w.ail or 0
  if math.abs(ail) < CLOSE_DEAD and w.stickSeen then w.closeArmed = true end
  if w.closeArmed and sign * ail > CLOSE_AIL then
    w.closeSince = w.closeSince or now
    if now - w.closeSince >= CLOSE_HOLD then
      if w.closeFullAt and now - w.closeFullAt >= CLOSE_SHOW then
        w.closeSince, w.closeFullAt, w.closeArmed = nil, nil, false
        return 0, true
      end
      w.closeFullAt = w.closeFullAt or now
      return 1, false
    end
  else
    w.closeSince, w.closeFullAt = nil, nil
  end
  return w.closeSince and math.min(1, (now - w.closeSince) / CLOSE_HOLD) or 0, false
end

-- The search page closes on the battery selection's confirm gesture (aileron
-- held right); aileron held left mutes or unmutes the finder beeps.
-- w.searchHold: hold -1..1, negative while held left.
local function pollSearchHold(w, now)
  local sign = (w.ail or 0) < 0 and -1 or 1
  local hold, done = pollHold(w, now, sign)
  w.searchHold = sign * hold
  if done and sign < 0 then
    w.finderMuted = not w.finderMuted
  elseif done then
    w.searching = nil
    if w.lipo then w.lipo.confirmArmed = false end   -- the same hold must not confirm a pack
  end
end

-- A new search starts with the finder beeps on.
local function startSearch(w)
  w.searching, w.finderMuted = true, nil
end

-- Switch page data from /SCRIPTS/WINGMAN/switches.lua, loaded only while the
-- page is open. A widget call runs tick and drawing within 20,000 Lua
-- instructions, so the static part (switches, mixes, special functions) is
-- read once per opening, one step per tick, and the view is built again only
-- when a switch, its channel or the stored modes change. Meanwhile the page
-- shows only its frame (SWITCHES_LOADING). Returns the view, or false when
-- switches.lua is missing (then w.swMissing: no switch gesture offered).
local SWITCHES_LOADING = { loading = true, rows = {} }
local function switchView(w)
  if w.swMod == nil then
    local chunk = loadScript("/SCRIPTS/WINGMAN/switches.lua")
    w.swMod = chunk and chunk() or false
    if not w.swMod then w.swMissing = true; return false end
    return SWITCHES_LOADING   -- loading the file is this tick's work
  end
  if not w.swMod then return false end
  if not w.swStatic then
    w.swBuild = w.swBuild or {}
    w.swStatic = w.swMod.buildStep(w.swBuild, getVersion and select(2, getVersion()))
    if not w.swStatic then return SWITCHES_LOADING end
    w.swBuild = nil
    return SWITCHES_LOADING   -- the view on the next tick
  end
  local key = w.swMod.stateKey(w.swStatic)
  if not w.swView or key ~= w.swKey or w.modesEntry ~= w.swModesOf then
    w.swView, w.swKey, w.swModesOf = w.swMod.view(w.swStatic, w.modesEntry, w.swView), key, w.modesEntry
  end
  return w.swView
end

local function closeSwitches(w)
  w.switchOpen, w.sw, w.swMod, w.swStatic, w.swBuild, w.swView, w.swKey, w.swModesOf =
    nil, nil, nil, nil, nil, nil, nil, nil
end

-- Wait page gestures, aileron held a second: left reopens the last summary for
-- ENDED_HOLD_T (while one is kept), right opens the switch page (switch page
-- on, no setup error); on the switch page left closes it. w.waitHold -1..1
-- (negative while held left) for the hint bar, w.waitHint the gestures offered.
local function waitGestures(w, now)
  if w.switchOpen then
    local hold, done = pollHold(w, now, -1)
    w.waitHold = -hold
    if done or not w.switchPage or w.setupError then closeSwitches(w)
    else
      w.sw = switchView(w)
      if w.sw then return end
      closeSwitches(w)
    end
  end
  if w.reviewAt and now * 10 - w.reviewAt < ENDED_HOLD_T then
    w.phase, w.post = M.ENDED, w.postKeep
    return
  end
  w.reviewAt = nil
  local review, switches = w.postKeep ~= nil, w.switchPage and not w.setupError and not w.swMissing
  if not review and not switches then return end
  w.waitHint = { review = review, switches = switches }
  local sign = (w.ail or 0) < 0 and -1 or 1
  local allowed = (sign < 0 and review) or (sign > 0 and switches)
  local hold, done = pollHold(w, now, allowed and sign or 0)
  w.waitHold = sign * hold
  if done and sign < 0 then
    w.reviewAt, w.phase, w.post = now * 10, M.ENDED, w.postKeep
  elseif done then
    w.switchOpen, w.sw = true, SWITCHES_LOADING   -- the reading starts on the next tick
  end
end

-- Pages from the cores. connected: link up (before the waiting overrides).
-- The search page is sticky (w.searching): it starts when the model comes to
-- rest far from home after a flight (disarmed far out, or the link lost with
-- the last position far out) and ends only on the close gesture or on arming.
local function buildPages(w, on, now, connected)
  w.flight, w.pre, w.search, w.post, w.waitSub = nil, nil, nil, nil, nil
  w.waitHold, w.waitHint, w.sw, w.preReady = nil, nil, nil, false
  if w.phase ~= M.WAITING or w.searching then closeSwitches(w) end
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
    if disarmed and w.flown and w.farOut then startSearch(w) end   -- landed or crashed far out
  elseif w.linked then     -- link just lost: search when the last position is far out
    w.linked, w.lostAt = false, now
    if w.phase == M.ENDED and w.flown and w.farOut then startSearch(w) end
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
  elseif w.phase == M.WAITING then
    waitGestures(w, now)
  end
end

-- Search page data from a position source: home and model position (degrees),
-- track = { { lat, lon }, ... }, course (deg or nil), sats, alt (m), live
-- (position current) and ageS. n/e are metres north/east of home; the model's
-- from the GPS core's geometry, the track flat (degrees times metres per degree):
-- up to 50 points through haversine would break the widget's instruction limit,
-- and over a few km the two differ by far less than a pixel. The track stops
-- growing once the search starts (disarmed or no link), so its conversion is kept
-- on src until a new point arrives.
function M.searchView(gps, src)
  local tr = src.track or {}
  if not src.trackNE or src.trackLast ~= tr[#tr] then
    local kn = math.rad(6371000)   -- metres per degree on the GPS core's sphere
    local ke = kn * math.cos(math.rad(src.homeLat))
    local ne, max2 = {}, 0
    for i, p in ipairs(tr) do
      local n, e = (p[1] - src.homeLat) * kn, (p[2] - src.homeLon) * ke
      ne[i] = { n, e }
      if n * n + e * e > max2 then max2 = n * n + e * e end
    end
    src.trackNE, src.trackMaxM, src.trackLast = ne, math.sqrt(max2), tr[#tr]
  end
  local v = { lat = src.lat, lon = src.lon, course = src.course, sats = src.sats,
              alt = src.alt, live = src.live, ageS = src.ageS, track = src.trackNE }
  v.distM = gps.haversine(src.homeLat, src.homeLon, src.lat, src.lon)
  v.bearing = gps.bearingTo(src.homeLat, src.homeLon, src.lat, src.lon)
  local b = math.rad(v.bearing)
  v.n, v.e = v.distM * math.cos(b), v.distM * math.sin(b)
  v.sector = gps.sectorOf(v.bearing)
  v.url = gps.mapUrl(src.lat, src.lon)
  v.maxM = math.max(v.distM, src.trackMaxM)
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

-- Model finder on the search page while the link is up: the link core's RSS at
-- 25 mW (dynamic power steps removed), smoothed (each new value counts 20 %), as
-- a strength 0..1 over FINDER_MIN..FINDER_MAX dBm and beeps that rise in pitch
-- and come faster with it (Geiger style). rss nil: no link, the finder rests and
-- starts fresh; so does a change of kind (RSS at 25 mW or plain), the two scales
-- differ by the TX power; w.finderMuted keeps the beeps silent. Sets v.signal
-- (dBm, rounded), v.strength, v.beepAt (getTime of the last beep), v.beepGap
-- (getTime units to the next) and v.muted on the search view.
M.FINDER_MIN, M.FINDER_MAX = -110, -40              -- dBm
local FINDER_TONE = { 600, 1200 }                   -- Hz, weak .. strong
local FINDER_GAP  = { 120, 10 }                     -- getTime units between beeps, weak .. strong
local FINDER_BEEP = 30                              -- ms
function M.updateFinder(w, v, rss, now, kind)
  local f = w.finder
  if not rss then w.finder = nil; return end
  if not f or f.kind ~= kind then f = { avg = rss, kind = kind }; w.finder = f end
  f.avg = 0.8 * f.avg + 0.2 * rss
  local s = (f.avg - M.FINDER_MIN) / (M.FINDER_MAX - M.FINDER_MIN)
  s = math.max(0, math.min(1, s))
  local gap = FINDER_GAP[1] + (FINDER_GAP[2] - FINDER_GAP[1]) * s
  if not f.beepAt or now - f.beepAt >= gap then
    f.beepAt = now
    if playTone and not w.finderMuted then playTone(math.floor(FINDER_TONE[1] + (FINDER_TONE[2] - FINDER_TONE[1]) * s), FINDER_BEEP, 0) end
  end
  v.signal, v.strength, v.beepAt, v.beepGap, v.muted = math.floor(f.avg + 0.5), s, f.beepAt, gap, w.finderMuted
end

-- Timer 1 of the model in seconds, nil while it is switched off.
local function readTimer(w)
  w.timerS = nil
  local t = model.getTimer and model.getTimer(0)
  if t and t.mode ~= 0 then w.timerS = t.value end
end

-- Colour levels (0 ok, 1 warning, 2 critical) for every page, all from the
-- cores' level functions: the widget only maps level and size to a colour.
-- Runs on the cores' views and the demo's alike. FLIGHT TIME on the post-flight
-- page takes the level of the time it shows (timeS, Timer 1 in seconds).
-- Each level guarded on its own: a failing level function leaves only that
-- value without a level (neutral colour), the others are still set.
local function lv(f, ...)
  if not f then return nil end
  local ok, v = pcall(f, ...)
  if ok then return v end
end
function M.addLevels(w)
  local lipo, gps, link = w.mods.lipo or {}, w.mods.gps or {}, w.mods.link or {}
  w.timerLevel = lv(lipo.timerLevel, w.timerS)
  for _, v in ipairs({ w.pre or false, w.flight or false }) do
    local b, g, l = v and v.batt, v and v.gps, v and v.link
    if b and not b.packs then
      b.level = lv(lipo.restLevel, b.pct, b.warn, b.crit)
      b.vLevel = lv(lipo.cellLevel, b.chem, b.cell)
    end
    if g then
      g.satsLevel, g.satsBars = lv(gps.satsLevel, g.sats, g.fixLost), lv(gps.satsBars, g.sats)
      g.satsBarsMax = gps.SATS_BAR_MIN and #gps.SATS_BAR_MIN   -- bars to draw, one per threshold
      g.fixLevel = lv(gps.fixLevel, g.fix)
      g.altLevel, g.distLevel = lv(gps.limitLevel, g.altOver or false), lv(gps.limitLevel, g.distOver or false)
    end
    if l then l.rssiLevel, l.lqStage = lv(link.rssiLevel, l.stage), l.lq and lv(link.lqLevel, l.lq) or nil end
  end
  local p = w.post
  if p then
    local b, g, l = p.batt, p.gps, p.link
    p.timeLevel = lv(lipo.timerLevel, p.timeS) or 0
    if b then
      b.level = lv(lipo.restLevel, b.left, b.warn, b.crit)
      b.lastVLevel = lv(lipo.lastVoltageLevel, b.chem, b.cell)
    end
    if g then g.altLevel, g.distLevel = lv(gps.limitLevel, g.altExceeded), lv(gps.limitLevel, g.distExceeded) end
    if l then l.lqStage = l.minLq and lv(link.lqLevel, l.minLq) or nil end
  end
  if w.search then w.search.satsLevel = lv(gps.satsLevel, w.search.sats) end
end

-- Page data from the demo: ("flight", view), ("pre", preflight data), ("post", summary),
-- ("switches", switch page view, with "hint" the wait page's hint) or ("search", position source).
local function updateDemo(w, now)
  w.search, w.flight, w.pre, w.post, w.sw, w.waitHint, w.waitHold = nil, nil, nil, nil, nil, nil, nil
  local kind, data
  -- DEMO may name the page ("flight", "search"); true takes the demo's default.
  if w.demo then kind, data = w.demo(w, now, M, type(M.DEMO) == "string" and M.DEMO or nil) end
  if kind == "flight" then w.flight = data end
  if kind == "switches" then
    w.sw, w.waitHint, w.waitHold = data.view, data.hint, data.hold
    w.stick, w.closeArmed = data.stick or 0, true
  end
  if kind == "post" then w.post = data end
  if kind == "pre" then
    w.pre = data
    w.preStatus = M.preflightStatus(data, w.mods)
  end
  if kind ~= "search" or not w.mods.gps then clearQr(w); w.finder = nil; return end
  local v = M.searchView(w.mods.gps, data)
  updateQr(w, v)
  M.updateFinder(w, v, data.live and data.refRssi or nil, now)
  w.search = v
end

-- ---------------------------------------------------------------------------
-- Settings: module switches per model, { models = { [filename] = { gps = false } } }.
-- Only switched-off modules are stored; a missing file means all on. Next to
-- models the switch page's modes per model (modes = { [filename] = ... },
-- written by the core after reading them from the FC). The path
-- is not written as `M.CONFIG_PATH = "..."` on purpose: the settings tool would
-- then ask to create the file.
-- ---------------------------------------------------------------------------
local CONFIG_PATH = "/SCRIPTS/WINGMAN/config.lua"
M.CONFIG_PATH = CONFIG_PATH
M.CONFIG_SCHEMA_VERSION = 1
M.MODULES = { "lipo", "link", "gps" }
local CONFIG_POLL = 500   -- getTime units: 5 s

M.MASCOTS = { "quad", "scout" }   -- wait page character, first = default
M.FLIGHT_TIMES = { "timer", "timeleft" }   -- flight page time beside the battery %, first = default
M.GPS_VIEWS = { "compass", "horizon" }      -- flight page GPS column, first = default

function M.defaultConfig()
  return { schemaVersion = M.CONFIG_SCHEMA_VERSION, generation = 0, models = {}, mascot = M.MASCOTS[1],
           flightTime = M.FLIGHT_TIMES[1], gpsView = M.GPS_VIEWS[1], switchPage = true, modes = {} }
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
  if cfg.flightTime ~= M.FLIGHT_TIMES[2] then cfg.flightTime = M.FLIGHT_TIMES[1] end
  if cfg.gpsView ~= M.GPS_VIEWS[2] then cfg.gpsView = M.GPS_VIEWS[1] end
  cfg.switchPage = cfg.switchPage ~= false
  if type(cfg.modes) ~= "table" then cfg.modes = {} end   -- switch page: FC modes by model file
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

-- Switches of the active model, the mascot, the flight time and GPS view choice, re-read every 5 s (a
-- change in the settings tool or a model switch applies without a reload). A damaged
-- file: all on, default mascot, flight time and GPS view. The stored modes keep their
-- table while unchanged, so the switch page is not built again on every read.
local function pollModules(w, now)
  if w.on and w.onAt and now - w.onAt < CONFIG_POLL then return w.on end
  w.onAt = now
  local cfg, file = M.loadConfig(), activeModel()
  w.on = M.modules(cfg, file)
  w.mascot = cfg and cfg.mascot
  w.flightTime = cfg and cfg.flightTime
  w.gpsView = cfg and cfg.gpsView
  w.switchPage = not cfg or cfg.switchPage
  local modes = cfg and file and cfg.modes[file] or nil
  if not (sameModes(w.modesEntry, modes) and w.modesEntry.date == modes.date) then w.modesEntry = modes end
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
  if not w.demo then pcall(readStick, w, now) end

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
      pcall(pollSearchHold, w, now)
      if not w.searching then w.search = nil end   -- closed by the gesture just now
    end
    if w.search then
      if not pcall(updateQr, w, w.search) then clearQr(w) end
    else
      clearQr(w)
    end
  end
  pcall(M.addLevels, w)
  w.setupErrors = M.setupErrors(w, on)
  if not w.appErrAt or now - w.appErrAt >= 100 then   -- setup changes slowly: once a second
    local appOk, appErr = pcall(appSetupError, w, on)
    w.appErr, w.appErrAt = appOk and appErr, now
  end
  w.setupError = #w.setupErrors > 0 or w.appErr
  if w.setupError then
    w.phase, w.flight, w.pre, w.search, w.post, w.waitHint = M.WAITING, nil, nil, nil, nil, nil
    closeSwitches(w)
    clearQr(w)
  end
  -- Finder after the setup check, so a hidden search page stays silent. Input:
  -- RSS at 25 mW, the plain RSS without TPWR; 0 means no reading yet.
  if not w.demo then
    local r = w.search and w.search.live and linkRes(w, on)
    local rss = r and r.status == "running" and (r.refRssi or r.linkRssi) or nil
    if rss == 0 then rss = nil end
    local kind = r and r.refRssi and "ref" or "raw"
    if not w.search or not pcall(M.updateFinder, w, w.search, rss, now, kind) then w.finder = nil end
  end
end

return M

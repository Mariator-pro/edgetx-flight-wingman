-- =====================================================================
-- main.lua  --  Flight Wingman widget (App mode, display only).
-- =====================================================================
-- SD card path: /WIDGETS/WINGMAN/main.lua
-- Needs /SCRIPTS/WINGMAN/core.lua; all logic lives there.
-- =====================================================================

local core, compass
do
  local function load(path)
    local chunk = loadScript(path)
    if chunk then
      local ok, mod = pcall(chunk)
      if ok then return mod end
    end
  end
  core = load("/SCRIPTS/WINGMAN/core.lua")
  compass = load("/SCRIPTS/GPSHOMER/compass.lua")   -- GPS Homer's compass drawing, the same on both
end

-- ---------------------------------------------------------------------------
-- Palettes (same as Link Sentinel). Set per frame from the Theme option.
-- ---------------------------------------------------------------------------
local DARK = {
  transparent = false,
  panel  = lcd.RGB( 18,  20,  18),
  fg     = lcd.RGB(235, 235, 235),
  muted  = lcd.RGB(150, 150, 150),
  track  = lcd.RGB( 55,  58,  55),
  accent = lcd.RGB(124, 210,  48),
  disk   = lcd.RGB( 22,  25,  22),   -- map background
  trail  = lcd.RGB( 60,  96,  30),   -- flight track, accent at 40 %
  box    = lcd.RGB( 27,  30,  27),
  halo   = lcd.RGB( 70,  26,  26),
  head   = lcd.RGB( 27,  30,  27),   -- wait page mascot
  disc   = lcd.RGB( 45,  74,  23),   -- spinning props, accent at 30 %
}
local LIGHT = {
  transparent = true,
  fg     = lcd.RGB(  0,   0,   0),
  muted  = lcd.RGB( 90,  90,  90),
  track  = lcd.RGB(200, 200, 205),
  accent = lcd.RGB(  1, 152,   8),
  trail  = lcd.RGB(130, 200, 120),
  box    = lcd.RGB(200, 200, 205),
  halo   = lcd.RGB(245, 190, 190),
  head   = lcd.RGB(205, 235, 190),   -- wait page mascot, light green
  eyeRing = lcd.RGB( 90,  90,  90),  -- white eyes need an outline on the light head
  disc   = lcd.RGB(195, 228, 175),   -- spinning props
}
local WARN_COL = lcd.RGB(255, 180,   0)
local CRIT_COL = lcd.RGB(220,  40,  40)

local COLORS = DARK

-- ---------------------------------------------------------------------------
-- Text helpers. Widths are cached; the cache is cleared at 200 entries so live
-- values cannot grow it without bound.
-- ---------------------------------------------------------------------------
local TEXT_CACHE_MAX = 200
local widthCache, widthCount = {}, 0
local heightCache = {}

local function textW(text, flags)
  local key = flags .. "|" .. text
  local w = widthCache[key]
  if not w then
    if widthCount >= TEXT_CACHE_MAX then widthCache, widthCount = {}, 0 end
    w = lcd.sizeText(text, flags)
    widthCache[key] = w
    widthCount = widthCount + 1
  end
  return w
end

local function fontH(flags)
  local h = heightCache[flags]
  if not h then
    local _, th = lcd.sizeText("0", flags)
    h = th
    heightCache[flags] = h
  end
  return h
end

-- Raw RGB through CUSTOM_COLOR so it never collides with size/align bits.
local function dtext(x, y, text, color, flags)
  lcd.setColor(CUSTOM_COLOR, color)
  lcd.drawText(x, y, text, CUSTOM_COLOR + (flags or 0))
end

-- ---------------------------------------------------------------------------
-- Drawing helpers
-- ---------------------------------------------------------------------------
-- Value text, "--" while the value is missing (never a made-up 0). f with %d
-- gets the value rounded.
local function fmt(f, v)
  if v == nil then return "--" end
  if string.find(f, "%%d") then v = math.floor(v + 0.5) end
  return string.format(f, v)
end

local function fillTri(x1, y1, x2, y2, x3, y3, col)
  if lcd.drawFilledTriangle then
    lcd.drawFilledTriangle(x1, y1, x2, y2, x3, y3, col)
  elseif lcd.drawTriangle then
    lcd.drawTriangle(x1, y1, x2, y2, x3, y3, col)
  end
end

-- Lines are 1 px in the Lua API: two side by side.
local function thickLine(x1, y1, x2, y2, col, pattern)
  lcd.drawLine(x1, y1, x2, y2, pattern or SOLID, col)
  lcd.drawLine(x1 + 1, y1, x2 + 1, y2, pattern or SOLID, col)
end

-- ---------------------------------------------------------------------------
-- Header: flight mode and ARMED fields in the middle; transmitter voltage over battery glyph, date over clock on the right.
-- ---------------------------------------------------------------------------
local function txBatteryPct(v, ctx)
  local lo, hi = ctx.battMin, ctx.battMax
  if not v or not lo or not hi or hi <= lo then return nil end
  local pct = (v - lo) / (hi - lo) * 100
  return math.max(0, math.min(100, pct))
end

-- Battery glyph lying flat: body, tip on the right, fill from the left.
local function drawTxBattery(x, y, w, h, pct)
  local tipW = math.max(2, math.floor(w / 10))
  local bw = w - tipW
  lcd.drawRectangle(x, y, bw, h, COLORS.fg)
  lcd.drawFilledRectangle(x + bw, y + math.floor(h / 4), tipW, h - 2 * math.floor(h / 4), COLORS.fg)
  if pct then
    local col = (pct > 30) and COLORS.accent or ((pct > 10) and WARN_COL or CRIT_COL)
    local fw = math.floor((bw - 4) * pct / 100 + 0.5)
    if fw > 0 then lcd.drawFilledRectangle(x + 2, y + 2, fw, h - 4, col) end
  end
end

-- Header height = EdgeTX menu button (45 px, scaled like the system UI: 62 on
-- 800 px), so the bottom line ends flush with the button.
local UI_SCALE = (lvgl and type(lvgl.LCD_SCALE) == "number") and lvgl.LCD_SCALE or 1
local HDR_H = math.floor(45 * UI_SCALE + 0.5)

-- Date over time like the EdgeTX header: same font (SMLSIZE = EdgeTX XS), line
-- pitch 15 px scaled, both centred on each other.
local DATE_LINE2 = math.floor(15 * UI_SCALE + 0.5)
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

-- Heartbeat (as in Link Sentinel / GPS Homer): red dot pulsing softly (2 s cosine
-- from the background to red) while telemetry packets arrive. drawFilledCircle has
-- no opacity, so the colour is mixed by hand; Light mixes from white.
local HEARTBEAT_PERIOD = 200   -- getTime ticks
local HEARTBEAT_RED    = { 220, 40, 40 }
local HEARTBEAT_BG     = { dark = { 18, 20, 18 }, light = { 255, 255, 255 } }
local HEARTBEAT_R      = math.floor(4 * UI_SCALE + 0.5)

-- floor (0..1): share of red kept at the low point (antenna tip: never gone);
-- fixed (0..1): a steady share of red instead of the pulse.
local function drawHeartbeat(cx, cy, r, floor, fixed)
  floor = floor or 0
  local t  = fixed or (floor + (1 - floor) * (0.5 - 0.5 * math.cos(2 * math.pi * (getTime() % HEARTBEAT_PERIOD) / HEARTBEAT_PERIOD)))
  local bg = COLORS.transparent and HEARTBEAT_BG.light or HEARTBEAT_BG.dark
  local function mix(i) return math.floor(bg[i] + (HEARTBEAT_RED[i] - bg[i]) * t + 0.5) end
  lcd.drawFilledCircle(cx, cy, r or HEARTBEAT_R, lcd.RGB(mix(1), mix(2), mix(3)))
end

-- No rounded rectangle in the Lua API: two overlapping bars plus four corner circles.
local function fillRounded(x, y, w, h, r, color)
  lcd.drawFilledRectangle(x + r, y, w - 2 * r, h, color)
  lcd.drawFilledRectangle(x, y + r, w, h - 2 * r, color)
  for _, c in ipairs({ { x + r, y + r }, { x + w - r - 1, y + r },
                       { x + r, y + h - r - 1 }, { x + w - r - 1, y + h - r - 1 } }) do
    lcd.drawFilledCircle(c[1], c[2], r, color)
  end
end

-- Bottom right of the page (countdowns, stick holds): a bar filled to frac
-- (0..1) in color, txt left of it; laid out for 800 x 480 like the flight page.
local CD_BAR_W = 120   -- design px
local function drawCornerBar(z, txt, frac, color)
  local kx = z.w / 800
  local k = math.min(kx, (z.h - HDR_H) / 418)
  local function sc(v) return math.max(1, math.floor(v * k + 0.5)) end
  local barW, barH = math.floor(CD_BAR_W * kx + 0.5), math.max(3, sc(6))
  local bx, by = z.w - math.floor(18 * kx + 0.5) - barW, z.h - sc(14) - barH
  fillRounded(bx, by, barW, barH, math.floor(barH / 2), COLORS.track)
  local fw = math.floor(barW * math.max(0, math.min(1, frac)))
  if fw >= barH then fillRounded(bx, by, fw, barH, math.floor(barH / 2), color) end
  dtext(bx - sc(12) - textW(txt, SMLSIZE), by + math.floor((barH - fontH(SMLSIZE)) / 2), txt, COLORS.muted, SMLSIZE)
end

-- Flight mode field and ARMED field on fixed slots: the mode
-- slot is sized for four wide letters (CRSF mode names are about four), the ARMED
-- slot stays empty while disarmed so nothing moves.
local FIELD_FONT  = BOLD
local FIELD_R     = math.floor(4 * UI_SCALE + 0.5)
local ARMED_TEXT  = "ARMED"
local WHITE       = lcd.RGB(255, 255, 255)

-- Text on a coloured field: dark on green and yellow, white on red.
local DARK_TEXT = lcd.RGB(18, 20, 18)

-- Mode field colour from the flight mode alert: failsafe red, rescue and landing yellow.
local ALERT_COL = { FS = CRIT_COL, RTH = WARN_COL, LAND = WARN_COL }

-- Timer 1 as m:ss (countdown below zero with a minus).
local function fmtTimer(s)
  local sign = (s < 0) and "-" or ""
  s = math.abs(s)
  return string.format("%s%02d:%02d", sign, math.floor(s / 60), s % 60)
end

-- Mode field and ARMED field as a group on fixed slots, centred; moved right to
-- start at minX (room for the model name), but not past right.
-- Returns the group's left edge.
local function drawModeFields(ctx, hdrH, pad, minX, right)
  local w = ctx.w
  local px, py = 3 * pad, pad
  local fh = fontH(FIELD_FONT) + 2 * py
  local modeW = textW("MMMM", FIELD_FONT) + 2 * px
  local armW = textW(ARMED_TEXT, FIELD_FONT) + 2 * px
  local gap = 2 * pad
  local groupW = modeW + armW + gap
  local x = math.min(math.max(math.floor((ctx.zone.w - groupW) / 2), minX), right - groupW)
  local y = math.floor((hdrH - fh) / 2)
  if not w then return x end
  if w.mode then
    local alert = ALERT_COL[w.alert or ""] or (w.armBlocked and WARN_COL)
    fillRounded(x, y, modeW, fh, FIELD_R, alert or COLORS.track)
    dtext(x + math.floor(modeW / 2), y + py, w.mode, alert and (alert == CRIT_COL and WHITE or DARK_TEXT) or COLORS.fg,
          FIELD_FONT + CENTER)
    if w.armed then
      local ax = x + modeW + gap
      fillRounded(ax, y, armW, fh, FIELD_R, CRIT_COL)
      dtext(ax + math.floor(armW / 2), y + py, ARMED_TEXT, WHITE, FIELD_FONT + CENTER)
    end
  end
  return x
end

-- Model name cut to maxW with a trailing ".."; the last result is kept.
local nameCut = {}
local function fitName(name, maxW)
  if nameCut.name == name and nameCut.maxW == maxW then return nameCut.text end
  local text = name
  if textW(text, 0) > maxW then
    while #text > 0 and textW(text .. "..", 0) > maxW do text = string.sub(text, 1, -2) end
    text = text .. ".."
  end
  nameCut = { name = name, maxW = maxW, text = text }
  return text
end

-- Model name right of the EdgeTX menu button (as wide as the header is high),
-- up to shortly before the mode field.
local function drawModelName(name, left, right, hdrH)
  if name == "" or right <= left then return end
  dtext(left, math.floor((hdrH - fontH(0)) / 2), fitName(name, right - left), COLORS.fg, 0)
end

local function drawHeader(ctx)
  local w = ctx.zone.w
  local pad = math.max(2, math.floor(w / 120))
  local hdrH = HDR_H

  local dt = getDateTime()
  local date = string.format("%d %s", dt.day, MONTHS[dt.mon] or "")
  local clock = string.format("%02d:%02d", dt.hour, dt.min)
  local blockW = math.max(textW(date, SMLSIZE), textW(clock, SMLSIZE))
  local cx = w - pad - math.floor(blockW / 2)
  local y = math.floor((hdrH - DATE_LINE2 - fontH(SMLSIZE)) / 2)
  dtext(cx, y, date, COLORS.fg, SMLSIZE + CENTER)
  dtext(cx, y + DATE_LINE2, clock, COLORS.fg, SMLSIZE + CENTER)

  -- Transmitter voltage over the battery glyph, rows aligned with date and time.
  local v = getValue("tx-voltage")
  local volt = string.format("%.1fV", v or 0)
  local bh = math.floor((fontH(SMLSIZE) + 2 * pad) * 0.45)   -- sized to the text, not the header
  local bw = math.floor(bh * 2.2)
  local colW = math.max(textW(volt, SMLSIZE), bw)
  local bx = w - pad - blockW - 4 * pad - math.floor(colW / 2)
  dtext(bx, y, volt, COLORS.fg, SMLSIZE + CENTER)
  local by = y + DATE_LINE2 + math.floor((fontH(SMLSIZE) - bh) / 2)
  drawTxBattery(bx - math.floor(bw / 2), by, bw, bh, txBatteryPct(v, ctx))

  local info = model.getInfo and model.getInfo()
  local name = info and info.name or ""
  local nameX = hdrH + 2 * pad
  local fieldsX = drawModeFields(ctx, hdrH, pad, nameX + textW(name, 0) + 4 * pad,
                                 bx - math.floor(colW / 2) - 4 * pad)
  drawModelName(name, nameX, fieldsX - 4 * pad, hdrH)

  lcd.drawFilledRectangle(0, hdrH - 1, w, 1, COLORS.track)
end

-- ---------------------------------------------------------------------------
-- Search page: radar map left (home in the centre, north up, three rings with
-- an automatic scale), distance, direction, signal and a map QR code right.
-- ---------------------------------------------------------------------------
local RING_STEPS = { 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000, 50000 }
local QR_DARK    = lcd.RGB(18, 20, 18)
local QR_QUIET   = 2      -- white modules around the code
local UNIT_DROP  = 0.12   -- unit text sits this share of the number height above its box bottom

-- Ring spacing in metres: three rings hold everything with 10 % margin.
local function ringStep(maxM)
  for _, s in ipairs(RING_STEPS) do
    if 3 * s >= maxM * 1.1 then return s end
  end
  return RING_STEPS[#RING_STEPS]
end

local function fmtDist(m)
  if m < 1000 then return string.format("%d", math.floor(m + 0.5)), "m" end
  return string.format("%.1f", m / 1000), "km"
end

local function fmtAge(s)
  if s < 60 then return string.format("%d s old", s) end
  return string.format("%d min old", math.floor(s / 60))
end

-- Arrow with its tip len px from (cx, cy) towards deg (0 = up = north).
local function drawArrow(cx, cy, len, deg, col)
  local function pt(a, r)
    local rad = math.rad(a)
    return math.floor(cx + r * math.sin(rad) + 0.5), math.floor(cy - r * math.cos(rad) + 0.5)
  end
  local x1, y1 = pt(deg, len)
  local x2, y2 = pt(deg + 145, len * 0.8)
  local x3, y3 = pt(deg - 145, len * 0.8)
  fillTri(x1, y1, x2, y2, x3, y3, col)
end

-- Centre x of a label kept inside xmin..xmax.
local function labelX(x, text, xmin, xmax)
  local half = math.floor(textW(text, SMLSIZE) / 2)
  return math.max(xmin + half, math.min(xmax - half, x))
end

local function drawMap(v, x0, y0, s, pad)
  local fh = fontH(SMLSIZE)
  local half = math.floor(s / 2)
  local cx, cy = x0 + half, y0 + half
  local R = half - fh - pad
  if COLORS.disk then lcd.drawFilledCircle(cx, cy, R + pad, COLORS.disk) end

  local step = ringStep(v.maxM)
  local k = R / (3 * step)
  local function xy(n, e) return math.floor(cx + e * k + 0.5), math.floor(cy - n * k + 0.5) end
  local mx, my = xy(v.n, v.e)
  local hr = math.floor(fh * 0.8)
  -- Model label above the dot; the ring labels go to the bottom of the rings
  -- when one of them would touch it at the top.
  local mText = v.live and "MODEL" or "LAST POSITION"
  local mlx   = labelX(mx, mText, x0, x0 + s)
  local mHalf = math.floor(textW(mText, SMLSIZE) / 2)
  local mTop  = my - hr - fh
  local rings, below = {}, false
  for i = 1, 3 do
    local r = math.floor(R * i / 3)
    local m = step * i
    local label = (m >= 1000) and string.format("%g km", m / 1000) or string.format("%d m", m)
    rings[i] = { r = r, label = label }
    local ly, lw = cy - r + 2, textW(label, SMLSIZE)
    if cx + pad < mlx + mHalf and cx + pad + lw > mlx - mHalf and ly < mTop + fh and ly + fh > mTop then
      below = true
    end
  end
  for _, ring in ipairs(rings) do
    lcd.drawCircle(cx, cy, ring.r, COLORS.track)
    dtext(cx + pad, below and (cy + ring.r - 2 - fh) or (cy - ring.r + 2), ring.label, COLORS.muted, SMLSIZE)
  end
  local rl = R + math.floor((half - R) / 2)
  dtext(cx, cy - rl - math.floor(fh / 2), "N", COLORS.fg, SMLSIZE + CENTER)
  dtext(cx + rl, cy - math.floor(fh / 2), "E", COLORS.muted, SMLSIZE + CENTER)
  dtext(cx, cy + rl - math.floor(fh / 2), "S", COLORS.muted, SMLSIZE + CENTER)
  dtext(cx - rl, cy - math.floor(fh / 2), "W", COLORS.muted, SMLSIZE + CENTER)

  local px, py
  for i, p in ipairs(v.track) do
    local x, y = xy(p[1], p[2])
    if i > 1 then thickLine(px, py, x, y, COLORS.trail) end
    px, py = x, y
  end
  thickLine(cx, cy, mx, my, WARN_COL, DOTTED)

  local hs = fh
  local hx, hy = cx - math.floor(hs / 2), cy - math.floor(hs / 2)
  lcd.drawFilledRectangle(hx, hy, hs, hs, COLORS.disk or COLORS.box)
  lcd.drawRectangle(hx, hy, hs, hs, COLORS.fg, 2)
  dtext(cx, cy - math.floor(fh / 2), "H", COLORS.fg, SMLSIZE + CENTER)

  if v.live then
    lcd.drawFilledCircle(mx, my, hr, COLORS.halo)
    if v.course then
      drawArrow(mx, my, math.floor(hr * 0.75), v.course, CRIT_COL)
    else
      lcd.drawFilledCircle(mx, my, math.floor(hr / 3), CRIT_COL)
    end
    dtext(mlx, mTop, mText, CRIT_COL, SMLSIZE + CENTER)
  else
    lcd.drawCircle(mx, my, hr, WARN_COL)
    lcd.drawFilledCircle(mx, my, math.floor(hr / 3), WARN_COL)
    dtext(mlx, mTop, mText, WARN_COL, SMLSIZE + CENTER)
  end
end

-- ---------------------------------------------------------------------------
-- Flight page: three columns, battery left, GPS middle, link right. Each column:
-- title, big value with caption, a bar or the compass, values below. Positions
-- are laid out for 800 x 480 (body 418 px under the header) and scaled to the
-- zone; text is placed by its baseline.
-- ---------------------------------------------------------------------------
local BODY_H    = 418
local GPS_W     = 200   -- GPS column in the 800 px design with all three modules on
local BASELINE  = 0.76   -- baseline inside a text box, as a share of its reported height
-- Capital letters inside a text box (share of its reported height), for centring
-- a word in a bar; measured on BOLD in the 800 x 480 simulator.
local CAP_TOP, CAP_H = 0.185, 0.593
local BAR_TOP, BAR_BOTTOM = 160, 194   -- battery and link bar, 34 px high, room for the mark labels
local FONTS_LRG = { hero = XLSIZE or DBLSIZE, unit = 0, cap = SMLSIZE, label = TINSIZE or SMLSIZE,
                    value = 0, side = MIDSIZE, title = SMLSIZE, stage = BOLD, ready = DBLSIZE }
local FONTS_STD = { hero = DBLSIZE, unit = SMLSIZE, cap = SMLSIZE, label = TINSIZE or SMLSIZE,
                    value = SMLSIZE, side = 0, title = SMLSIZE, stage = SMLSIZE, ready = MIDSIZE }
local STAGE_COL = { [1] = WARN_COL, [2] = CRIT_COL }
-- Level colour: 0 green (accent), 1 yellow, 2 red.
local function levelCol(lvl) return STAGE_COL[lvl] or COLORS.accent end
local SAT_STEPS = { 4, 6, 10, 15, 20 }   -- sats needed for bar 1..5 (as GPS Homer)
local SAT_BAR_H = { 8, 14, 20, 26, 32 }

local function satBars(sats)
  local n = 0
  for i, m in ipairs(SAT_STEPS) do if (sats or 0) >= m then n = i end end
  return n
end

-- Layout context: x from the 800 px design, y from the 418 px body, sizes by the smaller factor.
local function flightLayout(z)
  local kx, ky = z.w / 800, (z.h - HDR_H) / BODY_H
  local L = { kx = kx, ky = ky, k = math.min(kx, ky), top = HDR_H,
              f = (z.w >= 700) and FONTS_LRG or FONTS_STD }
  function L.x(v) return math.floor(v * kx + 0.5) end
  function L.y(v) return HDR_H + math.floor(v * ky + 0.5) end
  function L.s(v) return math.max(1, math.floor(v * L.k + 0.5)) end
  return L
end

-- Search page (right panel and the page itself); after flightLayout for the title.
local function drawSearchInfo(ctx, v, x0, y0, pw, ph, pad)
  local p = 2 * pad
  local x, y, right, bottom = x0 + p, y0 + p, x0 + pw - p, y0 + ph - p
  local fh = fontH(SMLSIZE)

  -- Bottom row, always reserved: how to close the page, the hold as a bar at
  -- the bottom right filling up while the aileron is held right.
  drawCornerBar(ctx.zone, "ail: hold > to close", ctx.w.searchClose or 0, COLORS.accent)
  bottom = bottom - fh - p

  -- Title with the accent square of the column titles, bold like Lipo Nanny's
  -- SELECT PACK; LINK LOST tag while the position is not live.
  local L  = flightLayout(ctx.zone)
  local th = fontH(BOLD)
  local sq = L.s(11)
  lcd.drawFilledRectangle(x, y + math.floor((th - sq) / 2), sq, sq, COLORS.accent)
  dtext(x + sq + L.s(8), y, "SEARCH MODEL", COLORS.accent, BOLD)
  if not v.live then
    local tw = textW("LINK LOST", SMLSIZE) + 2 * p
    local ty = y + math.floor((th - fh) / 2)
    fillRounded(right - tw, ty, tw, fh, FIELD_R, CRIT_COL)
    dtext(right - math.floor(tw / 2), ty, "LINK LOST", WHITE, SMLSIZE + CENTER)
  end
  y = y + th + p

  -- Distance from home, direction home -> model on the same row.
  dtext(x, y, "FROM HOME", COLORS.muted, SMLSIZE)
  y = y + fh
  -- 800 px: DBLSIZE distance, MIDSIZE unit and direction; smaller screens one step
  -- below each, so the signal line still fits above the QR code
  local wide = ctx.zone.w >= 700
  local big, dirF = wide and DBLSIZE or MIDSIZE, wide and MIDSIZE or 0
  local bh, mh, dh = fontH(big), fontH(MIDSIZE), fontH(dirF)
  local num, unit = fmtDist(v.distM)
  dtext(x, y, num, COLORS.fg, big)
  dtext(x + textW(num, big) + pad, y + bh - dh - math.floor(bh * UNIT_DROP), unit, COLORS.muted, dirF)
  local deg = string.format("%d\194\176", math.floor(v.bearing + 0.5) % 360)
  local sec = v.sector .. " "
  local cr = math.floor(dh / 2)
  local dx = right - textW(deg, dirF) - textW(sec, dirF)
  local dy = y + math.floor((bh - dh) / 2)
  dtext(dx, dy, sec, COLORS.fg, dirF)
  dtext(dx + textW(sec, dirF), dy, deg, COLORS.muted, dirF)
  local gx, gy = dx - pad - cr, dy + cr
  lcd.drawCircle(gx, gy, cr, COLORS.track)
  drawArrow(gx, gy, cr - 2, v.bearing, v.live and COLORS.accent or COLORS.muted)
  y = y + bh + p

  -- Signal, altitude, sats: in boxes, else as one text line, left out when the
  -- QR code would get too small.
  local boxH = fh + mh + p
  local gap = pad
  local bw = math.floor((right - x - 2 * gap) / 3)
  local cells = {
    { "SIGNAL", (v.live and ctx.w.rssi) and string.format("%d%%", ctx.w.rssi) or "--" },
    { "ALT", fmt("%d m", v.alt) },
    { "SATS", v.sats and tostring(v.sats) or "--" },
  }
  if bottom - (y + boxH + p) < 3 * 33 then
    if bottom - (y + fh + p) >= 3 * 33 then
      -- the three pairs spread evenly over the width
      local used = 0
      for _, c in ipairs(cells) do used = used + textW(c[1] .. " ", SMLSIZE) + textW(c[2], SMLSIZE) end
      local spread = math.max(pad, math.floor((right - x - used) / 2))
      local cx = x
      for _, c in ipairs(cells) do
        dtext(cx, y, c[1] .. " ", COLORS.muted, SMLSIZE)
        cx = cx + textW(c[1] .. " ", SMLSIZE)
        dtext(cx, y, c[2], v.live and COLORS.fg or COLORS.muted, SMLSIZE)
        cx = cx + textW(c[2], SMLSIZE) + spread
      end
      y = y + fh + p
    end
  else
    for i, c in ipairs(cells) do
      local bx = x + (i - 1) * (bw + gap)
      fillRounded(bx, y, bw, boxH, FIELD_R, COLORS.box)
      dtext(bx + pad, y + math.floor(p / 2), c[1], COLORS.muted, SMLSIZE)
      dtext(bx + pad, y + math.floor(p / 2) + fh, c[2], v.live and COLORS.fg or COLORS.muted, MIDSIZE)
    end
    y = y + boxH + p
  end

  -- QR code bottom left, position text beside it.
  local qr = v.qr
  local textBlockW = textW("00.000000", SMLSIZE)
  if qr then
    local mods = qr.size + 2 * QR_QUIET
    local m = math.max(1, math.floor(math.min(bottom - y, right - x - p - textBlockW) / mods))
    local size = mods * m
    local qx, qy = x, bottom - size
    lcd.drawFilledRectangle(qx, qy, size, size, WHITE)
    for _, r in ipairs(qr.runs) do
      lcd.drawFilledRectangle(qx + (r[2] - 1 + QR_QUIET) * m, qy + (r[1] - 1 + QR_QUIET) * m,
        r[3] * m, m, QR_DARK)
    end
    x, y = qx + size + p, qy + math.floor((size - 3 * fh) / 2)
  else
    y = bottom - 3 * fh
  end
  -- POSITION with live (or the age) beside it, then latitude and longitude
  local hx = x + textW("POSITION ", SMLSIZE)
  dtext(x, y, "POSITION ", COLORS.muted, SMLSIZE)
  if v.live then
    dtext(hx, y, "live", COLORS.accent, SMLSIZE)
  else   -- the age goes below the position when it does not fit beside the heading
    local age = fmtAge(v.ageS or 0)
    if hx + textW(age, SMLSIZE) <= right then dtext(hx, y, age, WARN_COL, SMLSIZE)
    else dtext(x, y + 3 * fh, age, WARN_COL, SMLSIZE) end
  end
  dtext(x, y + fh, string.format("%.5f", v.lat), COLORS.fg, SMLSIZE)
  dtext(x, y + 2 * fh, string.format("%.5f", v.lon), COLORS.fg, SMLSIZE)
end

local function drawSearch(ctx)
  local v = ctx.w and ctx.w.search
  if not v then return end
  local z = ctx.zone
  local pad = math.max(2, math.floor(z.w / 120))
  local top = HDR_H
  local s = math.min(z.h - top, math.floor(z.w / 2))
  -- Small zones (e.g. a layout zone before App mode) would give negative circle radii.
  if s < 6 * fontH(SMLSIZE) then return end
  drawMap(v, 0, top, s, pad)
  lcd.drawFilledRectangle(s, top, 1, z.h - top, COLORS.track)
  drawSearchInfo(ctx, v, s + 1, top, z.w - s - 1, z.h - top, pad)
end

-- Text with its baseline at y.
-- A missing value ("--") is neutral: neither OK nor a warning colour; keep
-- holds col for a "--" that is itself a warning (unknown link mode).
local function btext(x, y, text, col, font, keep)
  if text == "--" and not keep then col = COLORS.fg end
  dtext(x, y - math.floor(fontH(font) * BASELINE + 0.5), text, col, font)
end

local function rtext(right, y, text, col, font)
  btext(right - textW(text, font), y, text, col, font)
end

-- Accent square plus title.
-- dy: design offset from the top of the body (post-flight columns start lower).
local function drawTitle(L, x, text, dy)
  dy = dy or 0
  local s = L.s(11)
  lcd.drawFilledRectangle(x, L.y(21 + dy), s, s, COLORS.accent)
  btext(x + s + L.s(8), L.y(31 + dy), text, COLORS.accent, L.f.title)
end

-- Big value with unit and caption below; side block (label over value) right-aligned.
local HERO_Y = 98   -- big value baseline (design y), clear of the title
local function drawHero(L, x, right, num, unit, numCol, cap, sideLabel, sideValue, sideCol, keepDash)
  local base = L.y(HERO_Y)
  if num == "--" and not keepDash then numCol = COLORS.fg end   -- the unit too
  btext(x, base, num, numCol, L.f.hero, keepDash)
  if unit then btext(x + textW(num, L.f.hero) + L.s(6), base, unit, numCol, L.f.unit) end
  btext(x, L.y(HERO_Y + 29), cap, COLORS.muted, L.f.cap)
  if sideLabel then
    rtext(right, L.y(HERO_Y - 35), sideLabel, COLORS.muted, L.f.label)
    rtext(right, base, sideValue, sideCol or COLORS.fg, L.f.side)
  end
end

-- Packet-rate caption and value: a "Full" mode moves into the caption ("MODE (Full)"
-- over "X100Hz"), so the value stays short beside the big number.
local function modeParts(mode)
  local base = mode and string.match(mode, "^(.-) Full$")
  if base then return "MODE (Full)", base end
  return "MODE", mode or "--"
end

-- Label over value, rows from the given design y.
local function drawCell(L, x, row0, label, value, col)
  btext(x, L.y(row0 + 10), label, COLORS.muted, L.f.label)
  btext(x, L.y(row0 + 36), value, col or COLORS.fg, L.f.value)
end

-- Rows on a 57 px pitch from y 249, so the battery's third row lines up with
-- the GPS row at the bottom (363) and the link starts with the battery.
local GRID_TOP, GRID_PITCH = 249, 57

local function drawGrid(L, x, w, cells)
  local half = math.floor(w / 2)
  for i, c in ipairs(cells) do
    local row = math.floor((i - 1) / 2)
    drawCell(L, x + ((i - 1) % 2) * half, GRID_TOP + GRID_PITCH * row, c[1], c[2], c[3])
  end
end

local function stageOf(pct, warn, crit)
  if not pct then return 0 end
  if pct <= crit then return 2 end
  if pct <= warn then return 1 end
  return 0
end

-- Battery bar with the warning and critical marks, their labels above and below.
local function drawBattBar(L, x, w, b, col)
  local by, bh, r = L.y(BAR_TOP), L.y(BAR_BOTTOM) - L.y(BAR_TOP), L.s(4)
  fillRounded(x, by, w, bh, r, COLORS.track)
  local fw = math.floor(w * math.max(0, math.min(100, b.pct or 0)) / 100)
  if fw >= 2 * r then fillRounded(x, by, fw, bh, r, col) end
  local t = L.s(4)
  for _, m in ipairs({ { b.warn, WARN_COL, "WARN", L.y(BAR_TOP - 7) }, { b.crit, CRIT_COL, "CRIT", L.y(BAR_BOTTOM + 20) } }) do
    local mx = x + math.floor(w * m[1] / 100)
    lcd.drawFilledRectangle(mx, by - t, 2, bh + 2 * t, m[2])
    local label = string.format("%s %d %%", m[3], m[1])
    btext(mx - math.floor(textW(label, L.f.label) / 2), m[4], label, m[2], L.f.label)
  end
end

-- text cut to maxW with "..", keep (e.g. " #3") stays whole.
local function cutText(text, keep, maxW, font)
  if textW(text .. keep, font) <= maxW then return text .. keep end
  while #text > 0 and textW(text .. ".." .. keep, font) > maxW do text = string.sub(text, 1, -2) end
  return text .. ".." .. keep
end

-- Pack name as a column title: the full name when it fits, else the one without
-- the manufacturer, cut with ".." if still too long; the number ("#3", "#1+2") whole.
local function packTitle(L, w, name, short)
  name = name or "--"
  local maxW = w - L.s(19)
  if textW(name, L.f.title) <= maxW then return name end
  name = short or name
  local num = string.match(name, " #[%d%+]+$") or ""
  return cutText(string.sub(name, 1, #name - #num), num, maxW, L.f.title)
end

local function drawBattery(L, x, w, b, timerS)
  local right = x + w
  local stage = stageOf(b.pct, b.warn, b.crit)
  local col = STAGE_COL[stage] or COLORS.accent
  local hot = b.vLevel and levelCol(b.vLevel)   -- voltage coloured as on Lipo Nanny (per-cell thresholds)
  drawTitle(L, x, packTitle(L, w, b.name, b.nameShort))
  drawHero(L, x, right, fmt("%d", b.pct), "%", col, "REMAINING",
           timerS and "TIMER", timerS and fmtTimer(timerS))

  drawBattBar(L, x, w, b, col)
  drawGrid(L, x, w, {
    { "VOLTAGE", fmt("%.1f V", b.volt), hot },
    { "PER CELL", fmt("%.2f V", b.cell), hot },
    { "LEFT", fmt("%d mAh", b.left) },
    { "USED", fmt("%d mAh", b.used) },
    { "CAPACITY", fmt("%d mAh", b.cap) },
    { "CURRENT", fmt("%.1f A", b.amps) },
  })
end

local function drawLink(L, x, w, l, linkUp)
  local right = x + w
  local col = STAGE_COL[l.stage] or COLORS.accent
  drawTitle(L, x, l.modLine)
  -- Heartbeat top right, centred on the title square, while packets arrive.
  if linkUp then drawHeartbeat(right - HEARTBEAT_R, L.y(21) + math.floor(L.s(11) / 2)) end
  -- A mode without a sensitivity limit is a warning in the link core (as in
  -- link-sentinel's widget): "--" in the stage colour and a full bar.
  local unknown = l.sensLimit == 0
  local modeCap, modeVal = modeParts(l.mode)
  drawHero(L, x, right, fmt("%d", l.range), "%", col, "RANGELIMIT", modeCap, modeVal, nil, unknown)

  -- Range bar: fills towards the limit, the stage word inside.
  local by, bh, r = L.y(BAR_TOP), L.y(BAR_BOTTOM) - L.y(BAR_TOP), L.s(4)
  fillRounded(x, by, w, bh, r, COLORS.track)
  local pct = unknown and 100 or (l.range or 0)
  local fw = math.max(2 * r, math.floor(w * math.max(0, math.min(100, pct)) / 100))
  fillRounded(x, by, fw, bh, r, col)
  local word = (l.stage == 2 and "CRITICAL") or (l.stage == 1 and "WARNING") or "OK"
  local fh = fontH(L.f.stage)
  local ty = by + math.floor((bh - fh * CAP_H) / 2 - fh * CAP_TOP + 0.5)
  dtext(x + L.s(10), ty, word, (l.stage == 2) and WHITE or DARK_TEXT, L.f.stage)

  drawGrid(L, x, w, {
    { "LQ", fmt("%d %%", l.lq), l.lqStage and levelCol(l.lqStage) },
    { "RSSI", fmt("%d dBm", l.rssi) },
    { "ANTENNA", fmt("%d", l.ant) },
    { "TX POWER", fmt("%d mW", l.tpwr) },
  })
end

-- Compass from GPS Homer's compass.lua (the same drawing on both widgets):
-- Nose up or North up by the Compass option; none without the file.
local NORTH_UP = false
-- kind from compass.label: "ring" (before home), "house" (on the home point) or
-- "arrow"; course and rel smoothed like on GPS Homer.
local function drawCompass(L, cx, cy, g, kind, course, rel)
  local R = math.floor(70 * L.k * 0.8 + 0.5)   -- design: 200 unit compass drawn at 160 px
  local col = { track = COLORS.track, fg = COLORS.fg, muted = COLORS.muted }
  if kind ~= "arrow" then
    compass.ring(cx, cy, R, NORTH_UP and 0 or -(course or 0), nil, false, NORTH_UP, col)
    if kind == "house" then compass.house(cx, cy, math.floor(R * 0.55), COLORS.fg, COLORS.track) end
    return
  end
  compass.draw(cx, cy, R, { course = course, rel = rel, bearing = g.bearing }, NORTH_UP, false, col)
end

-- Satellites as the big value, five bars on the right (stages as GPS Homer).
local function drawSats(L, x, right, sats)
  local n = satBars(sats)
  local satCol = (n <= 1) and CRIT_COL or ((n == 2) and WARN_COL or COLORS.accent)
  drawHero(L, x, right, fmt("%d", sats), nil, satCol, "SATS")
  local bw, bg = L.s(8), L.s(3)
  local bx = right - 5 * bw - 4 * bg
  for i, h in ipairs(SAT_BAR_H) do
    local hh = L.s(h)
    lcd.drawFilledRectangle(bx + (i - 1) * (bw + bg), L.y(HERO_Y) - hh, bw, hh, (i <= n) and satCol or COLORS.track)
  end
end

local function drawGps(L, x, w, g, alert, ctx)
  local right = x + w
  drawTitle(L, x, "GPS")
  drawSats(L, x, right, g.sats)

  -- Compass and the line under it as on GPS Homer (shared compass.lua): what to
  -- show and the text; course and rel smoothed per widget.
  if compass then
    local sm = ctx.smooth or {}
    ctx.smooth = sm
    sm.course = compass.smooth(sm.course, g.course)
    sm.rel    = compass.smooth(sm.rel, g.rel)
    local kind, lb = compass.label({ gpsState = g.gpsState, noHome = g.noHome, atHome = g.atHome, alert = alert,
                                     courseValid = g.courseValid, rel = sm.rel, sector = g.sector, bearing = g.bearing },
                                   { ahead = g.ahead or 15, behind = g.behind or 165 })
    local cx, base = x + math.floor(w / 2), L.y(308)
    drawCompass(L, cx, L.y(208), g, kind, sm.course, sm.rel)
    local col = (lb.col == "warn" and WARN_COL) or (lb.col == "crit" and CRIT_COL)
                or (lb.col == "muted" and COLORS.muted) or COLORS.fg
    if lb.cap then
      local gap = L.s(6)
      local lw = textW(lb.cap, L.f.label) + gap + textW(lb.text, L.f.value)
      local lx = cx - math.floor(lw / 2)
      btext(lx, base, lb.cap, COLORS.muted, L.f.label)
      btext(lx + textW(lb.cap, L.f.label) + gap, base, lb.text, col, L.f.value)
    else
      local t = (textW(lb.text, L.f.value) <= w) and lb.text or lb.short
      btext(cx - math.floor(textW(t, L.f.value) / 2), base, t, col, L.f.value)
    end
  end

  local half = math.floor(w / 2)
  drawCell(L, x, GRID_TOP + 2 * GRID_PITCH, "ALT", fmt("%d m", g.alt))
  drawCell(L, x + half, GRID_TOP + 2 * GRID_PITCH, "DIST", fmt("%d m", g.dist))
end

-- Column lines from top (default: under the header) down to bottom. All three
-- modules on: GPS narrower in the middle, battery and link share the rest; a
-- module switched off frees its column and the others share the width equally.
-- Returns x, w of battery (1, 2), GPS (3, 4) and link (5, 6), nil when off.
local COL_MODULES = { "lipo", "gps", "link" }
local function columns(L, z, on, bottom, top)
  top = top or HDR_H
  on = on or {}
  local shown = {}
  for i, k in ipairs(COL_MODULES) do if on[k] ~= false then shown[#shown + 1] = i end end
  local n = #shown
  local edges = { 0 }
  if n == 3 then
    local sideW = math.floor((z.w - L.x(GPS_W)) / 2)
    edges = { 0, sideW, z.w - sideW }
  else
    for j = 2, n do edges[j] = math.floor((j - 1) * z.w / n) end
  end
  edges[n + 1] = z.w
  local pad, c = L.x(18), {}
  for j, i in ipairs(shown) do
    local x0, x1 = edges[j], edges[j + 1]
    if j > 1 then lcd.drawFilledRectangle(x0, top, 1, bottom - top, COLORS.track) end
    c[2 * i - 1], c[2 * i] = x0 + pad, x1 - x0 - 2 * pad
  end
  return c
end

local function drawFlight(ctx)
  local v = ctx.w and ctx.w.flight
  if not v then return end
  local z = ctx.zone
  if z.h - HDR_H < 8 * fontH(SMLSIZE) then return end
  local L = flightLayout(z)
  local c = columns(L, z, ctx.w.on, z.h)
  if v.batt and c[1] then drawBattery(L, c[1], c[2], v.batt, ctx.w.timerS) end
  if v.gps and c[3] then drawGps(L, c[3], c[4], v.gps, ctx.w.alert, ctx) end
  if v.link and c[5] then drawLink(L, c[5], c[6], v.link, ctx.w.linkUp) end
end

-- ---------------------------------------------------------------------------
-- Preflight page: the flight page's columns, 300 of 418 design px high, each
-- with a status line at the bottom; below a strip with the ready field (GO /
-- CHECK), the line next to it and the versions. Statuses come from the core.
-- ---------------------------------------------------------------------------
local PRE_COLS_H = 300
local STATUS_Y   = 282   -- status line baseline (design y)
local PRE_ROW0   = 150   -- label and value cells below the big value
local PACK_TOP, PACK_ROW_H = 50, 36
local READY_W, READY_H = 190, 76
local CONFIRM_FILL_OPACITY = 8   -- confirm hold bar behind the selected pack

-- Dot plus status text in its level colour.
local function drawStatus(L, x, st)
  if not st then return end
  local col, font = levelCol(st.level), L.f.value
  local fh, d = fontH(font), L.s(10)
  local base = L.y(STATUS_Y)
  local cy = base - math.floor(fh * (BASELINE - CAP_TOP - CAP_H / 2) + 0.5)
  lcd.drawFilledCircle(x + math.floor(d / 2), cy, math.floor(d / 2), col)
  btext(x + d + L.s(8), base, st.text, col, font)
end

local function drawPreBattery(L, x, w, b, st)
  local col = levelCol(st.batt.level)
  drawTitle(L, x, packTitle(L, w, b.name, b.nameShort))
  drawHero(L, x, x + w, fmt("%.2f", b.cell), "V", col, "PER CELL", "TOTAL", fmt("%.1f V", b.volt), col)
  drawBattBar(L, x, w, b, col)
  drawStatus(L, x, st.batt)
end

-- Marquee as in LiPo Nanny's selection popup: a name too long for its row
-- scrolls by one character per MARQUEE_STEP, pausing MARQUEE_PAUSE steps at the
-- start and the end. Whole characters, because a widget can't clip text.
local MARQUEE_STEP  = 30   -- 0.3 s (getTime units)
local MARQUEE_PAUSE = 3

-- True for a UTF-8 continuation byte (never the start of a character).
local function isContByte(s, i)
  local b = string.byte(s, i)
  return b ~= nil and b >= 128 and b < 192
end

-- Longest part of s from byte first on that fits maxW, never ending inside a
-- multi-byte character. Binary search: ~log2(#s) measurements.
local function fitFrom(s, first, maxW, font)
  local lo, hi = first - 1, #s
  if textW(string.sub(s, first), font) <= maxW then return string.sub(s, first) end
  while hi - lo > 1 do
    local mid = math.floor((lo + hi) / 2)
    if textW(string.sub(s, first, mid), font) <= maxW then lo = mid else hi = mid end
  end
  while lo >= first and isContByte(s, lo + 1) do lo = lo - 1 end
  return string.sub(s, first, lo)
end

-- The part of name to show at time t (getTime units since the row got the cursor).
local function marqueeText(name, maxW, t, font)
  if textW(name, font) <= maxW then return name end
  local starts = {}
  for i = 1, #name do
    if not isContByte(name, i) then starts[#starts + 1] = i end
  end
  local lo, hi = 1, #starts
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if textW(string.sub(name, starts[mid]), font) <= maxW then hi = mid else lo = mid + 1 end
  end
  local steps = lo - 1
  local pos = math.floor(t / MARQUEE_STEP) % (steps + 2 * MARQUEE_PAUSE) - MARQUEE_PAUSE
  if pos < 0 then pos = 0 elseif pos > steps then pos = steps end
  return fitFrom(name, starts[pos + 1], maxW, font)
end

-- Pack selection inside the battery column: window around the cursor, confirm
-- hold as a bar behind the selected row, gesture legend at the bottom. The
-- selected name scrolls (restarting when the cursor moves), the others are cut.
local function drawPackList(L, x, w, b, ctx)
  drawTitle(L, x, "SELECT PACK")
  local font = L.f.value
  local rowH = L.y(PACK_TOP + PACK_ROW_H) - L.y(PACK_TOP)
  local maxRows = math.floor((STATUS_Y - 24 - PACK_TOP) / PACK_ROW_H)
  local cursor = b.cursor or 1
  if ctx.marqueeRow ~= cursor then ctx.marqueeRow, ctx.marqueeSince = cursor, getTime() end
  local start = math.max(1, math.min(cursor - math.floor((maxRows - 1) / 2), #b.packs - maxRows + 1))
  for i = start, math.min(#b.packs, start + maxRows - 1) do
    local pk, y = b.packs[i], L.y(PACK_TOP + (i - start) * PACK_ROW_H)
    local sel = i == cursor
    if sel and (b.hold or 0) > 0 then
      lcd.drawFilledRectangle(x, y, math.floor(w * math.min(1, b.hold)), rowH - 2, COLORS.accent, CONFIRM_FILL_OPACITY)
    end
    local prefix = sel and "> " or "  "
    local suffix = string.format(" #%d (%dc)", pk.pos, pk.cycles)
    local nameW = w - textW(prefix .. suffix, font)
    local text = sel and marqueeText(pk.name, nameW, getTime() - ctx.marqueeSince, font)
                 or cutText(pk.name, "", nameW, font)
    -- the number sits fixed at the right edge, so it never jumps with the scrolling name
    local ty, col = y + math.floor((rowH - fontH(font)) / 2), sel and COLORS.accent or COLORS.fg
    dtext(x, ty, prefix .. text, col, font)
    dtext(x + w - textW(suffix, font), ty, suffix, col, font)
  end
  btext(x, L.y(STATUS_Y), "ele: up/dn  ail: hold >", COLORS.muted, L.f.cap)
end

local function drawPreGps(L, x, w, g, st)
  drawTitle(L, x, "GPS")
  drawSats(L, x, x + w, g.sats)
  local half = math.floor(w / 2)
  drawCell(L, x, PRE_ROW0, g.dopKind or "PDOP", g.dop and string.format("%.1f", g.dop) or "--",
           g.dop and levelCol(st.dopStage))
  drawCell(L, x + half, PRE_ROW0, "FIX", g.fix or "--")
  drawStatus(L, x, st.gps)
end

local function drawPreLink(L, x, w, l, st, linkUp)
  local right = x + w
  drawTitle(L, x, l.modLine)
  if linkUp then drawHeartbeat(right - HEARTBEAT_R, L.y(21) + math.floor(L.s(11) / 2)) end
  local modeCap, modeVal = modeParts(l.mode)
  drawHero(L, x, right, fmt("%d", l.lq), "%", st.lqLevel and levelCol(st.lqLevel) or COLORS.fg, "LQ", modeCap, modeVal)
  local half = math.floor(w / 2)
  drawCell(L, x, PRE_ROW0, "RSSI", fmt("%d dBm", l.rssi))
  drawCell(L, x + half, PRE_ROW0, "TX POWER", fmt("%d mW", l.tpwr))
  drawStatus(L, x, st.link)
end

-- Seconds left on a page timer that started at `since` (the core's ms clock,
-- getTime() * 10) and runs `total` ms.
local function secsLeft(since, total)
  return math.max(0, math.ceil((total - (getTime() * 10 - since)) / 1000))
end

-- Countdown at the bottom right (preflight and post-flight page): text left of
-- a bar that runs empty. countdownW is the width it takes, reserved also while
-- it does not run so nothing moves.
local function countdownW(L, label)
  return L.x(CD_BAR_W) + L.s(12) + textW(label .. " in 00 s", SMLSIZE)
end
local function drawCountdown(z, secs, total, label)
  drawCornerBar(z, string.format("%s in %d s", label, secs), secs / total, COLORS.muted)
end

-- Ready field left, the line (arming blocked in yellow) and the versions right
-- of it, cut short of the countdown's place at the bottom right.
local function drawReady(L, z, top, p, st)
  local bw, bh = L.x(READY_W), L.s(READY_H)
  local bx, by = L.x(18), top + math.floor((z.h - top - bh) / 2)
  fillRounded(bx, by, bw, bh, L.s(10), (st.ready == "GO") and COLORS.accent or WARN_COL)
  local f = L.f.ready
  local fh = fontH(f)
  dtext(bx + math.floor(bw / 2), by + math.floor((bh - fh * CAP_H) / 2 - fh * CAP_TOP + 0.5), st.ready,
        DARK_TEXT, f + CENTER)
  local tx = bx + bw + L.x(18)
  local tw = z.w - tx - L.x(18) - countdownW(L, "Flight page") - L.x(18)
  if st.line then
    btext(tx, by + math.floor(bh * 0.45), cutText(st.line, "", tw, L.f.value),
          p.armBlocked and WARN_COL or COLORS.fg, L.f.value)
  end
  local ver = getVersion and getVersion()
  local parts = {}
  if p.fcInfo then parts[#parts + 1] = p.fcInfo end
  if ver then parts[#parts + 1] = "EdgeTX " .. ver end
  btext(tx, by + bh - L.s(8), cutText(table.concat(parts, ", "), "", tw, L.f.cap), COLORS.muted, L.f.cap)
end

local function drawPre(ctx)
  local w = ctx.w
  local p, st = w and w.pre, w and w.preStatus
  if not (p and st) then return end
  local z = ctx.zone
  if z.h - HDR_H < 8 * fontH(SMLSIZE) then return end
  local L = flightLayout(z)
  local top = L.y(PRE_COLS_H)
  local c = columns(L, z, w.on, top)
  lcd.drawFilledRectangle(0, top, z.w, 1, COLORS.track)
  if p.batt and p.batt.packs and c[1] then
    drawPackList(L, c[1], c[2], p.batt, ctx)
  else
    ctx.marqueeRow = nil   -- next selection starts its marquee anew
    if p.batt and c[1] then drawPreBattery(L, c[1], c[2], p.batt, st) end
  end
  if p.gps and c[3] then drawPreGps(L, c[3], c[4], p.gps, st) end
  if p.link and c[5] then drawPreLink(L, c[5], c[6], p.link, st, w.linkUp) end
  drawReady(L, z, top, p, st)
  local fs = w.fs
  if fs and fs.readySince and w.phase == core.PRE then   -- GO: countdown to the flight page
    drawCountdown(z, secsLeft(fs.readySince, core.PRE_HOLD_T), core.PRE_HOLD_T / 1000, "Flight page")
  end
end

-- ---------------------------------------------------------------------------
-- Post-flight page: three key figures on top (flight time, used mAh, distance
-- flown), the flight's values per module in the flight page's columns, the
-- alerts with their flight time below and the countdown to the wait page.
-- ---------------------------------------------------------------------------
local POST_KPI_H  = 100   -- key figure strip (design px of the 418 body)
local POST_COLS_B = 306   -- columns end here
local POST_ROW0, POST_ROW_H = 54, 30   -- first value row (offset in the column), pitch
local ALERT_ROW_H = 24

local function kmText(m) return m and string.format("%.1f", m / 1000) or "--" end
local function distText(m)
  if not m then return "--" end
  local v, u = fmtDist(m)
  return v .. " " .. u
end

-- One key figure: caption over a big value with a smaller unit, centred on cx.
-- cap: text, or { long, short } (the short one when the long one is wider than maxW).
local function drawKpi(L, cx, cap, value, unit, col, maxW)
  local f, uf = L.f.hero, L.f.unit
  if type(cap) == "table" then cap = textW(cap[1], L.f.cap) <= maxW and cap[1] or cap[2] end
  -- The caption sits a fixed gap above the number's capitals, so the gap looks
  -- the same with the big font (800 px) and the smaller one (480 px).
  local valY = L.y(86)
  local capY = valY - math.floor(fontH(f) * CAP_H + 0.5) - L.s(14)
  btext(cx - math.floor(textW(cap, L.f.cap) / 2), capY, cap, COLORS.muted, L.f.cap)
  local vw = textW(value, f)
  local uw = unit and (L.s(6) + textW(unit, uf)) or 0
  local x0 = cx - math.floor((vw + uw) / 2)
  btext(x0, valY, value, col or COLORS.fg, f)
  if unit then btext(x0 + vw + L.s(6), valY, unit, col or COLORS.fg, uf) end
end

-- Label left, value right, rows from the column top.
-- Label: text, or { long, short } (the short one when the long one does not fit
-- beside the value); a label that does not fit at all is left out, the value stays.
local function drawRows(L, x, w, rows)
  for i, row in ipairs(rows) do
    local base  = L.y(POST_KPI_H + POST_ROW0 + (i - 1) * POST_ROW_H)
    local label = row[1]
    local room  = w - textW(row[2], L.f.value) - (row[4] and textW(row[4], L.f.value) or 0) - L.s(6)
    if type(label) == "table" then
      label = textW(label[1], L.f.label) <= room and label[1] or label[2]
    end
    if textW(label, L.f.label) <= room then btext(x, base, label, COLORS.muted, L.f.label) end
    rtext(x + w, base, row[2], row[3] or COLORS.fg, L.f.value)
    if row[4] then rtext(x + w - textW(row[2], L.f.value), base, row[4], COLORS.fg, L.f.value) end   -- lead-in, text colour
  end
end

local function drawPostColumns(L, c, p)
  local b, g, l = p.batt, p.gps, p.link
  if b and c[1] then
    local stage = stageOf(b.left, b.warn, b.crit)
    drawTitle(L, c[1], packTitle(L, c[2], b.name, b.nameShort), POST_KPI_H)
    local lastV = b.volt and (fmt("%.1f V", b.volt) .. "  " .. fmt("%.2f V/c", b.cell)) or "--"
    drawRows(L, c[1], c[2], {
      { "CHARGE", fmt("%d %%", b.left), STAGE_COL[stage], fmt("%d %%", b.start) .. " -> " },
      { { "LAST VOLTAGE", "LAST V" }, lastV },
      { { "MAX CURRENT", "MAX CURR" }, fmt("%.1f A", b.maxA) },
      { "PACK CYCLES", b.cycles or "--" },
    })
  end
  if g and c[3] then
    drawTitle(L, c[3], "GPS", POST_KPI_H)
    local co = g.coord or function(v) return string.format("%.5f", v) end
    drawRows(L, c[3], c[4], {
      { { "MAX DISTANCE", "MAX DIST" }, distText(g.maxDist) },
      { { "MAX ALTITUDE", "MAX ALT" }, fmt("%d m", g.maxAlt) },
      { { "MAX SPEED", "MAX SPD" }, fmt("%d km/h", g.maxSpd) },
      { { "LAST POSITION", "LAST POS" }, g.lat and co(g.lat) or "--" },
      { "", g.lon and co(g.lon) or "" },
    })
  end
  if l and c[5] then
    drawTitle(L, c[5], l.modLine, POST_KPI_H)
    drawRows(L, c[5], c[6], {
      { { "LOW LINK QUALITY", "LOW LQ" }, fmt("%d %%", l.minLq), l.lqStage and levelCol(l.lqStage) },
      { "MAX RANGELIMIT", fmt("%d %%", l.maxRange), l.rangeStage and levelCol(l.rangeStage) },
      { { "MAX TX POWER", "MAX TX PWR" }, fmt("%d mW", l.maxTpwr) },
      { "RF MODE", l.mode or "--" },
    })
  end
end

-- Alerts: newest top left, then down the column and on in the second; six at
-- most, the sixth carrying "+N" for the older ones not shown.
local function drawAlerts(L, z, p, pad)
  local top = L.y(POST_COLS_B + 22)
  btext(pad, top, "ALERTS", COLORS.muted, L.f.label)
  local list, n = p.alerts or {}, #(p.alerts or {})
  if n == 0 then
    btext(pad, L.y(POST_COLS_B + 22 + ALERT_ROW_H), "none", COLORS.muted, L.f.value)
    return
  end
  local colW = math.floor((z.w - 2 * pad) * 0.36)
  for i = 1, math.min(6, n) do
    local a = list[n - i + 1]   -- newest first
    local x = pad + ((i > 3) and colW or 0)
    local base = L.y(POST_COLS_B + 22 + (((i - 1) % 3) + 1) * ALERT_ROW_H)
    local t = string.format("%02d:%02d", math.floor(a.t / 60), a.t % 60)
    btext(x, base, t, COLORS.muted, L.f.value)
    local tx = x + textW("00:00 ", L.f.value)
    local text = a.text
    if i == 6 and n > 6 then text = text .. "  +" .. (n - 6) end
    btext(tx, base, text, levelCol(a.level), L.f.value)
  end
end

local function drawPost(ctx)
  local w = ctx.w
  local p = w and w.post
  if not p then return end
  local z = ctx.zone
  if z.h - HDR_H < 8 * fontH(SMLSIZE) then return end
  local L = flightLayout(z)
  local b, g = p.batt or {}, p.gps or {}
  local third = math.floor(z.w / 3)
  drawKpi(L, math.floor(third / 2), "FLIGHT TIME", p.time or "--")
  drawKpi(L, third + math.floor(third / 2), { "USED CAPACITY", "USED CAP" }, fmt("%d", b.used), "mAh",
          STAGE_COL[stageOf(b.left, b.warn or 0, b.crit or 0)], third - L.s(16))
  drawKpi(L, 2 * third + math.floor(third / 2), "FLOWN", kmText(g.flown), "km")
  local kpiB, colsB = L.y(POST_KPI_H), L.y(POST_COLS_B)
  lcd.drawFilledRectangle(0, kpiB, z.w, 1, COLORS.track)
  lcd.drawFilledRectangle(0, colsB, z.w, 1, COLORS.track)
  local c = columns(L, z, w.on, colsB, kpiB)
  drawPostColumns(L, c, p)
  local pad = L.x(18)
  drawAlerts(L, z, p, pad)
  -- Countdown to the wait page (demo data brings its own seconds; reopened by stick: from then).
  local left = p.leftS or secsLeft(w.reviewAt or (w.fs and w.fs.endedAt) or 0, core.ENDED_HOLD_T)
  drawCountdown(z, left, core.ENDED_HOLD_T / 1000, "Wait page")
end

-- ---------------------------------------------------------------------------
-- Wait page: a mascot while no telemetry arrives, chosen in the settings tool
-- (Display): "Quad", a quad seen slightly from above (the camera is its face,
-- props as discs), or "Scout", a round head; both with an antenna sending signal
-- arcs. With a setup error the mascot is sad, next to a yellow speech bubble.
-- Mascots drawn in a 150 x 122 design box, scaled with the page; animation from
-- getTime() (rocks on its foot, props spin, arcs pulse outwards, red tip pulses
-- like the heartbeat, eyes blink and now and then look ahead). The API cannot rotate
-- shapes, so the rocking figure is built from triangles and circles at rotated
-- points.
-- ---------------------------------------------------------------------------
local WAIT_TITLE = "LOOKING FOR THE MODEL"
local WAIT_SUB   = "No telemetry yet"
local ROCK_T, ARC_T, BLINK_T = 500, 180, 500   -- periods in getTime ticks
local ROCK_DEG = 6                             -- rocking amplitude
local LOOK_T, LOOK_FROM, LOOK_TO, LOOK_EASE = 800, 450, 650, 20   -- looks ahead 2 s every 8 s
local PIVOT_U, PIVOT_V = 75, 100               -- rocking point (design units)
local ARC_R = { 12, 20, 28 }
local ANT_DEG = -20    -- antenna leans left, arcs follow it
local TIP_DIM = 0.35   -- antenna tip at its dimmest: 35 % red
local PROP_DEG = 3     -- prop turn per getTime tick
local ERR_TITLE = "Configuration error"
local ERR_LINES = { "Please check", "Tool Flight Bag" }

-- Quad parts, same in Dark and Light.
local CARBON    = lcd.RGB( 38,  38,  38)
local PLATE     = lcd.RGB( 42,  42,  42)
local TPU       = lcd.RGB( 90, 160,  32)
local BATT      = lcd.RGB(240, 192,  32)
local BATT_TOP  = lcd.RGB(246, 216,  96)
local STRAP_TOP = lcd.RGB(155, 224,  90)
local LENS      = lcd.RGB( 28,  47,  69)

-- Props: centre, radii, blade angle, turning direction (diagonal pairs alike).
local REAR_PROPS  = { { 38, 66, 20, 5.5, 60, 1 }, { 112, 66, 20, 5.5, 0, -1 } }
local FRONT_PROPS = { { 22, 86, 25, 7, 20, -1 }, { 128, 86, 25, 7, 80, 1 } }

-- Unit directions along each corner arc (top right, bottom right, bottom left,
-- top left; clockwise on screen).
local CORNER_STEPS = 5
local CORNER_DIRS = {}
for q = 1, 4 do
  CORNER_DIRS[q] = {}
  for i = 0, CORNER_STEPS do
    local a = math.rad(-90 + (q - 1) * 90 + i * 90 / CORNER_STEPS)
    CORNER_DIRS[q][i + 1] = { math.cos(a), math.sin(a) }
  end
end

-- Unit circle for the prop discs.
local ELLIPSE_STEPS = 10
local ELLIPSE_DIRS = {}
for i = 1, ELLIPSE_STEPS do
  local a = 2 * math.pi * i / ELLIPSE_STEPS
  ELLIPSE_DIRS[i] = { math.cos(a), math.sin(a) }
end

local function drawScout(mx, my, k, t, sad)
  local deg = ROCK_DEG * math.sin(2 * math.pi * (t % ROCK_T) / ROCK_T)
  local c, sn = math.cos(math.rad(deg)), math.sin(math.rad(deg))
  -- Design point rotated about the pivot (positive = clockwise), in pixels.
  local function P(u, v)
    local du, dv = u - PIVOT_U, v - PIVOT_V
    return math.floor(mx + (PIVOT_U + du * c - dv * sn) * k + 0.5),
           math.floor(my + (PIVOT_V + du * sn + dv * c) * k + 0.5)
  end
  local function S(n) return math.max(1, math.floor(n * k + 0.5)) end
  local function rect(u, v, w, h, col)
    local x1, y1 = P(u, v)
    local x2, y2 = P(u + w, v)
    local x3, y3 = P(u + w, v + h)
    local x4, y4 = P(u, v + h)
    fillTri(x1, y1, x2, y2, x3, y3, col)
    fillTri(x1, y1, x3, y3, x4, y4, col)
  end
  -- Rounded rectangle as one convex polygon (CORNER_STEPS segments per corner),
  -- filled as a fan from its centre: no seams between separately rounded parts.
  local function rounded(u, v, w, h, r, col)
    local cu, cv = P(u + w / 2, v + h / 2)
    local fx, fy
    local px, py
    for qi, q in ipairs({ { u + w - r, v + r }, { u + w - r, v + h - r }, { u + r, v + h - r }, { u + r, v + r } }) do
      for _, d in ipairs(CORNER_DIRS[qi]) do
        local x, y = P(q[1] + r * d[1], q[2] + r * d[2])
        if px then fillTri(cu, cv, px, py, x, y, col) else fx, fy = x, y end
        px, py = x, y
      end
    end
    fillTri(cu, cv, px, py, fx, fy, col)
  end
  local function circle(u, v, r, col)
    local x, y = P(u, v)
    lcd.drawFilledCircle(x, y, S(r), col)
  end

  -- Shadow stays put.
  fillRounded(math.floor(mx + 49 * k + 0.5), math.floor(my + 106 * k + 0.5), S(52), S(5), S(2), COLORS.track)

  -- Antenna on top of the head, arcs around its tip.
  local bx, by = P(75, 46)
  local ex, ey = P(75, 28)
  local tx, ty = P(75, 23)
  thickLine(bx, by, ex, ey, COLORS.muted)
  if sad then
    drawHeartbeat(tx, ty, S(5), nil, TIP_DIM)   -- tip stays dim, no arcs
  elseif lcd.drawAnnulus then
    local w = math.max(2, math.floor(3 * k + 0.5))
    for i, r in ipairs(ARC_R) do
      local ph = ((t - (i - 1) * 30) % ARC_T) / ARC_T
      if ph > 0.1 and ph < 0.65 then
        local ro = math.floor(r * k + 0.5)
        lcd.drawAnnulus(tx, ty, ro - w, ro, (deg - 45) % 360, (deg + 45) % 360, COLORS.accent)
      end
    end
  end
  if not sad then drawHeartbeat(tx, ty, S(5), TIP_DIM) end   -- tip pulses like the heartbeat, dimmed only

  -- Head: accent rim around the body colour, ears on both sides.
  rounded(34, 64, 6, 18, 2, COLORS.muted)
  rounded(110, 64, 6, 18, 2, COLORS.muted)
  rounded(40, 46, 70, 56, 16, COLORS.accent)
  rounded(43, 49, 64, 50, 13, COLORS.head)

  -- Eyes looking up at the antenna, now and then straight ahead (pupils glide
  -- down and back); a short blink once per rock.
  local lt = t % LOOK_T
  local ahead = math.max(0, math.min(1, (lt - LOOK_FROM) / LOOK_EASE, (LOOK_TO - lt) / LOOK_EASE))
  local pupilV = sad and 73 or (67 + 3 * ahead)   -- sad: looks down
  local blink = (t % BLINK_T) >= 290 and (t % BLINK_T) < 305
  for _, eu in ipairs({ 62, 88 }) do
    if blink then
      rect(eu - 8, 69, 16, 3, WHITE)
    else
      if COLORS.eyeRing then circle(eu, 70, 9.5, COLORS.eyeRing) end
      circle(eu, 70, 8, WHITE)
      circle(eu, pupilV, 4, DARK_TEXT)
    end
  end
  if sad then
    -- Mouth as a downward arc.
    local px, py
    for i = 0, 4 do
      local s = i / 4   -- quadratic curve (68,93) (75,86) (82,93)
      local x, y = P(68 + 14 * s, 93 - 14 * s * (1 - s))
      if px then thickLine(px, py, x, y, COLORS.accent); thickLine(px, py + 1, x, y + 1, COLORS.accent) end
      px, py = x, y
    end
    return
  end
  local mx2, my2 = P(75, 89)
  lcd.drawCircle(mx2, my2, S(4), COLORS.accent)
  lcd.drawCircle(mx2, my2, S(3), COLORS.accent)
end

local function drawQuad(mx, my, k, t, sad)
  local deg = ROCK_DEG * math.sin(2 * math.pi * (t % ROCK_T) / ROCK_T)
  local c, sn = math.cos(math.rad(deg)), math.sin(math.rad(deg))
  -- Design point rotated about the pivot (positive = clockwise), in pixels.
  local function P(u, v)
    local du, dv = u - PIVOT_U, v - PIVOT_V
    return math.floor(mx + (PIVOT_U + du * c - dv * sn) * k + 0.5),
           math.floor(my + (PIVOT_V + du * sn + dv * c) * k + 0.5)
  end
  local function S(n) return math.max(1, math.floor(n * k + 0.5)) end
  local function quad(u1, v1, u2, v2, u3, v3, u4, v4, col)
    local x1, y1 = P(u1, v1)
    local x2, y2 = P(u2, v2)
    local x3, y3 = P(u3, v3)
    local x4, y4 = P(u4, v4)
    fillTri(x1, y1, x2, y2, x3, y3, col)
    fillTri(x1, y1, x3, y3, x4, y4, col)
  end
  local function rect(u, v, w, h, col) quad(u, v, u + w, v, u + w, v + h, u, v + h, col) end
  -- Straight bar of width w (design units) from one point to another.
  local function bar(u1, v1, u2, v2, w, col)
    local du, dv = u2 - u1, v2 - v1
    local f = w / 2 / math.sqrt(du * du + dv * dv)
    local nu, nv = -dv * f, du * f
    quad(u1 + nu, v1 + nv, u2 + nu, v2 + nv, u2 - nu, v2 - nv, u1 - nu, v1 - nv, col)
  end
  -- Convex polygons filled as a fan from their centre: no seams.
  local function ellipse(u, v, rx, ry, col)
    local cu, cv = P(u, v)
    local px, py = P(u + rx, v)
    for _, d in ipairs(ELLIPSE_DIRS) do
      local x, y = P(u + rx * d[1], v + ry * d[2])
      fillTri(cu, cv, px, py, x, y, col)
      px, py = x, y
    end
  end
  -- Rounded rectangle as one convex polygon (CORNER_STEPS segments per corner).
  local function rounded(u, v, w, h, r, col)
    local cu, cv = P(u + w / 2, v + h / 2)
    local fx, fy
    local px, py
    for qi, q in ipairs({ { u + w - r, v + r }, { u + w - r, v + h - r }, { u + r, v + h - r }, { u + r, v + r } }) do
      for _, d in ipairs(CORNER_DIRS[qi]) do
        local x, y = P(q[1] + r * d[1], q[2] + r * d[2])
        if px then fillTri(cu, cv, px, py, x, y, col) else fx, fy = x, y end
        px, py = x, y
      end
    end
    fillTri(cu, cv, px, py, fx, fy, col)
  end
  local function circle(u, v, r, col)
    local x, y = P(u, v)
    lcd.drawFilledCircle(x, y, S(r), col)
  end
  -- Prop: disc and three blades (2 px lines, cheap) while spinning, only the
  -- blades when stopped.
  local spin = sad and 0 or t * PROP_DEG
  local function prop(p)
    local u, v, rx, ry = p[1], p[2], p[3], p[4]
    if not sad then ellipse(u, v, rx, ry, COLORS.disc) end
    local cx, cy = P(u, v)
    for i = 0, 2 do
      local a = math.rad(p[5] + p[6] * spin + i * 120)
      local x, y = P(u + rx * math.cos(a), v + ry * math.sin(a))
      thickLine(cx, cy, x, y, COLORS.accent)
      thickLine(cx, cy + 1, x, y + 1, COLORS.accent)
    end
  end

  -- Shadow stays put.
  fillRounded(math.floor(mx + 22 * k + 0.5), math.floor(my + 112 * k + 0.5), S(106), S(6), S(3), COLORS.track)

  -- Rear arms, motors and props behind the body.
  bar(75, 80, 38, 74, 4, CARBON)
  bar(75, 80, 112, 74, 4, CARBON)
  rect(33, 68, 10, 8, COLORS.muted)
  rect(107, 68, 10, 8, COLORS.muted)
  for _, p in ipairs(REAR_PROPS) do prop(p) end

  -- Top plate, battery (top face lighter) with strap.
  quad(52, 52, 98, 52, 100, 58, 50, 58, PLATE)
  quad(58, 30, 92, 30, 95, 38, 55, 38, BATT_TOP)
  rect(55, 38, 40, 15, BATT)
  rect(55, 38, 40, 4, PLATE)
  quad(72, 30, 78, 30, 79, 38, 71, 38, STRAP_TOP)
  rect(71, 38, 8, 15, COLORS.accent)

  -- Antenna from the battery, arcs around its tip.
  bar(64, 34, 58, 18, 2.5, COLORS.muted)
  local tx, ty = P(57, 14)
  if sad then
    drawHeartbeat(tx, ty, S(5), nil, TIP_DIM)   -- tip stays dim, no arcs
  elseif lcd.drawAnnulus then
    local w = math.max(2, math.floor(3 * k + 0.5))
    local dir = deg + ANT_DEG
    for i, r in ipairs(ARC_R) do
      local ph = ((t - (i - 1) * 30) % ARC_T) / ARC_T
      if ph > 0.1 and ph < 0.65 then
        local ro = math.floor(r * k + 0.5)
        lcd.drawAnnulus(tx, ty, ro - w, ro, (dir - 45) % 360, (dir + 45) % 360, COLORS.accent)
      end
    end
  end
  if not sad then drawHeartbeat(tx, ty, S(5), TIP_DIM) end   -- tip pulses like the heartbeat, dimmed only

  -- Front arms, bottom plate, front motors with accent caps.
  bar(75, 96, 22, 100, 6, CARBON)
  bar(75, 96, 128, 100, 6, CARBON)
  quad(50, 96, 100, 96, 104, 102, 46, 102, PLATE)
  rect(15, 90, 14, 12, COLORS.muted)
  rect(121, 90, 14, 12, COLORS.muted)
  rect(15, 88, 14, 4, COLORS.accent)
  rect(121, 88, 14, 4, COLORS.accent)

  -- Camera as the face: TPU mount, accent rim, the real lens small on the forehead.
  rect(47, 64, 5, 32, TPU)
  rect(98, 64, 5, 32, TPU)
  rounded(51, 60, 48, 40, 9, COLORS.accent)
  rounded(54, 63, 42, 34, 7, COLORS.head)
  circle(75, 67, 1.5, LENS)

  -- Eyes looking up at the antenna, now and then straight ahead (pupils glide
  -- down and back); a short blink once per rock.
  local lt = t % LOOK_T
  local ahead = math.max(0, math.min(1, (lt - LOOK_FROM) / LOOK_EASE, (LOOK_TO - lt) / LOOK_EASE))
  local pupilV = sad and 81 or (75 + 3 * ahead)   -- sad: looks down
  local blink = (t % BLINK_T) >= 290 and (t % BLINK_T) < 305
  for _, eu in ipairs({ 66, 84 }) do
    if blink then
      rect(eu - 7, 77, 14, 3, WHITE)
    else
      if COLORS.eyeRing then circle(eu, 78, 8.5, COLORS.eyeRing) end
      circle(eu, 78, 7, WHITE)
      circle(eu, pupilV, 3.5, DARK_TEXT)
    end
  end
  if sad then
    -- Mouth as a downward arc.
    local px, py
    for i = 0, 4 do
      local s = i / 4   -- quadratic curve (70,95) (75,89) (80,95)
      local x, y = P(70 + 10 * s, 95 - 12 * s * (1 - s))
      if px then thickLine(px, py, x, y, COLORS.accent); thickLine(px, py + 1, x, y + 1, COLORS.accent) end
      px, py = x, y
    end
  else
    local mx2, my2 = P(75, 91)
    lcd.drawCircle(mx2, my2, S(3), COLORS.accent)
    lcd.drawCircle(mx2, my2, S(2), COLORS.accent)
  end

  -- Front props over the arms and the sides of the face, hubs on top.
  for _, p in ipairs(FRONT_PROPS) do
    prop(p)
    circle(p[1], p[2], 2.5, TPU)
  end
end

-- Sad Scout left, yellow speech bubble right (tail towards the head), the
-- group centred; no details here, they are in the settings tool.
-- Mascot chosen in the settings tool; the quad unless "scout".
local function mascot(w)
  return (w and w.mascot == "scout") and drawScout or drawQuad
end

-- Sad mascot with a speech bubble: setup error, core missing, widget error.
local function drawBubble(z, bodyH, draw, title, lines)
  draw = draw or drawQuad
  local k = math.min(bodyH / 227, z.w / 480)
  local th, sh = fontH(BOLD), fontH(SMLSIZE)
  local pad = math.floor(16 * k + 0.5)
  local bw = textW(title, BOLD)
  for _, l in ipairs(lines) do bw = math.max(bw, textW(l, SMLSIZE)) end
  bw = bw + 2 * pad
  local bh = 2 * pad + th + math.floor(6 * k + 0.5) + #lines * sh
  local sw, gap = math.floor(150 * k + 0.5), math.floor(16 * k + 0.5)
  local x0 = math.floor((z.w - sw - gap - bw) / 2)
  local my = HDR_H + math.floor((bodyH - 122 * k) / 2)
  draw(x0, my, k, getTime(), true)
  local bx = x0 + sw + gap
  local by = my + math.floor(61 * k + 0.5) - math.floor(bh / 2) - math.floor(12 * k + 0.5)
  fillRounded(bx, by, bw, bh, math.floor(14 * k + 0.5), WARN_COL)
  local ty = by + math.floor(43 * k + 0.5)   -- tail on the head's height
  local tl = math.floor(12 * k + 0.5)
  fillTri(bx - tl, ty, bx + 1, ty - math.floor(9 * k + 0.5), bx + 1, ty + math.floor(9 * k + 0.5), WARN_COL)
  dtext(bx + pad, by + pad, title, DARK_TEXT, BOLD)
  for i, l in ipairs(lines) do
    dtext(bx + pad, by + pad + th + math.floor(6 * k + 0.5) + (i - 1) * sh, l, DARK_TEXT, SMLSIZE)
  end
end

local function drawWait(ctx)
  local z = ctx.zone
  local bodyH = z.h - HDR_H
  if bodyH < 6 * fontH(SMLSIZE) then return end
  if ctx.w and ctx.w.setupError then return drawBubble(z, bodyH, mascot(ctx.w), ERR_TITLE, ERR_LINES) end
  local th, sh = fontH(BOLD), fontH(SMLSIZE)
  -- Designed for 480 x 272.
  local k = math.min(bodyH / 227, z.w / 480)
  local t = getTime()
  local gap = math.floor(10 * k + 0.5)
  local blockH = math.floor(122 * k + 0.5) + gap + th + sh
  local cx = math.floor(z.w / 2)
  local my = HDR_H + math.floor((bodyH - blockH) / 2)
  mascot(ctx.w)(cx - 75 * k, my, k, t)

  -- Title with dots counting up; left edge fixed so the text does not jump.
  local ty = my + math.floor(122 * k + 0.5) + gap
  local tx = cx - math.floor(textW(WAIT_TITLE .. "...", BOLD) / 2)
  dtext(tx, ty, WAIT_TITLE .. string.rep(".", math.floor(t / 50) % 4), COLORS.fg, BOLD)
  dtext(cx, ty + th, (ctx.w and ctx.w.waitSub) or WAIT_SUB, COLORS.muted, SMLSIZE + CENTER)

  -- While a summary is kept: the gesture to reopen it, the hold as a bar.
  local hold = ctx.w and ctx.w.reviewHold
  if hold then drawCornerBar(z, "ail: hold < last flight", hold, COLORS.accent) end
end

-- Wingman's own core missing or failing: say so instead of an empty page.
-- Without the Wingman core: the same tile text as the sibling widgets.
local function drawNoCore(ctx)
  local z = ctx.zone
  if z.h - HDR_H >= 6 * fontH(SMLSIZE) then drawBubble(z, z.h - HDR_H, nil, "Core missing", { "Reinstall", "Flight Wingman" }) end
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
local function create(zone, options)
  local ctx = { zone = zone, options = options }
  if core then
    local ok, w = pcall(core.new)
    if ok then ctx.w = w end
  end
  local gs = getGeneralSettings and getGeneralSettings()
  if gs then ctx.battMin, ctx.battMax = gs.battMin, gs.battMax end
  return ctx
end

local function update(ctx, options)
  ctx.options = options
end

-- Watchdog as on the sibling widgets: a failing tick is caught; ERROR_LIMIT in a
-- row stop the widget with "Widget error / Restart radio".
local ERROR_LIMIT = 5
local function background(ctx)
  if not ctx.w or ctx.fatalError then return end
  if pcall(core.tick, ctx.w) then
    ctx.errorStreak = 0
  else
    ctx.errorStreak = (ctx.errorStreak or 0) + 1
    if ctx.errorStreak >= ERROR_LIMIT then ctx.fatalError = true end
  end
end

local function drawFatal(ctx)
  local z = ctx.zone
  if z.h - HDR_H >= 6 * fontH(SMLSIZE) then
    drawBubble(z, z.h - HDR_H, mascot(ctx.w), "Widget error", { "Restart radio" })
  end
end

local function refresh(ctx, event, touchState)
  background(ctx)   -- background() does not run while the widget is visible
  COLORS = (ctx.options.Theme == 2) and LIGHT or DARK
  NORTH_UP = (ctx.options.Compass == 2)

  local z = ctx.zone
  if not COLORS.transparent then
    lcd.drawFilledRectangle(0, 0, z.w, z.h, COLORS.panel)
  else
    -- Light: milky overlay, Transparency 1..6 = 0..100 % see-through.
    local trans = ctx.options.Transparency
    if type(trans) ~= "number" or trans < 1 or trans > 6 then trans = 3 end
    if trans < 6 then
      lcd.drawFilledRectangle(0, 0, z.w, z.h, COLOR_THEME_PRIMARY2, 3 * (trans - 1))
    end
  end

  local w = ctx.w
  local page = (not w and drawNoCore) or (ctx.fatalError and drawFatal) or (w.setupError and drawWait) or (w and w.flight and drawFlight) or (w and w.pre and drawPre)
               or (w and w.search and drawSearch) or (w and w.post and drawPost)
               or (w and w.phase == core.WAITING and drawWait) or drawSearch
  if not pcall(drawHeader, ctx) or not pcall(page, ctx) then
    dtext(4, 4, "Widget error", COLORS.muted, SMLSIZE)
  end
end

return {
  name    = "Wingman",
  options = {
    { "Theme", CHOICE, 1, { "Dark", "Light" } },
    { "Compass", CHOICE, 1, { "NoseUp", "NorthUp" } },   -- same place as in GPS Homer
    { "Transparency", CHOICE, 3, { "0%", "20%", "40%", "60%", "80%", "100%" } },
    { "Accent", CHOICE, 1, { "Default", "Theme", "Custom" } },
    { "AccentColor", COLOR, lcd.RGB(124, 210, 48) },
  },
  create     = create,
  update     = update,
  refresh    = refresh,
  background = background,
}

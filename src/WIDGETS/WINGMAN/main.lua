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
-- Colours that get mixed by hand are kept as { r, g, b } in rgb, the lcd colour
-- is made from them.
-- ---------------------------------------------------------------------------
local function rgb(c) return lcd.RGB(c[1], c[2], c[3]) end

-- a mixed towards b by t (0..1), as an lcd colour.
local function mixRGB(a, b, t)
  local function m(i) return math.floor(a[i] + (b[i] - a[i]) * t + 0.5) end
  return lcd.RGB(m(1), m(2), m(3))
end

-- accent: titles, selection, gestures, mascot (the Accent option replaces it);
-- ok: a value that is fine (always the palette's green).
local DARK_RGB  = { panel = { 18, 20, 18 }, track = { 55, 58, 55 }, accent = { 124, 210, 48 }, ok = { 124, 210, 48 },
                    box = { 27, 30, 27 } }
local LIGHT_RGB = { track = { 200, 200, 205 }, accent = { 1, 152, 8 }, ok = { 1, 152, 8 }, box = { 200, 200, 205 } }
local DARK = {
  transparent = false,
  panel  = rgb(DARK_RGB.panel),
  fg     = lcd.RGB(235, 235, 235),
  muted  = lcd.RGB(150, 150, 150),
  track  = rgb(DARK_RGB.track),
  accent = rgb(DARK_RGB.accent),
  ok     = rgb(DARK_RGB.ok),
  rgb    = DARK_RGB,
  disk   = lcd.RGB( 22,  25,  22),   -- map background
  trail  = lcd.RGB( 60,  96,  30),   -- flight track, accent at 40 %
  box    = rgb(DARK_RGB.box),
  face   = lcd.RGB( 27,  30,  27),   -- compass dial
  halo   = lcd.RGB( 70,  26,  26),
  head   = lcd.RGB( 27,  30,  27),   -- wait page mascot
  disc   = lcd.RGB( 45,  74,  23),   -- spinning props, accent at 30 %
  swCur  = rgb(DARK_RGB.track),      -- switch page: current position
  swTile = lcd.RGB( 50,  53,  50),   -- switch page: tile behind a position's symbol
  swOnAccent = rgb(DARK_RGB.panel),  -- switch page: symbol on the accent tile
}
local LIGHT = {
  transparent = true,
  fg     = lcd.RGB(  0,   0,   0),
  muted  = lcd.RGB( 90,  90,  90),
  track  = rgb(LIGHT_RGB.track),
  accent = rgb(LIGHT_RGB.accent),
  ok     = rgb(LIGHT_RGB.ok),
  rgb    = LIGHT_RGB,
  trail  = lcd.RGB(130, 200, 120),
  box    = rgb(LIGHT_RGB.box),
  face   = lcd.RGB(235, 235, 240),   -- compass dial
  halo   = lcd.RGB(245, 190, 190),
  head   = lcd.RGB(205, 235, 190),   -- wait page mascot, light green
  eyeRing = lcd.RGB( 90,  90,  90),  -- white eyes need an outline on the light head
  disc   = lcd.RGB(195, 228, 175),   -- spinning props
  swCur  = lcd.RGB(165, 165, 172),   -- switch page: current position on the box colour
  swTile = lcd.RGB(225, 225, 230),
  swOnAccent = lcd.RGB(255, 255, 255),
}
local WARN_RGB, CRIT_RGB = { 255, 180, 0 }, { 220, 40, 40 }
local WARN_COL, CRIT_COL = rgb(WARN_RGB), rgb(CRIT_RGB)

local COLORS = DARK

-- Quad mascot: camera mount and the strap's top, shades of the accent.
DARK.tpu, DARK.strapTop = lcd.RGB(90, 160, 32), lcd.RGB(155, 224, 90)
LIGHT.tpu, LIGHT.strapTop = DARK.tpu, DARK.strapTop

-- Shades worked out from the accent when the Accent option replaces it:
-- { colour, mixed towards, share } (the fixed ones above are about the same
-- mixes of the palette green).
local WHITE_RGB, BLACK_RGB = { 255, 255, 255 }, { 0, 0, 0 }
local MASCOT_SHADES = { { "tpu", BLACK_RGB, 0.27 }, { "strapTop", WHITE_RGB, 0.25 } }
DARK.shades  = { { "trail", DARK_RGB.panel, 0.6 }, { "disc", DARK_RGB.panel, 0.7 }, table.unpack(MASCOT_SHADES) }
LIGHT.shades = { { "trail", WHITE_RGB, 0.5 }, { "disc", WHITE_RGB, 0.75 }, { "head", WHITE_RGB, 0.8 },
                 table.unpack(MASCOT_SHADES) }

-- The palette with the accent from the Accent option: 2 the EdgeTX theme's
-- focus colour, 3 the AccentColor picker (lcd.getColor turns a theme index into
-- RGB). The copy is kept until the colour changes, so drawings kept per
-- palette stay valid. Default or no colour: the palette itself.
local accented = {}
local function withAccent(base, opt, custom)
  local c
  if opt == 2 and lcd.getColor then c = lcd.getColor(COLOR_THEME_FOCUS)
  elseif opt == 3 and custom then c = lcd.getColor and lcd.getColor(custom) or custom end
  if type(c) ~= "number" then return base end
  local kept = accented[base]
  if kept and kept.c == c then return kept.pal end
  local v = (c >> 16) & 0xFFFF   -- RGB565 in the upper half
  local a = { (v & 0xF800) >> 8, (v & 0x07E0) >> 3, (v & 0x1F) << 3 }
  local pal, prgb = {}, {}
  for k, x in pairs(base) do pal[k] = x end
  for k, x in pairs(base.rgb) do prgb[k] = x end
  prgb.accent, pal.rgb, pal.accent = a, prgb, rgb(a)
  for _, sh in ipairs(base.shades) do pal[sh[1]] = mixRGB(a, sh[2], sh[3]) end
  accented[base] = { c = c, pal = pal }
  return pal
end

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

-- A stand-in for the drawing function f that appends the call to ops instead
-- ({ f, arguments... }, replayed later through table.unpack). The helpers below
-- take an optional ops to lay out once what is drawn every frame.
local function rec(ops, f) return function(...) ops[#ops + 1] = { f, ... } end end

-- Raw RGB through CUSTOM_COLOR so it never collides with size/align bits.
local function dtext(x, y, text, color, flags, ops)
  local set, draw = lcd.setColor, lcd.drawText
  if ops then set, draw = rec(ops, set), rec(ops, draw) end
  set(CUSTOM_COLOR, color)
  draw(x, y, text, CUSTOM_COLOR + (flags or 0))
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

-- Capacity and current in a shorter form from 10000 mAh / 100 A on, so they keep
-- their column width: "15.8 Ah", "123 A".
local function fmtMah(v)
  if v ~= nil and math.floor(v + 0.5) >= 10000 then return string.format("%.1f Ah", math.floor(v + 0.5) / 1000) end
  return fmt("%d mAh", v)
end
local function fmtAmps(v)
  if v ~= nil and v >= 99.95 then return fmt("%d A", v) end
  return fmt("%.1f A", v)
end

local function fillTri(x1, y1, x2, y2, x3, y3, col, ops)
  local tri = lcd.drawFilledTriangle or lcd.drawTriangle
  if tri and ops then tri = rec(ops, tri) end
  if tri then tri(x1, y1, x2, y2, x3, y3, col) end
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
    local col = (pct > 30) and COLORS.ok or ((pct > 10) and WARN_COL or CRIT_COL)
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
local HEARTBEAT_BG     = { dark = DARK_RGB.panel, light = { 255, 255, 255 } }
local HEARTBEAT_R      = math.floor(4 * UI_SCALE + 0.5)

-- floor (0..1): share of red kept at the low point (antenna tip: never gone);
-- fixed (0..1): a steady share of red instead of the pulse.
local function drawHeartbeat(cx, cy, r, floor, fixed)
  floor = floor or 0
  local t  = fixed or (floor + (1 - floor) * (0.5 - 0.5 * math.cos(2 * math.pi * (getTime() % HEARTBEAT_PERIOD) / HEARTBEAT_PERIOD)))
  local bg = COLORS.transparent and HEARTBEAT_BG.light or HEARTBEAT_BG.dark
  lcd.drawFilledCircle(cx, cy, r or HEARTBEAT_R, mixRGB(bg, CRIT_RGB, t))
end

-- No rounded rectangle in the Lua API: two overlapping bars plus four corner circles.
local function fillRounded(x, y, w, h, r, color, ops)
  local rect, circ = lcd.drawFilledRectangle, lcd.drawFilledCircle
  if ops then rect, circ = rec(ops, rect), rec(ops, circ) end
  rect(x + r, y, w - 2 * r, h, color)
  rect(x, y + r, w, h - 2 * r, color)
  local x2, y2 = x + w - r - 1, y + h - r - 1
  circ(x + r, y + r, r, color)
  circ(x2, y + r, r, color)
  circ(x + r, y2, r, color)
  circ(x2, y2, r, color)
end

-- Bar fill of width w in a track with corner radius r. Two radii or wider:
-- rounded like the track. Narrower: the track's left rounding cut off at w, one
-- 1 px column each (as if the track clipped it), straight on the right; 0 draws
-- nothing. Returns true when the right end is rounded.
local function fillBar(x, y, w, h, r, color)
  if w >= 2 * r then fillRounded(x, y, w, h, r, color); return true end
  for i = 0, w - 1 do
    local d = r - i   -- column distance from the corner circle's centre
    local inset = (d > 0) and math.floor(r - math.sqrt(r * r - d * d) + 0.5) or 0
    lcd.drawFilledRectangle(x + i, y + inset, 1, h - 2 * inset, color)
  end
  return false
end

-- Bottom right of the page (countdowns, stick holds): a bar filled to frac
-- (0..1, negative: -1..0 filled from the right) in color, txt left of it; laid
-- out for 800 x 480 like the flight page.
local CD_BAR_W = 120   -- design px
local function drawCornerBar(z, txt, frac, color)
  local kx = z.w / 800
  local k = math.min(kx, (z.h - HDR_H) / 418)
  local function sc(v) return math.max(1, math.floor(v * k + 0.5)) end
  local barW, barH = math.floor(CD_BAR_W * kx + 0.5), math.max(3, sc(6))
  local bx, by = z.w - math.floor(18 * kx + 0.5) - barW, z.h - sc(14) - barH
  fillRounded(bx, by, barW, barH, math.floor(barH / 2), COLORS.track)
  local fw = math.floor(barW * math.min(1, math.abs(frac)))
  if fw >= barH then fillRounded(frac < 0 and bx + barW - fw or bx, by, fw, barH, math.floor(barH / 2), color) end
  dtext(bx - sc(12) - textW(txt, SMLSIZE), by + math.floor((barH - fontH(SMLSIZE)) / 2), txt, COLORS.muted, SMLSIZE)
end

-- Nudge offset 0..amp px (0.6 s cosine cycle) for an arrow that asks for more
-- stick deflection.
local function nudge(amp)
  return math.floor(amp * (0.5 - 0.5 * math.cos(getTime() % 60 / 60 * 2 * math.pi)) + 0.5)
end

-- Stick gesture hint: a stick symbol whose knob follows the live sticks (o.stick
-- aileron, o.ele elevator, -1..1, accent once off the centre), a button left
-- and right of it (o.left, o.right: label or nil) that fills from the stick
-- outwards with the hold (o.hold -1..1, negative held left), its arrow nudging
-- while the gesture is armed (o.armed: the stick was back in the centre) and
-- the stick leans towards it short of the hold. Placed with the symbol centred
-- on o.cx (default the zone's middle) or its left edge at o.x, vertically
-- centred on o.cy (default the zone's bottom); o.bw and o.gap override the
-- button width and the gap beside the symbol. Design px for 800 wide.
-- Returns the hint's top.
local function drawStickHint(z, o)
  local kx = z.w / 800
  local k = math.min(kx, (z.h - HDR_H) / 418)
  local function sc(v) return math.max(1, math.floor(v * k + 0.5)) end
  local h, bw, gap, line = sc(30), o.bw or math.floor(120 * kx + 0.5), o.gap or sc(14), sc(2)
  local r = math.max(2, sc(6))
  local left, right, hold, stick, armed = o.left, o.right, o.hold or 0, o.stick or 0, o.armed
  local y = o.cy and o.cy - math.floor(h / 2) or z.h - sc(6) - h
  local ix = o.x or (o.cx or math.floor(z.w / 2)) - math.floor(h / 2)
  local cx = ix + math.floor(h / 2)
  local cy = y + math.floor(h / 2)
  -- Stick: outline, cross, knob (accent while deflected).
  fillRounded(ix, y, h, h, r, COLORS.muted)
  fillRounded(ix + line, y + line, h - 2 * line, h - 2 * line, math.max(1, r - line), COLORS.panel or COLORS.box)
  lcd.drawFilledRectangle(cx, y + sc(6), 1, h - 2 * sc(6), COLORS.track)
  lcd.drawFilledRectangle(ix + sc(6), cy, h - 2 * sc(6), 1, COLORS.track)
  local ele = o.ele or 0
  local off, offY = math.floor(sc(6) * stick + 0.5), -math.floor(sc(6) * ele + 0.5)
  local live = math.abs(stick) > 0.05 or math.abs(ele) > 0.05
  lcd.drawFilledCircle(cx + off, cy + offY, math.max(2, sc(4)), live and COLORS.accent or COLORS.muted)
  -- Buttons: border accent while held towards them, filled from the stick side.
  local ah, aw = sc(12), sc(10)
  for side = -1, 1, 2 do
    local label = right
    if side < 0 then label = left end   -- not "and/or": a missing left must stay nil
    if label then
      local bx = side < 0 and ix - gap - bw or ix + h + gap
      local frac = math.max(0, math.min(1, hold * side))
      fillRounded(bx, y, bw, h, r, frac > 0 and COLORS.accent or COLORS.track)
      fillRounded(bx + line, y + line, bw - 2 * line, h - 2 * line, math.max(1, r - line), COLORS.box)
      local fw = math.floor((bw - 2 * line) * frac)
      if fw > 0 then
        lcd.drawFilledRectangle(side < 0 and bx + bw - line - fw or bx + line, y + line, fw, h - 2 * line, COLORS.trail)
      end
      local tw = textW(label, SMLSIZE)
      local tx = bx + math.floor((bw - tw - aw - sc(8)) / 2)
      local ay = cy - math.floor(ah / 2)
      -- Stick towards the button but the hold not started: the arrow nudges
      -- outwards (0.6 s cycle) to ask for the full deflection.
      local d = 0
      if armed and stick * side > 0.05 and frac <= 0 then
        d = side * nudge(2 * sc(3))
      end
      if side < 0 then
        fillTri(tx + aw + d, ay, tx + d, cy, tx + aw + d, ay + ah, COLORS.fg)
        tx = tx + aw + sc(8)
      else
        local ax = tx + tw + sc(8) + d
        fillTri(ax, ay, ax + aw, cy, ax, ay + ah, COLORS.fg)
      end
      dtext(tx, cy, label, COLORS.fg, SMLSIZE + VCENTER)
    end
  end
  return y
end

-- Wait page menu: a column of tiles on the left (icon over the name, the name
-- alone when the tile is too low), the selected one in accent, filled from the
-- left with the hold; the stick hint with Open at the bottom. Elevator picks,
-- aileron held right opens. The tiles are laid out once as drawing calls (as
-- the switch cards) while zone, entries, selection and palette stay; per frame
-- only the hold fill and the stick hint are worked out. menuLayout gives the
-- layout (its width for the page beside it), drawMenu draws it. Design px for
-- 800 x 480.
local MENU_LABEL = { review = "Last flight", switches = "Switches", channels = "Channels" }
local function menuIcon(key, cx, cy, s, col, ops)
  local rect, circ, fcirc, line = rec(ops, lcd.drawFilledRectangle), rec(ops, lcd.drawCircle),
                                   rec(ops, lcd.drawFilledCircle), rec(ops, lcd.drawLine)
  local r = math.floor(s / 2)
  local t = math.max(1, math.floor(s / 14))
  if key == "review" then   -- clock
    for i = 0, t do circ(cx, cy, r - i, col) end
    local hl = math.floor(r * 0.6)
    rect(cx - math.floor(t / 2), cy - hl, t + 1, hl + 1, col)
    rect(cx, cy - math.floor(t / 2), math.floor(r * 0.45), t + 1, col)
  elseif key == "switches" then   -- toggle: base, lever, knob
    local bw, bh = math.floor(s * 0.7), math.max(3, math.floor(s * 0.22))
    local by = cy + r - bh
    rect(cx - math.floor(bw / 2), by, bw, bh, col)
    local kr = math.max(2, math.floor(s * 0.14))
    local kx, ky = cx - math.floor(s * 0.22), cy - r + kr
    for i = -t, t do line(cx + i, by, kx + i, ky, SOLID, col) end
    fcirc(kx, ky, kr, col)
  else   -- channels: bars up and down from a centre line
    local bw = math.max(2, math.floor(s / 7))
    local g = math.max(1, math.floor(bw * 0.6))
    local x = cx - math.floor((4 * bw + 3 * g) / 2)
    rect(cx - r, cy, s, 1, COLORS.muted)
    for i, f in ipairs({ -0.9, 0.6, -0.5, 0.35 }) do
      local bh = math.max(1, math.floor(r * math.abs(f)))
      rect(x + (i - 1) * (bw + g), f < 0 and cy - bh or cy + 1, bw, bh, col)
    end
  end
end

local menuLay
-- The column's inner width from all entries, so the page beside it stays put
-- when an entry or the whole menu is not offered.
local function menuInner(z, k, sc)
  local lw = 0
  for _, label in pairs(MENU_LABEL) do lw = math.max(lw, textW(label, SMLSIZE)) end
  return math.max(lw + sc(16), sc(30) + sc(8) + textW("Open", SMLSIZE) + sc(48), math.floor(86 * k + 0.5))
end

-- Width of the column and its line: kept free on the wait page also without a menu.
local function menuWidth(z)
  local k = math.min(z.w / 800, (z.h - HDR_H) / 418)
  local function sc(v) return math.max(1, math.floor(v * k + 0.5)) end
  return menuInner(z, k, sc) + 2 * sc(12) + sc(2)
end

local function layoutMenu(z, hint, key)
  local k = math.min(z.w / 800, (z.h - HDR_H) / 418)
  local function sc(v) return math.max(1, math.floor(v * k + 0.5)) end
  local pad, gap, line, hgap = sc(12), sc(10), sc(2), sc(8)
  local bw = textW("Open", SMLSIZE) + sc(48)
  local inner = menuInner(z, k, sc)
  local lay = { key = key, colors = COLORS, pad = pad, bw = bw, hgap = hgap, width = inner + 2 * pad + line,
                bg = {}, fg = {} }
  local bg, fg = lay.bg, lay.fg
  rec(bg, lcd.drawFilledRectangle)(inner + 2 * pad, HDR_H, line, z.h - HDR_H, COLORS.track)
  local n = #hint.items
  -- room for a triangle above and below the entries (as on the pack selection)
  local triW, triH, triGap = sc(12), sc(7), sc(3)
  local top = HDR_H + pad + triH + triGap
  local hintY = z.h - sc(6) - sc(30)   -- the stick hint's top (drawStickHint)
  local th = math.min(math.floor(86 * k + 0.5),
                      math.floor((hintY - pad - triH - triGap - top - (n - 1) * gap) / n))
  local fh, is = fontH(SMLSIZE), sc(34)
  local icon = th >= fh + is + sc(18)
  local r = math.max(2, sc(8))
  local cx = pad + math.floor(inner / 2)
  lay.tri = { cx = cx, w = triW, h = triH, up = HDR_H + pad, down = top + n * th + (n - 1) * gap + triGap,
              amp = math.min(sc(3), pad - 1), sel = hint.sel, n = n }
  for i, item in ipairs(hint.items) do
    local y = top + (i - 1) * (th + gap)
    local sel = i == hint.sel
    local col = sel and COLORS.accent or COLORS.fg
    fillRounded(pad, y, inner, th, r, sel and COLORS.accent or COLORS.track, bg)
    fillRounded(pad + line, y + line, inner - 2 * line, th - 2 * line, math.max(1, r - line), COLORS.box, bg)
    if sel then lay.fill = { pad + line, y + line, inner - 2 * line, th - 2 * line } end
    if icon then
      local cy = y + math.floor((th - is - sc(6) - fh) / 2)
      menuIcon(item, cx, cy + math.floor(is / 2), is, col, fg)
      dtext(cx, cy + is + sc(6), MENU_LABEL[item], col, SMLSIZE + CENTER, fg)
    else
      dtext(cx, y + math.floor(th / 2), MENU_LABEL[item], col, SMLSIZE + CENTER + VCENTER, fg)
    end
  end
  return lay
end

local function menuLayout(z, hint)
  local key = z.w .. "|" .. z.h .. "|" .. table.concat(hint.items, ",") .. "|" .. hint.sel
  local lay = menuLay
  if not lay or lay.key ~= key or lay.colors ~= COLORS then
    lay = layoutMenu(z, hint, key)
    menuLay = lay
  end
  return lay
end

local function drawMenu(z, w, lay)
  local unpack = table.unpack
  for _, o in ipairs(lay.bg) do o[1](unpack(o, 2)) end
  local f = lay.fill
  local fw = f and math.floor(f[3] * math.max(0, math.min(1, w.waitHold or 0))) or 0
  if fw > 0 then lcd.drawFilledRectangle(f[1], f[2], fw, f[4], COLORS.trail) end
  for _, o in ipairs(lay.fg) do o[1](unpack(o, 2)) end
  -- A triangle above and below while the selection can move that way: accent
  -- while the elevator leans that way, nudging until the step counts.
  local t = lay.tri
  local hw = math.floor(t.w / 2)
  for dir = -1, 1, 2 do   -- -1 up, 1 down
    if dir < 0 and t.sel > 1 or dir > 0 and t.sel < t.n then
      local lean = -dir * (w.stickEle or 0) > 0.05   -- elevator up (positive) moves the selection up
      local d = (lean and w.eleArmed) and dir * nudge(t.amp) or 0
      local col = lean and COLORS.accent or COLORS.muted
      if dir < 0 then
        local ty = t.up + d
        fillTri(t.cx - hw, ty + t.h, t.cx + hw, ty + t.h, t.cx, ty, col)
      else
        local ty = t.down + d
        fillTri(t.cx - hw, ty, t.cx + hw, ty, t.cx, ty + t.h, col)
      end
    end
  end
  drawStickHint(z, { right = "Open", x = lay.pad, bw = lay.bw, gap = lay.hgap, hold = w.waitHold,
                     stick = w.stick, ele = w.stickEle, armed = w.closeArmed })
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
-- Display units after the radio's setting (GPS Homer reads it). Altitude, speed and
-- vertical speed come in the sensor units set on the radio, so only their labels
-- change; distances are computed in metres and scaled by f. Rings in display units,
-- from ringBig all three labelled in the big unit (half a mile: 0.5, 1, 1.5 mi).
local UNITS = {
  metric   = { f = 1, len = "m", spd = "km/h", big = 1000, bigU = "km", vsFull = 5, ringBig = 1000,
               rings = { 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000, 50000 } },
  imperial = { f = 3.28084, len = "ft", spd = "mph", big = 5280, bigU = "mi", vsFull = 15, ringBig = 2640,
               rings = { 50, 100, 200, 500, 1000, 2640, 5280, 10560, 26400, 52800, 105600, 264000 } },
}
local U = UNITS.metric   -- set per refresh
local QR_DARK    = lcd.RGB(18, 20, 18)
local QR_QUIET   = 2      -- white modules around the code
local UNIT_DROP  = 0.12   -- unit text sits this share of the number height above its box bottom

-- Ring spacing in display units: three rings hold everything with 10 % margin.
local function ringStep(maxD)
  for _, s in ipairs(U.rings) do
    if 3 * s >= maxD * 1.1 then return s end
  end
  return U.rings[#U.rings]
end

-- Metres as display text: m or ft, from 1 km or 1 mi (after rounding) in those with one decimal.
local function fmtDist(m)
  local d = math.floor(m * U.f + 0.5)
  if d < U.big then return string.format("%d", d), U.len end
  return string.format("%.1f", m * U.f / U.big), U.bigU
end
local function distText(m)
  if not m then return "--" end
  local v, u = fmtDist(m)
  return v .. " " .. u
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

  local step = ringStep(v.maxM * U.f)
  local k = R / (3 * step) * U.f   -- px per metre
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
    local d = step * i
    local label = (d >= U.big or step >= U.ringBig) and string.format("%g %s", d / U.big, U.bigU) or string.format("%d %s", d, U.len)
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

  -- Track inlined and without zero-length segments: up to 50 points per call.
  local trail, line, floor = COLORS.trail, lcd.drawLine, math.floor
  local px, py
  for _, p in ipairs(v.track) do
    local x, y = floor(cx + p[2] * k + 0.5), floor(cy - p[1] * k + 0.5)
    if px and (x ~= px or y ~= py) then
      line(px, py, x, y, SOLID, trail)
      line(px + 1, py, x + 1, y, SOLID, trail)
    end
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
-- Battery and link bar, 34 px high; style from the settings tool: "solid",
-- "segments" (N blocks, unlit blocks in a threshold zone in its colour mixed into
-- the track by ZONE_TRACK) or "zones" (thinner bar, a zone strip and a pointer).
local BAR = { TOP = 170, BOTTOM = 204, N = 20, ZONE_TRACK = 0.8, style = "solid" }

-- Draws the bar in a style other than Solid and returns true; false for Solid,
-- which the caller draws. inner: side of a vertical bar facing the page (1 right,
-- -1 left); the other arguments as BAR.drawSegments.
function BAR.drawStyled(L, x, y, w, h, vertical, inner, pct, solid, col, resCol, marks, high)
  if BAR.style == "segments" then
    BAR.drawSegments(x, y, w, h, vertical, L.s(3), pct, solid, col, resCol, marks, high)
  elseif BAR.style == "zones" then
    BAR.drawZones(L, x, y, w, h, vertical, inner, pct, solid, col, resCol, marks, high)
  else
    return false
  end
  return true
end

-- Zones style: the bar (lightened end from solid % on) and beside it, towards the
-- page, a strip with each mark's zone in full colour and a pointer at pct.
function BAR.drawZones(L, x, y, w, h, vertical, inner, pct, solid, col, resCol, marks, high)
  local st, g, r = math.max(2, L.s(6)), math.max(1, L.s(4)), L.s(4)
  local len = vertical and h or w
  local bt = (vertical and w or h) - st - g   -- bar thickness
  local fl = math.floor(len * math.max(0, math.min(100, pct or 0)) / 100)
  local sl = math.min(fl, math.floor(len * math.max(0, math.min(100, solid)) / 100))
  local sx, sy, sw, sh = x, y + bt + g, w, st   -- strip
  if vertical then
    local bx = (inner < 0) and x + st + g or x
    sx, sy, sw, sh = (inner < 0) and x or x + bt + g, y, st, h
    fillRounded(bx, y, bt, h, r, COLORS.track)
    for i = (fl > sl) and 1 or 2, 2 do
      local l, c = (i == 1) and fl or sl, (i == 1) and resCol or col
      if l >= 2 * r then fillRounded(bx, y + h - l, bt, l, r, c)
      elseif l > 0 then lcd.drawFilledRectangle(bx + r, y + h - l, bt - 2 * r, l, c) end
    end
  else
    fillRounded(x, y, w, bt, r, COLORS.track)
    if fl > sl then fillBar(x, y, fl, bt, r, resCol) end
    if sl > 0 and fillBar(x, y, sl, bt, r, col) and fl > sl then lcd.drawFilledRectangle(x + sl - r, y, r, bt, col) end
  end
  -- A mark's zone runs to the next mark (low: from below it to it, high: from it up).
  local sr = math.floor((st - 1) / 2)   -- strip ends rounded, zones squared where they meet
  fillRounded(sx, sy, sw, sh, sr, COLORS.track)
  for _, m in ipairs(marks) do
    local p = m[1]
    if p then
      local a, b = high and p or 0, high and 100 or p
      for _, o in ipairs(marks) do
        local q = o[1]
        if q and high and q > p and q < b then b = q end
        if q and not high and q < p and q > a then a = q end
      end
      local pa, pb, c = math.floor(len * a / 100), math.floor(len * math.min(100, b) / 100), rgb(m[2])
      if pb - pa < 2 * sr then
        if vertical then lcd.drawFilledRectangle(sx, sy + h - pb, sw, pb - pa, c)
        else lcd.drawFilledRectangle(sx + pa, sy, pb - pa, sh, c) end
      elseif vertical then
        local zy = sy + h - pb
        fillRounded(sx, zy, sw, pb - pa, sr, c)
        if pb < len then lcd.drawFilledRectangle(sx, zy, sw, sr, c) end
        if pa > 0 then lcd.drawFilledRectangle(sx, zy + pb - pa - sr, sw, sr, c) end
      else
        fillRounded(sx + pa, sy, pb - pa, sh, sr, c)
        if pa > 0 then lcd.drawFilledRectangle(sx + pa, sy, sr, sh, c) end
        if pb < len then lcd.drawFilledRectangle(sx + pb - sr, sy, sr, sh, c) end
      end
    end
  end
  if not pct then return end
  local tri, ps, pd, pg = lcd.drawFilledTriangle or lcd.drawTriangle, math.max(3, L.s(6)), math.max(4, L.s(8)), L.s(2)
  if vertical then
    local py, tx = y + h - fl, (inner < 0) and sx - pg or sx + sw + pg
    local bx = (inner < 0) and tx - pd or tx + pd
    tri(tx, py, bx, py - ps, bx, py + ps, COLORS.fg)
  else
    local px, ty = x + fl, sy + sh + pg
    tri(px, ty, px - ps, ty + pd, px + ps, ty + pd, COLORS.fg)
  end
end

-- Segmented bar over x, y, w, h (vertical: filled from the bottom), gap px between
-- blocks: lit up to pct in col, from solid % on in resCol (the lightened end; 100: none).
-- marks { pct, rgb }: an unlit block whose middle is below a mark (above with high)
-- takes the nearest such mark's zone colour.
function BAR.drawSegments(x, y, w, h, vertical, gap, pct, solid, col, resCol, marks, high)
  local len, n = vertical and h or w, BAR.N
  local step = 100 / n
  for i = 0, n - 1 do
    local a = math.floor(i * (len + gap) / n)
    local b = math.floor((i + 1) * (len + gap) / n) - gap
    local lo, c = i * step, COLORS.track
    if (pct or 0) > lo then
      c = (lo >= solid) and resCol or col
    else
      local mid, zone, best = lo + step / 2, nil, nil
      for _, m in ipairs(marks) do
        local p = m[1]
        if p and ((high and mid >= p) or (not high and mid < p))
           and (not best or (high and p > best) or (not high and p < best)) then zone, best = m[2], p end
      end
      if zone then c = mixRGB(zone, COLORS.rgb.track, BAR.ZONE_TRACK) end
    end
    if vertical then lcd.drawFilledRectangle(x, y + h - b, w, b - a, c)
    else lcd.drawFilledRectangle(x + a, y, b - a, h, c) end
  end
end
local FONTS_LRG = { hero = DBLSIZE, unit = MIDSIZE, cap = SMLSIZE, label = TINSIZE or SMLSIZE,
                    value = 0, side = MIDSIZE, title = SMLSIZE, stage = BOLD, ready = DBLSIZE }
local FONTS_STD = { hero = DBLSIZE, unit = 0, cap = SMLSIZE, label = TINSIZE or SMLSIZE,
                    value = SMLSIZE, side = 0, title = SMLSIZE, stage = SMLSIZE, ready = MIDSIZE }
local STAGE_COL = { [1] = WARN_COL, [2] = CRIT_COL }
-- Colour from a core's level (0 ok, 1 warning, 2 critical): big values and
-- status green, yellow or red; small values text colour, yellow or red.
local function levelCol(lvl) return (lvl == nil) and COLORS.fg or STAGE_COL[lvl] or COLORS.ok end   -- no level: neutral
local function smallCol(lvl) return STAGE_COL[lvl] or COLORS.fg end

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

-- Speaker glyph h px high, left edge x, centred on cy; accent while lit (a finder beep),
-- struck through when muted. The sizes per h are kept (the switch page draws many).
local drawSpeaker
do
  local geo = {}
  function drawSpeaker(x, cy, h, lit, muted, ops)
    local col = lit and COLORS.accent or COLORS.muted
    local rect = ops and rec(ops, lcd.drawFilledRectangle) or lcd.drawFilledRectangle
    local g = geo[h]
    if not g then
      g = { math.max(2, math.floor(h * 0.25)), math.max(2, math.floor(h * 0.2)), math.max(3, math.floor(h * 0.45)), math.floor(h * 0.45) }
      geo[h] = g
    end
    local bw, bt, cw, ch = g[1], g[2], g[3], g[4]
    rect(x, cy - bt, bw, 2 * bt, col)
    fillTri(x + bw, cy - bt, x + bw + cw, cy - ch, x + bw + cw, cy + ch, col, ops)
    fillTri(x + bw, cy - bt, x + bw + cw, cy + ch, x + bw, cy + bt, col, ops)
    if muted then thickLine(x - 1, cy + ch, x + bw + cw, cy - ch, COLORS.fg) end
  end
end

-- Finder strength 0..1 as 20 segments over w.
local FINDER_SEGS = 20
local function drawSegBar(x, y, w, h, frac)
  local gap = math.max(1, math.floor(h / 2))
  local seg = (w - (FINDER_SEGS - 1) * gap) / FINDER_SEGS
  local n = math.floor(frac * FINDER_SEGS + 0.5)
  for i = 0, FINDER_SEGS - 1 do
    local sx = x + math.floor(i * (seg + gap))
    lcd.drawFilledRectangle(sx, y, math.max(1, math.floor(seg)), h, i < n and COLORS.accent or COLORS.track)
  end
end

-- Search page (right panel and the page itself); after flightLayout for the title.
local function drawSearchInfo(ctx, v, x0, y0, pw, ph, pad)
  local p = 2 * pad
  local x, y, right, bottom = x0 + p, y0 + p, x0 + pw - p, y0 + ph - p
  local fh = fontH(SMLSIZE)

  -- Bottom row, always reserved: the two aileron holds (mute left, close right).
  local top = drawStickHint(ctx.zone, { left = ctx.w.finderMuted and "Sound on" or "Mute", right = "Close",
                            hold = ctx.w.searchHold, stick = ctx.w.stick, armed = ctx.w.closeArmed, cx = x0 + math.floor(pw / 2) })
  bottom = math.min(bottom - fh, top) - p

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
  -- 800 px: DBLSIZE distance, MIDSIZE unit and direction; smaller screens one step
  -- below each, so the signal line still fits above the QR code
  local wide = ctx.zone.w >= 700
  local big, dirF = wide and DBLSIZE or MIDSIZE, wide and MIDSIZE or 0
  local bh, dh = fontH(big), fontH(dirF)
  -- Signal, altitude and sats as one line with the finder bar below; where that
  -- would leave too little room for the QR code, only the signal as a column
  -- beside the distance.
  local barH = math.max(3, math.floor(fh / 4))
  local lineMode = bottom - (y + fh + bh + p + fh + p + barH + p) >= 3 * 33
  -- Finder signal in dBm; without it the radio's link value in %.
  local sigNum = v.signal and tostring(v.signal) or ((v.live and ctx.w.rssi) and string.format("%d%%", ctx.w.rssi) or "--")
  local sigUnit = v.signal and "dBm" or ""
  -- speaker lit 150 ms after a beep, at most half the gap so fast beeps still blink
  local lit = not v.muted and v.beepAt and getTime() - v.beepAt < math.min(15, (v.beepGap or 30) / 2)

  dtext(x, y, "FROM HOME", COLORS.muted, SMLSIZE)
  local num, unit = fmtDist(v.distM)
  local deg = string.format("%d\194\176", math.floor(v.bearing + 0.5) % 360)
  local sec = v.sector .. " "
  local cr = math.floor(dh / 2)
  local dx = right - textW(deg, dirF) - textW(sec, dirF)
  local gx = dx - pad - cr
  if not lineMode then
    -- centred in the gap between the distance and the direction; left out when
    -- a long distance and direction leave no room
    local left = math.max(x + textW("FROM HOME", SMLSIZE), x + textW(num, big) + pad + textW(unit, dirF)) + p
    local room = gx - cr - p - left
    local function colW(f) return math.max(textW("SIGNAL", SMLSIZE) + pad + fh, textW(sigNum, f) + pad + textW(sigUnit, dirF)) end
    local nf = (colW(big) <= room) and big or dirF
    if colW(nf) <= room then
      local cx = left + math.floor((room - colW(nf)) / 2)
      dtext(cx, y, "SIGNAL", COLORS.muted, SMLSIZE)
      if v.signal then drawSpeaker(cx + textW("SIGNAL", SMLSIZE) + pad, y + math.floor(fh / 2), fh, lit, v.muted) end
      local ny = y + fh + math.floor((bh - fontH(nf)) / 2)
      dtext(cx, ny, sigNum, v.live and COLORS.fg or COLORS.muted, nf)
      if sigUnit ~= "" then
        dtext(cx + textW(sigNum, nf) + pad, ny + fontH(nf) - dh - math.floor(fontH(nf) * UNIT_DROP), sigUnit, COLORS.muted, dirF)
      end
    end
  end
  y = y + fh
  dtext(x, y, num, COLORS.fg, big)
  dtext(x + textW(num, big) + pad, y + bh - dh - math.floor(bh * UNIT_DROP), unit, COLORS.muted, dirF)
  local dy = y + math.floor((bh - dh) / 2)
  dtext(dx, dy, sec, COLORS.fg, dirF)
  dtext(dx + textW(sec, dirF), dy, deg, COLORS.muted, dirF)
  lcd.drawCircle(gx, dy + cr, cr, COLORS.track)
  drawArrow(gx, dy + cr, cr - 2, v.bearing, v.live and COLORS.ok or COLORS.muted)
  y = y + bh + p

  -- Without link the line and bar mean nothing: left out, their room kept so
  -- the QR code keeps its size.
  if lineMode and v.live then
    -- the three pairs spread evenly over the width
    local cells = {
      { "SIGNAL ", v.signal and (sigNum .. " dBm") or sigNum },
      { "ALT ", fmt("%d " .. U.len, v.alt) },
      { "SATS ", v.sats and tostring(v.sats) or "--", smallCol(v.satsLevel) },
    }
    local used = 0
    for _, c in ipairs(cells) do used = used + textW(c[1], SMLSIZE) + textW(c[2], SMLSIZE) end
    local spread = math.max(pad, math.floor((right - x - used) / 2))
    local cx = x
    for _, c in ipairs(cells) do
      dtext(cx, y, c[1], COLORS.muted, SMLSIZE)
      cx = cx + textW(c[1], SMLSIZE)
      dtext(cx, y, c[2], c[3] or COLORS.fg, SMLSIZE)
      cx = cx + textW(c[2], SMLSIZE) + spread
    end
    y = y + fh + p
    -- finder bar over the width, the speaker at its right end
    local spW = v.signal and fh or 0
    drawSegBar(x, y, right - x - spW, barH, v.strength or 0)
    if v.signal then drawSpeaker(right - math.floor(fh * 0.8), y + math.floor(barH / 2), fh, lit, v.muted) end
    y = y + barH + p
  elseif lineMode then
    y = y + fh + p + barH + p
  end

  -- QR code bottom left, position text beside it.
  local qr = v.qr
  local textBlockW = textW("LON ", SMLSIZE) + textW("00.000000", SMLSIZE)
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
  -- POSITION with live (or the age) beside it, then latitude and longitude with
  -- LAT / LON labels, the values on one edge
  local hx = x + textW("POSITION ", SMLSIZE)
  dtext(x, y, "POSITION ", COLORS.muted, SMLSIZE)
  if v.live then
    dtext(hx, y, "live", COLORS.ok, SMLSIZE)
  else   -- the age goes below the position when it does not fit beside the heading
    local age = fmtAge(v.ageS or 0)
    if hx + textW(age, SMLSIZE) <= right then dtext(hx, y, age, WARN_COL, SMLSIZE)
    else dtext(x, y + 3 * fh, age, WARN_COL, SMLSIZE) end
  end
  local vx = x + math.max(textW("LAT ", SMLSIZE), textW("LON ", SMLSIZE))
  dtext(x, y + fh, "LAT ", COLORS.muted, SMLSIZE)
  dtext(vx, y + fh, string.format("%.5f", v.lat), COLORS.fg, SMLSIZE)
  dtext(x, y + 2 * fh, "LON ", COLORS.muted, SMLSIZE)
  dtext(vx, y + 2 * fh, string.format("%.5f", v.lon), COLORS.fg, SMLSIZE)
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
-- Satellite bars on the big value's baseline: one per GPS-core threshold
-- (satsBarsMax, 5 without it), 8 to 32 design px high, filled up to satsBars.
local function satBarsW(g, bw, bg) return (g.satsBarsMax or 5) * (bw + bg) - bg end
local function drawSatBars(L, x, g, bw, bg, col)
  local n = g.satsBarsMax or 5
  for i = 1, n do
    local hh = L.s(8 + math.floor(24 * (i - 1) / math.max(n - 1, 1) + 0.5))
    lcd.drawFilledRectangle(x + (i - 1) * (bw + bg), L.y(HERO_Y) - hh, bw, hh, (i <= (g.satsBars or 0)) and col or COLORS.track)
  end
end
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
-- draw (optional) draws value itself: draw(L, x, baseline y, value).
local function drawCell(L, x, row0, label, value, col, draw)
  btext(x, L.y(row0 + 10), label, COLORS.muted, L.f.label)
  if draw then draw(L, x, L.y(row0 + 36), value) return end
  btext(x, L.y(row0 + 36), value, col or COLORS.fg, L.f.value)
end

-- RSSI of both antennas, the inactive one grey. One value without a second antenna.
local function drawRssi(L, x, y, l)
  local col = smallCol(l.rssiLevel)
  if not l.rss2 then btext(x, y, fmt("%d", l.rssi), col, L.f.value) return end
  for i, v in ipairs({ l.rss1, l.rss2 }) do
    local text = fmt("%d", v)
    btext(x, y, text, (l.ant and l.ant ~= i) and COLORS.muted or col, L.f.value)
    x = x + textW(text, L.f.value)
    if i == 1 then btext(x, y, " / ", COLORS.fg, L.f.value); x = x + textW(" / ", L.f.value) end
  end
end

-- Rows on a 57 px pitch from y 249, so the battery's third row lines up with
-- the GPS row at the bottom (363) and the link starts with the battery.
local GRID_TOP, GRID_PITCH = 249, 57

local function drawGrid(L, x, w, cells)
  local half = math.floor(w / 2)
  for i, c in ipairs(cells) do
    local row = math.floor((i - 1) / 2)
    drawCell(L, x + ((i - 1) % 2) * half, GRID_TOP + GRID_PITCH * row, c[1], c[2], c[3], c[4])
  end
end

-- Bar filled to pct with threshold marks { pct, rgb } (below them is worse); by
-- (optional) its top in px.
local function drawBar(L, x, w, pct, col, marks, by)
  local bh, r = L.y(BAR.BOTTOM) - L.y(BAR.TOP), L.s(4)
  by = by or L.y(BAR.TOP)
  if BAR.drawStyled(L, x, by, w, bh, false, 1, pct, 100, col, col, marks) then return end
  fillRounded(x, by, w, bh, r, COLORS.track)
  local fw = math.floor(w * math.max(0, math.min(100, pct or 0)) / 100)
  fillBar(x, by, fw, bh, r, col)
  local t = L.s(4)
  for _, m in ipairs(marks) do
    lcd.drawFilledRectangle(x + math.floor(w * m[1] / 100), by - t, L.s(3), bh + 2 * t, rgb(m[2]))
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

-- Stage field (OK green, WARNING yellow, CRITICAL red) with its top at design y;
-- left-aligned at x, or right-aligned at x when right.
local STAGE_FIELD_Y = 108   -- compass page: under the side value, right-aligned
local function drawStage(L, x, right, stage, y)
  local word = (stage == 2 and "CRITICAL") or (stage == 1 and "WARNING") or "OK"
  local f, pad = L.f.stage, L.s(8)
  local ww, wh = textW(word, f) + 2 * pad, fontH(f)
  local wx, wy = right and x - ww or x, L.y(y)
  fillRounded(wx, wy, ww, wh, L.s(4), STAGE_COL[stage] or COLORS.ok)
  dtext(wx + pad, wy, word, (stage == 2) and WHITE or DARK_TEXT, f)
end

local function drawBattery(L, x, w, b, sideLabel, sideValue, sideCol)
  local right = x + w
  local stage = b.level or 0
  local col = levelCol(stage)
  local hot = smallCol(b.vLevel)   -- per-cell voltage against the chemistry
  drawTitle(L, x, packTitle(L, w, b.name, b.nameShort))
  drawHero(L, x, right, fmt("%d", b.pct), "%", col, "REMAINING",
           sideValue and sideLabel, sideValue, sideCol)
  if b.pct then drawStage(L, right, true, stage, STAGE_FIELD_Y) end
  drawBar(L, x, w, b.pct, col, { { b.warn, WARN_RGB }, { b.crit, CRIT_RGB } })
  drawGrid(L, x, w, {
    { "PACK", fmt("%.1f V", b.volt), hot },
    { "PER CELL", fmt("%.2f V", b.cell), hot },
    { "LEFT", fmtMah(b.left), smallCol(b.level) },
    { "USED", fmtMah(b.used) },
    { "CURRENT", fmtAmps(b.amps) },   -- capacity is in the title
  })
end

-- Warning sign: triangle h px high centred on cx from top, "!" in inner.
local function drawWarnSign(cx, top, h, col, inner)
  local hw = math.floor(h * 0.6)
  fillTri(cx - hw, top + h, cx + hw, top + h, cx, top, col)
  local bw = math.max(2, math.floor(h * 0.12))
  lcd.drawFilledRectangle(cx - math.floor(bw / 2), top + math.floor(h * 0.35), bw, math.floor(h * 0.33), inner)
  lcd.drawFilledRectangle(cx - math.floor(bw / 2), top + math.floor(h * 0.76), bw, bw, inner)
end

-- Battery column while armed without a chosen pack: no % and no warnings, so
-- a yellow notice instead of an empty column.
local function drawNoPack(L, x, w)
  local s, cx = L.s(11), x + math.floor(w / 2)
  lcd.drawFilledRectangle(x, L.y(21), s, s, WARN_COL)
  btext(x + s + L.s(8), L.y(31), "NO PACK", WARN_COL, L.f.title)
  drawWarnSign(cx, L.y(80), L.s(80), WARN_COL, DARK_TEXT)
  local f = MIDSIZE
  if textW("NO BATTERY", f) > w then f = L.f.value end
  for i, t in ipairs({ "NO BATTERY", "SELECTED" }) do
    btext(cx - math.floor(textW(t, f) / 2), L.y(225 + (i - 1) * 40), t, WARN_COL, f)
  end
  -- one line, or two where the column is narrow (horizon page)
  local fv = L.f.value
  local lines = (textW("No battery warnings", fv) <= w) and { "No battery warnings" } or { "No battery", "warnings" }
  for i, t in ipairs(lines) do
    btext(cx - math.floor(textW(t, fv) / 2), L.y(315 + (i - 1) * 32), t, COLORS.fg, fv)
  end
end

-- TX power label with the link core's DYN / MAX tag (dynamic power below the
-- maximum / at it or fixed); none while the module did not answer.
local function txLabel(l)
  return l.pwrTag and ("TX POWER (" .. l.pwrTag .. ")") or "TX POWER"
end

-- Lightened end of the range bar: the stage colour mixed with the track, drawn
-- opaque so it can have round corners (translucent circles would overlap).
local RESERVE_TRACK = 0.6   -- share of the track in the mix
local STAGE_RGB = { [1] = WARN_RGB, [2] = CRIT_RGB }
local function reserveColor(stage)
  return mixRGB(STAGE_RGB[stage] or COLORS.rgb.ok, COLORS.rgb.track, RESERVE_TRACK)
end

local function drawLink(L, x, w, l, linkUp)
  local right = x + w
  local col = STAGE_COL[l.stage] or COLORS.ok
  drawTitle(L, x, l.modLine)
  -- Heartbeat top right, centred on the title square, while packets arrive.
  if linkUp then drawHeartbeat(right - HEARTBEAT_R, L.y(21) + math.floor(L.s(11) / 2)) end
  -- A mode without a sensitivity limit is a warning in the link core (as in
  -- link-sentinel's widget): "--" in the stage colour and a full bar.
  local unknown = l.sensLimit == 0
  local modeCap, modeVal = modeParts(l.mode)
  drawHero(L, x, right, fmt("%d", l.range), "%", col, "RANGELIMIT", modeCap, modeVal, nil, unknown)

  -- Range bar: fills towards the limit. With dynamic TX
  -- power below the maximum the end the bar would lose at full power is lightened.
  local by, bh, r = L.y(BAR.TOP), L.y(BAR.BOTTOM) - L.y(BAR.TOP), L.s(4)
  local pct = unknown and 100 or math.max(0, math.min(100, l.range or 0))
  local solid = (l.reserve and not unknown) and math.max(0, pct - l.reserve) or pct
  -- zone above the stage 1 limit
  if not BAR.drawStyled(L, x, by, w, bh, false, 1, pct, solid, col, reserveColor(l.stage),
                        { { not unknown and l.warn, WARN_RGB } }, true) then
    fillRounded(x, by, w, bh, r, COLORS.track)
    local fw, sw = math.floor(w * pct / 100), math.floor(w * solid / 100)
    -- lightened end under the solid part, which is squared off where it ends
    if fw > sw then fillBar(x, by, fw, bh, r, reserveColor(l.stage)) end
    if sw > 0 then
      if fillBar(x, by, sw, bh, r, col) and fw > sw then lcd.drawFilledRectangle(x + sw - r, by, r, bh, col) end
    end
    if l.warn and not unknown then   -- stage 1 mark as on the battery bar
      local t = L.s(4)
      lcd.drawFilledRectangle(x + math.floor(w * l.warn / 100), by - t, L.s(3), bh + 2 * t, WARN_COL)
    end
  end
  drawStage(L, right, true, l.stage, STAGE_FIELD_Y)

  drawGrid(L, x, w, {
    { "LQ", fmt("%d %%", l.lq), smallCol(l.lqStage) },
    { "RSSI dBm", l, nil, drawRssi },
    { "RSNR", fmt("%d dB", l.rsnr) },
    { txLabel(l), fmt("%d mW", l.tpwr) },
  })
end

-- Compass from GPS Homer's compass.lua (the same drawing on both widgets):
-- Nose up or North up by the Compass option; none without the file.
local NORTH_UP = false
-- kind from compass.label: "ring" (before home), "house" (on the home point) or
-- "arrow"; course and rel smoothed like on GPS Homer.
local function compassR(L) return math.floor(70 * L.k * 0.8 + 0.5) end   -- design: 200 unit compass drawn at 160 px
local function drawCompass(L, cx, cy, g, kind, course, rel)
  local R = compassR(L)
  local col = { track = COLORS.track, fg = COLORS.fg, muted = COLORS.muted, face = COLORS.face }
  if kind ~= "arrow" then
    compass.ring(cx, cy, R, NORTH_UP and 0 or -(course or 0), nil, false, NORTH_UP, col)
    if kind == "house" then compass.house(cx, cy, math.floor(R * 0.55), COLORS.fg, COLORS.track) end
    return
  end
  compass.draw(cx, cy, R, { course = course, rel = rel, bearing = g.bearing }, NORTH_UP, false, col)
end

-- Satellites as the big value, the bars on the right (stages as GPS Homer).
local function drawSats(L, x, right, g)
  local satCol = levelCol(g.satsLevel)
  drawHero(L, x, right, fmt("%d", g.sats), nil, satCol, "SATS")
  local bw, bg = L.s(8), L.s(3)
  drawSatBars(L, right - satBarsW(g, bw, bg), g, bw, bg, satCol)
end

local function drawGps(L, x, w, g, alert, ctx)
  local right = x + w
  drawTitle(L, x, "GPS")
  drawSats(L, x, right, g)

  -- Compass and the line under it as on GPS Homer (shared compass.lua): what to
  -- show and the text; course and rel smoothed per widget.
  if compass then
    local sm = ctx.smooth or {}
    ctx.smooth = sm
    sm.course = compass.smooth(sm.course, g.course)
    sm.rel    = compass.smooth(sm.rel, g.rel)
    local kind, lb = compass.label({ gpsState = g.gpsState, noHome = g.noHome, atHome = g.atHome, alert = alert,
                                     courseValid = g.courseValid, estimated = g.estimated, rel = sm.rel,
                                     sector = g.sector, bearing = g.bearing },
                                   { ahead = g.ahead or 15, behind = g.behind or 165 })
    -- the letters keep their size on small screens: the line moves down to stay clear of the S
    local cx, cy = x + math.floor(w / 2), L.y(208)
    local sBottom = cy + compass.letterRadius(compassR(L)) + math.ceil(fontH(SMLSIZE) / 2)
    local base = math.max(L.y(308), sBottom + math.max(3, L.s(6)) + math.floor(fontH(L.f.value) * BASELINE + 0.5))
    drawCompass(L, cx, cy, g, kind, sm.course, sm.rel)
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
  drawCell(L, x, GRID_TOP + 2 * GRID_PITCH, "ALT", fmt("%d " .. U.len, g.alt), STAGE_COL[g.altLevel])
  drawCell(L, x + half, GRID_TOP + 2 * GRID_PITCH, "DIST", fmt("%d " .. U.len, g.dist and g.dist * U.f), STAGE_COL[g.distLevel])
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

-- Other page styles are files of their own beside this one
-- (/WIDGETS/WINGMAN/<name>.lua), loaded when first shown and dropped when another
-- one is chosen. Each returns function(K), K the helpers and constants it draws
-- with, and from it its pages (flight, pre). nil for the built-in style and when
-- the file is missing or fails. VIEW.more: helpers defined further down.
local VIEW = { files = { horizon = true, tiles = true } }
local function loadView(name)
  if not VIEW.files[name] then name = nil end
  if VIEW.name ~= name then
    VIEW.name, VIEW.kit, VIEW.pages = name, nil, nil
    local chunk = name and loadScript("/WIDGETS/WINGMAN/" .. name .. ".lua")
    local ok, make = pcall(chunk)
    if ok and type(make) == "function" then
      VIEW.kit = {
        core = core, cutText = cutText, mixRGB = mixRGB, DARK_TEXT = DARK_TEXT, CAP_TOP = CAP_TOP, CAP_H = CAP_H,
        compass = compass, textW = textW, fontH = fontH, dtext = dtext, btext = btext, rtext = rtext,
        fmt = fmt, fmtMah = fmtMah, fmtAmps = fmtAmps, fmtTimer = fmtTimer, distText = distText,
        fillRounded = fillRounded, fillTri = fillTri, drawHeartbeat = drawHeartbeat,
        WARN_COL = WARN_COL, CRIT_COL = CRIT_COL, WARN_RGB = WARN_RGB, CRIT_RGB = CRIT_RGB, STAGE_COL = STAGE_COL,
        HERO_Y = HERO_Y, BASELINE = BASELINE, HEARTBEAT_R = HEARTBEAT_R, BAR = BAR,
        levelCol = levelCol, smallCol = smallCol, reserveColor = reserveColor,
        drawTitle = drawTitle, packTitle = packTitle, drawStage = drawStage,
        drawNoPack = drawNoPack, drawWarnSign = drawWarnSign,
        modeParts = modeParts, txLabel = txLabel, satBarsW = satBarsW, drawSatBars = drawSatBars,
      }
      for k, f in pairs(VIEW.more or {}) do VIEW.kit[k] = f end
      ok, VIEW.pages = pcall(make, VIEW.kit)
      if not ok or type(VIEW.pages) ~= "table" then VIEW.pages = nil end
    end
  end
  if VIEW.pages then VIEW.kit.COLORS, VIEW.kit.U = COLORS, U end   -- set per refresh
  return VIEW.pages
end

local drawPackList   -- pack selection in the battery column, with the preflight page below

local function drawFlight(ctx)
  local v = ctx.w and ctx.w.flight
  if not v then return end
  local z = ctx.zone
  if z.h - HDR_H < 8 * fontH(SMLSIZE) then return end
  local L = flightLayout(z)
  local view = loadView(ctx.w.gpsView)
  if view and view.flight and view.flight(ctx, L, z, v) ~= false then return end   -- false: not without GPS
  local c = columns(L, z, ctx.w.on, z.h)
  if v.batt and c[1] then
    -- Side value chosen in the settings tool: Timer 1 (none while off) or Lipo Nanny's time left.
    if ctx.w.flightTime == "timeleft" then
      drawBattery(L, c[1], c[2], v.batt, "TIME LEFT", v.batt.timeLeft)
    else
      drawBattery(L, c[1], c[2], v.batt, "TIMER", ctx.w.timerS and fmtTimer(ctx.w.timerS), smallCol(ctx.w.timerLevel))
    end
  elseif v.packSel and c[1] then   -- disarmed again without a pack
    drawPackList(L, c[1], c[2], v.packSel, ctx)
  elseif v.noPack and c[1] then
    drawNoPack(L, c[1], c[2])
  end
  if not (v.packSel and c[1]) then ctx.marqueeRow = nil end   -- next selection starts its marquee anew
  if v.gps and c[3] then drawGps(L, c[3], c[4], v.gps, ctx.w.alert, ctx) end
  if v.link and c[5] then drawLink(L, c[5], c[6], v.link, ctx.w.linkUp) end
end

-- ---------------------------------------------------------------------------
-- Preflight page: the flight page's columns, 300 of 418 design px high, each
-- with a status line at the bottom; below a strip with the ready field (GO /
-- CHECK), the line next to it and the versions. Statuses come from the core.
-- ---------------------------------------------------------------------------
local KEPT, secsLeft, countdownW, drawCountdown, drawPre
do
  local PRE_COLS_H = 300
  local STATUS_Y   = 282   -- status line baseline (design y)
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

  -- Bar and cells spread with equal gaps between the big value's caption and the
  -- status line: bar top, cell label baseline and label-to-value pitch in px.
  local function preRows(L)
    local top = L.y(HERO_Y + 29)
    local bottom = L.y(STATUS_Y) - math.floor(fontH(L.f.value) * (BASELINE - CAP_TOP) + 0.5)
    local bh = L.y(BAR.BOTTOM) - L.y(BAR.TOP)
    local capH = math.floor(fontH(L.f.label) * CAP_H + 0.5)
    local pitch = L.y(36) - L.y(10)   -- label to value baseline, as drawCell
    local gap = math.floor((bottom - top - bh - capH - pitch) / 3)
    return top + gap, top + 2 * gap + bh + capH, pitch
  end

  -- Two cells { label, value, col, draw } (as drawCell) on the preflight cell row.
  local function drawPreCells(L, x, w, cells)
    local _, base, pitch = preRows(L)
    for i, c in ipairs(cells) do
      local cx = x + (i - 1) * math.floor(w / 2)
      btext(cx, base, c[1], COLORS.muted, L.f.label)
      if c[4] then c[4](L, cx, base + pitch, c[2]) else btext(cx, base + pitch, c[2], c[3] or COLORS.fg, L.f.value) end
    end
  end

  local function drawPreBattery(L, x, w, b, st)
    local col = levelCol(st.batt.level)
    drawTitle(L, x, packTitle(L, w, b.name, b.nameShort))
    local small = smallCol(b.level)
    -- PER CELL and PACK by the cell voltage as on the flight page; bar, cells and status by the rest
    drawHero(L, x, x + w, fmt("%.2f", b.cell), "V", levelCol(b.vLevel), "PER CELL", "PACK", fmt("%.1f V", b.volt), smallCol(b.vLevel))
    drawBar(L, x, w, b.pct, col, { { b.warn, WARN_RGB }, { b.crit, CRIT_RGB } }, preRows(L))
    drawPreCells(L, x, w, { { "REMAINING", fmt("%d %%", b.pct), small }, { "LEFT", fmtMah(b.left), small } })
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

  -- Scroll steps until the end of name fits maxW (0: the whole name fits), one
  -- per byte: a multi-byte character just holds its place one step longer.
  local function marqueeSteps(name, maxW, font)
    if textW(name, font) <= maxW then return 0 end
    local lo, hi = 1, #name
    while lo < hi do
      local mid = math.floor((lo + hi) / 2)
      if textW(string.sub(name, mid), font) <= maxW then hi = mid else lo = mid + 1 end
    end
    return lo - 1
  end

  -- First byte shown at time t: one step per MARQUEE_STEP, MARQUEE_PAUSE steps
  -- at the start and the end, never inside a multi-byte character.
  local function marqueeFirst(name, t, steps)
    local pos = math.floor(t / MARQUEE_STEP) % (steps + 2 * MARQUEE_PAUSE) - MARQUEE_PAUSE
    local first = math.max(0, math.min(steps, pos)) + 1
    while isContByte(name, first) do first = first + 1 end
    return first
  end

  -- The part of name to show at time t (getTime units since the row got the cursor).
  local function marqueeText(name, maxW, t, font)
    local steps = marqueeSteps(name, maxW, font)
    if steps == 0 then return name end
    return fitFrom(name, marqueeFirst(name, t, steps), maxW, font)
  end

  -- KEPT.marquee and KEPT.cut: as marqueeText and cutText, but each text measured
  -- once per width and font (the switch page draws many texts every frame); the
  -- memo starts over at KEPT.max texts. Measuring is spread over frames: at most
  -- KEPT.left new measurements per frame (set by the caller), the next marquee
  -- step measured ahead; past that nil (KEPT.missed) or the last marquee step.
  KEPT = { memo = {}, n = 0, max = 400, left = 0 }
  -- A new memo slot for key when this frame may still measure, else nil.
  local function keptSlot(key)
    if KEPT.left <= 0 then KEPT.missed = true; return false end
    if KEPT.n >= KEPT.max then KEPT.memo, KEPT.n = {}, 0 end
    KEPT.n, KEPT.left = KEPT.n + 1, KEPT.left - 1
    return true
  end
  function KEPT.marquee(name, maxW, t, font, key)   -- key: as built here, when the caller keeps it
    key = key or (font .. "|" .. maxW .. "|" .. name)
    local m = KEPT.memo[key]
    if not m then
      if not keptSlot(key) then return nil end
      m = { steps = marqueeSteps(name, maxW, font) }
      KEPT.memo[key] = m
    end
    if m.steps == 0 then return name end
    local step = math.floor(t / MARQUEE_STEP)
    if m.at == step then return m.last end
    local first = marqueeFirst(name, t, m.steps)
    local part = m[first]
    if not part then
      if KEPT.left <= 0 then KEPT.missed = KEPT.missed or not m.last; return m.last end
      part, KEPT.left = fitFrom(name, first, maxW, font), KEPT.left - 1
      m[first] = part
    end
    m.last, m.at = part, step
    if m.ahead ~= first and KEPT.left > 0 then   -- once per step: the next one
      local nxt = marqueeFirst(name, t + MARQUEE_STEP, m.steps)
      if not m[nxt] then m[nxt], KEPT.left = fitFrom(name, nxt, maxW, font), KEPT.left - 1 end
      m.ahead = first
    end
    return part
  end
  function KEPT.cut(text, maxW, font)
    local key = "cut|" .. font .. "|" .. maxW .. "|" .. text
    local c = KEPT.memo[key]
    if not c then
      if not keptSlot(key) then return nil end
      c = cutText(text, "", maxW, font)
      KEPT.memo[key] = c
    end
    return c
  end

  -- Pack selection inside the battery column: window around the cursor, confirm
  -- hold as a bar behind the selected row, the stick hint at the bottom. A
  -- triangle above and below the list while the cursor can move that way (the
  -- elevator gesture): accent while the elevator leans that way, nudging until
  -- the step counts. The selected name scrolls (restarting when the cursor
  -- moves), the others are cut.
  function drawPackList(L, x, w, b, ctx)   -- also drawn on the flight page and by the views
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
    local tw, th, cx = L.s(12), L.s(7), x + math.floor(w / 2)
    local rows = math.min(#b.packs, maxRows)
    for dir = -1, 1, 2 do   -- -1 up, 1 down
      if dir < 0 and cursor > 1 or dir > 0 and cursor < #b.packs then
        local lean = -dir * (b.ele or 0) > 0.05   -- elevator up (positive) moves the cursor up
        local top = L.y(PACK_TOP) - L.s(3) - th
        -- Up: never further than to the title's baseline (small screens have 1 or 2 px).
        local amp = dir < 0 and math.min(L.s(3), math.max(0, top - L.y(31) - 1)) or L.s(3)
        local d = (lean and b.eleArmed) and dir * nudge(amp) or 0
        local col = lean and COLORS.accent or COLORS.muted
        if dir < 0 then
          local ty = top + d
          fillTri(cx - math.floor(tw / 2), ty + th, cx + math.floor(tw / 2), ty + th, cx, ty, col)
        else
          local ty = L.y(PACK_TOP + rows * PACK_ROW_H) + L.s(2) + d
          fillTri(cx - math.floor(tw / 2), ty, cx + math.floor(tw / 2), ty, cx, ty + th, col)
        end
      end
    end
    -- Gesture hint on the status line: elevator moves the cursor (the knob shows
    -- it), aileron held right selects.
    local fh = fontH(L.f.cap)
    drawStickHint(ctx.zone, { right = "Select", hold = b.hold, stick = b.stick, ele = b.ele, armed = b.armed, x = x,
                              cy = L.y(STATUS_Y) - math.floor(fh * BASELINE + 0.5) + math.floor(fh / 2) })
  end

  local function drawPreGps(L, x, w, g, st)
    drawTitle(L, x, "GPS")
    drawSats(L, x, x + w, g)
    drawPreCells(L, x, w, { { g.dopKind or "PDOP", g.dop and string.format("%.1f", g.dop) or "--",
                              g.dop and smallCol(st.dopStage) }, { "FIX", g.fix or "--", smallCol(g.fixLevel) } })
    drawStatus(L, x, st.gps)
  end

  local function drawPreLink(L, x, w, l, st, linkUp)
    local right = x + w
    drawTitle(L, x, l.modLine)
    if linkUp then drawHeartbeat(right - HEARTBEAT_R, L.y(21) + math.floor(L.s(11) / 2)) end
    local modeCap, modeVal = modeParts(l.mode)
    local col = st.lqLevel and levelCol(st.lqLevel) or COLORS.fg
    drawHero(L, x, right, fmt("%d", l.lq), "%", col, "LQ", modeCap, modeVal)
    -- red mark at the link core's stage 2 LQ limit
    drawBar(L, x, w, l.lq, col, l.lqCrit and { { l.lqCrit, CRIT_RGB } } or {}, preRows(L))
    drawPreCells(L, x, w, { { "RSSI dBm", l, nil, drawRssi }, { txLabel(l), fmt("%d mW", l.tpwr) } })
    drawStatus(L, x, st.link)
  end

  -- Seconds left on a page timer that started at `since` (the core's ms clock,
  -- getTime() * 10) and runs `total` ms.
  function secsLeft(since, total)
    return math.max(0, math.ceil((total - (getTime() * 10 - since)) / 1000))
  end

  -- Countdown at the bottom right (preflight and post-flight page): text left of
  -- a bar that runs empty. countdownW is the width it takes.
  function countdownW(L, label)
    return L.x(CD_BAR_W) + L.s(12) + textW(label .. " in 00 s", SMLSIZE)
  end
  function drawCountdown(z, secs, total, label)
    drawCornerBar(z, string.format("%s in %d s", label, secs), secs / total, COLORS.muted)
  end

  -- Ready field left; right of it the versions on top and below the line
  -- (warnings in yellow), both to the right edge. While the countdown runs (GO)
  -- the line stops short of it.
  local function drawReady(L, z, top, p, st, counting)
    local bw, bh = L.x(READY_W), L.s(READY_H)
    local bx, by = L.x(18), top + math.floor((z.h - top - bh) / 2)
    fillRounded(bx, by, bw, bh, L.s(10), (st.ready == "GO") and COLORS.ok or WARN_COL)
    local f = L.f.ready
    local fh = fontH(f)
    dtext(bx + math.floor(bw / 2), by + math.floor((bh - fh * CAP_H) / 2 - fh * CAP_TOP + 0.5), st.ready,
          DARK_TEXT, f + CENTER)
    local tx = bx + bw + L.x(18)
    local tw = z.w - tx - L.x(18)
    local ver = getVersion and getVersion()
    local parts = {}
    if p.fcInfo then parts[#parts + 1] = p.fcInfo end
    if ver then parts[#parts + 1] = "EdgeTX " .. ver end
    btext(tx, by + math.floor(bh * 0.4), cutText(table.concat(parts, ", "), "", tw, L.f.cap), COLORS.muted, L.f.cap)
    if st.line then
      if counting then tw = tw - countdownW(L, "Flight page") - L.x(18) end
      btext(tx, by + bh - L.s(8), cutText(st.line, "", tw, L.f.value),
            (p.armBlocked or st.lineWarn) and WARN_COL or COLORS.fg, L.f.value)
    end
  end

  VIEW.more = { drawPackList = drawPackList, secsLeft = secsLeft }

  function drawPre(ctx)
    local w = ctx.w
    local p, st = w and w.pre, w and w.preStatus
    if not (p and st) then return end
    local z = ctx.zone
    if z.h - HDR_H < 8 * fontH(SMLSIZE) then return end
    local L = flightLayout(z)
    local view = loadView(w.gpsView)
    if view and view.pre then view.pre(ctx, L, z) return end
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
    local fs = w.fs
    local counting = fs and fs.readySince and w.phase == core.PRE
    drawReady(L, z, top, p, st, counting)
    if counting then   -- GO: countdown to the flight page
      drawCountdown(z, secsLeft(fs.readySince, core.PRE_HOLD_T), core.PRE_HOLD_T / 1000, "Flight page")
    end
  end
end

-- ---------------------------------------------------------------------------
-- Post-flight page: three key figures on top (flight time, used mAh, distance
-- flown), the flight's values per module in the flight page's columns, the
-- alerts with their flight time below and the countdown to the wait page.
-- ---------------------------------------------------------------------------
local drawPost
do
  local POST_KPI_H  = 100   -- key figure strip (design px of the 418 body)
  local POST_COLS_B = 306   -- columns end here
  local POST_ROW0, POST_ROW_H = 62, 30   -- first value row (offset in the column), pitch
  local ALERT_ROW_H = 24

  local function kmText(m) return m and string.format("%.1f", m * U.f / U.big) or "--" end   -- km or mi

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
      drawTitle(L, c[1], packTitle(L, c[2], b.name, b.nameShort), POST_KPI_H)
      local lastV = b.cell and fmt("%.2f V", b.cell) or "--"
      drawRows(L, c[1], c[2], {
        { "CHARGE", fmt("%d %%", b.left), smallCol(b.level), fmt("%d %%", b.start) .. " -> " },
        { { "LAST PER CELL", "LAST CELL" }, lastV, smallCol(b.lastVLevel) },
        { { "MAX CURRENT", "MAX CURR" }, fmtAmps(b.maxA) },
        { "PACK CYCLES", b.cycles or "--" },
      })
    end
    if g and c[3] then
      drawTitle(L, c[3], "GPS", POST_KPI_H)
      local co = g.coord or function(v) return string.format("%.5f", v) end
      drawRows(L, c[3], c[4], {
        { { "MAX DISTANCE", "MAX DIST" }, distText(g.maxDist), smallCol(g.distLevel) },
        { { "MAX ALTITUDE", "MAX ALT" }, fmt("%d " .. U.len, g.maxAlt), smallCol(g.altLevel) },
        { { "MAX SPEED", "MAX SPD" }, fmt("%d " .. U.spd, g.maxSpd) },
        { { "LAST POSITION", "LAST POS" }, g.lat and co(g.lat) or "--" },
        { "", g.lon and co(g.lon) or "" },
      })
    end
    if l and c[5] then
      drawTitle(L, c[5], l.modLine, POST_KPI_H)
      drawRows(L, c[5], c[6], {
        { { "LOW LINK QUALITY", "LOW LQ" }, fmt("%d %%", l.minLq), smallCol(l.lqStage) },
        { "MAX RANGELIMIT", fmt("%d %%", l.maxRange), smallCol(l.rangeStage) },
        { { "MAX TX POWER", "MAX TX PWR" }, fmt("%d mW", l.maxTpwr) },
        { "RF MODE", l.mode or "--" },
      })
    end
  end

  -- Alerts: newest top left, then down the column and on in the second; six at
  -- most, the sixth carrying "+N" for the older ones not shown.
  local function drawAlerts(L, z, p, pad)
    local top = L.y(POST_COLS_B + 22)
    local list, n = p.alerts or {}, #(p.alerts or {})
    btext(pad, top, (n > 6) and ("ALERTS  +" .. (n - 6)) or "ALERTS", COLORS.muted, L.f.label)
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
      -- bottom right: ends before the countdown
      if i == 6 then text = cutText(text, "", z.w - pad - countdownW(L, "Wait page") - L.s(12) - tx, L.f.value) end
      btext(tx, base, text, levelCol(a.level), L.f.value)
    end
  end

  function drawPost(ctx)
    local w = ctx.w
    local p = w and w.post
    if not p then return end
    local z = ctx.zone
    if z.h - HDR_H < 8 * fontH(SMLSIZE) then return end
    local L = flightLayout(z)
    local b, g = p.batt or {}, p.gps or {}
    local third = math.floor(z.w / 3)
    -- key figures: text colour, yellow or red only on a problem
    drawKpi(L, math.floor(third / 2), "FLIGHT TIME", p.time or "--", nil, smallCol(p.timeLevel))
    drawKpi(L, third + math.floor(third / 2), { "USED CAPACITY", "USED CAP" }, fmt("%d", b.used), "mAh",
            smallCol(b.level), third - L.s(16))
    drawKpi(L, 2 * third + math.floor(third / 2), "FLOWN", kmText(g.flown), U.bigU)
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
end

-- ---------------------------------------------------------------------------
-- Wait page: a mascot while no telemetry arrives, chosen in the settings tool
-- (Display): "Quad", a quad seen slightly from above (the camera is its face,
-- props as discs), or "Scout", a round head; both with an antenna sending signal
-- arcs. "Model image" shows the model's own image from the model settings
-- instead (the quad without one). With a setup error the mascot is sad, next to
-- a yellow speech bubble.
-- Mascots drawn in a 150 x 122 design box, scaled with the page; animation from
-- getTime() (rocks on its foot, props spin, arcs pulse outwards, red tip pulses
-- like the heartbeat, eyes blink and now and then look ahead). The API cannot rotate
-- shapes, so the rocking figure is built from triangles and circles at rotated
-- points.
-- ---------------------------------------------------------------------------
local mascot, drawBubble, drawWait
do
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
  local BATT      = lcd.RGB(240, 192,  32)
  local BATT_TOP  = lcd.RGB(246, 216,  96)
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
    -- Design point rotated about the pivot (positive = clockwise), in pixels;
    -- the constant part worked out once per frame (P runs a few hundred times).
    local floor, ck, sk = math.floor, c * k, sn * k
    local ax = mx + (PIVOT_U - PIVOT_U * c + PIVOT_V * sn) * k + 0.5
    local ay = my + (PIVOT_V - PIVOT_U * sn - PIVOT_V * c) * k + 0.5
    local function P(u, v)
      return floor(ax + u * ck - v * sk), floor(ay + u * sk + v * ck)
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
    -- Design point rotated about the pivot (positive = clockwise), in pixels;
    -- the constant part worked out once per frame (P runs a few hundred times).
    local floor, ck, sk = math.floor, c * k, sn * k
    local ax = mx + (PIVOT_U - PIVOT_U * c + PIVOT_V * sn) * k + 0.5
    local ay = my + (PIVOT_V - PIVOT_U * sn - PIVOT_V * c) * k + 0.5
    local function P(u, v)
      return floor(ax + u * ck - v * sk), floor(ay + u * sk + v * ck)
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
    quad(72, 30, 78, 30, 79, 38, 71, 38, COLORS.strapTop)
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
    rect(47, 64, 5, 32, COLORS.tpu)
    rect(98, 64, 5, 32, COLORS.tpu)
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
      circle(p[1], p[2], 2.5, COLORS.tpu)
    end
  end

  -- Sad Scout left, yellow speech bubble right (tail towards the head), the
  -- group centred; no details here, they are in the settings tool.
  -- Mascot chosen in the settings tool; the quad unless "scout".
  function mascot(w)
    return (w and w.mascot == "scout") and drawScout or drawQuad
  end

  -- Sad mascot with a speech bubble: setup error, core missing, widget error.
  function drawBubble(z, bodyH, draw, title, lines)
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

  -- The model image, opened once per file name; nil when missing or not loadable.
  local imgName, imgBmp
  local function modelImage(name)
    if name ~= imgName then
      imgName, imgBmp = name, nil
      if name and Bitmap then
        local path = string.sub(name, 1, 1) == "/" and name or "/IMAGES/" .. name
        local ok, bmp = pcall(Bitmap.open, path)
        if ok and bmp and Bitmap.getSize(bmp) > 0 then imgBmp = bmp end
      end
    end
    return imgBmp
  end

  -- Model image in the mascot's place: as high as the mascot, at most 1.6 times
  -- as wide as high, centred on cx.
  local function drawImage(bmp, cx, my, k)
    local iw, ih = Bitmap.getSize(bmp)
    local bh = 122 * k
    local scale = math.min(bh / ih, 1.6 * bh / iw)
    local pct = math.floor(scale * 100)
    local dw, dh = math.floor(iw * pct / 100), math.floor(ih * pct / 100)
    lcd.drawBitmap(bmp, cx - math.floor(dw / 2), my + math.floor((bh - dh) / 2), pct)
  end

  function drawWait(ctx)
    local z = ctx.zone
    local bodyH = z.h - HDR_H
    if bodyH < 6 * fontH(SMLSIZE) then return end
    if ctx.w and ctx.w.setupError then return drawBubble(z, bodyH, mascot(ctx.w), ERR_TITLE, ERR_LINES) end
    local th, sh = fontH(BOLD), fontH(SMLSIZE)
    -- Menu on the left (while one is offered), the rest centred beside it; its
    -- place stays free without a menu (model connected), so nothing moves.
    local hint = ctx.w and ctx.w.waitHint
    local menu = hint and hint.items and menuLayout(z, hint)
    local railW = menuWidth(z)
    -- Designed for 480 x 272; beside the menu only the mascot (150 wide plus
    -- margins) has to fit, so the menu does not shrink it.
    local k = math.min(bodyH / 227, z.w / 480, (z.w - railW) / 190)
    local t = getTime()
    local gap = math.floor(10 * k + 0.5)
    local blockH = math.floor(122 * k + 0.5) + gap + th + sh
    local cx = railW + math.floor((z.w - railW) / 2)
    local my = HDR_H + math.floor((bodyH - blockH) / 2)
    local bmp = ctx.w and ctx.w.mascot == "model" and modelImage(ctx.w.modelImage)
    if bmp then drawImage(bmp, cx, my, k) else mascot(ctx.w)(cx - 75 * k, my, k, t) end

    -- Title with dots counting up; left edge fixed so the text does not jump.
    local ty = my + math.floor(122 * k + 0.5) + gap
    local title = (ctx.w and ctx.w.waitTitle) or WAIT_TITLE
    local tx = cx - math.floor(textW(title .. "...", BOLD) / 2)
    dtext(tx, ty, title .. string.rep(".", math.floor(t / 50) % 4), COLORS.fg, BOLD)
    dtext(cx, ty + th, (ctx.w and ctx.w.waitSub) or WAIT_SUB, COLORS.muted, SMLSIZE + CENTER)
    if menu then drawMenu(z, ctx.w, menu) end
  end
end

-- Switch page: title with the source of the modes, the switches as cards in
-- rows of four (two left, two right, as on the radio), each with its channel
-- and per position the FC's modes and the special functions, the current
-- position on a darker band; bottom right the gesture back.
-- A card's static part (box, name, channel, bands, tiles, speakers) is laid out
-- once as drawing calls (rec) and replayed every frame through table.unpack;
-- only the marquee texts are worked out per frame. Kept on the card while its
-- place, size and palette stay.
local drawSwitches
do
  local SW_GAP = { card = 10, side = 22 }   -- design px between cards, between the two sides
  local LAYS = 2                            -- cards laid out per frame at most
  local floor, max, unpack = math.floor, math.max, table.unpack

  -- lay.ops: the static drawing; lay.mq: the marquee texts, 7 slots each (x, y,
  -- text, width, colour, font, KEPT key).
  local function layout(c, x, y, w, h, wide)
    local pad = max(3, floor(8 * w / 180 + 0.5))
    local fName, fRow, fSym = wide and BOLD or SMLSIZE, SMLSIZE, SMLSIZE
    local nh, lh = fontH(fName), fontH(fRow)
    local right, bottom = x + w - pad, y + h - floor(pad / 2)
    local ops, mq = {}, {}
    local lay = { x = x, y = y, w = w, h = h, wide = wide, colors = COLORS, ops = ops, mq = mq }
    local function marquee(tx, ty, t, maxW, col)
      local n = #mq
      mq[n + 1], mq[n + 2], mq[n + 3], mq[n + 4], mq[n + 5], mq[n + 6], mq[n + 7] =
        tx, ty, t, maxW, col, fRow, fRow .. "|" .. maxW .. "|" .. t
    end
    fillRounded(x, y, w, h, max(2, floor(pad * 0.75)), COLORS.box, ops)
    local nameW = textW(c.name, fName)
    local tag = c.tag
    if textW(tag, SMLSIZE) > w - 3 * pad - nameW then tag = c.tagShort or tag end
    -- The tag is measured outside the frame's allowance (the marquees of the
    -- cards drawn before may have used it up), at most LAYS per frame.
    local left = KEPT.left
    KEPT.left = 1
    tag = KEPT.cut(tag, max(0, w - 3 * pad - nameW), SMLSIZE)
    KEPT.left = left
    dtext(x + pad, y + pad, c.name, COLORS.fg, fName, ops)
    if tag then dtext(right - textW(tag, SMLSIZE), y + pad + nh - fontH(SMLSIZE), tag, COLORS.muted, SMLSIZE, ops) end
    local rect = rec(ops, lcd.drawFilledRectangle)
    local half = floor(pad / 2)
    local symW = textW("W", fRow) + pad
    local tileX, tileW, inset = x + pad, symW - half, max(1, floor(pad / 3))
    local bandR = max(2, half)
    local tx = x + pad + symW
    local tw = right - tx
    local gh = floor(lh * 0.6)
    local playX, ghMid = tx + gh + half, floor(lh / 2)
    local ty = y + pad + nh
    -- Modes and special functions on separate lines; when that does not fit,
    -- the functions beside modes only on the current position.
    local need = 0
    for _, p in ipairs(c.pos) do need = need + ((p.modes and p.sf) and 2 or 1) end
    local all = ty + need * lh <= bottom
    for _, p in ipairs(c.pos) do
      local sf = p.sf
      if p.modes and not (all or p.cur) then sf = nil end
      local lh2 = ((p.modes and sf) and 2 or 1) * lh
      if ty + lh2 > bottom then break end
      -- The symbol on a tile over all lines of its position, accent when current.
      if p.cur then fillRounded(x + half, ty, w - pad, lh2, bandR, COLORS.swCur, ops) end
      local th = lh2 - 2 * inset
      local col = p.cur and COLORS.accent or COLORS.swTile   -- two rectangles: 1 px corners, no circles
      rect(tileX + 1, ty + inset, tileW - 2, th, col)
      rect(tileX, ty + inset + 1, tileW, th - 2, col)
      dtext(tileX + floor((tileW - textW(p.sym, fSym)) / 2), ty + inset + floor(th / 2),
            p.sym, p.cur and COLORS.swOnAccent or COLORS.fg, fSym + VCENTER, ops)
      if p.modes then marquee(tx, ty, p.modes, tw, COLORS.fg) end
      if sf then
        local sy, sx = p.modes and ty + lh or ty, tx
        if p.play then
          drawSpeaker(sx, sy + ghMid, gh, false, false, ops)
          sx = playX
        end
        marquee(sx, sy, sf, right - sx, COLORS.muted)
      end
      ty = ty + lh2
    end
    return lay
  end

  -- dry: measure only (texts for KEPT), nothing drawn. At most KEPT.lays cards
  -- are laid out per frame; past that the card is left out and the page goes
  -- back to measuring (KEPT.ready false) until every card has its layout.
  local function drawSwitchCard(c, x, y, w, h, wide, now, dry)
    local lay = c.lay
    if not lay or lay.x ~= x or lay.y ~= y or lay.w ~= w or lay.h ~= h or lay.wide ~= wide or lay.colors ~= COLORS then
      if KEPT.lays <= 0 then KEPT.missed, KEPT.ready = true, false; return end
      KEPT.lays = KEPT.lays - 1
      lay = layout(c, x, y, w, h, wide)
      c.lay = lay
    end
    local mq, marquee = lay.mq, KEPT.marquee
    if dry then
      for i = 1, #mq, 7 do marquee(mq[i + 2], mq[i + 3], now, mq[i + 5], mq[i + 6]) end
      return
    end
    local ops = lay.ops
    for i = 1, #ops do
      local o = ops[i]
      o[1](unpack(o, 2))
    end
    local set, draw = lcd.setColor, lcd.drawText
    for i = 1, #mq, 7 do
      local t = marquee(mq[i + 2], mq[i + 3], now, mq[i + 5], mq[i + 6])
      if t then
        set(CUSTOM_COLOR, mq[i + 4])
        draw(mq[i], mq[i + 1], t, CUSTOM_COLOR + mq[i + 5])
      end
    end
  end

  function drawSwitches(ctx)
    local z, v, now = ctx.zone, ctx.w.sw, getTime()
    if z.h - HDR_H < 8 * fontH(SMLSIZE) then return end
    local L = flightLayout(z)
    local wide = z.w >= 700
    local x0, right = L.x(18), z.w - L.x(18)
    drawTitle(L, x0, "SWITCHES")
    -- After opening, the texts are measured over a few frames (cards not yet
    -- drawn) so no frame measures them all; then a few new ones per frame.
    if v.loading then KEPT.ready = false end
    local dry = not KEPT.ready
    KEPT.left, KEPT.missed, KEPT.lays = dry and 24 or 4, false, LAYS
    if v.src then
      local titleR = x0 + L.s(19) + textW("SWITCHES", L.f.title) + L.x(16)
      local src = KEPT.cut(v.src, right - titleR, SMLSIZE)
      if src then rtext(right, L.y(31), src, COLORS.muted, SMLSIZE) end
    end
    local top = L.y(46)
    local bottom = z.h - fontH(SMLSIZE) - L.s(26)
    local gap, side = L.x(SW_GAP.card), L.x(SW_GAP.side)
    local cw = floor((right - x0 - side - 2 * gap) / 4)
    local n = max(1, #v.rows)
    local rgap = L.s(SW_GAP.card)
    local ch = floor((bottom - top - (n - 1) * rgap) / n)
    for r, row in ipairs(v.rows) do
      local y = top + (r - 1) * (ch + rgap)
      for i = 1, 4 do
        local c = row[i]
        if c then
          local x = x0 + (i - 1) * (cw + gap) + ((i > 2) and (side - gap) or 0)
          drawSwitchCard(c, x, y, cw, ch, wide, now, dry)
        end
      end
    end
    if dry and not v.loading and not KEPT.missed then KEPT.ready = true end
    drawStickHint(z, { left = "Back", hold = ctx.w.waitHold, stick = ctx.w.stick, armed = ctx.w.closeArmed })
  end
end

-- Channel page: the channels with mixes as bars from the centre (-100 to
-- +100 %), number, name and value; two columns from five channels on, as many
-- rows as fit. Bottom right the gesture back.
local function drawChannels(ctx)
  local z, v = ctx.zone, ctx.w.ch
  if z.h - HDR_H < 8 * fontH(SMLSIZE) then return end
  local L = flightLayout(z)
  local x0, right = L.x(18), z.w - L.x(18)
  drawTitle(L, x0, "CHANNELS")
  local hintY = drawStickHint(z, { left = "Back", hold = ctx.w.waitHold, stick = ctx.w.stick, armed = ctx.w.closeArmed })
  local rows = v.rows
  local top, bottom = L.y(50), hintY - L.s(12)
  if #rows == 0 then
    dtext(math.floor(z.w / 2), math.floor((top + bottom) / 2), "No channel has a mix", COLORS.muted, SMLSIZE + CENTER + VCENTER)
    return
  end
  local fh = fontH(SMLSIZE)
  local cols = #rows > 4 and 2 or 1
  local per = math.min(math.ceil(#rows / cols), math.max(1, math.floor((bottom - top) / (fh + L.s(4)))))
  local rh = math.min(L.s(44), math.floor((bottom - top) / per))
  local cgap = L.x(40)
  local cw = math.floor((right - x0 - (cols - 1) * cgap) / cols)
  local numW, nameW = textW("CH32", SMLSIZE), 0
  for _, r in ipairs(rows) do
    if r.name ~= "" then nameW = math.max(nameW, textW(r.name, SMLSIZE)) end
  end
  local valW, tg = textW("-150%", SMLSIZE), L.x(10)
  local barH = math.max(4, math.floor(rh * 0.35))
  for i = 1, math.min(#rows, cols * per) do
    local r = rows[i]
    local c = math.floor((i - 1) / per)
    local x, cy = x0 + c * (cw + cgap), top + ((i - 1) % per) * rh + math.floor(rh / 2)
    dtext(x, cy, "CH" .. r.n, COLORS.muted, SMLSIZE + VCENTER)
    local nx = x + numW + tg
    if r.name ~= "" then dtext(nx, cy, r.name, COLORS.fg, SMLSIZE + VCENTER) end
    local bx = nx + (nameW > 0 and nameW + tg or 0)
    local bwid = x + cw - valW - tg - bx
    local pct = (r.v or 0) * 100 / 1024
    local p = math.floor(math.abs(pct) + 0.5)
    local val = (pct < 0 and p > 0 and "-" or "") .. p .. "%"
    dtext(x + cw - textW(val, SMLSIZE), cy, val, COLORS.fg, SMLSIZE + VCENTER)
    if bwid >= 20 then
      local by, mid = cy - math.floor(barH / 2), bx + math.floor(bwid / 2)
      lcd.drawFilledRectangle(bx, by, bwid, barH, COLORS.track)
      local fw = math.floor(bwid / 2 * math.min(1, math.abs(pct) / 100) + 0.5)
      if fw > 0 then lcd.drawFilledRectangle(pct < 0 and mid - fw or mid, by, fw, barH, COLORS.accent) end
      lcd.drawFilledRectangle(mid, by - L.s(3), 1, barH + 2 * L.s(3), COLORS.fg)
    end
  end
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
  COLORS = withAccent((ctx.options.Theme == 2) and LIGHT or DARK, ctx.options.Accent, ctx.options.AccentColor)
  NORTH_UP = (ctx.options.Compass == 2)
  BAR.style = ctx.w and ctx.w.barStyle or "solid"
  U = (ctx.w and ctx.w.imperial) and UNITS.imperial or UNITS.metric

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
  local page = (not w and drawNoCore) or (ctx.fatalError and drawFatal) or (w.setupError and drawWait) or (w.sw and drawSwitches) or (w.ch and drawChannels) or (w and w.flight and drawFlight) or (w and w.pre and drawPre)
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

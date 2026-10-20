-- Compass drawing for the GPS Homer widget and other widgets that load it
-- (display only, no state between calls). Load with loadScript(path, "bt")().
--
-- Dial face inside a ring band in track colour, ticks inside the band (every
-- 10 degrees on large rings, else every 30; the cardinals lighter, N in the
-- text colour), N E S W outside it (N bold), a notched two-tone arrow, a house
-- on the letter track towards home. Two modes:
--   North up: ring fixed, arrow = course, house = bearing to home.
--   Nose up:  ring turns with the course, a fixed mark at 12 o'clock, the arrow
--             points home (bearing relative to the course), no house.
-- Without a course the ring holds north up, the house marks home and a crosshair
-- replaces the arrow. Compact: the bare band (no letters, ticks or mark) for
-- boxes too low for the letters, home as a dot on the band.
-- Colours: col = { track = ..., fg = ..., muted = ..., face = ... } (lcd colour
-- values; face is the dial, none without it).

local C = {}
local FONT = SMLSIZE
local N_FONT = BOLD or FONT   -- N a size larger and bold (bold exists only at standard size)

local heights = {}
local widths = { [FONT] = {}, [N_FONT] = {} }
local function fontH(f)
  f = f or FONT
  if not heights[f] then heights[f] = select(2, lcd.sizeText("0", f)) end
  return heights[f]
end
local function textW(t, f)
  f = f or FONT
  local w = widths[f][t]
  if not w then w = lcd.sizeText(t, f); widths[f][t] = w end
  return w
end
local function text(x, y, t, col, f)
  lcd.setColor(CUSTOM_COLOR, col)
  lcd.drawText(x, y, t, CUSTOM_COLOR + (f or FONT))
end

-- Point at radius r towards deg (0 = up, clockwise).
local function pt(cx, cy, r, deg)
  local a = math.rad(deg)
  return math.floor(cx + r * math.sin(a) + 0.5), math.floor(cy - r * math.cos(a) + 0.5)
end
C.point = pt

local function fillTri(x1, y1, x2, y2, x3, y3, col)
  if lcd.drawFilledTriangle then
    lcd.drawFilledTriangle(x1, y1, x2, y2, x3, y3, col)
  elseif lcd.drawTriangle then
    lcd.drawTriangle(x1, y1, x2, y2, x3, y3, col)
  end
end

-- Band width for a ring of radius R (6 of 70 in the design), at least 2 px.
function C.bandWidth(R) return math.max(2, math.floor(R * 6 / 70 + 0.5)) end

-- Radius of the letter track outside a ring of radius R.
function C.letterRadius(R)
  return R + math.ceil(C.bandWidth(R) / 2) + math.floor(fontH() * 0.45)
end

local function angDiff(a, b) return math.abs(((a - b + 540) % 360) - 180) end

local function drawBand(cx, cy, R, rw, col)
  local r0, r1 = R - math.floor(rw / 2), R + math.ceil(rw / 2)
  if lcd.drawAnnulus then
    -- a full 0..360 annulus draws nothing in EdgeTX: two half arcs
    lcd.drawAnnulus(cx, cy, r0, r1, 0, 180, col)
    lcd.drawAnnulus(cx, cy, r0, r1, 180, 360, col)
  elseif lcd.drawCircle then
    for r = r0, r1 - 1 do lcd.drawCircle(cx, cy, r, col) end
  end
end

-- Lines are 1 px in the Lua API: w (1..3) side by side.
local function thickLine(x1, y1, x2, y2, col, w)
  lcd.drawLine(x1, y1, x2, y2, SOLID, col)
  if (w or 2) >= 2 then lcd.drawLine(x1 + 1, y1, x2 + 1, y2, SOLID, col) end
  if (w or 2) >= 3 then lcd.drawLine(x1 - 1, y1, x2 - 1, y2, SOLID, col) end
end

-- Ticks inside the band, turned by rotDeg: from a small gap under the band
-- inwards, 30 degree ticks longer, the cardinals longest (N in fg, 3 px). The
-- 10 degree ticks only from FINE_TICKS_R on (closer than about 6 px apart below).
local FINE_TICKS_R = 40
local function drawTicks(cx, cy, R, ri, rotDeg, col)
  local r1 = ri - math.max(1, math.floor(R * 0.05 + 0.5))
  local fine = R >= FINE_TICKS_R
  for i = 0, 35 do
    local a = i * 10 + rotDeg
    if i % 9 == 0 then
      local x1, y1 = pt(cx, cy, r1 - math.floor(R * 0.25 + 0.5), a)
      local x2, y2 = pt(cx, cy, r1, a)
      if i == 0 then thickLine(x1, y1, x2, y2, col.fg, 3) else thickLine(x1, y1, x2, y2, col.muted, 2) end
    elseif i % 3 == 0 then
      local x1, y1 = pt(cx, cy, r1 - math.floor(R * 0.2 + 0.5), a)
      local x2, y2 = pt(cx, cy, r1, a)
      thickLine(x1, y1, x2, y2, col.track, 2)
    elseif fine then
      local x1, y1 = pt(cx, cy, r1 - math.max(2, math.floor(R * 0.1 + 0.5)), a)
      local x2, y2 = pt(cx, cy, r1, a)
      thickLine(x1, y1, x2, y2, col.track, 1)
    end
  end
end

-- Fixed mark at 12 o'clock on the letter track (Nose up), tip towards the ring.
local function drawNoseMark(cx, cy, tr, col)
  local h = math.max(3, math.floor(fontH() * 0.4))
  local w = math.max(2, math.floor(h * 0.6))
  local y = cy - tr
  fillTri(cx - w, y - h, cx + w, y - h, cx, y + h, col)
end

-- Ring with face, ticks and letters turned by rotDeg (Nose up: -course).
-- skipAng: a letter the house (or the nose mark) would touch there is left out.
-- Compact: the bare band. Returns the letter radius.
function C.ring(cx, cy, R, rotDeg, skipAng, compact, northUp, col)
  local rw = C.bandWidth(R)
  local ri = R - math.floor(rw / 2)
  if not compact and col.face and lcd.drawFilledCircle then lcd.drawFilledCircle(cx, cy, ri, col.face) end
  drawBand(cx, cy, R, rw, col.track)
  local tr = C.letterRadius(R)
  if compact then return tr end
  if lcd.drawLine then drawTicks(cx, cy, R, ri, rotDeg, col) end
  if not northUp then skipAng = 0; drawNoseMark(cx, cy, tr, col.fg) end
  local minSep = math.deg((textW("W") / 2 + fontH() / 2) / tr)
  for i, letter in ipairs({ "N", "E", "S", "W" }) do
    local a = (i - 1) * 90 + rotDeg
    if not skipAng or angDiff(a, skipAng) > minSep then
      local f = (i == 1) and N_FONT or FONT
      local lx, ly = pt(cx, cy, tr, a)
      text(lx - math.floor(textW(letter, f) / 2), ly - math.floor(fontH(f) / 2), letter, (i == 1) and col.fg or col.muted, f)
    end
  end
  return tr
end

-- Notched arrow: tip, wings and tail notch as in the design (radius r = the tip).
-- shade: colour of the right half (lit from the left), none = one colour.
function C.arrow(cx, cy, r, deg, col, shade)
  local tx, ty = pt(cx, cy, r, deg)
  local rx, ry = pt(cx, cy, r * 0.968, deg + 141.7)
  local nx, ny = pt(cx, cy, r * 0.44, deg + 180)
  local lx, ly = pt(cx, cy, r * 0.968, deg - 141.7)
  fillTri(tx, ty, rx, ry, nx, ny, shade or col)
  fillTri(tx, ty, nx, ny, lx, ly, col)
end

-- Crosshair (position known, heading not): arms of radius r/2, band-thin.
function C.crosshair(cx, cy, r, thick, col)
  r = math.max(3, math.floor(r / 2))
  local hthick = math.floor(thick / 2)
  lcd.drawFilledRectangle(cx - r, cy - hthick, 2 * r, thick, col)
  lcd.drawFilledRectangle(cx - hthick, cy - r, thick, 2 * r, col)
end

-- Small house (standing on the home point) in the ring centre: filled roof over a
-- filled body, the door in doorCol (track) so it reads on both themes. The icon
-- spans about 1.5 r around (cx, cy).
function C.house(cx, cy, r, col, doorCol)
  local roofTop, eave, base = cy - math.floor(r * 0.75), cy - math.floor(r * 0.1), cy + math.floor(r * 0.75)
  local halfRoof, halfBody = math.floor(r * 0.85), math.floor(r * 0.6)
  fillTri(cx, roofTop, cx - halfRoof, eave, cx + halfRoof, eave, col)
  lcd.drawFilledRectangle(cx - halfBody, eave, 2 * halfBody, base - eave, col)
  local dw = math.max(2, math.floor(r * 0.3))
  local dh = math.max(3, math.floor(r * 0.45))
  lcd.drawFilledRectangle(cx - math.floor(dw / 2), base - dh, dw, dh, doorCol)
end

-- House on the letter track, or (compact) a dot on the band.
local function drawHome(cx, cy, R, tr, bearing, compact, col)
  if not bearing then return end
  local rw = C.bandWidth(R)
  if compact then
    local hx, hy = pt(cx, cy, R, bearing)
    lcd.drawFilledCircle(hx, hy, rw + 1, col.fg)
    return
  end
  local hx, hy = pt(cx, cy, tr, bearing)
  C.house(hx, hy, math.floor(fontH() * 0.6), col.fg, col.track)
end

-- The whole compass. d = { course = deg or nil (no valid course), rel = home
-- relative to the course, bearing = deg to home or nil }.
function C.draw(cx, cy, R, d, northUp, compact, col)
  local r = math.floor(R * 50 / 70)
  if not d.course then
    local tr = C.ring(cx, cy, R, 0, d.bearing, compact, true, col)
    drawHome(cx, cy, R, tr, d.bearing, compact, col)
    C.crosshair(cx, cy, r, C.bandWidth(R), col.fg)
  elseif northUp then
    local tr = C.ring(cx, cy, R, 0, d.bearing, compact, true, col)
    C.arrow(cx, cy, r, d.course, col.fg, col.muted)
    drawHome(cx, cy, R, tr, d.bearing, compact, col)
  else
    C.ring(cx, cy, R, -d.course, nil, compact, false, col)
    if d.rel then C.arrow(cx, cy, r, d.rel, col.fg, col.muted) end
  end
end

-- Angle smoothing (display only): each frame moves the drawn angle towards the
-- target by half the remaining way, capped at SMOOTH_MAX_STEP degrees, along the
-- shorter direction, so GPS jitter softens and a real turn follows within a few
-- frames. nil target (no course) forgets the value, the next one snaps. The
-- result is always -180..180 (rel's range, which relText relies on).
local SMOOTH_MAX_STEP = 40
function C.smooth(prev, target)
  if target == nil then return nil end
  if prev == nil then return target end
  local diff = ((target - prev + 540) % 360) - 180
  if math.abs(diff) < 0.5 then return target end
  local step = diff * 0.5
  if step >  SMOOTH_MAX_STEP then step =  SMOOTH_MAX_STEP end
  if step < -SMOOTH_MAX_STEP then step = -SMOOTH_MAX_STEP end
  return ((prev + step + 180) % 360) - 180
end

-- Steering hint from rel: "ahead" / "behind" within the GPS core's limits
-- (P = { ahead = AHEAD_DEG, behind = BEHIND_DEG }), else "30 R" / "30 L".
function C.relText(rel, P)
  if not rel then return "" end
  local a = math.abs(rel)
  if a <= P.ahead then return "ahead" end
  if a >= P.behind then return "behind" end
  return string.format("%d %s", math.floor(a + 0.5), (rel > 0) and "R" or "L")
end

-- FC status that replaces the home line: long text, short form, colour key.
local ALERTS = {
  RTH  = { "RETURN TO HOME", "RTH",  "warn" },
  FS   = { "FAILSAFE",       "FS",   "crit" },
  LAND = { "LANDING",        "LAND", "warn" },
}

-- What the compass shows and the text under it, the same on both widgets.
-- d = { gpsState, noHome, atHome, alert, courseValid, estimated, rel, sector,
-- bearing }; estimated (nose from yaw while hovering) puts "~" before the hint.
-- Returns kind ("ring": ring without arrow before home; "house": ring with the
-- house on the home point; "arrow": the compass with arrow) and the label
-- { cap ("HOME" or nil), text, short (for little room), ref (widest text of its
-- kind, so the slot never shifts), col ("muted", "fg", "warn", "crit") }.
function C.label(d, P)
  if d.gpsState == "READY" then
    if d.noHome then return "ring", { text = "NO HOME", short = "NO HOME", ref = "NO HOME", col = "crit" } end
    return "ring", { text = "READY TO FLY", short = "READY", ref = "READY TO FLY", col = "muted" }
  end
  local a = ALERTS[d.alert or ""]
  if d.atHome then
    if a then return "house", { text = a[1], short = a[2], ref = a[1], col = a[3] } end
    return "house", { text = "AT HOME", short = "AT HOME", ref = "AT HOME", col = "muted" }
  end
  if a then return "arrow", { text = a[1], short = a[2], ref = a[1], col = a[3] } end
  if d.courseValid and d.rel then
    return "arrow", { cap = "HOME", text = (d.estimated and "~" or "") .. C.relText(d.rel, P), ref = "~180 R", col = "fg" }
  end
  local t = string.format("%s %d\194\176", d.sector or "?", math.floor((d.bearing or 0) + 0.5))
  return "arrow", { cap = "HOME", text = t, short = t, ref = "NW 360\194\176", col = "fg" }
end

return C

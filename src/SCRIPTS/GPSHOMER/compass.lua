-- Compass drawing for the GPS Homer widget and other widgets that load it
-- (display only, no state between calls). Load with loadScript(path, "bt")().
--
-- Ring band in track colour with ticks at the intercardinals and N E S W
-- outside it (N in the text colour), a notched arrow, an H badge on the letter
-- track towards home. Two modes:
--   North up: ring fixed, arrow = course, H = bearing to home.
--   Nose up:  ring turns with the course, a fixed mark at 12 o'clock, the arrow
--             points home (bearing relative to the course), no H.
-- Without a course the ring holds north up, the H marks home and a crosshair
-- replaces the arrow. Compact: the bare band (no letters, ticks or mark) for
-- boxes too low for the letters, home as a dot on the band.
-- Colours: col = { track = ..., fg = ..., muted = ... } (lcd colour values).

local C = {}
local FONT = SMLSIZE

local fh
local widths = {}
local function fontH()
  if not fh then fh = select(2, lcd.sizeText("0", FONT)) end
  return fh
end
local function textW(t)
  local w = widths[t]
  if not w then w = lcd.sizeText(t, FONT); widths[t] = w end
  return w
end
local function text(x, y, t, col)
  lcd.setColor(CUSTOM_COLOR, col)
  lcd.drawText(x, y, t, CUSTOM_COLOR + FONT)
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

-- Lines are 1 px in the Lua API: two side by side.
local function thickLine(x1, y1, x2, y2, col)
  lcd.drawLine(x1, y1, x2, y2, SOLID, col)
  lcd.drawLine(x1 + 1, y1, x2 + 1, y2, SOLID, col)
end

-- Fixed mark at 12 o'clock on the letter track (Nose up), tip towards the ring.
local function drawNoseMark(cx, cy, tr, col)
  local h = math.max(3, math.floor(fontH() * 0.4))
  local w = math.max(2, math.floor(h * 0.6))
  local y = cy - tr
  fillTri(cx - w, y - h, cx + w, y - h, cx, y + h, col)
end

-- Ring with ticks and letters turned by rotDeg (Nose up: -course). skipAng: a
-- letter or tick the H badge (or the nose mark) would touch there is left out.
-- Returns the letter radius.
function C.ring(cx, cy, R, rotDeg, skipAng, compact, northUp, col)
  local rw = C.bandWidth(R)
  drawBand(cx, cy, R, rw, col.track)
  local tr = C.letterRadius(R)
  if compact then return tr end
  if not northUp then skipAng = 0; drawNoseMark(cx, cy, tr, col.fg) end
  local minSep = math.deg((textW("W") / 2 + fontH() / 2) / tr)
  local h = fontH()
  for i, letter in ipairs({ "N", "E", "S", "W" }) do
    local a = (i - 1) * 90 + rotDeg
    if not skipAng or angDiff(a, skipAng) > minSep then
      local lx, ly = pt(cx, cy, tr, a)
      text(lx - math.floor(textW(letter) / 2), ly - math.floor(h / 2), letter, (i == 1) and col.fg or col.muted)
    end
  end
  if lcd.drawLine then
    for i = 0, 3 do
      local a = 45 + i * 90 + rotDeg
      if not skipAng or angDiff(a, skipAng) > minSep then
        local x1, y1 = pt(cx, cy, R - math.floor(rw / 2), a)
        local x2, y2 = pt(cx, cy, tr - 1, a)
        thickLine(x1, y1, x2, y2, col.track)
      end
    end
  end
  return tr
end

-- Notched arrow: tip, wings and tail notch as in the design (radius r = the tip).
function C.arrow(cx, cy, r, deg, col)
  local tx, ty = pt(cx, cy, r, deg)
  local rx, ry = pt(cx, cy, r * 0.968, deg + 141.7)
  local nx, ny = pt(cx, cy, r * 0.44, deg + 180)
  local lx, ly = pt(cx, cy, r * 0.968, deg - 141.7)
  fillTri(tx, ty, rx, ry, nx, ny, col)
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

-- H badge on the letter track, or (compact) a dot on the band.
local function drawHome(cx, cy, R, tr, bearing, compact, col)
  if not bearing then return end
  local rw = C.bandWidth(R)
  if compact then
    local hx, hy = pt(cx, cy, R, bearing)
    lcd.drawFilledCircle(hx, hy, rw + 1, col.fg)
    return
  end
  local hx, hy = pt(cx, cy, tr, bearing)
  if lcd.drawCircle then lcd.drawCircle(hx, hy, math.floor(fontH() / 2) - 1, col.fg) end
  text(hx - math.floor(textW("H") / 2), hy - math.floor(fontH() / 2), "H", col.fg)
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
    C.arrow(cx, cy, r, d.course, col.fg)
    drawHome(cx, cy, R, tr, d.bearing, compact, col)
  else
    C.ring(cx, cy, R, -d.course, nil, compact, false, col)
    if d.rel then C.arrow(cx, cy, r, d.rel, col.fg) end
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

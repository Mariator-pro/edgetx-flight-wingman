-- =====================================================================
-- horizon.lua  --  Flight Wingman widget: flight page for page style "Horizon".
-- =====================================================================
-- SD card path: /WIDGETS/WINGMAN/horizon.lua
-- Loaded by the widget only while this view is chosen. Draws with the
-- widget's helpers and constants passed in K; K.COLORS and K.U are set per
-- frame.
-- =====================================================================
-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 Mariator-pro
-- =====================================================================

return function(K)
  local compass, textW, fontH, dtext, btext, rtext = K.compass, K.textW, K.fontH, K.dtext, K.btext, K.rtext
  local fmt, fmtMah, fmtAmps, fmtTimer, distText = K.fmt, K.fmtMah, K.fmtAmps, K.fmtTimer, K.distText
  local fillRounded, fillTri, drawHeartbeat = K.fillRounded, K.fillTri, K.drawHeartbeat
  local WARN_COL, CRIT_COL, WARN_RGB, CRIT_RGB, STAGE_COL = K.WARN_COL, K.CRIT_COL, K.WARN_RGB, K.CRIT_RGB, K.STAGE_COL
  local HERO_Y, BASELINE, HEARTBEAT_R, BAR = K.HERO_Y, K.BASELINE, K.HEARTBEAT_R, K.BAR
  local levelCol, smallCol, reserveColor = K.levelCol, K.smallCol, K.reserveColor
  local drawTitle, packTitle, drawStage = K.drawTitle, K.packTitle, K.drawStage
  local modeParts, txLabel, satBarsW, drawSatBars = K.modeParts, K.txLabel, K.satBarsW, K.drawSatBars
  local COLORS, U   -- theme colours and units of this frame

  -- ---------------------------------------------------------------------------
  -- Horizon page (page style "Horizon"): status at the top, live values below.
  -- Top: battery and link with a vertical bar at the outer edge, big value,
  -- caption and side value inside; satellites in the middle. Below: the battery
  -- and link values in rows at the sides, in the middle a large horizon with the
  -- heading band at its top, speed and altitude tapes, roll and pitch at the aircraft
  -- symbol, home direction and distance at its bottom. Design y in the 418 px body.
  -- ---------------------------------------------------------------------------
  local HZ = {
    X0 = 212, X1 = 588,    -- middle: horizon
    TOP = 140, BOTTOM = 412,   -- horizon box
    BAND_H = 46,    -- heading band over the top of the horizon (no ladder numbers)
    BAND_BASE = 22, -- band letter baseline below the top; tape scales from just under it
    BAR_W = 28, BAR_TOP = 44, BAR_BOTTOM = 251,   -- vertical bars at the outer edges
    STAGE_Y = 135, SIDE_CAP_Y = 184, SIDE_Y = 212,   -- stage field top, timer / mode caption and value
    ROW0 = 281, ROW_H = 30,  -- value rows at the sides (baselines)
    SPAN = 100,     -- band: degrees either side of the nose
    HOLD = 10,      -- band: home behind changes edge only this far past 180 deg
    VS_TAU = 30,    -- vertical speed: smoothing time constant in 10 ms ticks (settled in about 1 s)
    PPD  = 3.5,     -- horizon: design px per degree of pitch
    TAPE_W = 52,    -- speed (left) and altitude (right) tape inside the horizon box
    TAPE_PPU = 4,   -- tape: design px per unit (km/h or mph, m or ft); ticks every 5, numbers every 10
    SKY = lcd.RGB(47, 110, 168), GROUND = lcd.RGB(122, 82, 48),
    PILL = lcd.RGB(18, 20, 18), PILL_OPACITY = 4,   -- dark backing for numbers on sky or ground
    WHITE = lcd.RGB(255, 255, 255), GREY = lcd.RGB(150, 150, 150),   -- text on the dark backings, any theme
    NAMES = { [0] = "N", [45] = "NE", [90] = "E", [135] = "SE", [180] = "S", [225] = "SW", [270] = "W", [315] = "NW" },
    LABEL_COL = { warn = WARN_COL, crit = CRIT_COL },
  }

  -- Heading band over x, y, w in white as the pitch ladder, without a line: letters
  -- every 45 deg and ticks between, moving with the course; in the middle the course
  -- in a box, the house at rel (held at the edge beyond SPAN). No course: nothing.
  function HZ.band(L, x, y, w, course, rel)
    local mid, base, f = x + math.floor(w / 2), y + L.s(HZ.BAND_BASE), L.f.cap
    local ppd = w / (2 * HZ.SPAN)
    if not course then return end
    local ht = string.format("%d", math.floor(course + 0.5) % 360)
    local hw = textW(ht, f)
    local bw = math.floor(hw / 2) + L.s(6)
    for k = math.ceil((course - HZ.SPAN) / 22.5), math.floor((course + HZ.SPAN) / 22.5) do
      local px = mid + math.floor((k * 22.5 - course) * ppd + 0.5)
      local name = (k % 2 == 0) and HZ.NAMES[(k * 45 / 2) % 360]
      local tw = name and textW(name, f) or L.s(2)
      -- inside the band and clear of the course box
      if px - tw / 2 >= x and px + tw / 2 <= x + w and math.abs(px - mid) >= bw + tw / 2 + L.s(2) then
        if name then btext(px - math.floor(tw / 2), base, name, HZ.WHITE, f)
        else lcd.drawFilledRectangle(px - 1, base - L.s(12), L.s(2), L.s(10), HZ.WHITE) end
      end
    end
    HZ.round(mid - bw, y + L.s(3), 2 * bw, L.s(26), L.s(4), HZ.PILL)
    btext(mid - math.floor(hw / 2), base, ht, HZ.WHITE, f)
    local hx, hy, hs = HZ.housePos(L, x, y, w, course, rel)
    if hx then HZ.house(hx, hy, hs) end
  end

  -- Band house: roof tip x, y and half width, nil without course or home direction.
  function HZ.housePos(L, x, y, w, course, rel)
    if not (course and rel) then return nil end
    local hs = L.s(9)
    local hx = x + math.floor(w / 2) + math.floor(math.max(-HZ.SPAN, math.min(HZ.SPAN, rel)) * w / (2 * HZ.SPAN) + 0.5)
    return math.max(x + hs, math.min(x + w - hs, hx)), y + L.s(HZ.BAND_BASE + 6), hs
  end

  -- House (roof tip at x, y, roof half width s): the compass house in the warning yellow, door as the pill.
  function HZ.house(x, y, s)
    local r = s / 0.85
    compass.house(x, y + math.floor(r * 0.75), r, WARN_COL, HZ.PILL)
  end

  -- Polygon (list of {x, y}) cut to the side where (q - p) . n >= 0. Returns the
  -- polygon and the cut points (the horizon line's ends inside the box).
  function HZ.clip(poly, px, py, nx, ny)
    local out, cut = {}, {}
    for i = 1, #poly do
      local a, b = poly[i], poly[i % #poly + 1]
      local da = (a[1] - px) * nx + (a[2] - py) * ny
      local db = (b[1] - px) * nx + (b[2] - py) * ny
      if da >= 0 then out[#out + 1] = a end
      if (da >= 0) ~= (db >= 0) then
        local t = da / (da - db)
        local q = { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t }
        out[#out + 1], cut[#cut + 1] = q, q
      end
    end
    return out, cut
  end

  -- Rounded rectangle that may be translucent (op): no part is drawn twice, so the
  -- corners are not darker than the middle. Corners as the horizon box (radius r);
  -- side "left" or "right" rounds only that side.
  function HZ.round(x, y, w, h, r, col, op, side)
    local rl, rr = (side ~= "right") and r or 0, (side ~= "left") and r or 0
    lcd.drawFilledRectangle(x + rl, y, w - rl - rr, h, col, op)
    for i = 0, r - 1 do
      local d = r - i - 0.5   -- distance at the column's middle: covers lcd.drawFilledCircle's edge pixels
      local inset = math.floor(r - math.sqrt(r * r - d * d))
      if rl > 0 then lcd.drawFilledRectangle(x + i, y + inset, 1, h - 2 * inset, col, op) end
      if rr > 0 then lcd.drawFilledRectangle(x + w - 1 - i, y + inset, 1, h - 2 * inset, col, op) end
    end
  end

  -- Text on a dark backing, centred on cx with its top at y; wide extra px left
  -- of the text (room for an icon), tail (optional) after it in tailCol. Returns
  -- the backing's left edge.
  function HZ.pill(L, cx, y, text, col, wide, tail, tailCol)
    local f, pad = L.f.cap, L.s(5)
    wide, tail = wide or 0, tail or ""
    local tw = textW(text, f) + textW(tail, f) + wide
    local x = cx - math.floor(tw / 2)
    HZ.round(x - pad, y, tw + 2 * pad, fontH(f), L.s(4), HZ.PILL, HZ.PILL_OPACITY)
    dtext(x + wide, y, text, col, f)
    if tail ~= "" then dtext(x + wide + textW(text, f), y, tail, tailCol or col, f) end
    return x
  end

  -- Horizon in the box x, y, w, h: sky, ground cut along the horizon (rolled by
  -- roll, moved down by pitch), pitch lines at 10 and 20 deg with their numbers, the
  -- fixed aircraft symbol, roll left of it and pitch below (the last values: how
  -- fresh depends on the telemetry ratio).
  function HZ.attitude(L, x, y, w, h, g, clear)
    local cx, cy = x + math.floor(w / 2), y + math.floor(h / 2)
    local roll, pitch, rr = g.roll, g.pitch, L.s(4)   -- corner radius as the bars
    local a, ppd = math.rad(roll), HZ.PPD * L.k
    local dx, dy = math.cos(a), -math.sin(a)   -- along the horizon (right side up in a right bank)
    local nx, ny = -dy, dx                      -- towards the ground
    local function r(v) return math.floor(v + 0.5) end
    fillRounded(x, y, w, h, rr, HZ.SKY)
    -- Ground cut to the box with chamfered corners (within a px of the rounding), down to
    -- the last row and column (no sky line under it).
    local x2, y2 = x + w - 1, y + h - 1
    local ground, cut = HZ.clip({ { x + rr, y }, { x2 - rr, y }, { x2, y + rr }, { x2, y2 - rr },
                                  { x2 - rr, y2 }, { x + rr, y2 }, { x, y2 - rr }, { x, y + rr } },
                                cx + nx * pitch * ppd, cy + ny * pitch * ppd, nx, ny)
    for i = 2, #ground - 1 do
      fillTri(r(ground[1][1]), r(ground[1][2]), r(ground[i][1]), r(ground[i][2]), r(ground[i + 1][1]), r(ground[i + 1][2]), HZ.GROUND)
    end
    -- corners wholly on the ground side with the same circles as the sky's rounding, so
    -- no sky pixel stays between the chamfer and the arc
    local hx, hy = cx + nx * pitch * ppd, cy + ny * pitch * ppd
    for _, c in ipairs({ { x + rr, y + rr }, { x + w - rr - 1, y + rr }, { x + rr, y + h - rr - 1 }, { x + w - rr - 1, y + h - rr - 1 } }) do
      if (c[1] - hx) * nx + (c[2] - hy) * ny >= rr then lcd.drawFilledCircle(c[1], c[2], rr, HZ.GROUND) end
    end
    if #cut == 2 then   -- two px wide; the second px stays inside the box
      local ax, ay, bx, by = r(cut[1][1]), r(cut[1][2]), r(cut[2][1]), r(cut[2][2])
      lcd.drawLine(ax, ay, bx, by, SOLID, HZ.WHITE)
      lcd.drawLine(math.min(ax + 1, x2), ay, math.min(bx + 1, x2), by, SOLID, HZ.WHITE)
    end
    -- roll left of the aircraft symbol, pitch below it; ladder numbers keep clear of
    -- both, of the band and status above clear and of the home line at the bottom
    local t, wing, gap = L.s(3), L.s(34), L.s(12)
    local cf, ch, pad = L.f.cap, fontH(L.f.cap), L.s(5)
    local rt, pt = string.format("%d\194\176", r(roll)), string.format("%+d\194\176", r(pitch))
    local rcx = cx - wing - L.s(14) - math.floor(textW(rt, cf) / 2)
    local pills = { { rcx, cy - math.floor(ch / 2), rt }, { cx, cy + L.s(14), pt } }
    local function free(x0, y0, x1, y1)
      if y0 < clear or y1 > y + h - ch - L.s(10) then return false end
      for _, p in ipairs(pills) do
        local hw = math.floor(textW(p[3], cf) / 2) + pad
        if x0 < p[1] + hw and x1 > p[1] - hw and y0 < p[2] + ch and y1 > p[2] then return false end
      end
      return true
    end
    local f, fh = L.f.label, fontH(L.f.label)
    for _, d in ipairs({ -20, -10, 10, 20 }) do
      local qx, qy = cx + nx * (pitch - d) * ppd, cy + ny * (pitch - d) * ppd
      local hw = L.s(math.abs(d) == 10 and 14 or 24)
      local x1, y1, x2, y2 = r(qx - dx * hw), r(qy - dy * hw), r(qx + dx * hw), r(qy + dy * hw)
      local tx, ty = r(qx + dx * (hw + L.s(10))), r(qy + dy * (hw + L.s(10)))
      if math.min(x1, x2, tx - L.s(10)) > x and math.max(x1, x2, tx + L.s(10)) < x + w
         and math.min(y1, y2, ty - fh) > y and math.max(y1, y2, ty + fh) < y + h then
        lcd.drawLine(x1, y1, x2, y2, SOLID, HZ.WHITE)
        local n = tostring(math.abs(d))
        local nx0, ny0 = tx - math.floor(textW(n, f) / 2), ty - math.floor(fh / 2)
        if free(nx0, ny0, nx0 + textW(n, f), ny0 + fh) then dtext(nx0, ny0, n, HZ.WHITE, f) end
      end
    end
    lcd.drawFilledRectangle(cx - wing, cy - 1, wing - gap, t, WARN_COL)
    lcd.drawFilledRectangle(cx + gap, cy - 1, wing - gap, t, WARN_COL)
    lcd.drawFilledRectangle(cx - gap - 1, cy - 1, t, L.s(8), WARN_COL)
    lcd.drawFilledRectangle(cx + gap - t + 1, cy - 1, t, L.s(8), WARN_COL)
    lcd.drawFilledCircle(cx, cy, L.s(3), WARN_COL)
    for _, p in ipairs(pills) do HZ.pill(L, p[1], p[2], p[3], WARN_COL) end
    return true
  end

  -- Tape over the box edge x, y, w, h (right: the altitude tape on the right edge), the
  -- name centred in the bottom row (as the home line), no unit: the scale between top0
  -- (under the band letters) and the name moves with v, marks under the band's house
  -- (hide = { x0, y0, x1, y1 }) and below px under the value box left out, ticks on the outer side and the numbers
  -- inside them, v in a box across the tape at the middle (in vcol, default white).
  -- lo: no scale below it (speed). No v: "--".
  function HZ.tape(L, x, y, w, h, v, right, name, lo, vcol, top0, hide, below)
    local f, sf, rr = L.f.cap, L.f.cap, L.s(4)
    local fh, sh, cy, ppu = fontH(f), fontH(sf), y + math.floor(h / 2), HZ.TAPE_PPU * L.k
    HZ.round(x, y, w, h, rr, HZ.PILL, HZ.PILL_OPACITY, right and "right" or "left")   -- outer corners as the box
    local ny = y + h - fh - L.s(8)
    dtext(x + math.floor((w - textW(name, f)) / 2), ny, name, HZ.WHITE, f)
    if v then
      local top, bottom = top0 + math.floor(sh / 2), ny - L.s(2) - math.ceil(sh / 2)
      for k = math.ceil((v - h / ppu / 2) / 5), math.floor((v + h / ppu / 2) / 5) do
        local py = cy - math.floor((k * 5 - v) * ppu + 0.5)
        local hidden = hide and hide[1] < x + w and hide[3] > x and py + sh / 2 > hide[2] and py - sh / 2 < hide[4]
        local clear = py < cy - fh or py > cy + fh + (below or 0)   -- clear of the value box
        if py >= top and py <= bottom and (not lo or k * 5 >= lo) and clear and not hidden then
          local len = L.s(k % 2 == 0 and 8 or 4)
          lcd.drawFilledRectangle(right and x + w - len or x, py, len, L.s(2), HZ.GREY)
          if k % 2 == 0 then
            local t = tostring(k * 5)
            local tx = right and x + w - len - L.s(3) - textW(t, sf) or x + len + L.s(3)
            dtext(tx, py - math.floor(sh / 2), t, HZ.GREY, sf)
          end
        end
      end
    end
    local bh = fh + L.s(6)
    HZ.round(x, cy - math.floor(bh / 2), w, bh, rr, HZ.PILL)
    local t = v and tostring(math.floor(v + 0.5)) or "--"
    dtext(x + math.floor((w - textW(t, f)) / 2), cy - math.floor(fh / 2), t, v and vcol or HZ.WHITE, f)
  end

  -- Vertical speed at the altitude tape x, y, w, h: a bar on its horizon side from the
  -- middle, up in white when climbing, down in yellow when sinking (full at 5 m/s or
  -- 15 ft/s), and the value in the sensor's unit under the altitude box.
  function HZ.vario(L, x, y, w, h, vs)
    local f, cy = L.f.cap, y + math.floor(h / 2)
    local fh, bw = fontH(f), L.s(5)
    local len = math.floor(math.min(U.vsFull, math.abs(vs)) / U.vsFull * (h / 2 - fh - L.s(14)) + 0.5)
    if len > 0 then
      lcd.drawFilledRectangle(x - bw, vs > 0 and cy - len or cy, bw, len, vs > 0 and HZ.WHITE or WARN_COL)
    end
    local t = (math.abs(vs) < 0.05) and "0.0" or string.format("%+.1f", vs)
    local ny = cy + math.floor(fh / 2) + L.s(6)
    HZ.round(x, ny, w, fh, L.s(4), HZ.PILL)
    dtext(x + math.floor((w - textW(t, f)) / 2), ny, t, HZ.WHITE, f)
  end

  -- Vertical bar from the bottom: track, then a fill of h px in col from the bottom.
  function HZ.vfill(x, bottom, w, h, r, col)
    if h <= 0 then return end
    if h >= 2 * r then fillRounded(x, bottom - h, w, h, r, col)
    else lcd.drawFilledRectangle(x + r, bottom - h, w - 2 * r, h, col) end
  end

  -- Big value with its unit and caption; right-aligned at x when right.
  function HZ.hero(L, x, right, num, unit, col, cap, keep)
    local hf, base = L.hero, L.y(HERO_Y)
    if num == "--" and not keep then col = COLORS.fg end
    local gap = L.s(6)
    local w = textW(num, hf) + gap + textW(unit, L.f.unit)
    local x0 = right and x - w or x
    btext(x0, base, num, col, hf, true)
    btext(x0 + textW(num, hf) + gap, base, unit, col, L.f.unit)
    if right then rtext(x, L.y(HERO_Y + 29), cap, COLORS.muted, L.f.cap)
    else btext(x, L.y(HERO_Y + 29), cap, COLORS.muted, L.f.cap) end
  end

  -- Caption over value (timer, mode) below the stage field; on small screens moved
  -- down so the caption clears the field.
  function HZ.side(L, x, right, cap, value, col)
    local put = right and rtext or btext
    local cy = math.max(L.y(HZ.SIDE_CAP_Y), L.y(HZ.STAGE_Y) + fontH(L.f.stage) + L.s(6)
                        + math.floor(fontH(L.f.label) * BASELINE + 0.5))
    put(x, cy, cap, COLORS.muted, L.f.label)
    put(x, cy + L.y(HZ.SIDE_Y) - L.y(HZ.SIDE_CAP_Y), value or "--", col or COLORS.fg, L.f.side)
  end

  -- Value rows: label left at x, value right-aligned at right. Shorter labels
  -- (row[5], row[6]) stand in when the long one does not fit; draw (optional)
  -- draws the value itself right-aligned: draw(L, right, baseline y, value).
  function HZ.rows(L, x, right, rows)
    for i, row in ipairs(rows) do
      local y = L.y(HZ.ROW0 + (i - 1) * HZ.ROW_H)
      local label, value = row[1], row[2]
      local vw = row[4] and row[4](L, nil, nil, value) or textW(value, L.f.value)
      for k = 5, 6 do
        if row[k] and x + textW(label, L.f.label) + L.s(8) + vw > right then label = row[k] end
      end
      btext(x, y, label, COLORS.muted, L.f.label)
      if row[4] then row[4](L, right, y, value) else rtext(right, y, value, row[3] or COLORS.fg, L.f.value) end
    end
  end

  -- RSSI of both antennas right-aligned at right, the inactive one grey; without
  -- right only the width.
  function HZ.rssi(L, right, y, l)
    local f = L.f.value
    local parts = l.rss2 and { { fmt("%d", l.rss1), 1 }, { " / ", sep = true }, { fmt("%d", l.rss2), 2 } } or { { fmt("%d", l.rssi) } }
    local w = 0
    for _, p in ipairs(parts) do w = w + textW(p[1], f) end
    if not right then return w end
    local x = right - w
    for _, p in ipairs(parts) do
      -- the separator in text colour as in drawRssi
      local col = p.sep and COLORS.fg or (p[2] and l.ant and l.ant ~= p[2]) and COLORS.muted or smallCol(l.rssiLevel)
      btext(x, y, p[1], col, f)
      x = x + textW(p[1], f)
    end
  end

  function HZ.battery(L, z, b, sideCap, sideValue, sideCol)
    local x, bw, r = L.x(18), L.s(HZ.BAR_W), L.s(6)
    local top, bottom = L.y(HZ.BAR_TOP), L.y(HZ.BAR_BOTTOM)
    local stage = b.level or 0
    local col = levelCol(stage)
    drawTitle(L, x, packTitle(L, L.x(HZ.X0) - x, b.name, b.nameShort))
    if not BAR.drawStyled(L, x, top, bw, bottom - top, true, 1, b.pct, 100, col, col,
                          { { b.warn, WARN_RGB }, { b.crit, CRIT_RGB } }) then
      fillRounded(x, top, bw, bottom - top, r, COLORS.track)
      HZ.vfill(x, bottom, bw, math.floor((bottom - top) * math.max(0, math.min(100, b.pct or 0)) / 100), r, col)
      for _, m in ipairs({ { b.warn, WARN_COL }, { b.crit, CRIT_COL } }) do
        lcd.drawFilledRectangle(x - L.s(4), bottom - math.floor((bottom - top) * m[1] / 100) - 1, bw + L.s(8), L.s(3), m[2])
      end
    end
    local tx = x + bw + L.s(14)
    HZ.hero(L, tx, false, fmt("%d", b.pct), "%", col, "REMAINING")
    if sideValue then HZ.side(L, tx, false, sideCap, sideValue, sideCol) end   -- none while Timer 1 is off
    if b.pct then drawStage(L, tx, false, stage, HZ.STAGE_Y) end
    local hot = smallCol(b.vLevel)
    HZ.rows(L, x, L.x(HZ.X0) - L.x(26), {
      { "PACK", fmt("%.1f V", b.volt), hot },
      { "PER CELL", fmt("%.2f V", b.cell), hot },
      { "LEFT", fmtMah(b.left), smallCol(b.level) },
      { "USED", fmtMah(b.used) },
      { "CURRENT", fmtAmps(b.amps) },
    })
  end

  -- Link: range bar on the right edge filling upwards (lightened end with dynamic
  -- power below the maximum), the stage as a field below the mode.
  function HZ.link(L, z, l, linkUp)
    local right, bw, r = z.w - L.x(18), L.s(HZ.BAR_W), L.s(6)
    local x, top, bottom = right - bw, L.y(HZ.BAR_TOP), L.y(HZ.BAR_BOTTOM)
    local col = STAGE_COL[l.stage] or COLORS.accent
    -- heartbeat in the top right corner while packets arrive, the title right-aligned left of it
    local s, title = L.s(11), l.modLine or "--"
    local tx = right - 2 * HEARTBEAT_R - L.s(10) - textW(title, L.f.title) - s - L.s(8)
    drawTitle(L, tx, title)
    if linkUp then drawHeartbeat(right - HEARTBEAT_R, L.y(21) + math.floor(s / 2)) end
    local unknown = l.sensLimit == 0
    local h = bottom - top
    local pct = unknown and 100 or math.max(0, math.min(100, l.range or 0))
    local solid = (l.reserve and not unknown) and math.max(0, pct - l.reserve) or pct
    if not BAR.drawStyled(L, x, top, bw, h, true, -1, pct, solid, col, reserveColor(l.stage),
                          { { not unknown and l.warn, WARN_RGB } }, true) then
      fillRounded(x, top, bw, h, r, COLORS.track)
      local fh, sh = math.floor(h * pct / 100), math.floor(h * solid / 100)
      if fh > sh then HZ.vfill(x, bottom, bw, fh, r, reserveColor(l.stage)) end
      HZ.vfill(x, bottom, bw, sh, r, col)
      if l.warn and not unknown then
        lcd.drawFilledRectangle(x - L.s(4), bottom - math.floor(h * l.warn / 100) - 1, bw + L.s(8), L.s(3), WARN_COL)
      end
    end
    local inner = x - L.s(14)
    local modeCap, modeVal = modeParts(l.mode)
    HZ.hero(L, inner, true, fmt("%d", l.range), "%", col, "RANGELIMIT", unknown)
    HZ.side(L, inner, true, modeCap, modeVal)
    drawStage(L, inner, true, l.stage, HZ.STAGE_Y)
    HZ.rows(L, L.x(HZ.X1) + L.x(26), right, {
      { "LQ", fmt("%d %%", l.lq), smallCol(l.lqStage) },
      { "RSSI dBm", l, nil, HZ.rssi, "RSSI" },
      { "RSNR", fmt("%d dB", l.rsnr) },
      { txLabel(l), fmt("%d mW", l.tpwr), nil, nil, l.pwrTag and ("TX PWR (" .. l.pwrTag .. ")") or "TX PWR",
        l.pwrTag and ("TX (" .. l.pwrTag .. ")") },   -- the tag stays, "PWR" goes when 1000 mW needs the room
    })
  end

  -- Satellites centred over the middle: number, caption and the bars (as on the
  -- compass page) as one group.
  function HZ.sats(L, g)
    local satCol = levelCol(g.satsLevel)
    local num, bw, bg = fmt("%d", g.sats), L.s(8), L.s(3)
    local gw = textW(num, L.hero) + L.s(14) + satBarsW(g, bw, bg)
    local x = L.x(400) - math.floor(gw / 2)
    drawTitle(L, x, "GPS")
    btext(x, L.y(HERO_Y), num, satCol, L.hero)
    btext(x, L.y(HERO_Y + 29), "SATS", COLORS.muted, L.f.cap)
    drawSatBars(L, x + textW(num, L.hero) + L.s(14), g, bw, bg, satCol)
  end

  -- Middle: horizon with tapes, the heading band over its full width at the top and at its bottom home
  -- direction with distance, or the GPS status without a home hint (before home, at
  -- home). FC alerts stay in the header's mode field.
  function HZ.middle(L, g, ctx)
    local x, w = L.x(HZ.X0), L.x(HZ.X1) - L.x(HZ.X0)
    local sm = ctx.smooth or {}
    ctx.smooth = sm
    local lb
    if compass then
      sm.course = compass.smooth(sm.course, g.course)
      sm.rel    = compass.smooth(sm.rel, g.rel)
      lb = select(2, compass.label({ gpsState = g.gpsState, noHome = g.noHome, atHome = g.atHome,
                                     courseValid = g.courseValid, estimated = g.estimated, rel = sm.rel,
                                     sector = g.sector, bearing = g.bearing },
                                   { ahead = g.ahead or 15, behind = g.behind or 165 }))
    end
    local top, h, tw = L.y(HZ.TOP), L.y(HZ.BOTTOM) - L.y(HZ.TOP), L.s(HZ.TAPE_W)
    local cx, fh = x + math.floor(w / 2), fontH(L.f.cap)
    local rel = lb and lb.cap and sm.rel or nil
    if rel then   -- home about behind: the house stays at its edge until home is clearly on the other side
      if sm.side and rel * sm.side < 0 and math.abs(rel) > 180 - HZ.HOLD then rel = sm.side * 180 end
      sm.side = (rel >= 0) and 1 or -1
    end
    -- vertical speed smoothed over time (the sensor steps and arrives irregularly)
    local now = getTime()
    sm.vs = g.vspd and (sm.vs and sm.vs + (g.vspd - sm.vs) * math.min(1, (now - sm.vsAt) / HZ.VS_TAU) or g.vspd)
    sm.vsAt = now
    -- horizon only with pitch and roll (the cores hold the last values, nil: no sensor)
    if g.roll and g.pitch then HZ.attitude(L, x, top, w, h, g, top + L.s(HZ.BAND_H) + L.s(4))
    else fillRounded(x, top, w, h, L.s(4), COLORS.track) end
    local hx, hy, hs = HZ.housePos(L, x, top, w, sm.course, rel)
    local hide = hx and { hx - hs - L.s(2), hy, hx + hs + L.s(2), hy + 2 * hs }
    local top0 = top + L.s(HZ.BAND_BASE + 4)
    HZ.tape(L, x, top, tw, h, g.gspd, false, "SPD", 0, nil, top0, hide)   -- tapes always, "--" without a value
    HZ.tape(L, x + w - tw, top, tw, h, g.alt, true, "ALT", nil, STAGE_COL[g.altLevel], top0, hide,
            sm.vs and fh + L.s(3))   -- red over Max altitude; room for the vertical speed
    if sm.vs then HZ.vario(L, x + w - tw, top, tw, h, sm.vs) end
    HZ.band(L, x, top, w, sm.course, rel)
    local py = top + h - fh - L.s(8)
    if lb and not lb.cap then
      local t = (textW(lb.text, L.f.cap) <= w - 2 * tw) and lb.text or lb.short
      HZ.pill(L, cx, py, t, HZ.LABEL_COL[lb.col] or (lb.col == "muted" and HZ.GREY) or HZ.WHITE)
      return
    end
    -- home: house, direction (with a heading) and distance
    local hs = math.floor(fh * 0.4)
    local text = lb and (lb.text .. "  ") or ""
    local dist = distText(g.dist)   -- km from 1000 m, mi from 5280 ft
    local px = HZ.pill(L, cx, py, text, HZ.WHITE, 2 * hs + L.s(8), dist, STAGE_COL[g.distLevel])   -- distance red over Max distance
    HZ.house(px + hs, py + math.floor((fh - 1.8 * hs) / 2), hs)
  end

  function HZ.page(ctx, L, z, v)
    if not v.gps then return false end   -- the widget draws its own page
    COLORS, U = K.COLORS, K.U
    L.hero = L.f.hero   -- big values as on the compass page
    local w = ctx.w
    local on = w.on or {}
    if v.batt and on.lipo ~= false then
      if w.flightTime == "timeleft" then
        HZ.battery(L, z, v.batt, "TIME LEFT", v.batt.timeLeft)
      else
        HZ.battery(L, z, v.batt, "TIMER", w.timerS and fmtTimer(w.timerS), smallCol(w.timerLevel))
      end
    elseif v.noPack and on.lipo ~= false then
      local x = L.x(18)
      K.drawNoPack(L, x, L.x(HZ.X0) - L.x(26) - x)
    end
    HZ.sats(L, v.gps)
    HZ.middle(L, v.gps, ctx)
    if v.link and on.link ~= false then HZ.link(L, z, v.link, w.linkUp) end
  end

  return { flight = HZ.page }
end

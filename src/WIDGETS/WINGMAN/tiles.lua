-- =====================================================================
-- tiles.lua  --  Flight Wingman widget: preflight and flight page for
-- page style "Tiles".
-- =====================================================================
-- SD card path: /WIDGETS/WINGMAN/tiles.lua
-- Loaded by the widget only while this style is chosen. Draws with the
-- widget's helpers and constants passed in K; K.COLORS is set per frame.
--
-- Three tall tiles for a glance: battery left, GPS in the middle, link
-- right. A tile fills from the bottom with its value, turns yellow at a
-- warning and all red when critical; the bar style of the settings tool
-- shapes the fill (solid with marks at the edges, 20 blocks, or a zone
-- strip with a pointer).
-- =====================================================================
-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 Mariator-pro
-- =====================================================================

return function(K)
  local core, compass, textW, fontH, dtext, btext = K.core, K.compass, K.textW, K.fontH, K.dtext, K.btext
  local fmt, fmtMah, distText, cutText, mixRGB = K.fmt, K.fmtMah, K.distText, K.cutText, K.mixRGB
  local fillRounded, fillTri = K.fillRounded, K.fillTri
  local WARN_COL, CRIT_COL, WARN_RGB, CRIT_RGB, DARK_TEXT = K.WARN_COL, K.CRIT_COL, K.WARN_RGB, K.CRIT_RGB, K.DARK_TEXT
  local BASELINE, CAP_TOP, CAP_H, BAR = K.BASELINE, K.CAP_TOP, K.CAP_H, K.BAR
  local drawPackList, secsLeft = K.drawPackList, K.secsLeft
  local COLORS   -- theme colours of this frame

  -- Design px in the 800 x 480 layout (y in the 418 px body under the header).
  local T = {
    MARGIN = 12, GAP = 10, RADIUS = 14,
    TOP = 12, FLIGHT_BOTTOM = 406, PRE_BOTTOM = 310,   -- tiles
    READY_TOP = 322, READY_BOTTOM = 406,               -- ready field under the preflight tiles
    FILL = 0.22,        -- fill: stage colour mixed into the tile by this share
    N = 20, SEG_INSET = 10, SEG_GAP = 4, SEG_LIT = 0.34, SEG_ZONE = 0.16, SEG_OFF = 0.5,   -- bar style Segments
    STRIP_W = 8, STRIP_INSET = 16,   -- bar style Zones: strip at the tile's outer edge
    MARK_W = 22, MARK_H = 4,         -- bar style Solid: threshold marks at both edges
    GPS_SATS_SHARE = 80,             -- preflight GPS fill: satellites up to this %, a stable fix fills the rest
    WHITE = lcd.RGB(255, 255, 255),
    MODULES = { "lipo", "gps", "link" },
    BIG = XXLSIZE or DBLSIZE,
  }

  -- Rows ya (inclusive) to yb (exclusive) of the rounded rectangle x, y, w, h with
  -- corner radius r: no pixel twice, the corner rows one by one.
  local function band(x, y, w, h, r, ya, yb, col)
    ya, yb = math.max(ya, y), math.min(yb, y + h)
    if yb <= ya then return end
    local s0, s1 = math.max(ya, y + r), math.min(yb, y + h - r)
    if s1 > s0 then lcd.drawFilledRectangle(x, s0, w, s1 - s0, col) end
    local function row(yy, d)
      local inset = math.floor(r - math.sqrt(r * r - d * d) + 0.5)
      lcd.drawFilledRectangle(x + inset, yy, w - 2 * inset, 1, col)
    end
    for yy = ya, math.min(yb, y + r) - 1 do row(yy, y + r - yy - 0.5) end
    for yy = math.max(ya, y + h - r), yb - 1 do row(yy, yy - (y + h - r) + 0.5) end
  end

  -- Colour of a level as { r, g, b }: ok, warning or critical.
  local function levelRGB(level)
    return (level == 2 and CRIT_RGB) or (level == 1 and WARN_RGB) or COLORS.rgb.ok
  end

  -- Threshold zone a value lies in: the mark's { r, g, b }, nil outside. Low marks
  -- (battery, LQ): below the mark, the lowest one wins; high (range): from the mark up.
  local function zoneRGB(marks, high, pct)
    local z, zp
    for _, m in ipairs(marks) do
      local p = m[1]
      if p and ((high and pct >= p) or (not high and pct < p)) and (not zp or (high and p > zp) or (not high and p < zp)) then
        z, zp = m[2], p
      end
    end
    return z
  end

  -- Fill of a tile up to pct in the bar style; marks { pct, rgb }, outer: the
  -- tile's edge at the screen side ("left" / "right") for the zone strip.
  local function drawFill(L, x, y, w, h, r, pct, rgb, marks, high, outer)
    local box = COLORS.rgb.box
    pct = math.max(0, math.min(100, pct))
    local style = BAR.style
    if style == "segments" then
      local inset, gap = L.s(T.SEG_INSET), math.max(1, L.s(T.SEG_GAP))
      local bh = (h - 2 * inset - (T.N - 1) * gap) / T.N
      local lit, off = mixRGB(box, rgb, T.SEG_LIT), mixRGB(box, COLORS.rgb.track, T.SEG_OFF)
      for i = 0, T.N - 1 do
        local mid = (i + 0.5) * 100 / T.N
        local by = y + h - inset - math.floor((i + 1) * bh + i * gap + 0.5)
        local col = lit
        if mid > pct then
          local z = zoneRGB(marks, high, mid)
          col = z and mixRGB(box, z, T.SEG_ZONE) or off
        end
        lcd.drawFilledRectangle(x + inset, by, w - 2 * inset, math.max(1, math.floor(bh + 0.5)), col)
      end
      return
    end
    local level = y + h - math.floor(h * pct / 100 + 0.5)
    local edge = math.max(1, L.s(3))
    band(x, y, w, h, r, level, y + h, mixRGB(box, rgb, T.FILL))
    band(x, y, w, h, r, level, level + edge, lcd.RGB(rgb[1], rgb[2], rgb[3]))
    if style == "zones" then
      local sw, si = L.s(T.STRIP_W), L.s(T.STRIP_INSET)
      local sx, sy, sh = (outer == "right") and x + w - L.s(4) - sw or x + L.s(4), y + si, h - 2 * si
      fillRounded(sx, sy, sw, sh, math.floor(sw / 2), COLORS.track)
      -- each mark's zone runs to the next mark (low: from the one below, high: up to the one above);
      -- on the fill's scale, so the fill's edge, the pointer and the zone borders line up
      local function zy(p) return math.max(sy, math.min(sy + sh, y + h - math.floor(h * p / 100 + 0.5))) end
      for _, m in ipairs(marks) do
        if m[1] then
          local lo, hi = high and m[1] or 0, high and 100 or m[1]
          for _, o in ipairs(marks) do
            if o[1] and not high and o[1] < m[1] and o[1] > lo then lo = o[1] end
            if o[1] and high and o[1] > m[1] and o[1] < hi then hi = o[1] end
          end
          local y0, y1 = zy(hi), zy(lo)
          if y1 > y0 then lcd.drawFilledRectangle(sx, y0, sw, y1 - y0, lcd.RGB(m[2][1], m[2][2], m[2][3])) end
        end
      end
      local py, pw, ph = math.max(sy, math.min(sy + sh, level)), L.s(14), L.s(9)
      if outer == "right" then fillTri(sx - L.s(4), py, sx - L.s(4) - pw, py - ph, sx - L.s(4) - pw, py + ph, COLORS.fg)
      else fillTri(sx + sw + L.s(4), py, sx + sw + L.s(4) + pw, py - ph, sx + sw + L.s(4) + pw, py + ph, COLORS.fg) end
      return
    end
    local mw, mh = L.x(T.MARK_W), math.max(2, L.s(T.MARK_H))
    for _, m in ipairs(marks) do
      if m[1] then
        local my = y + h - math.floor(h * m[1] / 100 + 0.5) - math.floor(mh / 2)
        local col = lcd.RGB(m[2][1], m[2][2], m[2][3])
        band(x, y, mw, h, 0, my, my + mh, col)
        band(x + w - mw, y, mw, h, 0, my, my + mh, col)
      end
    end
  end

  -- One tile. t: title, big (text) or draw(cx, cy, size, col), pct (fill, none
  -- without), level (0, 1, 2; nil: neutral), marks, high, outer, keep (a "--" keeps
  -- the level colour), sub1, sub1Col, sub2, sub2Col (default muted).
  local function drawTile(L, x, y, w, h, t)
    local r = L.s(T.RADIUS)
    local crit = t.level == 2
    band(x, y, w, h, r, y, y + h, crit and CRIT_COL or COLORS.box)
    if t.pct and not crit then drawFill(L, x, y, w, h, r, t.pct, levelRGB(t.level), t.marks or {}, t.high, t.outer) end
    local fg, muted = crit and T.WHITE or COLORS.fg, crit and T.WHITE or COLORS.muted
    local stage = crit and T.WHITE or (t.level == 1 and WARN_COL) or (t.level == 0 and COLORS.ok) or COLORS.fg
    local pad, cx = L.s(20), x + math.floor(w / 2)
    dtext(x + pad, y + L.s(14), cutText(t.title, "", w - 2 * pad, BOLD), muted, BOLD)
    -- two lines at the bottom, the big value centred in the room above them
    local f1, f2 = L.f.stage, L.f.cap
    local base2 = y + h - L.s(24)
    local base1 = base2 - math.max(L.s(32), fontH(f2))
    local top = y + L.s(14) + fontH(BOLD)
    local cy = top + math.floor((base1 - math.floor(fontH(f1) * BASELINE + 0.5) - top) / 2)
    if t.draw then
      t.draw(cx, cy, math.floor(math.min(w - 2 * pad, base1 - fontH(f1) - top) * 0.8), stage)
    else
      local f = (textW(t.big, T.BIG) <= w - 2 * pad) and T.BIG or DBLSIZE
      local fh = fontH(f)
      local col = (t.big == "--" and not t.keep) and fg or stage
      dtext(cx - math.floor(textW(t.big, f) / 2), cy - math.floor(fh * (CAP_TOP + CAP_H / 2) + 0.5), t.big, col, f)
    end
    local function line(base, text, col, f)
      if not text then return end
      text = cutText(text, "", w - 2 * L.s(8), f)
      dtext(cx - math.floor(textW(text, f) / 2), base - math.floor(fontH(f) * BASELINE + 0.5), text, col, f)
    end
    line(base1, t.sub1, crit and T.WHITE or t.sub1Col or fg, f1)
    line(base2, t.sub2, crit and T.WHITE or t.sub2Col or muted, f2)
  end

  -- x and width of the tiles of the modules switched on, by module index (1 battery,
  -- 2 GPS, 3 link); the tiles share the width equally.
  local function places(L, z, on)
    on = on or {}
    local shown = {}
    for i, k in ipairs(T.MODULES) do if on[k] ~= false then shown[#shown + 1] = i end end
    local n, margin, gap, c = #shown, L.x(T.MARGIN), L.x(T.GAP), {}
    local tw = math.floor((z.w - 2 * margin - (n - 1) * gap) / math.max(1, n))
    for j, i in ipairs(shown) do c[i] = { margin + (j - 1) * (tw + gap), tw } end
    return c
  end

  -- Colour of a line whose value has a level of its own: yellow or red, nil when fine.
  local function lineCol(level)
    if level == 2 then return CRIT_COL end
    if level == 1 then return WARN_COL end
  end

  local function batteryMarks(b) return { { b.warn, WARN_RGB }, { b.crit, CRIT_RGB } } end

  -- Home tile: the arrow home relative to the nose; before home a ring, on the
  -- home point the house, without a course the bearing as text.
  local function homeTile(L, g, ctx)
    local sm = ctx.smooth or {}
    ctx.smooth = sm
    local kind, lb = "arrow", { cap = "HOME", text = "--" }
    if compass then
      sm.rel = compass.smooth(sm.rel, g.rel)
      kind, lb = compass.label({ gpsState = g.gpsState, noHome = g.noHome, atHome = g.atHome,
                                 courseValid = g.courseValid, estimated = g.estimated, rel = sm.rel,
                                 sector = g.sector, bearing = g.bearing },
                               { ahead = g.ahead or 15, behind = g.behind or 165 })
    end
    local level = math.max(g.satsLevel or 0, g.distLevel or 0, g.altLevel or 0)
    local sub1Col
    if not lb.cap then   -- GPS Homer's notice in its own colour (NO HOME in red)
      sub1Col = lineCol((lb.col == "crit" and 2) or (lb.col == "warn" and 1) or 0)
    elseif g.distLevel == 1 then
      sub1Col = WARN_COL
    end
    local t = { title = "HOME", level = (level == 2) and 2 or nil,
                sub1 = lb.cap and distText(g.dist) or lb.text, sub1Col = sub1Col,
                sub2 = fmt("%d SATS", g.sats), sub2Col = (g.satsLevel == 1) and WARN_COL or nil }
    if g.altLevel == 2 then t.sub2 = fmt("ALT %d " .. K.U.len, g.alt) end   -- over Max altitude: the reason for the red tile
    local warn = level == 1
    function t.draw(cx, cy, size, col)
      if warn then col = WARN_COL end
      if kind == "arrow" and g.courseValid and sm.rel and compass then
        -- the compass page's notched arrow, its right half shaded towards the tile
        local r = math.floor(size * 0.48)
        local rgb = (level == 2 and { 255, 255, 255 }) or (warn and WARN_RGB) or nil
        local shade = rgb and mixRGB(rgb, level == 2 and CRIT_RGB or COLORS.rgb.box, 0.35) or COLORS.muted
        compass.arrow(cx, cy, r, sm.rel, col, shade)
      elseif kind == "arrow" then   -- no course: sector and bearing
        local f = (textW(lb.text, DBLSIZE) <= size) and DBLSIZE or MIDSIZE
        dtext(cx - math.floor(textW(lb.text, f) / 2), cy - math.floor(fontH(f) / 2), lb.text, col, f)
      elseif compass then
        local R = math.floor(size * 0.4)
        compass.ring(cx, cy, R, 0, nil, true, false, { track = col, fg = col, muted = col })
        if kind == "house" then compass.house(cx, cy, math.floor(R * 0.55), col, level == 2 and CRIT_COL or COLORS.box) end
      end
    end
    return t
  end

  local function flight(ctx, L, z, v)
    COLORS = K.COLORS
    local w = ctx.w
    local c = places(L, z, w.on)
    local y, h = L.y(T.TOP), L.y(T.FLIGHT_BOTTOM) - L.y(T.TOP)
    local b, g, l = v.batt, v.gps, v.link
    if b and c[1] then
      drawTile(L, c[1][1], y, c[1][2], h, {
        title = "BATTERY", big = fmt("%d", b.pct), pct = b.pct or 0, level = b.level or 0,
        marks = batteryMarks(b), outer = "left",
        sub1 = fmt("%.2f V /cell", b.cell), sub1Col = lineCol(b.vLevel), sub2 = fmtMah(b.left) })
    elseif v.packSel and c[1] then   -- disarmed again without a pack: the selection as on the preflight page
      local x, tw, r = c[1][1], c[1][2], L.s(T.RADIUS)
      band(x, y, tw, h, r, y, y + h, COLORS.box)
      drawPackList(L, x + L.s(14), tw - 2 * L.s(14), v.packSel, ctx)
    elseif v.noPack and c[1] then   -- armed without a chosen pack: a warning sign instead of the %
      drawTile(L, c[1][1], y, c[1][2], h, {
        title = "NO PACK", level = 1,
        -- warning sign with "NO BATTERY" / "SELECTED" below it, centred in the room
        draw = function(cx, cy, size)
          local f = L.f.stage
          local tri, gap, lh = math.floor(size * 0.45), L.s(16), fontH(f)
          local top = cy - math.floor((tri + gap + 2 * lh) / 2)
          K.drawWarnSign(cx, top, tri, WARN_COL, DARK_TEXT)
          for i, t in ipairs({ "NO BATTERY", "SELECTED" }) do
            dtext(cx - math.floor(textW(t, f) / 2), top + tri + gap + (i - 1) * lh, t, WARN_COL, f)
          end
        end,
        sub2 = "No battery warnings" })
    end
    if not (v.packSel and c[1]) then ctx.marqueeRow = nil end   -- next selection starts its marquee anew
    if g and c[2] then drawTile(L, c[2][1], y, c[2][2], h, homeTile(L, g, ctx)) end
    if l and c[3] then
      local unknown = l.sensLimit == 0   -- unknown link mode: no range, a warning as on the other pages
      drawTile(L, c[3][1], y, c[3][2], h, {
        title = "RANGELIMIT", big = fmt("%d", l.range), keep = unknown, pct = unknown and 100 or (l.range or 0),
        level = unknown and math.max(1, l.stage or 0) or (l.stage or 0),
        marks = { { not unknown and l.warn, WARN_RGB } }, high = true, outer = "right",
        sub1 = fmt("LQ %d %%", l.lq), sub1Col = lineCol(l.lqStage), sub2 = fmt("%d mW", l.tpwr) .. (l.pwrTag and (" (" .. l.pwrTag .. ")") or "") })
    end
  end

  -- Ready field over the full width: GO / CHECK, the core's line and, while GO
  -- counts down, the time to the flight page with a bar running empty.
  local function drawReady(L, z, st, secs, total)
    local x, y = L.x(T.MARGIN), L.y(T.READY_TOP)
    local w, h = z.w - 2 * x, L.y(T.READY_BOTTOM) - y
    fillRounded(x, y, w, h, L.s(T.RADIUS), (st.ready == "GO") and COLORS.ok or WARN_COL)
    local f, pad = L.f.ready, L.x(28)
    local fh = fontH(f)
    dtext(x + pad, y + math.floor((h - fh * CAP_H) / 2 - fh * CAP_TOP + 0.5), st.ready, DARK_TEXT, f)
    local tx, right = x + pad + textW(st.ready, f) + L.x(22), x + w - pad
    local vf = L.f.value
    local vy = y + math.floor((h - fontH(vf)) / 2)
    if secs then
      local bw, bh = L.x(78), math.max(4, L.s(12))
      local bx, by = right - bw, y + math.floor((h - bh) / 2)
      lcd.drawFilledRectangle(bx, by, bw, bh, DARK_TEXT, 11)
      lcd.drawFilledRectangle(bx, by, math.floor(bw * math.max(0, math.min(1, secs / total)) + 0.5), bh, DARK_TEXT)
      local ct = string.format("Flight page in %d s", secs)
      right = bx - L.x(12) - textW(ct, vf)
      dtext(right, vy, ct, DARK_TEXT, vf)
      right = right - L.x(18)
    end
    if st.line and right > tx then dtext(tx, vy, cutText(st.line, "", right - tx, vf), DARK_TEXT, vf) end
  end

  local function pre(ctx, L, z)
    COLORS = K.COLORS
    local w = ctx.w
    local p, st = w.pre, w.preStatus
    local c = places(L, z, w.on)
    local y, h = L.y(T.TOP), L.y(T.PRE_BOTTOM) - L.y(T.TOP)
    local b, g, l = p.batt, p.gps, p.link
    if b and b.packs and c[1] then   -- pack selection inside the battery tile
      local x, tw, r = c[1][1], c[1][2], L.s(T.RADIUS)
      band(x, y, tw, h, r, y, y + h, COLORS.box)
      drawPackList(L, x + L.s(14), tw - 2 * L.s(14), b, ctx)
    else
      ctx.marqueeRow = nil   -- next selection starts its marquee anew
      if b and c[1] and st.batt then
        drawTile(L, c[1][1], y, c[1][2], h, {
          title = "BATTERY", big = fmt("%d", b.pct), pct = b.pct or 0, level = st.batt.level,
          marks = batteryMarks(b), outer = "left",
          sub1 = fmt("%.2f V /cell", b.cell), sub1Col = lineCol(b.vLevel), sub2 = st.batt.text, sub2Col = K.levelCol(st.batt.level) })
      end
    end
    if g and c[2] and st.gps then
      local pct = 100
      if g.state ~= "ready" then
        pct = math.min(1, (g.sats or 0) / math.max(1, g.minSats or 1)) * T.GPS_SATS_SHARE
      end
      local dop = (g.dopKind or "PDOP") .. " " .. (g.dop and string.format("%.1f", g.dop) or "--")
      -- a DOP that is not good tints the tile yellow, the DOP / fix line takes the worse level
      local dopStage = g.dop and st.dopStage or 0
      local lineLevel = math.max(dopStage, g.fixLevel or 0)
      drawTile(L, c[2][1], y, c[2][2], h, {
        title = "GPS", big = fmt("%d", g.sats), pct = pct, level = math.max(st.gps.level or 0, dopStage > 0 and 1 or 0),
        sub1 = dop .. "  " .. (g.fix or "--"), sub1Col = lineCol(lineLevel),
        sub2 = st.gps.text, sub2Col = K.levelCol(st.gps.level) })
    end
    if l and c[3] and st.link then
      local level = math.max(st.link.level or 0, st.lqLevel or 0)
      drawTile(L, c[3][1], y, c[3][2], h, {
        title = "LINK", big = fmt("%d", l.lq), pct = l.lq or 0, level = level,
        marks = { { l.lqCrit, CRIT_RGB } }, outer = "right",
        sub1 = fmt("RSSI %d dBm", l.rssi), sub1Col = lineCol(l.rssiLevel), sub2 = st.link.text, sub2Col = K.levelCol(st.link.level) })
    end
    local fs = w.fs
    local counting = fs and fs.readySince and w.phase == core.PRE
    drawReady(L, z, st, counting and secsLeft(fs.readySince, core.PRE_HOLD_T), core.PRE_HOLD_T / 1000)
  end

  return { flight = flight, pre = pre }
end

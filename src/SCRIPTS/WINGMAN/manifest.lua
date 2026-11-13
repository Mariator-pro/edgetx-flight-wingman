-- =====================================================================
-- manifest.lua  --  Wingman as seen by the Flight Bag settings tool
-- =====================================================================
-- SD card path: /SCRIPTS/WINGMAN/manifest.lua
-- Loaded only by the settings tool. Fields, resets and files by id; their
-- texts come from lang/<code>.lua (lang: "en" when left out). The module
-- switches per model are on the Models page, the mascot and the flight time
-- on Display; the resets run core functions.
-- =====================================================================
-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 Mariator-pro
-- =====================================================================

return function(core, lang)
  local T = core.texts(lang)
  local man = {
    name    = "Wingman",
    author  = "Mariator-pro",
    license = "GPL-2.0",
    url     = "github.com/Mariator-pro/edgetx-flight-wingman",
    -- ids never change once released: other programs recognise an entry by it
    paths = {
      { id = "core",   path = "/SCRIPTS/WINGMAN/core.lua" },
      { id = "config", path = core.CONFIG_PATH },
      { id = "widget", path = "/WIDGETS/WINGMAN/main.lua" },
    },
    fields = {
      { key = "mascot", page = "display", type = "choice", choices = core.MASCOTS, default = core.MASCOTS[1] },
      { key = "flightTime", page = "display", shared = true, type = "choice",
        choices = core.FLIGHT_TIMES, default = core.FLIGHT_TIMES[1] },
      { key = "gpsView", page = "display", type = "choice", choices = core.GPS_VIEWS, default = core.GPS_VIEWS[1] },
      { key = "barStyle", page = "display", type = "choice", choices = core.BAR_STYLES, default = core.BAR_STYLES[1] },
      { key = "switchPage", page = "display", type = "bool", default = true },
      { key = "language", page = "display", shared = true, type = "choice",
        choices = core.LANGUAGES, default = core.LANGUAGES[1] },
    },

    resets = {
      { id = "settings", run = core.resetSettings },
      { id = "factory",  run = core.factoryReset },
    },
  }

  -- The texts, in the shape the settings tool reads: a file as { label, path },
  -- a field's label, hint (%v: its value) and labels of its choices.
  for _, p in ipairs(man.paths) do p[1], p[2] = T("files", p.id) or p.id, p.path end
  for _, f in ipairs(man.fields) do
    f.label = T("fields", f.key, "label") or f.key
    local hint = T("fields", f.key, "hint")
    if hint then f.hint = string.gsub(hint, "{v}", "%%v") end
    if f.choices then
      f.labels = {}
      for i, c in ipairs(f.choices) do f.labels[i] = T("fields", f.key, "choices", c) or tostring(c) end
    end
  end
  for _, r in ipairs(man.resets) do
    r.label = T("resets", r.id, "label") or r.id
    r.ask, r.desc = T("resets", r.id, "ask"), T("resets", r.id, "desc")
  end
  return man
end

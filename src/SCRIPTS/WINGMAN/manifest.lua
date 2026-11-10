-- =====================================================================
-- manifest.lua  --  Wingman as seen by the Flight Bag settings tool
-- =====================================================================
-- SD card path: /SCRIPTS/WINGMAN/manifest.lua
-- Loaded only by the settings tool. The module switches per model are on
-- the Models page, the mascot and the flight time on Display; the resets run
-- core functions.
-- =====================================================================
-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 Mariator-pro
-- =====================================================================

return function(core)
  return {
    name  = "Wingman",
    url   = "github.com/Mariator-pro/edgetx-flight-wingman",
    paths = {
      { "Core",   "/SCRIPTS/WINGMAN/core.lua" },
      { "Config", core.CONFIG_PATH },
      { "Widget", "/WIDGETS/WINGMAN/main.lua" },
    },
    fields = {
      { key = "mascot", page = "display", label = "Mascot", type = "choice",
        choices = core.MASCOTS, labels = { "Quad", "Scout" }, default = core.MASCOTS[1],
        hint = "Character on the wait page" },
      { key = "flightTime", page = "display", label = "Flight time", shared = true, type = "choice",
        choices = core.FLIGHT_TIMES, labels = { "EdgeTX Timer 1", "Remaining Timer" }, default = core.FLIGHT_TIMES[1],
        hint = "Time shown beside the battery % in flight" },
      { key = "gpsView", page = "display", label = "GPS view", type = "choice",
        choices = core.GPS_VIEWS, labels = { "Compass", "Horizon" }, default = core.GPS_VIEWS[1],
        hint = "Horizon: set Telem Ratio to 1:4 or faster" },
      { key = "barStyle", page = "display", label = "Bar style", type = "choice",
        choices = core.BAR_STYLES, labels = { "Solid", "Segments", "Zones" }, default = core.BAR_STYLES[1],
        hint = "Battery and link bars: plain, blocks or zones" },
      { key = "switchPage", page = "display", label = "Switch page", type = "bool", default = true,
        hint = "Switches and FC modes on the wait page (aileron right)" },
    },

    -- id never changes once released: other programs recognise a reset by it, not by its label
    resets = {
      { id = "settings", label = "Reset settings", ask = "Reset Wingman settings to factory defaults? Models and FC modes stay.",
        run = core.resetSettings },
      { id = "factory",  label = "Factory reset", ask = "Reset Wingman to factory settings? All models, FC modes and settings are erased.",
        run = core.factoryReset },
    },
  }
end

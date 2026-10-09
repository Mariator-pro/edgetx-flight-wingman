-- =====================================================================
-- manifest.lua  --  Wingman as seen by the Flight Bag settings tool
-- =====================================================================
-- SD card path: /SCRIPTS/WINGMAN/manifest.lua
-- Loaded only by the settings tool. The module switches per model are on
-- the Models page, the mascot and the flight time on Display.
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
      { key = "flightTime", page = "display", label = "Flight time", type = "choice",
        choices = core.FLIGHT_TIMES, labels = { "EdgeTX Timer 1", "Remaining Timer" }, default = core.FLIGHT_TIMES[1],
        hint = "Time shown beside the battery % in flight" },
    },
  }
end

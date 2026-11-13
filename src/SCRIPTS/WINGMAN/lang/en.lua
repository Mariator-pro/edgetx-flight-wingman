-- =====================================================================
-- lang/en.lua  --  English texts of Wingman in the Flight Bag tool
-- =====================================================================
-- SD card path: /SCRIPTS/WINGMAN/lang/en.lua
-- Every text by area and id; the complete set and the fallback of the
-- other languages. {name} is a placeholder. Plain quotes and dots only:
-- the radio's font has no typographic ones.
-- =====================================================================
-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 Mariator-pro
-- =====================================================================

return {
  fields = {
    mascot     = { label = "Mascot", hint = "Character on the wait page",
                   choices = { quad = "Quad", scout = "Scout" } },
    flightTime = { label = "Flight time", hint = "Time shown beside the battery % in flight",
                   choices = { timer = "EdgeTX Timer 1", timeleft = "Remaining Timer" } },
    gpsView    = { label = "GPS view", hint = "Horizon: set Telem Ratio to 1:4 or faster",
                   choices = { compass = "Compass", horizon = "Horizon" } },
    barStyle   = { label = "Bar style", hint = "Battery and link bars: plain, blocks or zones",
                   choices = { solid = "Solid", segments = "Segments", zones = "Zones" } },
    switchPage = { label = "Switch page", hint = "Switches and FC modes on the wait page (aileron right)" },
    language   = { label = "Language", hint = "Language of Flight Bag",
                   choices = { en = "English", de = "Deutsch" } },
  },
  resets = {
    settings = { label = "Reset settings", ask = "Reset Wingman's settings? \"Show in Wingman\" and FC modes stay.",
                 desc = "Mascot, GPS view, bar style and switch page go back to their defaults. \"Show in Wingman\" of every model and the stored FC modes stay. Flight time and language stay, they apply to all apps." },
    factory  = { label = "Erase everything",
                 ask = "Erase everything in Wingman? \"Show in Wingman\" and FC modes are erased, settings are reset.",
                 desc = "Every model shows battery, link and GPS again, the stored FC modes are erased and the settings go back to their defaults. Flight time and language stay, they apply to all apps." },
  },
  setup = {
    coreMissing = "{app} core missing",
    coreOld     = "{app} core too old",
    coreNew     = "{app} core too new",
  },
  files = { core = "Core", config = "Config", widget = "Widget" },
}

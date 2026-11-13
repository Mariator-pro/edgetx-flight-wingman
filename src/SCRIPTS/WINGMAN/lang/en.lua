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
    settings = { label = "Reset settings", ask = "Reset Wingman settings to factory defaults? Models and FC modes stay.",
                 desc = "Mascot, GPS view, bar style and switch page go back to factory settings. Models and FC modes stay." },
    factory  = { label = "Factory reset", ask = "Reset Wingman to factory settings? All models, FC modes and settings are erased.",
                 desc = "All models, FC modes and settings are erased. Every model shows battery, link and GPS again." },
  },
  setup = {
    coreMissing = "{app} core missing",
    coreOld     = "{app} core too old",
    coreNew     = "{app} core too new",
  },
  files = { core = "Core", config = "Config", widget = "Widget" },
}

-- =====================================================================
-- manifest.lua  --  GPS Homer as seen by the Flight Bag settings tool
-- =====================================================================
-- SD card path: /SCRIPTS/GPSHOMER/manifest.lua
-- Loaded only by the settings tool. Labels and hints live here; ranges,
-- defaults, sound slots and the config file live in core.lua.
-- =====================================================================
-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 Mariator-pro
-- =====================================================================

return function(core)
  local L, D = core.LIMITS, core.DEFAULTS
  return {
    name  = "GPS Homer",
    url   = "github.com/Mariator-pro/edgetx-gps-homer",
    paths = {
      { "Core",    "/SCRIPTS/GPSHOMER/core.lua" },
      { "Config",  core.CONFIG_PATH },
      { "Flights", core.FLIGHTS_PATH },
      { "Widget",  "/WIDGETS/GPSHOMER/main.lua" },
      { "Func",    "/SCRIPTS/FUNCTIONS/gpshom.lua" },
      { "Sounds",  core.SOUND_DIR },
    },

    fields = {
      { key = "homeMinSats", page = "warnings", label = "Home min sats",
        min = L.homeMinSats.min, max = L.homeMinSats.max, step = L.homeMinSats.step,
        default = D.homeMinSats,
        hint = "Home is set once %v sats are stable" },
      { key = "maxAlt", page = "warnings", label = "Max altitude",
        min = L.maxAlt.min, max = L.maxAlt.max, step = L.maxAlt.step,
        default = D.maxAlt, off = 0,
        unit = function() return core.PARAMS.UNITS == "imperial" and "ft" or "m" end,
        hint = "Announce once when higher than %v above home" },
      { key = "audio", page = "alerts", label = "Sounds", shared = true,
        type = "bool", default = D.audio, hint = "Off silences every announcement, vibration stays" },
      { key = "haptic", page = "alerts", label = "Vibration", shared = true,
        type = "bool", default = D.haptic },
      { key = "hapticStrength", page = "alerts", label = "Strength", shared = true,
        type = "choice", choices = { 1, 2, 3 }, labels = { "Soft", "Normal", "Strong" },
        default = D.hapticStrength },
    },

    -- Rows on the Alerts page, in core.SOUND_KEYS order
    sounds = {
      ready = { label = "Ready to fly", hint = "GPS fix is stable, safe to arm" },
      fix   = { label = "Home set",     hint = "Home stored when arming (or at first stable fix)" },
      lost  = { label = "GPS lost",     hint = "GPS fix lost for a few seconds" },
      rec   = { label = "GPS recover",  hint = "GPS fix is back after a loss" },
      alt   = { label = "Max altitude", hint = "Higher than Max altitude above home" },
    },

    resets = {
      { label = "Reset settings", ask = "Reset GPS Homer settings to factory defaults? The flight list stays.",
        run = core.resetSettings },
      { label = "Clear flights", ask = "Clear the list of last landing spots?",
        run = core.clearFlights },
      { label = "Factory reset", ask = "Reset GPS Homer settings and clear the flight list?",
        run = core.factoryReset },
    },
  }
end

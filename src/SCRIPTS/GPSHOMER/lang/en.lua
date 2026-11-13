-- =====================================================================
-- lang/en.lua  --  English texts of GPS Homer in the Flight Bag tool
-- =====================================================================
-- SD card path: /SCRIPTS/GPSHOMER/lang/en.lua
-- Every text by area and id; the complete set and the fallback of the
-- other languages. {name} is a placeholder. Plain quotes and dots only:
-- the radio's font has no typographic ones.
-- =====================================================================
-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 Mariator-pro
-- =====================================================================

return {
  fields = {
    homeMinSats    = { label = "Minimum satellites", hint = "Satellites needed for a valid GPS fix" },
    maxAlt         = { label = "Max altitude", hint = "Warning when the model is higher above home" },
    maxDist        = { label = "Max distance", hint = "Warning when the model is farther from home" },
    audio          = { label = "Sounds", hint = "Off silences every announcement, vibration stays" },
    haptic         = { label = "Vibration" },
    hapticStrength = { label = "Strength", choices = { "Soft", "Normal", "Strong" } },
    language       = { label = "Language", hint = "Language of Flight Bag",
                       choices = { en = "English", de = "Deutsch" } },
  },
  sounds = {
    ready = { label = "Ready to fly", hint = "GPS fix is stable, safe to arm" },
    fix   = { label = "Home set", hint = "Home stored when arming (or at first stable fix)" },
    lost  = { label = "GPS lost", hint = "GPS fix lost for a few seconds" },
    rec   = { label = "GPS recovered", hint = "GPS fix is back after a loss" },
    alt   = { label = "Max altitude", hint = "Higher than Max altitude above home" },
    dist  = { label = "Max distance", hint = "Farther than Max distance from home" },
  },
  resets = {
    settings = { label = "Reset settings", ask = "Reset GPS Homer settings to factory defaults? Last flights stay.",
                 desc = "GPS Homer goes back to its factory settings. The Last flights list stays." },
    flights  = { label = "Clear last flights", ask = "Clear the last flights list? Settings stay.",
                 desc = "The Last flights list is emptied. The settings stay." },
    factory  = { label = "Factory reset", ask = "Reset GPS Homer settings and clear the last flights list?",
                 desc = "GPS Homer goes back to its factory settings, and the Last flights list is emptied." },
  },
  setup = {
    damaged        = "Settings file damaged",
    compassMissing = "Compass file missing",
    reinstall      = "Reinstall GPS Homer",
    missingSensors = "Missing sensors: {sensors}",
    checkSensors   = "Check sensors config",
  },
  files = { core = "Core", config = "Config", flights = "Flights", widget = "Widget", func = "Func", sounds = "Sounds" },
}

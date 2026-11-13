-- =====================================================================
-- lang/de.lua  --  German texts of Wingman in the Flight Bag tool
-- =====================================================================
-- SD card path: /SCRIPTS/WINGMAN/lang/de.lua
-- Same areas and ids as lang/en.lua; a text missing here is shown in
-- English. {name} is a placeholder. Plain quotes and dots only: the
-- radio's font has no typographic ones.
-- =====================================================================
-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 Mariator-pro
-- =====================================================================

return {
  fields = {
    mascot     = { label = "Maskottchen", hint = "Figur auf der Warteseite" },
    flightTime = { label = "Flugzeit", hint = "Zeit neben dem Akku-% im Flug",
                   choices = { timer = "EdgeTX-Timer 1", timeleft = "Restzeit-Timer" } },
    gpsView    = { label = "GPS-Ansicht", hint = 'Horizont: "Telem Ratio" auf 1:4 oder schneller stellen',
                   choices = { compass = "Kompass", horizon = "Horizont" } },
    barStyle   = { label = "Balkenstil", hint = "Balken für Akku und Verbindung: durchgehend, in Blöcken oder in Zonen",
                   choices = { solid = "Durchgehend", segments = "Segmente", zones = "Zonen" } },
    switchPage = { label = "Schalterseite", hint = "Schalter und FC-Modi auf der Warteseite (Querruder rechts)" },
    language   = { label = "Sprache", hint = "Sprache von Flight Bag" },
  },
  resets = {
    settings = { label = "Einstellungen zurücksetzen",
                 ask = "Einstellungen von Wingman auf Werkseinstellungen zurücksetzen? Modelle und FC-Modi bleiben.",
                 desc = "Maskottchen, GPS-Ansicht, Balkenstil und Schalterseite bekommen wieder die Werkseinstellungen. Modelle und FC-Modi bleiben." },
    factory  = { label = "Alles zurücksetzen",
                 ask = "Wingman auf Werkseinstellungen zurücksetzen? Alle Modelle, FC-Modi und Einstellungen werden gelöscht.",
                 desc = "Alle Modelle, FC-Modi und Einstellungen werden gelöscht. Jedes Modell zeigt wieder Akku, Verbindung und GPS." },
  },
  setup = {
    coreMissing = "Core von {app} fehlt",
    coreOld     = "Core von {app} zu alt",
    coreNew     = "Core von {app} zu neu",
  },
  files = { core = "Core", config = "Einstellungen", widget = "Widget" },
}

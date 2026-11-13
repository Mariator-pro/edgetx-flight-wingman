-- =====================================================================
-- lang/de.lua  --  German texts of GPS Homer in the Flight Bag tool
-- =====================================================================
-- SD card path: /SCRIPTS/GPSHOMER/lang/de.lua
-- Same areas and ids as lang/en.lua; a text missing here is shown in
-- English. {name} is a placeholder. Plain quotes and dots only: the
-- radio's font has no typographic ones.
-- =====================================================================
-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 Mariator-pro
-- =====================================================================

return {
  fields = {
    homeMinSats    = { label = "Mindestzahl Satelliten", hint = "Nötige Satelliten für einen gültigen GPS-Fix" },
    maxAlt         = { label = "Maximale Höhe", hint = "Warnung, wenn das Modell höher über Home ist" },
    maxDist        = { label = "Maximale Entfernung", hint = "Warnung, wenn das Modell weiter von Home weg ist" },
    audio          = { label = "Töne", hint = "Aus schaltet alle Ansagen stumm, die Vibration bleibt" },
    haptic         = { label = "Vibration" },
    hapticStrength = { label = "Stärke", choices = { "Schwach", "Normal", "Stark" } },
    language       = { label = "Sprache", hint = "Sprache von Flight Bag" },
  },
  sounds = {
    ready = { label = "Bereit zum Fliegen", hint = "GPS-Fix ist stabil, du kannst scharf schalten" },
    fix   = { label = "Home gesetzt", hint = "Home beim Scharfschalten gespeichert (oder beim ersten stabilen Fix)" },
    lost  = { label = "GPS verloren", hint = "GPS-Fix für einige Sekunden weg" },
    rec   = { label = "GPS wieder da", hint = "GPS-Fix ist nach einem Verlust zurück" },
    alt   = { label = "Maximale Höhe", hint = 'Höher als "Maximale Höhe" über Home' },
    dist  = { label = "Maximale Entfernung", hint = 'Weiter als "Maximale Entfernung" von Home' },
  },
  resets = {
    settings = { label = "Einstellungen zurücksetzen",
                 ask = "Einstellungen von GPS Homer auf Werkseinstellungen zurücksetzen? Die letzten Flüge bleiben.",
                 desc = 'GPS Homer bekommt wieder seine Werkseinstellungen. Die Liste "Letzte Flüge" bleibt.' },
    flights  = { label = "Letzte Flüge leeren", ask = 'Liste "Letzte Flüge" leeren? Die Einstellungen bleiben.',
                 desc = 'Die Liste "Letzte Flüge" wird geleert. Die Einstellungen bleiben.' },
    factory  = { label = "Alles zurücksetzen", ask = 'GPS Homer zurücksetzen und die Liste "Letzte Flüge" leeren?',
                 desc = 'GPS Homer bekommt wieder seine Werkseinstellungen, und die Liste "Letzte Flüge" wird geleert.' },
  },
  setup = {
    damaged        = "Einstellungsdatei beschädigt",
    compassMissing = "Kompass-Datei fehlt",
    reinstall      = "GPS Homer neu installieren",
    missingSensors = "Sensoren fehlen: {sensors}",
    checkSensors   = "Sensoren des Modells prüfen",
  },
  files = { core = "Core", config = "Einstellungen", flights = "Flüge", widget = "Widget", func = "Funktion", sounds = "Töne" },
}

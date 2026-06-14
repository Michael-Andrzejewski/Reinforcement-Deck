# Reinforcement Deck

By **Soareverix**.

A jokerless Balatro deck where playing-card modifiers **stack** instead of replacing each other. Tarots and spectrals always increment a counter; the scoring code rolls the counters into a single combined effect each time a card is scored.

## Game Mechanics

- **0 Joker slots**: So, there are no Jokers in the shop, no Buffoon packs, and no Joker-related cards at all
- **Enhancements stack**: Chariot a card three times → 3× Steel (X1.5 in-hand becomes X1.5³ ≈ X3.375)
- **Editions stack and are adjusted**: Wheel of Fortune now gives a card in hand an edition. Foil does +50 and 2x chips; Holographic adds +mult equal to chips, and polychrome raises the score to the x^1.25 power. Editions are extremely powerful, but inconsistent.
- **Seals stack**: 2× Purple Seal discarded gives 2 Tarots, 3× Blue Seal at end of round gives 3 Planets, 2x red seal does +2 to every enhancement/edition (red seal does not add to other seals).
- **Hover tooltip** lists all stacked modifiers in a "Reinforcements:" block.

Banned consumables in this deck (since they require/target Jokers):

- The Judgement (creates a random Joker)
- Temperance (sums Joker sell values)
- Hex / Wraith / Ankh / Soul / Ectoplasm — these are vanilla spectrals that target Jokers; they will roll as nothing-happens on play.

## Required versions

This mod was tested and built against this exact stack:

| Component | Version | Where to get it |
|---|---|---|
| **Lovely** (mod injector) | **v0.9.0** | https://github.com/ethangreen-dev/lovely-injector/releases/tag/v0.9.0 |
| **Steamodded** (mod framework) | **1.0.0-beta-1620a** | https://github.com/Steamodded/smods/archive/refs/tags/1.0.0-beta-1620a.zip |
| **Balatro Multiplayer** (optional, for PvP) | **0.3.3** | https://github.com/Balatro-Multiplayer/BalatroMultiplayer/releases/tag/v0.3.3 |
| **Reinforcement Deck** | this repo | `git clone https://github.com/Michael-Andrzejewski/Reinforcement-Deck.git` |

Older or newer versions may work but are untested — if multiplayer is involved, both players should match exactly.

## Installation (Windows)

All paths assume a default Steam install. If your install differs, substitute accordingly.

### 1. Install Lovely v0.9.0

1. Download `lovely-x86_64-pc-windows-msvc.zip` from the Lovely v0.9.0 release page.
2. Extract `version.dll` from the zip.
3. Place it directly in your Balatro game folder, replacing any existing `version.dll`:
   ```
   C:\Program Files (x86)\Steam\steamapps\common\Balatro\version.dll
   ```

### 2. Install Steamodded 1.0.0-beta-1620a

1. Download the source zip from the link above.
2. Extract it. You'll get a folder named `smods-1.0.0-beta-1620a`.
3. **Rename that folder to `smods`** and place it in:
   ```
   %AppData%\Balatro\Mods\smods\
   ```
   (Full path: `C:\Users\<you>\AppData\Roaming\Balatro\Mods\smods\`)

### 3. Install Multiplayer 0.3.3 (optional — only needed for PvP)

1. Download `BalatroMultiplayer.zip` from the Multiplayer v0.3.3 release page.
2. Create a new folder `multiplayer-0.3.3` inside `%AppData%\Balatro\Mods\`.
3. Extract the zip's contents directly into that folder. The folder should contain `Multiplayer.json`, `core.lua`, `assets/`, etc. at its top level.

### 4. Install Reinforcement Deck

```
cd %AppData%\Balatro\Mods
git clone https://github.com/Michael-Andrzejewski/Reinforcement-Deck.git ReinforcementDeck
```

Or, if you don't have git, download the repo as a zip from GitHub, extract, and rename the extracted folder to `ReinforcementDeck`.

### 5. Final folder layout

`%AppData%\Balatro\Mods\` should now contain (at minimum):

```
Mods\
├── lovely\                  (auto-created by Lovely on first launch — logs and dump go here)
├── smods\                   (Steamodded)
├── multiplayer-0.3.3\       (optional, for PvP)
└── ReinforcementDeck\
    ├── ReinforcementDeck.json
    ├── ReinforcementDeck.lua
    ├── assets\
    └── localization\
```

### 6. Launch Balatro

You should see Lovely + mod loading messages briefly, then the main menu. The Reinforcement Deck shows up in the deck-selection cycle on the New Run screen.

## Playing multiplayer

Both players must have the same versions of Lovely, Steamodded, Multiplayer, and Reinforcement Deck installed. After both have launched the game with mods active:

1. **Host** (one player): Main Menu → **Play** → **Create Lobby**
2. Pick a ruleset / gamemode in the lobby.
3. Host clicks **View Code** and shares the code (text/Discord/voice).
4. **Other player**: Main Menu → **Play** → **Join Lobby** → enter the code.
5. Both players pick the **Reinforcement Deck** as their deck.
6. Host clicks **Start**.

Each player runs their own independent run with the deck. Multiplayer effects (e.g. Nemesis blinds, score racing) happen against the other player according to the chosen ruleset.

## Troubleshooting

- **"SMODS was not properly setup. Please make sure your lovely is up to date (Minimum lovely v0.9.0)"**
  Lovely is too old. Re-do step 1 with v0.9.0.
- **"Server expecting version X-MULTIPLAYER"**
  Your Multiplayer mod version doesn't match the server. Update Multiplayer to whatever version the WARN line names. As of this README, server expects 0.3.3.
- **Deck appears but card stacks don't apply (e.g., 3× Foil only adds 50 chips)**
  Make sure both `ReinforcementDeck.json` and `ReinforcementDeck.lua` are in the `ReinforcementDeck` folder, and the folder is directly inside `Mods\` (not nested).
- **Logs**
  Mod load errors and runtime errors are written to `%AppData%\Balatro\Mods\lovely\log\lovely-<timestamp>.log`. Latest log = newest timestamp.

## Compatibility

This mod is not designed for Cryptid and the two have not been tested together. ScalingStakes (a separate mod by Soareverix) is fine to run alongside.

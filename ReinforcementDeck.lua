--[[
  Reinforcement Deck
  Author: Soareverix

  A jokerless deck where every modifier on a playing card stacks instead
  of replacing what came before. Tarots / spectrals always increment a
  counter; the scoring code rolls the counters into a single combined
  effect each time a card is scored.

  Trigger formula (per spec):
    triggers(M) = count(M) + red_seal_count   for enhancements & editions
    triggers(M) = count(M)                    for seals (red doesn't add to seals)
    base rank chips fire (1 + red_seal_count) times
    Stone replaces rank scoring (other enhancements still apply on top)
    Vanilla Red Seal retrigger is disabled; everything stays in one pass.
--]]

----------------------------------------------------------------------
-- Diagnostic logging (gate-able)
----------------------------------------------------------------------

local RD_DEBUG = false
local function rd_log(msg)
    if not RD_DEBUG then return end
    if sendInfoMessage then sendInfoMessage(msg, "ReinforcementDeck") end
    print("RD: " .. tostring(msg))
end

----------------------------------------------------------------------
-- Mod config (Mods menu -> Reinforcement Deck -> Config tab)
----------------------------------------------------------------------

local rd_config_defaults = {
    start_dollars = 25,
    -- Plasma-Deck effect: equalize chips and mult at final scoring.
    plasma = false,
    -- Number of Joker slots (0 = jokerless). When > 0 the Joker-dependent
    -- bans (Judgement + Joker-targeting spectrals) are lifted.
    joker_slots = 0,
    -- Heidelberg effect (Perkeo without the Joker): at the end of each
    -- shop, create a Negative copy of a random held consumable.
    heidelberg = false,
    -- Shop appearance weights. Vanilla defaults: tarot 4, planet 4,
    -- spectral 0, joker 20. We default joker to 0 (jokerless) and the
    -- rest to vanilla, which reproduces the deck's normal shop.
    tarot_rate    = 4,
    planet_rate   = 4,
    spectral_rate = 0,
    joker_rate    = 0,
}

local rd_mod_handle = SMODS.current_mod
if rd_mod_handle then
    rd_mod_handle.config = rd_mod_handle.config or {}
    for k, v in pairs(rd_config_defaults) do
        if rd_mod_handle.config[k] == nil then
            rd_mod_handle.config[k] = v
        end
    end
end

local function rd_cfg()
    return (rd_mod_handle and rd_mod_handle.config) or rd_config_defaults
end

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

-- Big-number (Talisman / Amulet) compatibility. When one of those mods
-- is loaded, scoring values (hand_chips / mult, and the chips/mult passed
-- into Back:calculate) can become big numbers. Arithmetic metamethods
-- (+ - * / ^) dispatch fine, but under LuaJIT a mixed comparison and
-- math.floor would error. Amulet's OmegaNum is cdata (not a table), so we
-- detect via Big.is when available and fall back to a table check. Any
-- value that has grown into a big number during scoring is necessarily
-- large and positive, so the helpers can short-circuit safely.
local function rd_is_big(x)
    if Big and Big.is then return Big.is(x) and true or false end
    return type(x) == 'table'
end

local function rd_gt0(x)
    if rd_is_big(x) then return true end
    return x > 0
end

local function rd_floor(x)
    if rd_is_big(x) then return x end  -- huge magnitudes need no flooring
    return math.floor(x)
end

local function rd_active()
    if not (G and G.GAME and G.GAME.selected_back) then return false end
    local key = G.GAME.selected_back.effect and G.GAME.selected_back.effect.center
                and G.GAME.selected_back.effect.center.key
    if key == 'b_rd_reinforcement' then return true end
    if G.GAME.selected_back_key == 'b_rd_reinforcement' then return true end
    return false
end

-- Lazy-evaluated constant lookup. Reads from G.P_CENTERS so we stay in
-- sync if Balatro patches the values; falls back to the spec values
-- when G.P_CENTERS isn't ready yet (e.g. during boot).
local function rd_constant(center_key, config_key, fallback)
    local c = G and G.P_CENTERS and G.P_CENTERS[center_key]
    if c and c.config and c.config[config_key] ~= nil then
        return c.config[config_key]
    end
    return fallback
end

local function rd_blank_stacks()
    return {
        enh  = { bonus = 0, mult = 0, glass = 0, steel = 0, gold = 0, stone = 0, lucky = 0, wild = 0 },
        seal = { red = 0, blue = 0, gold = 0, purple = 0 },
        edit = { foil = 0, holographic = 0, polychrome = 0 },
    }
end

local RD_ENH_KEY_MAP = {
    m_bonus = 'bonus',
    m_mult  = 'mult',
    m_glass = 'glass',
    m_steel = 'steel',
    m_gold  = 'gold',
    m_stone = 'stone',
    m_lucky = 'lucky',
    m_wild  = 'wild',
}

local RD_SEAL_KEY_MAP = {
    Red    = 'red',
    Blue   = 'blue',
    Gold   = 'gold',
    Purple = 'purple',
}

-- Map a normalized edition type ('foil' | 'holo' | 'holographic' | 'polychrome')
-- to the field name we use in rd_stacks.edit. Negative is intentionally
-- absent: this deck doesn't track it.
local RD_EDITION_FIELD_MAP = {
    foil        = 'foil',
    holo        = 'holographic',
    holographic = 'holographic',
    polychrome  = 'polychrome',
}

-- Steamodded's set_edition accepts THREE different argument formats
-- (string "e_holo", table with .type, table with {flag=true}). Normalize
-- them all to a single edition type string.
local function rd_normalize_edition(edition)
    if not edition then return nil end
    if type(edition) == 'string' then
        if edition:sub(1, 2) == 'e_' then return edition:sub(3) end
        return edition
    elseif type(edition) == 'table' then
        if edition.type then return edition.type end
        for k, v in pairs(edition) do
            if v then return k end
        end
    end
    return nil
end

-- Lazily seed an rd_stacks table from the card's current vanilla state,
-- so cards that arrive with pre-existing modifiers (shop purchases,
-- Familiar-spawned cards, Death copies, etc.) get a count of 1 for each
-- modifier already on them.
local function rd_ensure_stacks(card)
    if not card or not card.ability then return nil end
    if card.ability.rd_stacks then return card.ability.rd_stacks end

    local s = rd_blank_stacks()

    local ck = card.config and card.config.center_key
    if ck and RD_ENH_KEY_MAP[ck] then
        s.enh[RD_ENH_KEY_MAP[ck]] = 1
    end

    if card.seal and RD_SEAL_KEY_MAP[card.seal] then
        s.seal[RD_SEAL_KEY_MAP[card.seal]] = 1
    end

    if card.edition then
        local etype = rd_normalize_edition(card.edition)
        local field = etype and RD_EDITION_FIELD_MAP[etype]
        if field then s.edit[field] = 1 end
    end

    card.ability.rd_stacks = s
    return s
end

-- triggers(M) = count(M) + red_seal_count for enhancements & editions
-- (when count > 0). Seals fire just count times; pass kind='seal' for that.
local function rd_triggers(card, kind, field)
    local s = card.ability and card.ability.rd_stacks
    if not s or not s[kind] then return 0 end
    local c = s[kind][field] or 0
    if c <= 0 then return 0 end
    if kind == 'seal' then return c end
    return c + (s.seal.red or 0)
end

-- Stone is special: when Stone is the *most recent* enhancement applied
-- (i.e. it's the visually-active enhancement), the card loses its rank
-- chips and suit identity, like vanilla. When Stone has since been
-- overridden by another enhancement (the user has, e.g., Towered then
-- Chariot'd a card), it acts only as a +50 chips bonus per stack and
-- the card behaves normally for hand evaluation. Same idea could be
-- extended to Wild later if desired, but per user spec Wild is
-- always-active regardless of override.
local function rd_stone_is_active(card)
    return card and card.config and card.config.center_key == 'm_stone'
end

----------------------------------------------------------------------
-- Atlas + Deck
----------------------------------------------------------------------

SMODS.Atlas({
    key  = "rd_decks",
    path = "rd_decks.png",
    px   = 71,
    py   = 95,
})

-- Starting consumables list. Empty for normal play. Add entries here
-- (e.g. 'c_chariot', 'c_aura', etc.) to give the player extras at run
-- start; the queue handles vanilla's apply_to_run race condition.
local RD_STARTING_CONSUMABLES = {}

local function rd_queue_consumable(idx)
    local key = RD_STARTING_CONSUMABLES[idx]
    if not key then
        rd_log("finished queueing all starting consumables")
        return
    end
    G.E_MANAGER:add_event(Event({
        trigger = 'after',
        delay = 0.05,
        func = function()
            local ok, err = pcall(function()
                local center = G.P_CENTERS[key]
                if not center then
                    rd_log(("consumable %d/%d: no center for %s"):format(idx, #RD_STARTING_CONSUMABLES, tostring(key)))
                    return
                end
                local card_type = (center.set == 'Spectral' and 'Spectral')
                                  or (center.set == 'Planet' and 'Planet')
                                  or 'Tarot'
                local card = create_card(card_type, G.consumeables, nil, nil, nil, nil, key, 'rdstart')
                if card then
                    card:add_to_deck()
                    G.consumeables:emplace(card)
                end
            end)
            if not ok then
                rd_log(("consumable %d crash: %s"):format(idx, tostring(err)))
            end
            rd_queue_consumable(idx + 1)
            return true
        end,
    }))
end

-- Run-level settings that need to persist across both new and loaded
-- runs: joker_rate=0, ban Buffoon packs and useless Joker-dependent
-- tarots, and short-circuit the forced first-shop Buffoon. apply() is
-- only called by vanilla on new runs (Game:start_run skips
-- Back:apply_to_run when loading a save), so we ALSO call this from
-- our Game:start_run hook below to cover continued runs.
-- Always banned, regardless of config.
local RD_BANNED_KEYS = {
    -- Buffoon packs (Joker packs)
    'p_buffoon_normal_1', 'p_buffoon_normal_2',
    'p_buffoon_jumbo_1',  'p_buffoon_mega_1',
    -- Tarot that pays out based on held Jokers' sell value
    'c_temperance',
    -- Boss blinds that soft-lock without Jokers
    'bl_final_leaf',      -- Verdant Leaf: debuffs all cards until a Joker is sold
}

-- Banned only while the deck is jokerless (joker_slots <= 0). These are
-- re-enabled the moment the player gives themselves Joker slots.
local RD_JOKER_DEPENDENT_KEYS = {
    'c_judgement',  -- creates a random Joker
    'c_wraith',     -- creates a random Rare Joker
    'c_ankh',       -- copies a Joker
    'c_hex',        -- adds Polychrome to a random Joker
    'c_soul',       -- creates a Legendary Joker
    'c_ectoplasm',  -- adds Negative to a random Joker
}

local function rd_apply_persistent_settings()
    if not (G and G.GAME) then return end
    local cfg = rd_cfg()
    G.GAME.banned_keys = G.GAME.banned_keys or {}

    -- Always-on bans
    for _, k in ipairs(RD_BANNED_KEYS) do
        G.GAME.banned_keys[k] = true
    end
    -- Joker-dependent bans: only while jokerless. Setting to nil clears the
    -- ban so Judgement / Joker-targeting spectrals come back when slots > 0.
    local jokerless = (cfg.joker_slots or 0) <= 0
    for _, k in ipairs(RD_JOKER_DEPENDENT_KEYS) do
        G.GAME.banned_keys[k] = jokerless or nil
    end

    G.GAME.first_shop_buffoon = true

    -- Shop appearance weights (read when the shop pool is built, so this
    -- covers new runs via apply() and continued runs via start_run).
    G.GAME.tarot_rate    = cfg.tarot_rate    or 4
    G.GAME.planet_rate   = cfg.planet_rate   or 4
    G.GAME.spectral_rate = cfg.spectral_rate or 0
    G.GAME.joker_rate    = cfg.joker_rate    or 0

    -- Fixup: if a save already has Verdant Leaf queued as the upcoming
    -- boss (selected before bl_final_leaf was banned), reroll it now.
    local blind_choices = G.GAME.round_resets and G.GAME.round_resets.blind_choices
    local cur_boss_choice = blind_choices and blind_choices.Boss
    local active_blind_key = G.GAME.blind and G.GAME.blind.config and G.GAME.blind.config.blind
                             and G.GAME.blind.config.blind.key
    rd_log(string.format('persistent: cur_boss_choice=%s active_blind=%s state=%s',
        tostring(cur_boss_choice), tostring(active_blind_key), tostring(G.STATE)))
    if blind_choices and cur_boss_choice == 'bl_final_leaf' and type(get_new_boss) == 'function' then
        local guard = 0
        local new_boss = 'bl_final_leaf'
        while new_boss == 'bl_final_leaf' and guard < 50 do
            new_boss = get_new_boss()
            guard = guard + 1
        end
        blind_choices.Boss = new_boss
        rd_log('persistent: rerolled queued Boss -> ' .. tostring(new_boss))
    end
end

SMODS.Back({
    key = 'reinforcement',
    name = 'Reinforcement Deck',
    atlas = 'rd_decks',
    pos = { x = 0, y = 0 },
    config = {
        -- Starting dollars and Joker slots are configurable via the Mods
        -- menu; we set the absolute totals in apply() below, so these stay 0.
        dollars = 0,
        joker_slot = 0,
        -- Default 2 consumable slots (no override)
    },
    unlocked = true,
    calculate = function(self, back, context)
        -- Plasma-Deck effect: equalize chips and mult at the final scoring
        -- step. Returns the balanced values; state_events.lua consumes them
        -- as the new hand_chips / mult (see vanilla Plasma in back.lua).
        if rd_cfg().plasma and context.context == 'final_scoring_step' then
            local tot  = (context.chips or 0) + (context.mult or 0)
            local half = rd_floor(tot / 2)
            context.chips = half
            context.mult  = half
            update_hand_text({ delay = 0 }, { chips = half, mult = half })
            if attention_text then
                attention_text({
                    scale = 1.3, text = localize('k_balanced'), hold = 1.4,
                    align = 'cm', offset = { x = 0, y = -2.7 }, major = G.play,
                })
            end
            return half, half
        end

        -- Heidelberg effect (Perkeo without the Joker): at the end of each
        -- shop, duplicate a random held consumable as a Negative copy.
        -- Mirrors Balatro Multiplayer's Heidelberg Deck (CC_heidelberg.lua).
        if rd_cfg().heidelberg and context.ending_shop
           and G.consumeables and G.consumeables.cards[1] then
            G.E_MANAGER:add_event(Event({
                func = function()
                    local card_to_copy = pseudorandom_element(
                        G.consumeables.cards, pseudoseed('rd_heidelberg'))
                    if card_to_copy then
                        local copied_card = copy_card(card_to_copy)
                        copied_card:set_edition('e_negative', true)
                        copied_card:add_to_deck()
                        G.consumeables:emplace(copied_card)
                    end
                    return true
                end,
            }))
            return { message = localize('k_duplicated_ex') }
        end
    end,
    apply = function(self)
        rd_apply_persistent_settings()
        -- Configurable starting dollars (Mods menu -> Reinforcement Deck).
        -- starting_params.dollars is the value copied into G.GAME.dollars
        -- after Back:apply_to_run returns (see game.lua:2219), so writing
        -- it here gives us absolute control regardless of base $4.
        local desired = math.floor((rd_cfg().start_dollars or 25) + 0.5)
        if desired < 0 then desired = 0 end
        if desired > 100 then desired = 100 end
        if G.GAME and G.GAME.starting_params then
            G.GAME.starting_params.dollars = desired
        end
        -- Configurable Joker slots (absolute). starting_params.joker_slots
        -- is copied into G.jokers' card_limit during run setup (game.lua),
        -- so writing it here gives exact control. config.joker_slot stays 0.
        local slots = math.floor((rd_cfg().joker_slots or 0) + 0.5)
        if slots < 0 then slots = 0 end
        if G.GAME and G.GAME.starting_params then
            G.GAME.starting_params.joker_slots = slots
        end
        -- Starting consumable spawn (event-chained). Only fires on a
        -- new run; loaded runs already have their starting consumables.
        G.E_MANAGER:add_event(Event({
            trigger = 'after',
            delay = 0.1,
            func = function()
                if G.consumeables and G.consumeables.config then
                    G.consumeables.config.card_limit = math.max(
                        G.consumeables.config.card_limit or 0,
                        #RD_STARTING_CONSUMABLES + 2
                    )
                end
                rd_queue_consumable(1)
                return true
            end,
        }))
    end,
})

-- Hook Game:start_run so persistent settings (joker_rate, banned_keys,
-- first_shop_buffoon) are re-applied on continued runs as well as new
-- ones. Vanilla only calls Back:apply_to_run for fresh runs, so a save
-- created before these settings existed (or a save where they got
-- cleared) would otherwise still let Buffoon packs / banned tarots
-- appear in the shop.
local rd_orig_start_run = Game.start_run
function Game:start_run(args)
    local res = rd_orig_start_run(self, args)
    if rd_active() then
        rd_apply_persistent_settings()
    end
    return res
end

----------------------------------------------------------------------
-- Apply hooks: enhancement / edition / seal -> increment counter
----------------------------------------------------------------------

local rd_orig_set_ability = Card.set_ability
function Card:set_ability(center, initial, delay_sprites)
    if rd_active() and center and center.key and RD_ENH_KEY_MAP[center.key] and not initial then
        rd_ensure_stacks(self)
        local field = RD_ENH_KEY_MAP[center.key]
        self.ability.rd_stacks.enh[field] = self.ability.rd_stacks.enh[field] + 1
        return rd_orig_set_ability(self, center, initial, delay_sprites)
    end
    local res = rd_orig_set_ability(self, center, initial, delay_sprites)
    if rd_active() then rd_ensure_stacks(self) end
    return res
end

-- IMPORTANT: skip increment when silent=true. Vanilla uses silent=true
-- for internal state-replication calls (copy_card after duplicating
-- ability table, UI preview rendering, challenge starting hands, etc.)
-- where the edition is already accounted for in the ability table.
-- Skipping silent=true prevents double-incrementing.
local rd_orig_set_edition = Card.set_edition
function Card:set_edition(edition, immediate, silent, delay)
    local etype = rd_normalize_edition(edition)
    if rd_active() and not silent and etype and RD_EDITION_FIELD_MAP[etype] then
        rd_ensure_stacks(self)
        local field = RD_EDITION_FIELD_MAP[etype]
        self.ability.rd_stacks.edit[field] = self.ability.rd_stacks.edit[field] + 1
    end
    return rd_orig_set_edition(self, edition, immediate, silent, delay)
end

-- Reinforcement Deck overrides for two consumables:
--   * Aura: drop the "card has no edition" gate so editions can stack.
--   * The Wheel of Fortune: vanilla requires an editionless Joker, but
--     this deck has no Jokers. Repurpose Wheel to apply a random
--     edition to a RANDOM hand card (no highlight needed), making it
--     a "spray" effect that's strictly weaker than Aura's targeted use.
local function rd_aura_gate(any_state, skip_check)
    if not skip_check and ((G.play and #G.play.cards > 0) or
        G.CONTROLLER.locked or
        (G.GAME.STOP_USE and G.GAME.STOP_USE > 0)) then
        return false
    end
    if (G.STATE ~= G.STATES.HAND_PLAYED
        and G.STATE ~= G.STATES.DRAW_TO_HAND
        and G.STATE ~= G.STATES.PLAY_TAROT)
        or any_state then
        return G.hand and (#G.hand.highlighted == 1) and G.hand.highlighted[1] ~= nil or false
    end
    return false
end

local function rd_wheel_gate(any_state, skip_check)
    -- Wheel doesn't need a highlighted card - just any card in hand.
    if not skip_check and ((G.play and #G.play.cards > 0) or
        G.CONTROLLER.locked or
        (G.GAME.STOP_USE and G.GAME.STOP_USE > 0)) then
        return false
    end
    if (G.STATE ~= G.STATES.HAND_PLAYED
        and G.STATE ~= G.STATES.DRAW_TO_HAND
        and G.STATE ~= G.STATES.PLAY_TAROT)
        or any_state then
        return G.hand and G.hand.cards and #G.hand.cards > 0 or false
    end
    return false
end

local rd_orig_can_use = Card.can_use_consumeable
function Card:can_use_consumeable(any_state, skip_check)
    if rd_active() and self.ability then
        if self.ability.name == 'Aura' then
            return rd_aura_gate(any_state, skip_check)
        end
        if self.ability.name == 'The Wheel of Fortune' then
            return rd_wheel_gate(any_state, skip_check)
        end
    end
    return rd_orig_can_use(self, any_state, skip_check)
end

-- Override Wheel of Fortune's use logic so it applies a random
-- non-negative edition (Foil / Holographic / Polychrome) to a RANDOM
-- card held in hand. Short-circuits BEFORE vanilla's Joker branch.
local rd_orig_use_consumeable = Card.use_consumeable
function Card:use_consumeable(area, copier)
    if rd_active() and self.ability and self.ability.name == 'The Wheel of Fortune' then
        stop_use()
        if not copier then set_consumeable_usage(self) end
        if self.debuff then return nil end
        local used_tarot = copier or self

        G.E_MANAGER:add_event(Event({
            trigger = 'after',
            delay = 0.4,
            func = function()
                if G.hand and G.hand.cards and #G.hand.cards > 0 then
                    local target = pseudorandom_element(G.hand.cards, pseudoseed('rd_wheel_target'))
                    if target then
                        local edition = poll_edition('rd_wheel', nil, true, true)
                        target:set_edition(edition, true)
                    end
                end
                used_tarot:juice_up(0.3, 0.5)
                return true
            end,
        }))
        delay(0.5)
        return
    end
    return rd_orig_use_consumeable(self, area, copier)
end

-- Same silent=true skip as set_edition above. Vanilla copy_card calls
-- new_card:set_seal(other.seal, true) after copying the ability table,
-- which already contains rd_stacks. Without this guard the destination
-- ends up with seal_count = source + 1.
local rd_orig_set_seal = Card.set_seal
function Card:set_seal(_seal, silent, immediate)
    if rd_active() and not silent and _seal and RD_SEAL_KEY_MAP[_seal] then
        rd_ensure_stacks(self)
        local field = RD_SEAL_KEY_MAP[_seal]
        self.ability.rd_stacks.seal[field] = self.ability.rd_stacks.seal[field] + 1
    end
    return rd_orig_set_seal(self, _seal, silent, immediate)
end

-- Wild and Stone enhancements affect suit-matching. Vanilla checks
-- `ability.name == "Wild Card"` and `ability.effect == "Stone Card"`,
-- both of which get overwritten when a later enhancement is applied.
-- We drive Wild off the rd_stacks counter so it always survives stacks.
-- Stone, per spec, only suppresses suit identity when it's the most
-- recent enhancement applied; once overridden, Stone falls back to a
-- pure +50 chip bonus and the card matches normally.
local rd_orig_is_suit = Card.is_suit
function Card:is_suit(suit, bypass_debuff, flush_calc)
    if not rd_active() then return rd_orig_is_suit(self, suit, bypass_debuff, flush_calc) end
    rd_ensure_stacks(self)
    local s = self.ability.rd_stacks
    local wild_present = s and (s.enh.wild or 0) > 0
    local stone_active = rd_stone_is_active(self)

    if flush_calc then
        if stone_active then return false end
        if wild_present and not self.debuff then return true end
    else
        if self.debuff and not bypass_debuff then return end
        if stone_active then return false end
        if wild_present then return true end
    end
    -- Fall through to vanilla for Smeared Joker handling and base.suit match.
    return rd_orig_is_suit(self, suit, bypass_debuff, flush_calc)
end

----------------------------------------------------------------------
-- Scoring: enhancements
--
-- NOTE on Stone+other enhancement: when stone_count > 0, base rank
-- chips are skipped (Stone replaces rank scoring). Other enhancement
-- effects (Bonus chips, Steel held-mult, Gold dollars, Lucky rolls)
-- still apply on top — the rd_stacks counters are independent. The
-- *hand evaluator* still sees the card by its rank/suit (because vanilla
-- Stone effect-string is overwritten by later set_ability calls). This
-- is the intended behavior: Stone removes rank chips, not suit/rank
-- identity for hand-type matching.
----------------------------------------------------------------------

-- Bonus + Stone -> chips, plus base rank chips with Red-Seal additivity.
-- Stone, per spec, only suppresses base rank scoring when it's the most
-- recently applied enhancement; otherwise it acts as +50 chips per stack
-- and rank chips still apply.
local rd_orig_get_chip_bonus = Card.get_chip_bonus
function Card:get_chip_bonus()
    if not rd_active() then return rd_orig_get_chip_bonus(self) end
    if self.debuff then return 0 end
    rd_ensure_stacks(self)
    local s = self.ability.rd_stacks
    local red = s.seal.red or 0

    local total = 0
    local stone_active = rd_stone_is_active(self)

    -- Base rank chips: only suppressed when Stone is the active (most
    -- recent) enhancement. Otherwise they fire (1 + red_seal_count) times.
    if not stone_active then
        total = total + (self.base.nominal or 0) * (1 + red)
    end

    -- Stone chips per stack always apply (50 per stack + red seal).
    local stone_trig = rd_triggers(self, 'enh', 'stone')
    if stone_trig > 0 then
        total = total + rd_constant('m_stone', 'bonus', 50) * stone_trig
    end

    -- Bonus chips per stack
    local bonus_trig = rd_triggers(self, 'enh', 'bonus')
    if bonus_trig > 0 then
        total = total + rd_constant('m_bonus', 'bonus', 30) * bonus_trig
    end

    -- Permanent bonus (e.g. from Hiker joker) follows base rank scaling
    total = total + (self.ability.perma_bonus or 0) * (1 + red)

    return total
end

-- Mult + Lucky -> +mult
local rd_orig_get_chip_mult = Card.get_chip_mult
function Card:get_chip_mult()
    if not rd_active() then return rd_orig_get_chip_mult(self) end
    if self.debuff then return 0 end
    rd_ensure_stacks(self)

    local total = 0

    local m_trig = rd_triggers(self, 'enh', 'mult')
    if m_trig > 0 then total = total + rd_constant('m_mult', 'mult', 4) * m_trig end

    local l_trig = rd_triggers(self, 'enh', 'lucky')
    if l_trig > 0 then
        local rolls_hit = 0
        for _ = 1, l_trig do
            if pseudorandom('lucky_mult') < (G.GAME.probabilities.normal / 5) then
                rolls_hit = rolls_hit + 1
            end
        end
        if rolls_hit > 0 then
            self.lucky_trigger = true
            total = total + rd_constant('m_lucky', 'mult', 20) * rolls_hit
        end
    end

    if total <= 0 then return rd_orig_get_chip_mult(self) end
    return total
end

-- Glass -> X mult, stacked multiplicatively
local rd_orig_get_chip_x_mult = Card.get_chip_x_mult
function Card:get_chip_x_mult(context)
    if not rd_active() then return rd_orig_get_chip_x_mult(self, context) end
    if self.debuff then return 0 end
    if self.ability.set == 'Joker' then return 0 end
    rd_ensure_stacks(self)
    local g_trig = rd_triggers(self, 'enh', 'glass')
    if g_trig <= 0 then return rd_orig_get_chip_x_mult(self, context) end
    return rd_constant('m_glass', 'Xmult', 2) ^ g_trig
end

-- Lucky money + Gold seal payouts on play
local rd_orig_get_p_dollars = Card.get_p_dollars
function Card:get_p_dollars()
    if not rd_active() then return rd_orig_get_p_dollars(self) end
    if self.debuff then return 0 end
    rd_ensure_stacks(self)

    local ret = 0

    -- Gold seal: $3 per Gold-seal stack (no red-seal additivity for seals)
    local gold_seal_trig = rd_triggers(self, 'seal', 'gold')
    if gold_seal_trig > 0 then ret = ret + 3 * gold_seal_trig end

    -- Lucky money
    local l_trig = rd_triggers(self, 'enh', 'lucky')
    if l_trig > 0 then
        local rolls_hit = 0
        for _ = 1, l_trig do
            if pseudorandom('lucky_money') < (G.GAME.probabilities.normal / 15) then
                rolls_hit = rolls_hit + 1
            end
        end
        if rolls_hit > 0 then
            self.lucky_trigger = true
            ret = ret + rd_constant('m_lucky', 'p_dollars', 20) * rolls_hit
        end
    end

    if ret > 0 then
        G.GAME.dollar_buffer = (G.GAME.dollar_buffer or 0) + ret
        G.E_MANAGER:add_event(Event({ func = function() G.GAME.dollar_buffer = 0; return true end }))
    end
    return ret
end

-- Steel held in hand -> X1.5 ^ triggers
local rd_orig_get_h_x_mult = Card.get_chip_h_x_mult
function Card:get_chip_h_x_mult()
    if not rd_active() then return rd_orig_get_h_x_mult(self) end
    if self.debuff then return 0 end
    rd_ensure_stacks(self)
    local triggers = rd_triggers(self, 'enh', 'steel')
    if triggers <= 0 then return rd_orig_get_h_x_mult(self) end
    return rd_constant('m_steel', 'h_x_mult', 1.5) ^ triggers
end

----------------------------------------------------------------------
-- Scoring: editions  (Holo + Foil + Polychrome)
----------------------------------------------------------------------

-- Steamodded's scoring pipeline calls Card:calculate_edition (not get_edition).
-- We override it to roll up our stacked edition counters into a single
-- combined effect table that SMODS.trigger_effects then applies.
local rd_orig_calc_edition = Card.calculate_edition
function Card:calculate_edition(context)
    if not rd_active() then return rd_orig_calc_edition(self, context) end
    rd_ensure_stacks(self)
    local foil_trig = rd_triggers(self, 'edit', 'foil')
    local holo_trig = rd_triggers(self, 'edit', 'holographic')
    local poly_trig = rd_triggers(self, 'edit', 'polychrome')

    if foil_trig <= 0 and holo_trig <= 0 and poly_trig <= 0 then
        return rd_orig_calc_edition(self, context)
    end

    -- Match vanilla edition calculate() context gating
    local active = context and (context.pre_joker
        or (context.main_scoring and context.cardarea == G.play))
    if not active then return rd_orig_calc_edition(self, context) end

    -- Buffed editions (this deck only). We precompute every value against
    -- the live running scoring globals so the result composes in the exact
    -- order the scoring pipeline applies effect keys:
    --   chips (additive) -> x_chips -> mult (additive) -> x_mult
    -- Returning a plain table keeps this idempotent even if the scoring
    -- engine calls calculate_edition more than once per card.
    local cur_chips = hand_chips or 0
    local cur_mult  = mult or 0

    local ret = { card = self }

    -- Foil: +50 chips per trigger, AND x2 chips per trigger.
    local chips_after_foil = cur_chips
    if foil_trig > 0 then
        local add  = rd_constant('e_foil', 'extra', 50) * foil_trig
        local xchp = 2 ^ foil_trig
        ret.chips   = add
        ret.x_chips = xchp
        chips_after_foil = (cur_chips + add) * xchp
    end

    -- Holographic: add the current chip total to mult, once per trigger.
    -- Uses the post-foil chip count so it lines up with apply order.
    local mult_after_holo = cur_mult
    if holo_trig > 0 then
        local holo_add = chips_after_foil * holo_trig
        ret.mult = holo_add
        mult_after_holo = cur_mult + holo_add
    end

    -- Polychrome: raise the (post-holo) mult to the power 1.25 per trigger.
    -- Expressed as an x_mult so it multiplies the running mult to mult^exp.
    if poly_trig > 0 and rd_gt0(mult_after_holo) then
        local exponent  = 1.25 ^ poly_trig
        local final_mult = mult_after_holo ^ exponent
        ret.x_mult = final_mult / mult_after_holo
    end

    return ret
end

----------------------------------------------------------------------
-- Scoring: end-of-round dollars (Gold enhancement) + Blue Seal
----------------------------------------------------------------------

local rd_orig_eor = Card.get_end_of_round_effect
function Card:get_end_of_round_effect(context)
    if not rd_active() then return rd_orig_eor(self, context) end
    if self.debuff then return {} end
    rd_ensure_stacks(self)
    local ret = {}

    -- Gold enhancement: $3 per (count + red_seal) per held card at end of round
    local gold_trig = rd_triggers(self, 'enh', 'gold')
    if gold_trig > 0 then
        ret.h_dollars = rd_constant('m_gold', 'h_dollars', 3) * gold_trig
        ret.card = self
    end

    -- Blue seal: create count Planets at end of round
    local blue_trig = rd_triggers(self, 'seal', 'blue')
    if blue_trig > 0 and G.consumeables and G.consumeables.config and G.GAME.last_hand_played then
        local cap_left = G.consumeables.config.card_limit
                       - (#G.consumeables.cards + (G.GAME.consumeable_buffer or 0))
        local can_make = math.min(blue_trig, cap_left)
        if can_make > 0 then
            for _ = 1, can_make do
                G.GAME.consumeable_buffer = (G.GAME.consumeable_buffer or 0) + 1
                G.E_MANAGER:add_event(Event({
                    trigger = 'before',
                    delay = 0.0,
                    func = function()
                        local _planet = nil
                        for _, v in pairs(G.P_CENTER_POOLS.Planet) do
                            if v.config.hand_type == G.GAME.last_hand_played then _planet = v.key end
                        end
                        local card = create_card('Planet', G.consumeables, nil, nil, nil, nil, _planet, 'blusl')
                        card:add_to_deck()
                        G.consumeables:emplace(card)
                        G.GAME.consumeable_buffer = math.max(0, (G.GAME.consumeable_buffer or 1) - 1)
                        return true
                    end,
                }))
            end
            local msg = (can_make > 1) and ("+" .. can_make .. " Planets") or localize('k_plus_planet')
            card_eval_status_text(self, 'extra', nil, nil, nil,
                { message = msg, colour = G.C.SECONDARY_SET.Planet })
            ret.effect = true
        end
    end

    return ret
end

----------------------------------------------------------------------
-- Scoring: seals on discard / repetition
----------------------------------------------------------------------

local rd_orig_calculate_seal = Card.calculate_seal
function Card:calculate_seal(context)
    if not rd_active() then return rd_orig_calculate_seal(self, context) end
    if self.debuff then return nil end
    rd_ensure_stacks(self)

    -- Vanilla Red Seal would request a +1 retrigger here. We disable
    -- that because rd_triggers already bakes red-seal additivity into
    -- every modifier's trigger count and into the base rank chips.
    if context.repetition then
        return nil
    end

    -- Purple Seal on discard: create count Tarot cards.
    --
    -- Steamodded fires calculate_seal TWICE per discarded card: once via
    -- the explicit `card:calculate_seal({discard=true})` call in
    -- state_events.lua, and once via SMODS.calculate_context (which
    -- iterates all hand cards through eval_card -> calculate_seal). Only
    -- the explicit call has context.other_card == nil; the scan path
    -- always sets it. We gate on that to fire the seal effect exactly
    -- once per discard, matching vanilla's behavior.
    if context.discard and not context.other_card then
        local purple_trig = rd_triggers(self, 'seal', 'purple')
        if purple_trig > 0 and G.consumeables and G.consumeables.config then
            local cap_left = G.consumeables.config.card_limit
                           - (#G.consumeables.cards + (G.GAME.consumeable_buffer or 0))
            local can_make = math.min(purple_trig, cap_left)
            if can_make > 0 then
                for _ = 1, can_make do
                    G.GAME.consumeable_buffer = (G.GAME.consumeable_buffer or 0) + 1
                    G.E_MANAGER:add_event(Event({
                        trigger = 'before',
                        delay = 0.0,
                        func = function()
                            local card = create_card('Tarot', G.consumeables, nil, nil, nil, nil, nil, '8ba')
                            card:add_to_deck()
                            G.consumeables:emplace(card)
                            G.GAME.consumeable_buffer = math.max(0, (G.GAME.consumeable_buffer or 1) - 1)
                            return true
                        end,
                    }))
                end
                local msg = (can_make > 1) and ("+" .. can_make .. " Tarots") or localize('k_plus_tarot')
                card_eval_status_text(self, 'extra', nil, nil, nil,
                    { message = msg, colour = G.C.PURPLE })
            end
        end
    end

    return nil
end

----------------------------------------------------------------------
-- Hover tooltip: append a Reinforcement-Stacks block to the card UI
----------------------------------------------------------------------

local RD_TOOLTIP_ORDER = {
    -- enhancements
    { kind = 'enh',  field = 'bonus',         label = 'Bonus',  colour_key = 'BLUE'    },
    { kind = 'enh',  field = 'mult',          label = 'Mult',   colour_key = 'MULT'    },
    { kind = 'enh',  field = 'glass',         label = 'Glass',  colour_key = 'XMULT'   },
    { kind = 'enh',  field = 'steel',         label = 'Steel',  colour_key = 'CHIPS'   },
    { kind = 'enh',  field = 'gold',          label = 'Gold',   colour_key = 'MONEY'   },
    { kind = 'enh',  field = 'stone',         label = 'Stone',  colour_key = 'JOKER_GREY' },
    { kind = 'enh',  field = 'lucky',         label = 'Lucky',  colour_key = 'GREEN'   },
    { kind = 'enh',  field = 'wild',          label = 'Wild',   colour_key = 'PURPLE'  },
    -- editions
    { kind = 'edit', field = 'foil',          label = 'Foil',         colour_key = 'BLUE'   },
    { kind = 'edit', field = 'holographic',   label = 'Holographic',  colour_key = 'MULT'   },
    { kind = 'edit', field = 'polychrome',    label = 'Polychrome',   colour_key = 'XMULT'  },
    -- seals
    { kind = 'seal', field = 'red',           label = 'Red Seal',     colour_key = 'RED'    },
    { kind = 'seal', field = 'blue',          label = 'Blue Seal',    colour_key = 'BLUE'   },
    { kind = 'seal', field = 'gold',          label = 'Gold Seal',    colour_key = 'MONEY'  },
    { kind = 'seal', field = 'purple',        label = 'Purple Seal',  colour_key = 'PURPLE' },
}

-- result.main entries are flat arrays of inline UIEs (one array per
-- localized line). The outer renderer wraps these in UIT.R rows.
-- Inserting full {n=R, nodes=...} UIEs here would crash UIBox
-- construction (pairs() yields named fields like ("n", 4) as if they
-- were children). We produce flat lines.
local function rd_build_stack_lines(card)
    if not card or not card.ability or not card.ability.rd_stacks then return nil end
    local s = card.ability.rd_stacks
    local lines = {}
    for _, entry in ipairs(RD_TOOLTIP_ORDER) do
        local v = s[entry.kind] and s[entry.kind][entry.field] or 0
        if v and v > 0 then
            local colour = G.C[entry.colour_key] or G.C.WHITE
            lines[#lines + 1] = {
                { n = G.UIT.T, config = {
                    text = tostring(v) .. "x " .. entry.label,
                    scale = 0.34,
                    colour = colour,
                } },
            }
        end
    end
    if #lines == 0 then return nil end
    table.insert(lines, 1, {
        { n = G.UIT.T, config = {
            text = "Reinforcements:",
            scale = 0.34,
            colour = G.C.WHITE,
        } },
    })
    return lines
end

-- Locally-scoped "currently hovered card" tracker; used as a fallback
-- when generate_card_ui isn't given the card explicitly.
local rd_hover_card = nil

-- Build the override description for Wheel of Fortune in this deck.
-- result.main entries are flat arrays of inline text UIEs (not full
-- UIT.R rows; outer renderer wraps them).
local function rd_wheel_description()
    return {
        {
            { n = G.UIT.T, config = { text = "Adds a random ", scale = 0.32, colour = G.C.UI.TEXT_DARK } },
            { n = G.UIT.T, config = { text = "Edition",         scale = 0.32, colour = G.C.DARK_EDITION } },
        },
        {
            { n = G.UIT.T, config = { text = "to a random card in hand", scale = 0.32, colour = G.C.UI.TEXT_DARK } },
        },
    }
end

local rd_orig_gen_card_ui = generate_card_ui
function generate_card_ui(...)
    -- Forward ALL args (Steamodded passes a 9th `card` arg).
    local args = { ... }
    local _c = args[1]
    local card_type = args[4]
    local card = args[9]
    local result = rd_orig_gen_card_ui(...)

    if not rd_active() or not result then return result end

    -- Override Wheel of Fortune's description while in this deck so
    -- it accurately reflects the repurposed behavior.
    if _c and _c.key == 'c_wheel_of_fortune' and result.main then
        local ok, err = pcall(function()
            result.main = rd_wheel_description()
        end)
        if not ok then rd_log("wheel description override failed: " .. tostring(err)) end
    end

    -- Stack-counter rows for playing cards.
    if (card_type == 'Default' or card_type == 'Enhanced') then
        local target = card or rd_hover_card
        if target then
            local ok, err = pcall(function()
                local lines = rd_build_stack_lines(target)
                if lines and result.main then
                    for _, line in ipairs(lines) do
                        table.insert(result.main, line)
                    end
                end
            end)
            if not ok then
                rd_log("tooltip injection failed: " .. tostring(err))
            end
        end
    end
    return result
end

local rd_orig_card_hover = Card.hover
function Card:hover()
    rd_hover_card = self
    return rd_orig_card_hover(self)
end

local rd_orig_card_stop_hover = Card.stop_hover
function Card:stop_hover()
    if rd_hover_card == self then rd_hover_card = nil end
    return rd_orig_card_stop_hover(self)
end

----------------------------------------------------------------------
-- EXPERIMENTAL: blended enhancement textures
--
-- A card normally shows only its single `children.center` sprite (the
-- most-recently applied enhancement). When several enhancement TYPES are
-- stacked, we instead draw each type's texture layered with an alpha
-- proportional to its count: alpha(M) = count(M) / total_count. So gold
-- alone is full gold; gold + steel is 1/2 each; gold + 2x steel is 1/3
-- gold under 2/3 steel. Purely cosmetic -- scoring is untouched.
----------------------------------------------------------------------

-- enhancement field ('gold') -> center key ('m_gold')
local RD_FIELD_TO_CENTER = {}
for center_key, field in pairs(RD_ENH_KEY_MAP) do
    RD_FIELD_TO_CENTER[field] = center_key
end

-- Fixed draw order (bottom -> top). rd_stacks only tracks counts, not the
-- order modifiers were applied, so we use a stable order rather than true
-- recency. Stone first so other enhancements layer over it.
local RD_ENH_DRAW_ORDER = { 'stone', 'bonus', 'mult', 'gold', 'steel', 'glass', 'lucky', 'wild' }

-- Collect the enhancement layers present on a card, in draw order.
-- Returns a list of { key = 'm_x', count = n } and the total count.
local function rd_enh_layers(card)
    local s = card and card.ability and card.ability.rd_stacks
    if not s then return {}, 0 end
    local list, total = {}, 0
    for _, field in ipairs(RD_ENH_DRAW_ORDER) do
        local c = s.enh[field] or 0
        local key = RD_FIELD_TO_CENTER[field]
        if c > 0 and key and G.P_CENTERS[key] and G.P_CENTERS[key].pos then
            list[#list + 1] = { key = key, count = c }
            total = total + c
        end
    end
    return list, total
end

-- Only blend when 2+ distinct enhancement types are stacked. A single
-- type already renders correctly via the vanilla center sprite.
local function rd_should_blend(card)
    local list = rd_enh_layers(card)
    return #list >= 2
end

-- Draw the proportional enhancement blend in place of the single center
-- texture. `orig` is the sprite's original draw_shader; we reuse the same
-- sprite, repointing its atlas position per layer and tinting alpha via
-- the engine overlay colour (G.BRUTE_OVERLAY), which Sprite drawing
-- multiplies in.
local function rd_draw_enh_blend(spr, card, orig, ...)
    local list, total = rd_enh_layers(card)
    if total <= 0 or #list < 2 then return orig(spr, 'dissolve', ...) end

    local saved_overlay = G.BRUTE_OVERLAY
    local restore_pos = card.config and card.config.center and card.config.center.pos

    -- Bottom-to-top alpha compositing. Drawing layer k at
    -- alpha = count_k / (running total through k) makes the final pixel
    -- equal sum(count_i / total * texture_i): the bottom layer paints
    -- opaque, each layer above contributes exactly its share. e.g. gold
    -- then 2x steel -> gold opaque, steel at 2/3 -> 1/3 gold, 2/3 steel.
    local running = 0
    for _, layer in ipairs(list) do
        local center = G.P_CENTERS[layer.key]
        if center and center.pos then
            running = running + layer.count
            spr:set_sprite_pos(center.pos)
            G.BRUTE_OVERLAY = { 1, 1, 1, layer.count / running }
            orig(spr, 'dissolve', ...)
        end
    end

    G.BRUTE_OVERLAY = saved_overlay
    if restore_pos then spr:set_sprite_pos(restore_pos) end
end

-- Wrap the center sprite's draw_shader whenever sprites are (re)built, so
-- the 'dissolve' enhancement draw routes through our blend. All other
-- shader passes (vortex/negative/edition overlays/etc.) fall through.
local rd_orig_set_sprites = Card.set_sprites
function Card:set_sprites(_center, _front)
    local res = rd_orig_set_sprites(self, _center, _front)
    if rd_active() and self.children and self.children.center then
        local spr = self.children.center
        if not spr.rd_blend_wrapped then
            spr.rd_blend_wrapped = true
            local card = self
            local orig_draw_shader = spr.draw_shader
            spr.draw_shader = function(s, _shader, ...)
                if _shader == 'dissolve' and rd_active() and rd_should_blend(card) then
                    return rd_draw_enh_blend(s, card, orig_draw_shader, ...)
                end
                return orig_draw_shader(s, _shader, ...)
            end
        end
    end
    return res
end

----------------------------------------------------------------------
-- Mod config tab UI
----------------------------------------------------------------------

if rd_mod_handle then
    rd_mod_handle.config_tab = function()
        local cfg = rd_mod_handle.config or rd_config_defaults

        -- Compact 2-column layout so everything fits on screen.
        local function label_row(text)
            return { n = G.UIT.R, config = { align = 'cm', padding = 0.02 }, nodes = {
                { n = G.UIT.T, config = { text = text, scale = 0.3, colour = G.C.UI.TEXT_LIGHT } },
            } }
        end
        local function slider(lbl, key, lo, hi)
            return create_slider({
                label = lbl, w = 3, h = 0.3, label_scale = 0.3, text_scale = 0.28,
                ref_table = cfg, ref_value = key,
                min = lo, max = hi, decimal_places = 0,
            })
        end
        local function toggle(lbl, key)
            return create_toggle({
                label = lbl, label_scale = 0.32, w = 2.4,
                ref_table = cfg, ref_value = key,
            })
        end
        -- Two cells side by side in one row.
        local function pair(a, b)
            return { n = G.UIT.R, config = { align = 'cm', padding = 0.02 }, nodes = {
                { n = G.UIT.C, config = { align = 'cm', padding = 0.06 }, nodes = { a } },
                { n = G.UIT.C, config = { align = 'cm', padding = 0.06 }, nodes = { b } },
            } }
        end

        return {
            n = G.UIT.ROOT,
            config = { align = 'cm', padding = 0.02, colour = G.C.CLEAR },
            nodes = {
                pair(slider('Start $', 'start_dollars', 0, 100),
                     slider('Joker slots', 'joker_slots', 0, 10)),
                pair(toggle('Plasma (equalize)', 'plasma'),
                     toggle('Heidelberg copy', 'heidelberg')),
                label_row('Shop weights (tarot/planet default 4, spectral/joker default 0):'),
                pair(slider('Tarot', 'tarot_rate', 0, 50),
                     slider('Planet', 'planet_rate', 0, 50)),
                pair(slider('Spectral', 'spectral_rate', 0, 50),
                     slider('Joker', 'joker_rate', 0, 50)),
            },
        }
    end
end

--[[
  Reinforcement Deck

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
-- Helpers
----------------------------------------------------------------------

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

SMODS.Back({
    key = 'reinforcement',
    name = 'Reinforcement Deck',
    atlas = 'rd_decks',
    pos = { x = 0, y = 0 },
    config = {
        -- $25 starting (base 4 + 21)
        dollars = 21,
        -- 0 joker slots (default 5 - 5)
        joker_slot = -5,
        -- Default 2 consumable slots (no override)
    },
    unlocked = true,
    apply = function(self)
        G.GAME.joker_rate = 0
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

local rd_orig_set_edition = Card.set_edition
function Card:set_edition(edition, immediate, silent, delay)
    local etype = rd_normalize_edition(edition)
    if rd_active() and etype and RD_EDITION_FIELD_MAP[etype] then
        rd_ensure_stacks(self)
        local field = RD_EDITION_FIELD_MAP[etype]
        self.ability.rd_stacks.edit[field] = self.ability.rd_stacks.edit[field] + 1
    end
    return rd_orig_set_edition(self, edition, immediate, silent, delay)
end

-- Aura's vanilla can_use_consumeable check blocks usage on cards that
-- already have an edition. Override that for our deck so editions can
-- truly stack. We replicate the same gating as vanilla but drop the
-- `not G.hand.highlighted[1].edition` clause.
local rd_orig_can_use = Card.can_use_consumeable
function Card:can_use_consumeable(any_state, skip_check)
    if rd_active() and self.ability and self.ability.name == 'Aura' then
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
    return rd_orig_can_use(self, any_state, skip_check)
end

local rd_orig_set_seal = Card.set_seal
function Card:set_seal(_seal, silent, immediate)
    if rd_active() and _seal and RD_SEAL_KEY_MAP[_seal] then
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

    local ret = { card = self }
    if foil_trig > 0 then ret.chips  = rd_constant('e_foil',       'extra', 50)  * foil_trig end
    if holo_trig > 0 then ret.mult   = rd_constant('e_holo',       'extra', 10)  * holo_trig end
    if poly_trig > 0 then ret.x_mult = rd_constant('e_polychrome', 'extra', 1.5) ^ poly_trig end
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

local rd_orig_gen_card_ui = generate_card_ui
function generate_card_ui(...)
    -- Forward ALL args (Steamodded passes a 9th `card` arg).
    local args = { ... }
    local card_type = args[4]
    local card = args[9]
    local result = rd_orig_gen_card_ui(...)

    if rd_active() and result and (card_type == 'Default' or card_type == 'Enhanced') then
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

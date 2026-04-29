--[[
  Reinforcement Deck — through Phase 4
--]]

----------------------------------------------------------------------
-- Diagnostic logging: writes both to lovely log via sendInfoMessage
-- AND directly to a file under our mod folder, in case sendInfoMessage
-- gets filtered or routed somewhere we can't see.
----------------------------------------------------------------------

local RD_LOG_PATH = nil
local function rd_log(msg)
    if sendInfoMessage then sendInfoMessage(msg, "ReinforcementDeck") end
    if not RD_LOG_PATH and SMODS and SMODS.current_mod and SMODS.current_mod.path then
        RD_LOG_PATH = SMODS.current_mod.path .. "rd_debug.log"
    end
    if RD_LOG_PATH and love and love.filesystem then
        local existing = love.filesystem.getInfo(RD_LOG_PATH) and (love.filesystem.read(RD_LOG_PATH) or "") or ""
        local stamp = os.date("%H:%M:%S")
        love.filesystem.write(RD_LOG_PATH, existing .. "[" .. stamp .. "] " .. tostring(msg) .. "\n")
    end
    print("RD: " .. tostring(msg))
end

rd_log("Mod file loading at top-level")

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

local function rd_active()
    if not (G and G.GAME and G.GAME.selected_back) then return false end
    local key = G.GAME.selected_back.effect and G.GAME.selected_back.effect.center and G.GAME.selected_back.effect.center.key
    if key == 'b_rd_reinforcement' then return true end
    if G.GAME.selected_back_key == 'b_rd_reinforcement' then return true end
    return false
end

local function rd_blank_stacks()
    return {
        enh = { bonus = 0, mult = 0, glass = 0, steel = 0, gold = 0, stone = 0, lucky = 0, wild = 0 },
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

-- Map vanilla seal name -> rd.seal field
local RD_SEAL_KEY_MAP = {
    Red    = 'red',
    Blue   = 'blue',
    Gold   = 'gold',
    Purple = 'purple',
}

-- Map vanilla edition flag -> rd.edit field
-- (Negative is intentionally absent: spec says it doesn't exist on cards)
local RD_EDIT_KEYS = { 'foil', 'holographic', 'polychrome' }

local RD_BASE = {
    bonus_chips   = 30,
    mult_mult     = 4,
    glass_xmult   = 2,
    steel_hxmult  = 1.5,
    stone_chips   = 50,
    gold_dollars  = 3,
    lucky_mult    = 20,
    lucky_money   = 20,
    foil_chips    = 50,
    holo_mult     = 10,
    poly_xmult    = 1.5,
    gold_seal_pay = 3,
}

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
        if card.edition.foil       then s.edit.foil = 1 end
        if card.edition.holo       then s.edit.holographic = 1 end
        if card.edition.polychrome then s.edit.polychrome = 1 end
    end
    card.ability.rd_stacks = s
    return s
end

-- Triggers for an enhancement or edition: count + red_seal_count
-- Seals are special-cased; pass kind='seal' to get just count (no red).
local function rd_triggers(card, kind, field)
    local s = card.ability and card.ability.rd_stacks
    if not s or not s[kind] then return 0 end
    local c = s[kind][field] or 0
    if c <= 0 then return 0 end
    if kind == 'seal' then return c end
    return c + (s.seal.red or 0)
end

local function rd_red_count(card)
    local s = card.ability and card.ability.rd_stacks
    if not s then return 0 end
    return s.seal.red or 0
end

----------------------------------------------------------------------
-- Atlas + Deck
----------------------------------------------------------------------

SMODS.Atlas({
    key = "rd_decks",
    path = "rd_decks.png",
    px = 71,
    py = 95,
})

-- Starting consumables list. We deliberately do NOT pass these via the
-- deck's `config.consumables` because vanilla `Back:apply_to_run` runs
-- the entire creation in a single tight event loop that crashes when
-- given more than ~12 entries (and also bumps consumable_slot AFTER
-- creating them, which tends to truncate the list). Instead we queue
-- them as separate events from our `apply` function below.
local RD_STARTING_CONSUMABLES = {
    -- 2 of each enhancement-applying tarot
    'c_chariot',    'c_chariot',     -- Steel
    'c_devil',      'c_devil',       -- Gold
    'c_justice',    'c_justice',     -- Glass
    'c_tower',      'c_tower',       -- Stone
    'c_magician',   'c_magician',    -- Lucky
    'c_empress',    'c_empress',     -- Mult
    'c_heirophant', 'c_heirophant',  -- Bonus (vanilla mis-spelling preserved)
    'c_lovers',     'c_lovers',      -- Wild
    -- 5 of each spectral for edition / seal testing
    'c_aura',     'c_aura',     'c_aura',     'c_aura',     'c_aura',
    'c_deja_vu',  'c_deja_vu',  'c_deja_vu',  'c_deja_vu',  'c_deja_vu',
    'c_familiar', 'c_familiar', 'c_familiar', 'c_familiar', 'c_familiar',
    'c_talisman', 'c_talisman', 'c_talisman', 'c_talisman', 'c_talisman',
    'c_trance',   'c_trance',   'c_trance',   'c_trance',   'c_trance',
}

-- Build a one-shot event that creates the next consumable in the list,
-- so each emplace finishes before the next starts.
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
                local before_n = G.consumeables and #G.consumeables.cards or -1
                local cap = G.consumeables and G.consumeables.config and G.consumeables.config.card_limit or -1
                local card = create_card(card_type, G.consumeables, nil, nil, nil, nil, key, 'rdstart')
                if card then
                    card:add_to_deck()
                    G.consumeables:emplace(card)
                    rd_log(("consumable %d/%d: created %s (set=%s) cards=%d->%d cap=%d"):format(
                        idx, #RD_STARTING_CONSUMABLES, key, center.set, before_n, #G.consumeables.cards, cap
                    ))
                else
                    rd_log(("consumable %d/%d: create_card returned nil for %s (cards=%d cap=%d)"):format(
                        idx, #RD_STARTING_CONSUMABLES, key, before_n, cap
                    ))
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
        dollars = 196,            -- $200 starting (testing)
        joker_slot = -5,          -- 0 joker slots
        consumable_slot = 39,     -- room for 41 starting consumables
    },
    unlocked = true,
    apply = function(self)
        rd_log("apply() called")
        G.GAME.joker_rate = 0
        G.E_MANAGER:add_event(Event({
            trigger = 'after',
            delay = 0.1,
            func = function()
                rd_log(("apply event fired. G.consumeables=%s"):format(tostring(G.consumeables ~= nil)))
                if G.consumeables and G.consumeables.config then
                    local desired = #RD_STARTING_CONSUMABLES + 2
                    G.consumeables.config.card_limit = math.max(
                        G.consumeables.config.card_limit or 0,
                        desired
                    )
                    rd_log(("set card_limit -> %d (#RD_STARTING_CONSUMABLES=%d)"):format(
                        G.consumeables.config.card_limit, #RD_STARTING_CONSUMABLES
                    ))
                end
                rd_queue_consumable(1)
                return true
            end,
        }))
    end,
})

----------------------------------------------------------------------
-- Hooks: enhancement / edition / seal application -> increment counters
----------------------------------------------------------------------

local rd_orig_set_ability = Card.set_ability
function Card:set_ability(center, initial, delay_sprites)
    if rd_active() and center and center.key and RD_ENH_KEY_MAP[center.key] and not initial then
        rd_ensure_stacks(self)
        local field = RD_ENH_KEY_MAP[center.key]
        self.ability.rd_stacks.enh[field] = self.ability.rd_stacks.enh[field] + 1
        local res = rd_orig_set_ability(self, center, initial, delay_sprites)
        return res
    end
    local res = rd_orig_set_ability(self, center, initial, delay_sprites)
    if rd_active() then rd_ensure_stacks(self) end
    return res
end

-- Steamodded REPLACES Card:set_edition entirely (see SMODS src/overrides.lua).
-- The replacement accepts THREE different argument formats:
--   1. string "e_holo" (or any "e_<key>" center key)
--   2. table with `.type` field (e.g. {type='holo'})
--   3. table with one boolean flag set (e.g. {holo=true})
-- Our increment logic must normalize all three to a single edition_type.
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

-- Map normalized type -> rd.edit field name
local RD_EDITION_FIELD_MAP = {
    foil       = 'foil',
    holo       = 'holographic',
    holographic = 'holographic',
    polychrome = 'polychrome',
    -- 'negative' is intentionally absent: this deck doesn't track it.
}

local rd_orig_set_edition = Card.set_edition
function Card:set_edition(edition, immediate, silent, delay)
    local etype = rd_normalize_edition(edition)
    rd_log(("set_edition: rd_active=%s normalized=%s silent=%s immediate=%s")
        :format(tostring(rd_active()), tostring(etype), tostring(silent), tostring(immediate)))

    if rd_active() and etype and RD_EDITION_FIELD_MAP[etype] then
        rd_ensure_stacks(self)
        local s = self.ability.rd_stacks.edit
        local field = RD_EDITION_FIELD_MAP[etype]
        local before = s[field]
        s[field] = s[field] + 1
        rd_log(("set_edition incremented %s: %d -> %d"):format(field, before, s[field]))
    end
    local res = rd_orig_set_edition(self, edition, immediate, silent, delay)
    return res
end

-- Aura's vanilla can_use_consumeable check blocks usage on cards that
-- already have an edition. Override that for our deck so editions can
-- truly stack. We replicate the same gating as vanilla but drop the
-- `not G.hand.highlighted[1].edition` clause.
local rd_orig_can_use = Card.can_use_consumeable
function Card:can_use_consumeable(any_state, skip_check)
    if rd_active() and self.ability and self.ability.name == 'Aura' then
        if not skip_check and ((G.play and #G.play.cards > 0) or
            (G.CONTROLLER.locked) or
            (G.GAME.STOP_USE and G.GAME.STOP_USE > 0)) then
            return false
        end
        -- Vanilla: entry when NOT in HAND_PLAYED/DRAW_TO_HAND/PLAY_TAROT, OR any_state.
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
        local s = self.ability.rd_stacks.seal
        local field = RD_SEAL_KEY_MAP[_seal]
        s[field] = s[field] + 1
    end
    return rd_orig_set_seal(self, _seal, silent, immediate)
end

----------------------------------------------------------------------
-- Scoring: enhancements
----------------------------------------------------------------------

-- Bonus + Stone -> chips, AND base rank chips with Red-Seal additivity.
-- Vanilla returns base.nominal + ability.bonus + perma_bonus
-- (or just bonus + perma_bonus when Stone). We rebuild that to
-- account for stacks and red-seal additivity.
local rd_orig_get_chip_bonus = Card.get_chip_bonus
function Card:get_chip_bonus()
    if not rd_active() then return rd_orig_get_chip_bonus(self) end
    if self.debuff then return 0 end
    rd_ensure_stacks(self)
    local s = self.ability.rd_stacks
    local red = s.seal.red or 0

    local total = 0

    -- Stone replaces rank scoring; if Stone is present we don't add nominal.
    local stone_trig = rd_triggers(self, 'enh', 'stone')
    if stone_trig > 0 then
        total = total + RD_BASE.stone_chips * stone_trig
    else
        -- Base rank chips fire (1 + red_seal_count) times.
        total = total + (self.base.nominal or 0) * (1 + red)
    end

    local bonus_trig = rd_triggers(self, 'enh', 'bonus')
    if bonus_trig > 0 then
        total = total + RD_BASE.bonus_chips * bonus_trig
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
    if m_trig > 0 then total = total + RD_BASE.mult_mult * m_trig end

    local l_trig = rd_triggers(self, 'enh', 'lucky')
    if l_trig > 0 then
        local rolls_hit = 0
        for i = 1, l_trig do
            if pseudorandom('lucky_mult') < (G.GAME.probabilities.normal / 5) then
                rolls_hit = rolls_hit + 1
            end
        end
        if rolls_hit > 0 then
            self.lucky_trigger = true
            total = total + RD_BASE.lucky_mult * rolls_hit
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
    return RD_BASE.glass_xmult ^ g_trig
end

-- Lucky money + Gold seal payouts
local rd_orig_get_p_dollars = Card.get_p_dollars
function Card:get_p_dollars()
    if not rd_active() then return rd_orig_get_p_dollars(self) end
    if self.debuff then return 0 end
    rd_ensure_stacks(self)
    local s = self.ability.rd_stacks

    local ret = 0

    -- Gold seal: $3 per Gold-seal stack (no red-seal additivity for seals)
    local gold_seal_trig = rd_triggers(self, 'seal', 'gold')
    if gold_seal_trig > 0 then ret = ret + RD_BASE.gold_seal_pay * gold_seal_trig end

    -- Lucky money: count + red rolls of 1/15 for $20
    local l_trig = rd_triggers(self, 'enh', 'lucky')
    if l_trig > 0 then
        local rolls_hit = 0
        for i = 1, l_trig do
            if pseudorandom('lucky_money') < (G.GAME.probabilities.normal / 15) then
                rolls_hit = rolls_hit + 1
            end
        end
        if rolls_hit > 0 then
            self.lucky_trigger = true
            ret = ret + RD_BASE.lucky_money * rolls_hit
        end
    end

    if ret > 0 then
        G.GAME.dollar_buffer = (G.GAME.dollar_buffer or 0) + ret
        G.E_MANAGER:add_event(Event({ func = (function() G.GAME.dollar_buffer = 0; return true end) }))
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
    return RD_BASE.steel_hxmult ^ triggers
end

----------------------------------------------------------------------
-- Scoring: editions  (Holo + Foil + Polychrome)
----------------------------------------------------------------------

-- Steamodded's scoring pipeline calls Card:calculate_edition(context),
-- not Card:get_edition. The default calculate_edition delegates to the
-- edition center's `calculate` function, which reads `card.edition.chips`
-- (or .mult / .x_mult) for a SINGLE edition. We override calculate_edition
-- to roll up our stacked edition counters into a single combined effect
-- table (chips + mult + x_mult), so all three contributions apply in one
-- scoring pass.
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
    if foil_trig > 0 then ret.chips  = RD_BASE.foil_chips * foil_trig end
    if holo_trig > 0 then ret.mult   = RD_BASE.holo_mult  * holo_trig end
    if poly_trig > 0 then ret.x_mult = RD_BASE.poly_xmult ^ poly_trig end
    rd_log(("calculate_edition: foil=%d holo=%d poly=%d -> chips=%s mult=%s x_mult=%s"):format(
        foil_trig, holo_trig, poly_trig,
        tostring(ret.chips), tostring(ret.mult), tostring(ret.x_mult)
    ))
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
        ret.h_dollars = RD_BASE.gold_dollars * gold_trig
        ret.card = self
    end

    -- Blue seal: create count Planets at end of round
    local blue_trig = rd_triggers(self, 'seal', 'blue')
    if blue_trig > 0 then
        local can_make = math.min(blue_trig,
            (G.consumeables.config.card_limit - (#G.consumeables.cards + (G.GAME.consumeable_buffer or 0))))
        if can_make > 0 then
            for i = 1, can_make do
                G.GAME.consumeable_buffer = (G.GAME.consumeable_buffer or 0) + 1
                G.E_MANAGER:add_event(Event({
                    trigger = 'before',
                    delay = 0.0,
                    func = function()
                        if G.GAME.last_hand_played then
                            local _planet = nil
                            for _, v in pairs(G.P_CENTER_POOLS.Planet) do
                                if v.config.hand_type == G.GAME.last_hand_played then _planet = v.key end
                            end
                            local card = create_card('Planet', G.consumeables, nil, nil, nil, nil, _planet, 'blusl')
                            card:add_to_deck()
                            G.consumeables:emplace(card)
                            G.GAME.consumeable_buffer = math.max(0, (G.GAME.consumeable_buffer or 1) - 1)
                        else
                            G.GAME.consumeable_buffer = math.max(0, (G.GAME.consumeable_buffer or 1) - 1)
                        end
                        return true
                    end,
                }))
            end
            card_eval_status_text(self, 'extra', nil, nil, nil,
                { message = localize('k_plus_planet'), colour = G.C.SECONDARY_SET.Planet })
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

    -- Vanilla Red Seal would request a +1 retrigger here. We disable that
    -- entirely because the rd_triggers formula already bakes the
    -- red-seal additivity into every modifier's trigger count, and into
    -- the base rank chips via get_chip_bonus.
    if context.repetition then
        return nil
    end

    -- Purple Seal on discard: create count Tarot cards
    if context.discard then
        local purple_trig = rd_triggers(self, 'seal', 'purple')
        if purple_trig > 0 then
            local cap = G.consumeables.config.card_limit - (#G.consumeables.cards + (G.GAME.consumeable_buffer or 0))
            local can_make = math.min(purple_trig, cap)
            if can_make > 0 then
                for i = 1, can_make do
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
                card_eval_status_text(self, 'extra', nil, nil, nil,
                    { message = localize('k_plus_tarot'), colour = G.C.PURPLE })
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
    { kind = 'enh',  field = 'bonus',         label = 'Bonus',  colour_key = 'BLUE'   },
    { kind = 'enh',  field = 'mult',          label = 'Mult',   colour_key = 'MULT'   },
    { kind = 'enh',  field = 'glass',         label = 'Glass',  colour_key = 'XMULT'  },
    { kind = 'enh',  field = 'steel',         label = 'Steel',  colour_key = 'CHIPS'  },
    { kind = 'enh',  field = 'gold',          label = 'Gold',   colour_key = 'MONEY'  },
    { kind = 'enh',  field = 'stone',         label = 'Stone',  colour_key = 'FILTER' },
    { kind = 'enh',  field = 'lucky',         label = 'Lucky',  colour_key = 'GREEN'  },
    { kind = 'enh',  field = 'wild',          label = 'Wild',   colour_key = 'PURPLE' },
    -- editions
    { kind = 'edit', field = 'foil',          label = 'Foil',         colour_key = 'BLUE'  },
    { kind = 'edit', field = 'holographic',   label = 'Holographic',  colour_key = 'MULT'  },
    { kind = 'edit', field = 'polychrome',    label = 'Polychrome',   colour_key = 'XMULT' },
    -- seals
    { kind = 'seal', field = 'red',           label = 'Red Seal',     colour_key = 'RED'    },
    { kind = 'seal', field = 'blue',          label = 'Blue Seal',    colour_key = 'BLUE'   },
    { kind = 'seal', field = 'gold',          label = 'Gold Seal',    colour_key = 'MONEY'  },
    { kind = 'seal', field = 'purple',        label = 'Purple Seal',  colour_key = 'PURPLE' },
}

-- IMPORTANT: result.main entries are flat arrays of inline UIEs (a row
-- being one localized line). Each entry looks like:
--     { {n=G.UIT.T, config={text=..., scale=..., colour=...}}, ... }
-- The outer code wraps these in a UIT.R row at draw time. Inserting a
-- full {n=R, nodes=...} UIE here would crash UIBox construction because
-- pairs() on it yields the named fields ("n","config") as if they were
-- children. We therefore produce flat lines.
local function rd_build_stack_lines(card)
    if not card or not card.ability or not card.ability.rd_stacks then
        rd_log("build_stack_lines: no rd_stacks on hovered card")
        return nil
    end
    local s = card.ability.rd_stacks
    rd_log(("build_stack_lines: enh.steel=%d enh.glass=%d edit.foil=%d edit.holo=%d edit.poly=%d seal.red=%d")
        :format(s.enh.steel or 0, s.enh.glass or 0,
                s.edit.foil or 0, s.edit.holographic or 0, s.edit.polychrome or 0,
                s.seal.red or 0))
    local lines = {}
    for _, entry in ipairs(RD_TOOLTIP_ORDER) do
        local v = s[entry.kind] and s[entry.kind][entry.field] or 0
        if v and v > 0 then
            local colour = G.C[entry.colour_key] or G.C.WHITE
            local text = tostring(v) .. "x " .. entry.label
            lines[#lines + 1] = {
                { n = G.UIT.T, config = { text = text, scale = 0.34, colour = colour } },
            }
        end
    end
    if #lines == 0 then return nil end
    table.insert(lines, 1, {
        { n = G.UIT.T, config = { text = "Reinforcements:", scale = 0.34, colour = G.C.WHITE } },
    })
    return lines
end

local rd_orig_gen_card_ui = generate_card_ui
function generate_card_ui(...)
    -- Forward ALL args (Steamodded passes a 9th `card` arg now).
    local args = { ... }
    local card_type = args[4]
    local card = args[9]
    local result = rd_orig_gen_card_ui(...)

    if rd_active() and result and (card_type == 'Default' or card_type == 'Enhanced') then
        local target = card or G.RD_HOVER_CARD
        if target then
            -- Wrap injection in pcall so a tooltip bug never crashes the
            -- game during a run.
            local ok, err = pcall(function()
                local lines = rd_build_stack_lines(target)
                if lines and result.main then
                    for _, line in ipairs(lines) do
                        table.insert(result.main, line)
                    end
                end
            end)
            if not ok then
                sendWarnMessage("RD tooltip injection failed: " .. tostring(err), "ReinforcementDeck")
            end
        end
    end
    return result
end

local rd_orig_card_hover = Card.hover
function Card:hover()
    G.RD_HOVER_CARD = self
    return rd_orig_card_hover(self)
end

local rd_orig_card_stop_hover = Card.stop_hover
function Card:stop_hover()
    if G.RD_HOVER_CARD == self then G.RD_HOVER_CARD = nil end
    return rd_orig_card_stop_hover(self)
end

--[[
  Reinforcement Deck — Phase 2

  Adds full enhancement stacking support:
    - Bonus / Mult / Glass / Steel / Gold / Stone / Lucky / Wild
  All scoring code paths multiply each enhancement's effect by its
  stack count (red-seal additivity will come in Phase 4).

  Also adds a small corner overlay on each playing card showing the
  largest stack counts.

  Phase 3 will add edition stacking; Phase 4 will add seal stacking
  and the red-seal additive trigger rule.
--]]

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

-- Base values per single enhancement application (vanilla):
--   Bonus +30 chips, Mult +4 mult, Glass X2 mult, Steel X1.5 in-hand,
--   Stone +50 chips, Gold $3 end-of-round, Lucky 1/5 +20 mult & 1/15 $20.
local RD_BASE = {
    bonus_chips = 30,
    mult_mult   = 4,
    glass_xmult = 2,
    steel_hxmult = 1.5,
    stone_chips = 50,
    gold_dollars = 3,
    lucky_mult = 20,
    lucky_money = 20,
}

local function rd_ensure_stacks(card)
    if not card or not card.ability then return nil end
    if card.ability.rd_stacks then return card.ability.rd_stacks end
    local s = rd_blank_stacks()
    local ck = card.config and card.config.center_key
    if ck and RD_ENH_KEY_MAP[ck] then
        s.enh[RD_ENH_KEY_MAP[ck]] = 1
    end
    if card.seal then
        local sk = string.lower(card.seal)
        if s.seal[sk] ~= nil then s.seal[sk] = 1 end
    end
    if card.edition then
        if card.edition.foil       then s.edit.foil = 1 end
        if card.edition.holo       then s.edit.holographic = 1 end
        if card.edition.polychrome then s.edit.polychrome = 1 end
    end
    card.ability.rd_stacks = s
    return s
end

-- triggers(M) = count(M) + red_seal_count if count(M) > 0, else 0
local function rd_triggers(card, enh_field)
    local s = card.ability and card.ability.rd_stacks
    if not s then return 0 end
    local c = s.enh[enh_field] or 0
    if c <= 0 then return 0 end
    return c + (s.seal.red or 0)
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

SMODS.Back({
    key = 'reinforcement',
    name = 'Reinforcement Deck',
    atlas = 'rd_decks',
    pos = { x = 0, y = 0 },
    config = {
        dollars = 196,            -- $200 starting (testing)
        joker_slot = -5,          -- 0 joker slots
        consumable_slot = 14,     -- room for the 16 starting tarots (default 2 + 14 = 16)
        consumables = {
            -- 2 of every enhancement-applying tarot for testing
            'c_chariot',    'c_chariot',     -- Steel
            'c_devil',      'c_devil',       -- Gold
            'c_justice',    'c_justice',     -- Glass
            'c_tower',      'c_tower',       -- Stone
            'c_magician',   'c_magician',    -- Lucky
            'c_empress',    'c_empress',     -- Mult
            'c_hierophant', 'c_hierophant',  -- Bonus
            'c_lovers',     'c_lovers',      -- Wild
        },
    },
    unlocked = true,
    apply = function(self)
        G.GAME.joker_rate = 0
    end,
})

----------------------------------------------------------------------
-- set_ability hook: enhancement application increments counter
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

----------------------------------------------------------------------
-- Scoring overrides
----------------------------------------------------------------------

-- Bonus + Stone -> chips
local rd_orig_get_chip_bonus = Card.get_chip_bonus
function Card:get_chip_bonus()
    if not rd_active() then return rd_orig_get_chip_bonus(self) end
    if self.debuff then return 0 end
    rd_ensure_stacks(self)

    local total = 0
    local b_trig = rd_triggers(self, 'bonus')
    local s_trig = rd_triggers(self, 'stone')
    if b_trig > 0 then total = total + RD_BASE.bonus_chips * b_trig end
    if s_trig > 0 then total = total + RD_BASE.stone_chips * s_trig end

    if total <= 0 then
        -- Fall back to vanilla so e.g. base playing cards still work
        return rd_orig_get_chip_bonus(self)
    end
    return total
end

-- Mult + Lucky -> +mult
local rd_orig_get_chip_mult = Card.get_chip_mult
function Card:get_chip_mult()
    if not rd_active() then return rd_orig_get_chip_mult(self) end
    if self.debuff then return 0 end
    rd_ensure_stacks(self)

    local total = 0
    -- Vanilla Mult enhancement: deterministic +4 per stack
    local m_trig = rd_triggers(self, 'mult')
    if m_trig > 0 then total = total + RD_BASE.mult_mult * m_trig end

    -- Lucky enhancement: probabilistic +20 mult per roll, count rolls
    local l_trig = rd_triggers(self, 'lucky')
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

    if total <= 0 then
        -- No stacked mult/lucky on this card -> defer to vanilla
        return rd_orig_get_chip_mult(self)
    end
    return total
end

-- Glass -> X mult, stacked multiplicatively
local rd_orig_get_chip_x_mult = Card.get_chip_x_mult
function Card:get_chip_x_mult(context)
    if not rd_active() then return rd_orig_get_chip_x_mult(self, context) end
    if self.debuff then return 0 end
    if self.ability.set == 'Joker' then return 0 end
    rd_ensure_stacks(self)
    local g_trig = rd_triggers(self, 'glass')
    if g_trig <= 0 then return rd_orig_get_chip_x_mult(self, context) end
    -- 2x Glass = X4, 3x Glass = X8, etc.
    return RD_BASE.glass_xmult ^ g_trig
end

-- Lucky money + Gold seal payouts
local rd_orig_get_p_dollars = Card.get_p_dollars
function Card:get_p_dollars()
    if not rd_active() then return rd_orig_get_p_dollars(self) end
    if self.debuff then return 0 end
    rd_ensure_stacks(self)

    local ret = 0
    -- Gold seal: $3 each (no stacking yet, comes in Phase 4)
    if self.seal == 'Gold' then ret = ret + 3 end

    -- Lucky money: $20 per successful roll, count rolls at 1/15
    local l_trig = rd_triggers(self, 'lucky')
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

-- Steel held in hand
local rd_orig_get_h_x_mult = Card.get_chip_h_x_mult
function Card:get_chip_h_x_mult()
    if not rd_active() then return rd_orig_get_h_x_mult(self) end
    if self.debuff then return 0 end
    rd_ensure_stacks(self)
    local triggers = rd_triggers(self, 'steel')
    if triggers <= 0 then return rd_orig_get_h_x_mult(self) end
    local base = self.ability.h_x_mult
    if not base or base <= 0 then base = RD_BASE.steel_hxmult end
    return base ^ triggers
end

-- Gold end-of-round dollars
local rd_orig_eor = Card.get_end_of_round_effect
function Card:get_end_of_round_effect(context)
    if not rd_active() then return rd_orig_eor(self, context) end
    local ret = rd_orig_eor(self, context) or {}
    rd_ensure_stacks(self)
    local g_trig = rd_triggers(self, 'gold')
    if g_trig > 0 then
        ret.h_dollars = RD_BASE.gold_dollars * g_trig
        ret.card = self
    end
    return ret
end

----------------------------------------------------------------------
-- Hover tooltip: append a Reinforcement-Stacks block to the card UI
----------------------------------------------------------------------

-- Pretty-printed labels (stable display order matters)
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
    -- editions / seals (here for Phase 3 / 4 — currently always 0)
    { kind = 'edit', field = 'foil',          label = 'Foil',         colour_key = 'BLUE'   },
    { kind = 'edit', field = 'holographic',   label = 'Holographic',  colour_key = 'MULT'   },
    { kind = 'edit', field = 'polychrome',    label = 'Polychrome',   colour_key = 'XMULT'  },
    { kind = 'seal', field = 'red',           label = 'Red Seal',     colour_key = 'RED'    },
    { kind = 'seal', field = 'blue',          label = 'Blue Seal',    colour_key = 'BLUE'   },
    { kind = 'seal', field = 'gold',          label = 'Gold Seal',    colour_key = 'MONEY'  },
    { kind = 'seal', field = 'purple',        label = 'Purple Seal',  colour_key = 'PURPLE' },
}

-- Build a list of UI rows to append to the hover tooltip describing the
-- card's stack counters. Returns nil if the card has no stacks.
local function rd_build_stack_rows(card)
    if not card or not card.ability or not card.ability.rd_stacks then return nil end
    local s = card.ability.rd_stacks

    local rows = {}
    for _, entry in ipairs(RD_TOOLTIP_ORDER) do
        local v = s[entry.kind] and s[entry.kind][entry.field] or 0
        if v and v > 0 then
            local colour = G.C[entry.colour_key] or G.C.WHITE
            rows[#rows + 1] = {
                n = G.UIT.R,
                config = { align = "cm", padding = 0 },
                nodes = {
                    { n = G.UIT.T, config = { text = tostring(v) .. "x ", scale = 0.32, colour = G.C.WHITE } },
                    { n = G.UIT.T, config = { text = entry.label,         scale = 0.32, colour = colour    } },
                },
            }
        end
    end

    if #rows == 0 then return nil end
    -- Header row to introduce the block
    table.insert(rows, 1, {
        n = G.UIT.R,
        config = { align = "cm", padding = 0.02 },
        nodes = {
            { n = G.UIT.T, config = { text = "Reinforcements:", scale = 0.32, colour = G.C.UI.TEXT_LIGHT } },
        },
    })
    return rows
end

-- Hook: when generate_card_ui builds the hover tooltip, append our rows
-- to the description "main" section. We hook generate_card_ui (rather
-- than Card:generate_UIBox_ability_table) because main_end is a local
-- variable inside that method, and post-processing the assembled
-- full_UI_table is the most surgical place to insert extra rows.
local rd_orig_gen_card_ui = generate_card_ui
function generate_card_ui(_c, full_UI_table, specific_vars, card_type, badges, hide_desc, main_start, main_end)
    -- Find the Card instance being described (the hovered card). Vanilla
    -- doesn't pass it directly, but G.CONTROLLER.focused.target is the
    -- hovered UIE; for cards in playing-card areas, this is the Card
    -- itself (or its child). We simply look at the global "hovered
    -- card" tracker set up below.
    local result = rd_orig_gen_card_ui(_c, full_UI_table, specific_vars, card_type, badges, hide_desc, main_start, main_end)

    -- Only augment when the deck is active and we're describing a
    -- playing card (Default / Enhanced sets), not jokers / consumables.
    if rd_active() and result and (card_type == 'Default' or card_type == 'Enhanced') and G.RD_HOVER_CARD then
        local rows = rd_build_stack_rows(G.RD_HOVER_CARD)
        if rows and result.main then
            for _, row in ipairs(rows) do
                table.insert(result.main, row)
            end
        end
    end

    return result
end

-- Track the currently-hovered Card so generate_card_ui can find it.
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

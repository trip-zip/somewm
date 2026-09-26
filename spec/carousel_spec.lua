---------------------------------------------------------------------------
-- Unit test: carousel pure-logic functions
--
-- Tests membership reconciliation and native focus policy without a compositor.
---------------------------------------------------------------------------

-- Minimal mocks so carousel module loads without the compositor.
local signals = {}
local mock_client = {
    focus = nil,
    connect_signal = function(_, name, fn)
        signals[name] = fn
    end,
}
local mock_screen = {}
local mock_awesome = {}

_G.client = mock_client
_G.screen = mock_screen
_G.awesome = mock_awesome

-- Stub requires that carousel touches at load time.
package.loaded["awful.client"] = { tiled = function() return {} end }
package.loaded["awful.screen"] = { focused = function() return nil end }
package.loaded["awful.layout"] = {
    get = function() return nil end,
    arrange = function() end,
}
package.loaded["beautiful"] = {}

local carousel = require("awful.layout.suit.carousel")
local T = carousel._test

describe("reconcile", function()
    -- Fake client objects (identity matters, not fields)
    local c1 = { id = 1 }
    local c2 = { id = 2 }
    local c3 = { id = 3 }

    it("creates columns for new clients on empty state", function()
        local state = T.get_state({})
        T.reconcile(state, { c1, c2 }, 1.0, nil)
        assert.are.equal(2, #state.columns)
        assert.are.equal(c1, state.columns[1].clients[1])
        assert.are.equal(c2, state.columns[2].clients[1])
        assert.are.equal(1.0, state.columns[1].width_fraction)
    end)

    it("removes dead clients and empty columns", function()
        local state = T.get_state({})
        state.columns = {
            { clients = { c1 }, width_fraction = 1.0 },
            { clients = { c2 }, width_fraction = 0.5 },
            { clients = { c3 }, width_fraction = 1.0 },
        }
        T.rebuild_index(state)

        -- c2 is gone
        T.reconcile(state, { c1, c3 }, 1.0, nil)
        assert.are.equal(2, #state.columns)
        assert.are.equal(c1, state.columns[1].clients[1])
        assert.are.equal(c3, state.columns[2].clients[1])
    end)

    it("inserts new clients after focused column", function()
        local state = T.get_state({})
        state.columns = {
            { clients = { c1 }, width_fraction = 1.0 },
            { clients = { c2 }, width_fraction = 1.0 },
        }
        T.rebuild_index(state)

        -- focus is c1 (col 1), new client c3 should appear after col 1
        T.reconcile(state, { c1, c2, c3 }, 0.5, c1)
        assert.are.equal(3, #state.columns)
        assert.are.equal(c1, state.columns[1].clients[1])
        assert.are.equal(c3, state.columns[2].clients[1])
        assert.are.equal(0.5, state.columns[2].width_fraction)
        assert.are.equal(c2, state.columns[3].clients[1])
    end)

    it("preserves column width_fraction for surviving columns", function()
        local state = T.get_state({})
        state.columns = {
            { clients = { c1 }, width_fraction = 0.75 },
        }
        T.rebuild_index(state)

        T.reconcile(state, { c1 }, 1.0, nil)
        assert.are.equal(0.75, state.columns[1].width_fraction)
    end)

    it("handles empty client list", function()
        local state = T.get_state({})
        state.columns = {
            { clients = { c1 }, width_fraction = 1.0 },
        }
        T.rebuild_index(state)

        T.reconcile(state, {}, 1.0, nil)
        assert.are.equal(0, #state.columns)
    end)

    it("inserts after correct column when compaction shifts indices", function()
        local c4 = { id = 4 }

        local state = T.get_state({})
        state.columns = {
            { clients = { c1 }, width_fraction = 1.0 },
            { clients = { c2 }, width_fraction = 1.0 },
            { clients = { c3 }, width_fraction = 1.0 },
        }
        T.rebuild_index(state)

        -- c1 dies, focus on c2 (was col 2, becomes col 1 after compaction)
        -- c4 is new and should be inserted after c2
        T.reconcile(state, { c2, c3, c4 }, 1.0, c2)
        assert.are.equal(3, #state.columns)
        assert.are.equal(c2, state.columns[1].clients[1])
        assert.are.equal(c4, state.columns[2].clients[1])
        assert.are.equal(c3, state.columns[3].clients[1])
    end)
end)

describe("reconcile index", function()
    local c1 = { id = 1 }
    local c2 = { id = 2 }

    it("builds correct client_to_column index", function()
        local state = T.get_state({})
        T.reconcile(state, { c1, c2 }, 1.0, nil)

        local e1 = state.client_to_column[c1]
        local e2 = state.client_to_column[c2]
        assert.are.equal(1, e1.col_idx)
        assert.are.equal(1, e1.row_idx)
        assert.are.equal(2, e2.col_idx)
        assert.are.equal(1, e2.row_idx)
    end)
end)


describe("_native.target", function()
    local target = carousel._native.target

    it("centres every column in always mode", function()
        assert.are.equal(-160, target("always", 0, 960, 1280, 0, 0))
        assert.are.equal(800, target("always", 960, 960, 1280, 0, 0))
        assert.are.equal(1760, target("always", 1920, 960, 1280, 0, 0))
    end)

    it("moves only completely hidden columns in never mode", function()
        assert.are.equal(0, target("never", 960, 960, 1280, 0, 0))
        assert.are.equal(1600, target("never", 1920, 960, 1280, 0, 0))
        assert.are.equal(0, target("never", 0, 960, 1280, 960, 0))
        assert.are.equal(32, target("never", 0, 960, 1280, 960, 32))
        assert.are.equal(1632, target("never", 1920, 960, 1280, 0, 32))
        assert.are.equal(0, target("never", 960, 960, 1280, 0, 32))
    end)

    it("aligns overflowing edges and adds the caller's padding", function()
        assert.are.equal(640, target("edge", 960, 960, 1280, 0, 0))
        assert.are.equal(960, target("edge", 960, 960, 1280, 1600, 0))
        assert.are.equal(832, target("edge", 960, 960, 1280, 800, 32))
        assert.are.equal(672, target("edge", 960, 960, 1280, 0, 32))
        assert.are.equal(992, target("edge", 960, 960, 1280, 1600, 32))
    end)

    it("recentres a column only when it overflows", function()
        assert.are.equal(800, target("on-overflow", 960, 960, 1280, 0, 0))
        assert.are.equal(1760, target("on-overflow", 1920, 960, 1280, 800, 0))
        assert.are.equal(800, target("on-overflow", 960, 960, 1280, 1600, 0))
        assert.are.equal(-160, target("on-overflow", 0, 960, 1280, 800, 0))
        assert.are.equal(800, target("on-overflow", 960, 960, 1280, 800, 32))
    end)
end)

---------------------------------------------------------------------------
-- Unit test: carousel pure-logic functions
--
-- Tests compute_column_positions, strip_width, clamp_offset,
-- offset_to_center_column, and reconcile without a running compositor.
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
package.loaded["awful.screen"] = { focused = function() return nil end }
package.loaded["awful.layout"] = {
    get = function() return nil end,
    arrange = function() end,
}
package.loaded["beautiful"] = {}

local carousel = require("awful.layout.suit.carousel")
local T = carousel._test

describe("compute_column_positions", function()
    it("returns empty table for no columns", function()
        local pos = T.compute_column_positions({}, 1000)
        assert.are.equal(0, #pos)
    end)

    it("computes sequential positions with no gap", function()
        local cols = {
            { width_fraction = 0.5 },
            { width_fraction = 0.5 },
        }
        local pos = T.compute_column_positions(cols, 1000)
        assert.are.equal(2, #pos)
        assert.are.equal(0, pos[1].canvas_x)
        assert.are.equal(500, pos[1].pixel_width)
        assert.are.equal(500, pos[2].canvas_x)
        assert.are.equal(500, pos[2].pixel_width)
    end)

    it("does not add extra gap between columns", function()
        local cols = {
            { width_fraction = 1.0 },
            { width_fraction = 1.0 },
        }
        local pos = T.compute_column_positions(cols, 800)
        assert.are.equal(0, pos[1].canvas_x)
        assert.are.equal(800, pos[1].pixel_width)
        assert.are.equal(800, pos[2].canvas_x) -- no extra gap in column advance
        assert.are.equal(800, pos[2].pixel_width)
    end)

    it("floors fractional pixel widths", function()
        local cols = { { width_fraction = 1/3 } }
        local pos = T.compute_column_positions(cols, 1000)
        assert.are.equal(333, pos[1].pixel_width) -- floor(333.33)
    end)
end)

describe("strip_width", function()
    it("returns 0 for empty positions", function()
        assert.are.equal(0, T.strip_width({}))
    end)

    it("returns right edge of last column", function()
        local pos = {
            { canvas_x = 0, pixel_width = 500 },
            { canvas_x = 510, pixel_width = 500 },
        }
        assert.are.equal(1010, T.strip_width(pos))
    end)

    it("works with single column", function()
        local pos = { { canvas_x = 0, pixel_width = 800 } }
        assert.are.equal(800, T.strip_width(pos))
    end)
end)

describe("clamp_offset", function()
    it("returns 0 for empty positions", function()
        assert.are.equal(0, T.clamp_offset(100, {}, 800))
    end)

    it("centers strip when narrower than viewport", function()
        local pos = { { canvas_x = 0, pixel_width = 400 } }
        -- strip=400, viewport=800, should center: -(800-400)/2 = -200
        assert.are.equal(-200, T.clamp_offset(0, pos, 800))
    end)

    it("clamps to 0 when offset is negative", function()
        local pos = {
            { canvas_x = 0, pixel_width = 500 },
            { canvas_x = 510, pixel_width = 500 },
        }
        -- strip=1010, viewport=800, min=0
        assert.are.equal(0, T.clamp_offset(-100, pos, 800))
    end)

    it("clamps to max when offset exceeds strip", function()
        local pos = {
            { canvas_x = 0, pixel_width = 500 },
            { canvas_x = 510, pixel_width = 500 },
        }
        -- strip=1010, viewport=800, max=1010-800=210
        assert.are.equal(210, T.clamp_offset(9999, pos, 800))
    end)

    it("passes through valid offset unchanged", function()
        local pos = {
            { canvas_x = 0, pixel_width = 500 },
            { canvas_x = 510, pixel_width = 500 },
        }
        -- strip=1010, viewport=800, valid range [0, 210]
        assert.are.equal(100, T.clamp_offset(100, pos, 800))
    end)
end)

describe("offset_to_center_column", function()
    it("returns 0 for nil input", function()
        assert.are.equal(0, T.offset_to_center_column(nil, 800))
    end)

    it("centers a column in the viewport", function()
        local col_pos = { canvas_x = 500, pixel_width = 200 }
        -- center of column = 500 + 100 = 600
        -- offset = 600 - 800/2 = 600 - 400 = 200
        assert.are.equal(200, T.offset_to_center_column(col_pos, 800))
    end)

    it("returns negative offset for first column", function()
        local col_pos = { canvas_x = 0, pixel_width = 200 }
        -- center = 100, offset = 100 - 400 = -300
        assert.are.equal(-300, T.offset_to_center_column(col_pos, 800))
    end)
end)

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
end)

describe("peek_width effect on column positions", function()
    it("reduces column pixel widths with effective_viewport", function()
        local cols = {
            { width_fraction = 1.0 },
        }
        -- Without peek: column fills 1000px
        local pos_full = T.compute_column_positions(cols, 1000)
        assert.are.equal(1000, pos_full[1].pixel_width)

        -- With peek=50: effective_viewport = 1000 - 100 = 900
        local effective = 1000 - 2 * 50
        local pos_peek = T.compute_column_positions(cols, effective)
        assert.are.equal(900, pos_peek[1].pixel_width)
    end)

    it("half-width columns are proportional to effective_viewport", function()
        local cols = {
            { width_fraction = 0.5 },
            { width_fraction = 0.5 },
        }
        local effective = 1000 - 2 * 50 -- 900
        local pos = T.compute_column_positions(cols, effective)
        assert.are.equal(450, pos[1].pixel_width)
        assert.are.equal(450, pos[2].pixel_width)
        assert.are.equal(450, pos[2].canvas_x)
    end)

    it("clamp_offset centers strip within effective_viewport", function()
        -- Single narrow column: strip < effective_viewport
        local pos = { { canvas_x = 0, pixel_width = 400 } }
        local effective = 900
        -- strip=400, viewport=900, center: -(900-400)/2 = -250
        assert.are.equal(-250, T.clamp_offset(0, pos, effective))
    end)

    it("clamp_offset bounds to strip with effective_viewport", function()
        local pos = {
            { canvas_x = 0, pixel_width = 900 },
            { canvas_x = 910, pixel_width = 900 },
        }
        local effective = 900
        -- strip = 910 + 900 = 1810, max_offset = 1810 - 900 = 910
        assert.are.equal(0, T.clamp_offset(-100, pos, effective))
        assert.are.equal(910, T.clamp_offset(9999, pos, effective))
        assert.are.equal(500, T.clamp_offset(500, pos, effective))
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

    it("inserts after correct column when compaction shifts indices", function()
        local c4 = { id = 4 }
        local state = T.get_state({})
        state.columns = {
            { clients = { c1 }, width_fraction = 1.0 },
            { clients = { c2 }, width_fraction = 1.0 },
            { clients = { { id = 3 } }, width_fraction = 1.0 },
        }
        T.rebuild_index(state)

        -- c2 dies, c4 is new, focus on the client at old col 3
        local c3 = state.columns[3].clients[1]
        T.reconcile(state, { c1, c3, c4 }, 0.5, c3)

        -- After compaction: [c1, c3]. c4 should insert after c3 (pos 3).
        assert.are.equal(3, #state.columns)
        assert.are.equal(c1, state.columns[1].clients[1])
        assert.are.equal(c3, state.columns[2].clients[1])
        assert.are.equal(c4, state.columns[3].clients[1])
        assert.are.equal(0.5, state.columns[3].width_fraction)
    end)
end)

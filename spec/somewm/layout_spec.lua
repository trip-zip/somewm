---------------------------------------------------------------------------
-- somewm.layout substrate principle: no dependency on wibox.
---------------------------------------------------------------------------

describe("somewm.layout", function()
    it("does not load wibox.widget.base when required", function()
        package.loaded["somewm.layout"] = nil
        package.loaded["wibox.widget.base"] = nil

        require("somewm.layout")

        assert.is_nil(package.loaded["wibox.widget.base"],
            "somewm.layout pulled wibox.widget.base in transitively. "
            .. "Substrate must stay engine- and surface-agnostic; the "
            .. "place_widget_at wrap belongs at the wibox caller side.")
    end)
end)

---------------------------------------------------------------------------
-- Reference solver: pure-Lua implementation of the engine contract used
-- when _somewm_clay is unavailable (busted environment). Solves the cases
-- wibox layouts and tag presets produce: row/column flow with grow,
-- fixed, percent, gap, padding, plus stack containers with absolute-
-- positioned children.
---------------------------------------------------------------------------

describe("somewm.layout reference solver", function()
    local layout

    before_each(function()
        package.loaded["somewm.layout"] = nil
        layout = require("somewm.layout")
    end)

    local function w() return { _is_widget_stub = true } end

    local function place(widget, x, y, width, height)
        return { widget = widget, x = x, y = y, width = width, height = height }
    end

    it("returns empty placements for empty root", function()
        local r = layout.solve {
            width = 100, height = 100,
            root = layout.row {},
        }
        assert.is.same({}, r.placements)
    end)

    it("distributes grow children evenly along main axis", function()
        local a, b, c = w(), w(), w()
        local r = layout.solve {
            width = 100, height = 100,
            root = layout.row {
                layout.widget(a, { grow = true }),
                layout.widget(b, { grow = true }),
                layout.widget(c, { grow = true }),
            },
        }
        assert.is.same({
            place(a,  0, 0, 33, 100),
            place(b, 33, 0, 34, 100),
            place(c, 67, 0, 33, 100),
        }, r.placements)
    end)

    it("rounds cumulative position to keep totals on integer boundaries", function()
        local a, b, c = w(), w(), w()
        local r = layout.solve {
            width = 20, height = 100,
            root = layout.row {
                layout.widget(a, { grow = true }),
                layout.widget(b, { grow = true }),
                layout.widget(c, { grow = true }),
            },
        }
        -- 20/3 = 6.66; rounded cumulative: 7, 13, 20.
        -- Sizes: 7-0=7, 13-7=6, 20-13=7.
        assert.is.same({
            place(a,  0, 0, 7, 100),
            place(b,  7, 0, 6, 100),
            place(c, 13, 0, 7, 100),
        }, r.placements)
    end)

    it("places column children with fixed heights stacked top to bottom", function()
        local a, b, c = w(), w(), w()
        local r = layout.solve {
            width = 100, height = 100,
            root = layout.column {
                layout.widget(a, { height = 10 }),
                layout.widget(b, { height = 15 }),
                layout.widget(c, { height = 10 }),
            },
        }
        assert.is.same({
            place(a, 0,  0, 100, 10),
            place(b, 0, 10, 100, 15),
            place(c, 0, 25, 100, 10),
        }, r.placements)
    end)

    it("inserts gap between flow children", function()
        local a, b = w(), w()
        local r = layout.solve {
            width = 100, height = 100,
            root = layout.row {
                gap = 5,
                layout.widget(a, { width = 20 }),
                layout.widget(b, { width = 30 }),
            },
        }
        assert.is.same({
            place(a,  0, 0, 20, 100),
            place(b, 25, 0, 30, 100),  -- 20 + 5 gap
        }, r.placements)
    end)

    it("resolves percent sizing against parent main axis", function()
        local a, b = w(), w()
        local r = layout.solve {
            width = 100, height = 100,
            root = layout.row {
                layout.widget(a, { width = layout.percent(40) }),
                layout.widget(b, { width = layout.percent(60) }),
            },
        }
        assert.is.same({
            place(a,  0, 0, 40, 100),
            place(b, 40, 0, 60, 100),
        }, r.placements)
    end)

    it("mixes fixed children and grow children", function()
        local a, b, c = w(), w(), w()
        local r = layout.solve {
            width = 100, height = 100,
            root = layout.row {
                layout.widget(a, { width = 20 }),
                layout.widget(b, { grow = true }),
                layout.widget(c, { width = 30 }),
            },
        }
        -- grow takes 100 - 20 - 30 = 50.
        assert.is.same({
            place(a,  0, 0, 20, 100),
            place(b, 20, 0, 50, 100),
            place(c, 70, 0, 30, 100),
        }, r.placements)
    end)

    it("caps grow children at grow_max", function()
        local a, b = w(), w()
        local r = layout.solve {
            width = 100, height = 100,
            root = layout.row {
                layout.widget(a, { grow = true, grow_max = 30 }),
                layout.widget(b, { grow = true, grow_max = 30 }),
            },
        }
        -- Each capped at 30; 40 leftover space stays empty.
        assert.is.same({
            place(a,  0, 0, 30, 100),
            place(b, 30, 0, 30, 100),
        }, r.placements)
    end)

    it("places stack children at absolute positions", function()
        local a, b = w(), w()
        local r = layout.solve {
            width = 100, height = 100,
            root = layout.stack {
                layout.widget(a, { x = 10, y = 20, width = 30, height = 40 }),
                layout.widget(b, { x = 50, y = 60, width = 25, height = 35 }),
            },
        }
        assert.is.same({
            place(a, 10, 20, 30, 40),
            place(b, 50, 60, 25, 35),
        }, r.placements)
    end)

    it("fills the parent for stack children with no explicit size", function()
        local a = w()
        local r = layout.solve {
            width = 100, height = 100,
            root = layout.stack {
                layout.widget(a),
            },
        }
        assert.is.same({ place(a, 0, 0, 100, 100) }, r.placements)
    end)

    it("applies padding before sizing children", function()
        local a = w()
        local r = layout.solve {
            width = 100, height = 100,
            root = layout.row {
                padding = 10,
                layout.widget(a, { grow = true }),
            },
        }
        assert.is.same({ place(a, 10, 10, 80, 80) }, r.placements)
    end)

    it("offsets root by spec.offset_x / offset_y", function()
        local a = w()
        local r = layout.solve {
            width = 100, height = 100,
            offset_x = 50, offset_y = 60,
            root = layout.row { layout.widget(a, { grow = true }) },
        }
        assert.is.same({ place(a, 50, 60, 100, 100) }, r.placements)
    end)

    it("returns workarea bounds from a measure leaf", function()
        local r = layout.solve {
            width = 200, height = 100,
            root = layout.row {
                layout.measure { grow = true },
            },
        }
        assert.is.same({}, r.placements)
        assert.is.same({ x = 0, y = 0, width = 200, height = 100 }, r.workarea)
    end)

    describe("clamp", function()
        local w = function() return { _is_widget_stub = true } end

        it("does not move a child that already fits", function()
            local a = w()
            local r = layout.solve {
                width = 100, height = 100,
                root = layout.stack {
                    layout.widget(a, {
                        x = 10, y = 20, width = 30, height = 40, clamp = true,
                    }),
                },
            }
            assert.is.same({
                { widget = a, x = 10, y = 20, width = 30, height = 40 },
            }, r.placements)
        end)

        it("pushes back when right edge would overflow", function()
            local a = w()
            local r = layout.solve {
                width = 100, height = 100,
                root = layout.stack {
                    layout.widget(a, {
                        x = 90, y = 50, width = 30, height = 30, clamp = true,
                    }),
                },
            }
            -- 90 + 30 = 120 > 100. Shift back to x = 70.
            assert.is.same({
                { widget = a, x = 70, y = 50, width = 30, height = 30 },
            }, r.placements)
        end)

        it("pushes down to 0 when origin is negative", function()
            local a = w()
            local r = layout.solve {
                width = 100, height = 100,
                root = layout.stack {
                    layout.widget(a, {
                        x = -10, y = -5, width = 20, height = 20, clamp = true,
                    }),
                },
            }
            assert.is.same({
                { widget = a, x = 0, y = 0, width = 20, height = 20 },
            }, r.placements)
        end)

        it("clamps both axes simultaneously when overflowing", function()
            local a = w()
            local r = layout.solve {
                width = 100, height = 100,
                root = layout.stack {
                    layout.widget(a, {
                        x = 110, y = 120, width = 30, height = 30, clamp = true,
                    }),
                },
            }
            assert.is.same({
                { widget = a, x = 70, y = 70, width = 30, height = 30 },
            }, r.placements)
        end)

        it("does nothing without clamp = true", function()
            local a = w()
            local r = layout.solve {
                width = 100, height = 100,
                root = layout.stack {
                    layout.widget(a, {
                        x = 90, y = 50, width = 30, height = 30,
                    }),
                },
            }
            assert.is.same({
                { widget = a, x = 90, y = 50, width = 30, height = 30 },
            }, r.placements)
        end)
    end)

    describe("mouse bindings", function()
        local w = function() return { _is_widget_stub = true } end

        it("resolves to current mouse coords at solve time", function()
            _G.mouse = { coords = function() return { x = 42, y = 17 } end }
            local a = w()
            local r = layout.solve {
                width = 200, height = 200,
                root = layout.stack {
                    layout.widget(a, {
                        x = layout.mouse.x, y = layout.mouse.y,
                        width = 30, height = 30,
                    }),
                },
            }
            assert.is.same({
                { widget = a, x = 42, y = 17, width = 30, height = 30 },
            }, r.placements)
            _G.mouse = nil
        end)

        it("supports arithmetic on the binding", function()
            _G.mouse = { coords = function() return { x = 50, y = 30 } end }
            local a = w()
            local r = layout.solve {
                width = 200, height = 200,
                root = layout.stack {
                    layout.widget(a, {
                        x = layout.mouse.x + 10, y = layout.mouse.y - 5,
                        width = 30, height = 30,
                    }),
                },
            }
            assert.is.same({
                { widget = a, x = 60, y = 25, width = 30, height = 30 },
            }, r.placements)
            _G.mouse = nil
        end)

        it("falls back to 0 when mouse is unavailable", function()
            _G.mouse = nil
            local a = w()
            local r = layout.solve {
                width = 200, height = 200,
                root = layout.stack {
                    layout.widget(a, {
                        x = layout.mouse.x, y = layout.mouse.y,
                        width = 30, height = 30,
                    }),
                },
            }
            assert.is.same({
                { widget = a, x = 0, y = 0, width = 30, height = 30 },
            }, r.placements)
        end)
    end)

    describe("avoid", function()
        local w = function() return { _is_widget_stub = true } end

        it("keeps the requested position when it does not overlap", function()
            local a = w()
            local r = layout.solve {
                width = 100, height = 100,
                root = layout.stack {
                    layout.widget(a, {
                        x = 60, y = 60, width = 30, height = 30,
                        avoid = { { x = 0, y = 0, width = 50, height = 50 } },
                    }),
                },
            }
            assert.is.same({
                { widget = a, x = 60, y = 60, width = 30, height = 30 },
            }, r.placements)
        end)

        it("snaps to a free region when the requested position overlaps", function()
            local a = w()
            local r = layout.solve {
                width = 100, height = 100,
                root = layout.stack {
                    layout.widget(a, {
                        x = 10, y = 10, width = 30, height = 30,
                        avoid = { { x = 0, y = 0, width = 60, height = 60 } },
                    }),
                },
            }
            -- The 60x60 obstacle leaves an L-shape free. The largest
            -- fitting region is the right strip (x=60..100). The target
            -- snaps there.
            assert.is_not_nil(r.placements[1])
            local p = r.placements[1]
            -- Should not overlap the obstacle.
            local overlaps = (p.x < 60 and p.y < 60)
            assert.is_false(overlaps)
        end)

        it("does nothing when avoid is empty or nil", function()
            local a = w()
            local r = layout.solve {
                width = 100, height = 100,
                root = layout.stack {
                    layout.widget(a, {
                        x = 10, y = 10, width = 30, height = 30,
                        avoid = {},
                    }),
                },
            }
            assert.is.same({
                { widget = a, x = 10, y = 10, width = 30, height = 30 },
            }, r.placements)
        end)
    end)
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80

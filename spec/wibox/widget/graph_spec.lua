---------------------------------------------------------------------------
-- @author Alex Belykh
-- @copyright 2021 Alex Belykh
---------------------------------------------------------------------------

-- Require test_utils for the assert.widget_fit() helper.
require("wibox.test_utils")
-- Set emit_signal so as to not die on deprecation warnings.
_G.awesome.emit_signal = function() end
-- Silence debug warnings.
require("gears.debug").print_warning = function() end

local unpack = unpack or table.unpack -- luacheck: globals unpack (compatibility with Lua 5.1)
local color = require("gears.color")
local graph = require("wibox.widget.graph")

local deprecated_properties = {
    height = true,
    width = true,
    stack_colors = true,
}

local property_defaults = {
    baseline_value = 0,
    clamp_bars = true,
    nan_indication = true,
    step_width = 1,
    step_spacing = 0,
}

local redrawless_properties = {
    capacity = true,
    height = true,
    width = true,
    stack_colors = true,
}

local data = {45.5, -44.5, -7.5, 1.5, 47.5, -38.5, 0.5, 38.0, 47.0, 23.5}
local data2 = {-26.5, 25.0, -19.0, 38.0, 12.0 -19.0, -35.0, 16.5}

local function push_data(widget, d, group_idx)
    -- Add in reverse, so that d could be compared with
    -- the backing value array directly.
    for i = #d,1,-1 do
        widget:add_value(d[i], group_idx)
    end
end

describe("wibox.widget.graph", function()
    local widget
    local redraw_needed, layout_changed

    before_each(function()
        widget = graph()

        widget:connect_signal("widget::redraw_needed", function()
            redraw_needed = redraw_needed + 1
        end)
        widget:connect_signal("widget::layout_changed", function()
            layout_changed = layout_changed + 1
        end)
        redraw_needed, layout_changed = 0, 0
    end)

    -- Check the trivial properties of all getters and setters.
    --
    -- There shouldn't be a field with a "get_/set_*" name, that isn't one.
    -- Iteration is over module fields, because fields of the instance can be
    -- polluted by inheritance and whatnot with something, that doesn't
    -- hold itself to the standard I'm setting here.
    for field, _ in pairs(graph) do

        if string.sub(field, 1, 4) == "get_" then
            -- A field with a getter-like name. Let's ensure that it is one.
            local prop_name = string.sub(field, 5)

            describe("field " .. field, function()
                it("has a corresponding set_" .. prop_name .. " counterpart", function()
                    assert.is_function(widget["set_" .. prop_name])
                end)

                it("is a property getter", function()
                    assert.is_function(widget[field])
                    stub(widget, field, 3456)
                    -- Access the property through metatable magic
                    local result_value = widget[prop_name]

                    assert.is.equal(3456, result_value)
                    assert.stub(widget[field]).was_called_with(widget)
                end)
            end)

        elseif string.sub(field, 1, 4) == "set_" then
            -- A field with a setter-like name. Let's ensure that it is one.
            local prop_name = string.sub(field, 5)

            describe("field " .. field, function()
                local property_signal_emitted, property_signal_emitted_with

                before_each(function()
                    widget:connect_signal("property::" .. prop_name, function(...)
                        property_signal_emitted = property_signal_emitted + 1
                        property_signal_emitted_with = {...}
                    end)
                    property_signal_emitted, property_signal_emitted_with = 0, nil
                end)

                it("has a corresponding get_" .. prop_name .. " counterpart", function()
                    assert.is_function(widget["get_" .. prop_name])
                end)

                it("is a property setter", function()
                    assert.is_function(widget[field])
                    assert.is.equal(0, redraw_needed)
                    assert.is.equal(0, layout_changed)
                    assert.is.equal(0, property_signal_emitted)

                    local s = spy.on(widget, field)

                    -- An access through metatable magic
                    widget[prop_name] = 3456

                    -- should have caused the call of the method
                    assert.spy(s).was_called_with(match.is_ref(widget), 3456)

                    -- and maybe a property::<prop_name> signal
                    assert.is.equal(deprecated_properties[prop_name] and 0 or 1, property_signal_emitted)
                    -- and maybe a redraw
                    assert.is.equal(redrawless_properties[prop_name] and 0 or 1, redraw_needed)
                    -- but never a layout change.
                    assert.is.equal(0, layout_changed)

                    if not deprecated_properties[prop_name] then
                        -- The property signal contains the new value.
                        assert.is.equal(widget, property_signal_emitted_with[1])
                        assert.is.equal(3456, property_signal_emitted_with[2])
                        -- What is set, can be gotten back through the prop_name field.
                        assert.is.equal(3456, widget[prop_name])
                        -- The setter returns the widget itself for call chaining.
                        assert.spy(s).returned_with(match.is_ref(widget))
                    end

                    s:clear()
                    assert.spy(s).was_not.called()

                    -- A repeated setting of the same value
                    widget[prop_name] = 3456
                    -- should have caused the call of the method again
                    assert.spy(s).was_called_with(match.is_ref(widget), 3456)
                    -- but none of the signals.
                    assert.is.equal(deprecated_properties[prop_name] and 0 or 1, property_signal_emitted)
                    assert.is.equal(redrawless_properties[prop_name] and 0 or 1, redraw_needed)
                    assert.is.equal(0, layout_changed)
                end)

                it("has a specific default value", function()
                    assert.is_equal(property_defaults[prop_name], widget[prop_name])
                end)

                it("is not magical on nil-s", function()
                    -- When set to nil
                    widget[prop_name] = nil
                    -- it should stay nil and not fall back to some "default".
                    assert.is.equal(nil, widget[prop_name])
                end)
            end) -- end describe(field)

        end -- end if
    end -- end field loop

    -- Now let's check some nontrivial behavior

    describe("values", function()
        it("are empty in a fresh instance", function()
            assert.is.same({}, widget._private.values)
        end)

        describe("method add_value()", function()
            it("adds values", function()
                push_data(widget, data)
                -- Adds into the first datagroup by default.
                assert.is.same({data}, widget._private.values)
            end)

            it("defaults to NaN when no/falsy value is supplied", function()
                local amount = 15
                for _ = 1, amount do
                    widget:add_value(false)
                    widget:add_value()
                    widget:add_value(false, 3)
                    widget:add_value(nil, 3)
                end

                assert.array(widget._private.values).has.no.holes()
                assert.is.equal(3, #widget._private.values)
                assert.is.equal(2*amount, #widget._private.values[1])
                assert.is.equal(0, #widget._private.values[2])
                assert.is.equal(2*amount, #widget._private.values[3])

                for i = 1, 2*amount do
                    local tmp = widget._private.values[1][i]
                    assert.is_not.equal(tmp, tmp)
                    tmp = widget._private.values[3][i]
                    assert.is_not.equal(tmp, tmp)
                end
            end)

            it("adds values into specific data group", function()
                push_data(widget, data, 15)
                assert.is.same(data, widget._private.values[15])

                -- Smaller datagroups are present too, but empty.
                assert.array(widget._private.values).has.no.holes()
                assert.is.equal(15, #widget._private.values)
                for i, data_group in ipairs(widget._private.values) do
                    assert.array(data_group).has.no.holes()
                    assert.is.equal(i ~= 15 and 0 or #data, #data_group)
                end

                -- Adding again to a different group
                push_data(widget, data2, 30)
                -- works
                assert.is.same(data2, widget._private.values[30])
                -- and doesn't affect the other group.
                assert.is.same(data, widget._private.values[15])

                -- Smaller-index datagroups are present but empty.
                assert.array(widget._private.values).has.no.holes()
                assert.is.equal(30, #widget._private.values)
                for i, data_group in ipairs(widget._private.values) do
                    assert.array(data_group).has.no.holes()
                    if i ~= 15 and i ~= 30 then
                        assert.is.same({}, data_group)
                    end
                end
            end)

            it("doesn't care about group order", function()
                for i = math.max(#data,#data2),1,-1 do
                    if i % 2 == 0 and data[i] then
                        widget:add_value(data[i], 1)
                    end
                    if data2[i] then
                     widget:add_value(data2[i], 2)
                    end
                    if i % 2 == 1 and data[i] then
                        widget:add_value(data[i], 1)
                    end
                end

                assert.is.same({data, data2}, widget._private.values)
            end)

            it("doesn't work with non-natural datagroups", function()
                for i = #data,1,-1 do
                    assert.has.errors(function()
                        widget:add_value(data[i], 14.5)
                    end)
                end
                for i = #data,1,-1 do
                    assert.has.errors(function()
                        widget:add_value(data[i], 0)
                    end)
                end
                for i = #data,1,-1 do
                    assert.has.errors(function()
                        widget:add_value(data[i], -4)
                    end)
                end
                for i = #data,1,-1 do
                    assert.has.errors(function()
                        widget:add_value(data[i], "index")
                    end)
                end
                for i = #data,1,-1 do
                    assert.has.errors(function()
                        widget:add_value(data[i], {1, 2, 3})
                    end)
                end
                for i = #data,1,-1 do
                    assert.has.errors(function()
                        widget:add_value(data[i], function() end)
                    end)
                end

                -- No values were added after all this,
                -- but some empty datagroups were. This is a bit suboptimal,
                -- but is not worth fixing. Adding an assert here
                -- so that one would be reminded to change it to
                -- a #values == 0 check, if one fixes it.
                assert.is.equal(14, #widget._private.values)
                assert.array(widget._private.values).has.no.holes()
                for _, data_group in ipairs(widget._private.values) do
                    assert.is.same({}, data_group)
                end
            end)

            it("honors the capacity property", function()
                local function check_cap(cap, expected_len)
                    expected_len = expected_len or math.max(0, math.ceil(cap))

                    widget.capacity = cap

                    push_data(widget, data, 1)
                    push_data(widget, data2, 2)

                    -- Only the last inserted elements are kept.
                    assert.is.same(
                        {
                           {unpack(data, 1, expected_len)},
                           {unpack(data2, 1, expected_len)}
                        },
                        widget._private.values
                    )
                end

                for i = 0, math.min(#data, #data2) do
                    check_cap(i)
                end
                -- It handles negatives and NaNs like zeros
                check_cap(-100, 0)
                check_cap(-100.5, 0)
                check_cap(0/0)
                -- And fractional numbers are rounded up
                check_cap(2.5, 3)

                -- But setting the capacity property by itself doesn't do anything,
                -- if add_value() wasn't called.
                widget.capacity = 1
                assert.is.equal(3, #widget._private.values[1])
                assert.is.equal(3, #widget._private.values[2])
            end)

            it("stores up to 8192 values when no usage stats are available", function()
                assert.is_nil(widget.capacity)
                assert.is_nil(widget._private.last_drawn_values_num)
                for i = 1, 9000 do
                    widget:add_value(i)
                    widget:add_value(i, 3)
                end
                assert.is.equal(8192, #widget._private.values[1])
                assert.is.equal(8192, #widget._private.values[3])
            end)

            it("relies on usage stats, when capacity is unset", function()
                assert.is_nil(widget.capacity)
                widget._private.last_drawn_values_num = 100

                for i = 1, 400 do
                    widget:add_value(i)
                    widget:add_value(i, 3)
                end

                -- The smallest multiple of 64 that is >= last_drawn_values_num + 64
                assert.is.equal(192, #widget._private.values[1])
                assert.is.equal(192, #widget._private.values[3])

                -- so 192 elements will be kept with this too.
                widget._private.last_drawn_values_num = 128

                widget:add_value(0)
                widget:add_value(0, 3)

                assert.is.equal(192, #widget._private.values[1])
                assert.is.equal(192, #widget._private.values[3])

                -- But this is one is already one too many.
                widget._private.last_drawn_values_num = 129

                for i = 1, 400 do
                    widget:add_value(i)
                    widget:add_value(i, 3)
                end

                assert.is.equal(256, #widget._private.values[1])
                assert.is.equal(256, #widget._private.values[3])

                -- Setting it back and calling add_value() once is enough
                -- to purge overflowing elements,
                widget._private.last_drawn_values_num = 128
                widget:add_value(0)
                assert.is.equal(192, #widget._private.values[1])
                -- but only in the group, for which add_value() happened to be
                -- called during the time last_drawn_values_num was small enough,
                -- even though it's probably not a very fair behavior and could
                -- lead to weird visual artefacts.
                assert.is.equal(256, #widget._private.values[3])

                -- Calling add_value for the other group puts it in line too.
                widget:add_value(0, 3)
                assert.is.equal(192, #widget._private.values[3])
            end)


        end) -- end describe(add_value)

        describe("method clear()", function()
            it("clears values", function()
                local function check_clear(i)
                    assert.is.same({}, widget._private.values)
                    push_data(widget, data)
                    assert.is.same({data}, widget._private.values)
                    widget:clear()
                    assert.is.same({}, widget._private.values)
                    push_data(widget, data2, 3*i)
                    assert.is.same(data2, widget._private.values[3*i])
                    widget:clear()
                    assert.is.same({}, widget._private.values)
                end

                for i = 1, 3 do
                    check_clear(i)
                end
            end)
        end) -- end describe(clear)

    end) -- end describe(values)


end) -- end describe(graph)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80

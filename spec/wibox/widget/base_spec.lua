---------------------------------------------------------------------------
-- @author Uli Schlachter
-- @copyright 2016 Uli Schlachter
---------------------------------------------------------------------------

local base = require("wibox.widget.base")

describe("wibox.widget.base", function()
    local widget1, widget2
    before_each(function()
        widget1 = base.make_widget()
        widget2 = base.make_widget()
    end)

    describe("Clay descriptions", function()
        it("describes a bare widget as an empty element", function()
            assert.is_table(widget1._clay)
            assert.is_same({}, widget1._clay.describe(widget1))
        end)

        it("describes a proxy through its original widget", function()
            local proxy = base.make_widget(widget1)
            assert.is_same({ specs = { { widget = widget1, w = "grow", h = "grow" } } },
                proxy._clay.describe(proxy))
        end)

        it("keeps descriptions through declarative and value constructors", function()
            for _, widget in ipairs {
                base.make_widget_declarative {},
                base.make_widget_from_value {},
                base.make_widget_from_value(base.make_widget),
                base.make_widget_from_value(widget1),
            } do
                assert.is_table(widget._clay)
                assert.is_same({}, widget._clay.describe(widget))
            end
        end)
    end)

    describe("animation policy and requests", function()
        for _, properties in ipairs {false, true} do
            it("keeps animate callable with properties " .. tostring(properties), function()
                local widget = base.make_widget(nil, nil, {enable_properties = properties})
                local animate = widget.animate
                local changes = 0
                widget:connect_signal("property::animation", function() changes = changes + 1 end)
                assert.is_nil(widget.animation)
                assert.is_function(animate)

                widget.animation = false
                assert.is_false(widget:get_animation())
                widget:animate {forced_width = 100, duration = .5}
                assert.equals(100, widget:get_forced_width())
                assert.is_false(widget.animation)
                assert.equals(1, changes)

                local policy = {forced_width = .2}
                widget.animation = policy
                assert.same(policy, widget:get_animation())
                assert.is_nil(getmetatable(widget.animation))
                policy.forced_width = .9
                assert.equals(.2, widget.animation.forced_width)
                local edited = widget.animation
                edited.forced_width = .7
                assert.equals(.2, widget.animation.forced_width)
                widget.animation = edited
                assert.equals(.7, widget.animation.forced_width)
                widget:animate {forced_width = 120, duration = .5}
                assert.equals(120, widget:get_forced_width())
                assert.equals(animate, widget.animate)

                widget:set_animation(nil)
                assert.is_nil(widget.animation)
                assert.equals(animate, widget.animate)
                assert.equals(4, changes)
            end)
        end
    end)

    describe("caches", function()
        it("garbage collectable", function()
            local alive = setmetatable({ widget1, widget2 }, { __mode = "kv" })
            assert.is.equal(2, #alive)

            widget1, widget2 = nil, nil
            collectgarbage("collect")
            assert.is.equal(0, #alive)
        end)

    end)

    describe("setup", function()
        it("Filters out 'false'", function()
            -- Regression test: There was a bug where "nil"s where correctly
            -- skipped, but "false" entries survived
            local layout1, layout2 = base.make_widget(), base.make_widget()
            local called = false
            function layout1:set_widget(w)
                called = true
                assert.equals(w, layout2)
            end
            function layout2:set_children(children)
                assert.is_same({nil, widget1, nil, widget2}, children)
            end
            layout2.allow_empty_widget = true
            layout1:setup{ layout = layout2, false, widget1, nil, widget2 }
            assert.is_true(called)
        end)

        it("Attribute 'false' works", function()
            -- Regression test: I introduced a bug with the above fix
            local layout1, layout2 = base.make_widget(), base.make_widget()
            local called1, called2 = false, false
            function layout1:set_widget(w)
                called1 = true
                assert.equals(w, layout2)
            end
            function layout2:set_children(children)
                assert.is_same({}, children)
            end
            function layout2:set_foo(foo)
                called2 = true
                assert.is_false(foo)
            end
            layout1:setup{ layout = layout2, foo = false }
            assert.is_true(called1)
            assert.is_true(called2)
        end)
    end)

    describe("Setters emit signals", function()
        local widget
        local signal_called
        local callback = function () signal_called = true end

        before_each(function()
            widget = base.make_widget()
            signal_called = false
        end)

        it("'set_visible' calls 'widget::layout_changed'", function()
            widget:connect_signal("widget::layout_changed", callback)
            widget:set_visible(false)
            assert.is_true(signal_called)
        end)

        it("'set_visible' calls 'widget::redraw_needed'", function()
            widget:connect_signal("widget::redraw_needed", callback)
            widget:set_visible(false)
            assert.is_true(signal_called)
        end)

        it("'set_opacity' calls 'widget::redraw_needed'", function()
            widget:connect_signal("widget::redraw_needed", callback)
            widget:set_opacity(0)
            assert.is_true(signal_called)
        end)

        it("'set_forced_width' calls 'widget::layout_changed'", function()
            widget:connect_signal("widget::layout_changed", callback)
            widget:set_forced_width(0)
            assert.is_true(signal_called)
        end)

        it("'set_forced_height' calls 'widget::layout_changed'", function()
            widget:connect_signal("widget::layout_changed", callback)
            widget:set_forced_height(0)
            assert.is_true(signal_called)
        end)

        it("'set_widget_common' calls 'property::widget'", function()
            -- Implement `set_widget`
            rawset(widget, "set_widget", base.set_widget_common)

            widget:connect_signal("property::widget", callback)
            widget:set_widget(base.make_widget())
            assert.is_true(signal_called)
        end)

        it("'set_widget_common' calls 'widget::layout_changed'", function()
            -- Implement `set_widget`
            rawset(widget, "set_widget", base.set_widget_common)

            widget:connect_signal("widget::layout_changed", callback)
            widget:set_widget(base.make_widget())
            assert.is_true(signal_called)
        end)
    end)
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80

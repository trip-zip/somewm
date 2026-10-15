describe("somewm.animation", function()
    local animation, theme, grabbing, saved_theme, saved_mouse, saved_alias
    before_each(function()
        saved_theme = package.loaded.beautiful
        saved_mouse = _G.mousegrabber
        saved_alias = package.loaded["somewm.layout_animation"]
        theme, grabbing = {}, false
        package.loaded.beautiful = theme
        _G.mousegrabber = {isrunning = function() return grabbing end}
        package.loaded["somewm.animation"] = nil
        package.loaded["somewm.layout_animation"] = nil
        animation = require("somewm.animation")
    end)
    after_each(function()
        package.loaded.beautiful = saved_theme
        _G.mousegrabber = saved_mouse
        package.loaded["somewm.layout_animation"] = saved_alias
        package.loaded["somewm.animation"] = nil
    end)
    local function settled(object, trigger)
        animation.word(object, trigger)
        return animation.word(object, trigger)
    end
    it("omits unconfigured client records at zero layout duration", function()
        assert.equals(0, animation.layout_duration)
        assert.is_nil(animation.word({}, "layout"))
    end)
    it("snaps the first configured declaration even after unconfigured calls", function()
        local object = {}
        assert.is_nil(animation.word(object, "layout"))
        theme.animation_duration = 0.4
        assert.same({properties = {"box", "border_color"}, duration = 0, tag_exit = "grow", tag_duration = 0.4}, animation.word(object, "layout"))
        assert.equals(0.4, animation.word(object, "layout").duration)
    end)
    it("reads object overrides ahead of both theme levels", function()
        theme.animation_duration, theme.animation_layout_duration = 0.5, 0.4
        assert.equals(0.2, settled({animation = {layout = 0.2}}, "layout").duration)
        assert.equals(0, settled({animation = false}, "layout").duration)
    end)
    it("reads each trigger and theme default on every call", function()
        theme.animation_duration = 0.5
        for _, trigger in ipairs({"layout", "maximize", "floating", "focus"}) do
            local object = {animation = {}}
            assert.equals(0.5, settled(object, trigger).duration)
            theme["animation_" .. trigger .. "_duration"] = 0.3
            assert.equals(0.3, animation.word(object, trigger).duration)
            theme["animation_" .. trigger .. "_duration"] = 0.7
            assert.equals(0.7, animation.word(object, trigger).duration)
        end
    end)
    it("uses the layout duration without the alias below theme keys", function()
        local object = {}
        animation.layout_duration = 0.3
        assert.equals(0, animation.word(object, "layout").duration)
        assert.equals(0.3, animation.word(object, "layout").duration)
        theme.animation_layout_duration = 0.4
        assert.equals(0.4, animation.word(object, "layout").duration)
        theme.animation_layout_duration = nil
        animation.layout_duration = 0
        assert.equals(0, animation.word(object, "layout").duration)
        assert.is_nil(animation.word({}, "layout"))
    end)
    it("uses the alias default only for layout below theme keys", function()
        local alias = require("somewm.layout_animation")
        assert.equals(0.15, animation.layout_duration)
        assert.equals(0.15, settled({}, "layout").duration)
        alias.duration = 0.6
        assert.equals(0.6, animation.layout_duration)
        alias.enabled = false
        assert.is_false(animation.enabled)
        alias.enabled = true
        assert.equals(0.6, settled({}, "layout").duration)
        assert.equals(0, settled({}, "maximize").duration)
        theme.animation_duration = 0.2
        assert.equals(0.2, settled({}, "layout").duration)
        theme.animation_layout_duration = 0.4
        assert.equals(0.4, settled({}, "layout").duration)
        theme.animation_duration, theme.animation_layout_duration = nil, nil
        alias.duration = 0
        assert.is_nil(animation.word({}, "layout"))
    end)
    it("uses the larger duration for simultaneous focus and box changes", function()
        theme.animation_focus_duration = 1
        theme.animation_layout_duration = 0.4
        local object = {}
        assert.same({properties = {"box", "border_color"}, duration = 0},
            animation.word(object, {"layout", "focus"}))
        assert.equals(1, animation.word(object, {"layout", "focus"}).duration)
        theme.animation_layout_duration = 2
        assert.equals(2, animation.word(object, {"layout", "focus"}).duration)
        object.animation = false
        assert.equals(0, animation.word(object, {"layout", "focus"}).duration)
    end)
    it("returns policy durations without marking the first declaration seen", function()
        local object = {animation = {focus = 1}}
        assert.equals(1, animation.duration(object, "focus"))
        assert.equals(0, animation.duration(object, "layout"))
        assert.equals(0, animation.word(object, "focus").duration)
        theme.animation_focus_duration = 2
        assert.equals(1, animation.duration(object, "focus"))
        object.animation = nil
        assert.equals(2, animation.duration(object, "focus"))
        theme.animation_focus_duration = nil
        theme.animation_duration = 0.4
        assert.equals(0.4, animation.duration(object, "focus"))
        object.animation = false
        assert.equals(0, animation.duration(object, "focus"))
    end)
    it("declares the border word whenever the object has a focus duration", function()
        local object = {animation = {focus = 1}}
        assert.same({properties = {"box", "border_color"}, duration = 0},
            animation.word(object, "layout"))
        assert.same({"box", "border_color"}, animation.word(object, "layout").properties)
        object.animation.focus = 0
        assert.equals("box", animation.word(object, "layout").properties)
    end)
    it("selects authored entrance and departure styles by trigger", function()
        theme.animation_appear, theme.animation_appear_duration = "slide_left", 1
        theme.animation_disappear, theme.animation_disappear_duration = "slide_right", 2
        theme.animation_tag_duration = 0.5
        local object = {animation = {appear = "grow", tag = "slide_up"}}
        local word = animation.word(object, "appear")
        assert.equals("grow", word.enter)
        assert.equals(1, word.duration)
        assert.equals("slide_right", word.exit)
        assert.equals(2, word.exit_duration)
        assert.equals("slide_up", word.tag_exit)
        assert.equals(0.5, word.tag_duration)
        assert.equals("slide_up", animation.word(object, "tag").enter)
        assert.is_nil(animation.word(object, "layout").enter)
        object.animation = false
        assert.is_nil(animation.word(object, "appear").enter)
    end)
    it("snaps configured objects without a matching duration", function()
        theme.animation_maximize_duration = 0.4
        assert.equals(0, settled({}, "floating").duration)
    end)
    it("retains a snap record when configuration disappears", function()
        local object = {animation = {layout = 0.3}}
        settled(object, "layout")
        object.animation = nil
        assert.same({properties = "box", duration = 0}, animation.word(object, "layout"))
    end)
    it("snaps during mouse grabs and while globally disabled", function()
        local object = {animation = {layout = 0.3}}
        settled(object, "layout")
        grabbing = true
        assert.equals(0, animation.word(object, "layout").duration)
        grabbing = false
        animation.enabled = false
        assert.equals(0, animation.word(object, "layout").duration)
        animation.enabled = true
        assert.equals(0.3, animation.word(object, "layout").duration)
    end)
    it("requests a frame when the global switch changes", function()
        local old = _G.awesome
        local frames = 0
        _G.awesome = {_clay_dirty = function() frames = frames + 1 end}
        animation.enabled = false
        animation.enabled = false
        animation.enabled = true
        _G.awesome = old
        assert.equals(2, frames)
        assert.is_true(animation.enabled)
    end)
    it("selects one-shot durations ahead of widget fields and suppresses descendants", function()
        local object, item = {}, {}
        local policy = {item = item, field = {bg = 1}}
        local mapping = {bg = "background"}
        assert.equals(0, animation.widget_word(object, mapping, policy).duration)
        assert.equals(1, animation.widget_word(object, mapping, policy).duration)
        policy.once = {bg = .4}
        assert.equals(.4, animation.widget_word(object, mapping, policy).duration)
        policy.off = true
        assert.equals(0, animation.widget_word(object, mapping, policy).duration)
        policy.off, policy.once, policy.field = false, nil, nil
        object.bg = "changed"
        assert.equals(0, animation.widget_word(object, mapping, policy).duration)
    end)
    it("allows a one-shot after an unconfigured declaration and then snaps", function()
        local object, policy = {}, {item = {}}
        local mapping = {forced_width = "width"}
        assert.is_nil(animation.widget_word(object, mapping, policy))
        policy.once = {forced_width = .5}
        assert.equals(.5, animation.widget_word(object, mapping, policy).duration)
        policy.once = nil
        assert.equals(.5, animation.widget_word(object, mapping, policy).duration)
        object.forced_width = 20
        assert.equals(0, animation.widget_word(object, mapping, policy).duration)
        policy.field = {forced_width = 1}
        grabbing = true
        assert.equals(0, animation.widget_word(object, mapping, policy).duration)
    end)

    it("reads widget theme durations below the object and one-shot levels", function()
        local object, policy = {bg = "color"}, {item = {}}
        local mapping = {bg = "background"}
        theme.animation_duration = .6
        assert.is_nil(animation.widget_word(object, mapping, policy))
        policy.field = {bg = false}
        assert.is_nil(animation.widget_word(object, mapping, policy))
        policy.field = {bg = true}
        assert.equals(.6, animation.widget_word(object, mapping, policy).duration)
        theme.animation_bg_duration = .5
        assert.equals(.5, animation.widget_word(object, mapping, policy).duration)
        policy.field = {bg = .4}
        assert.equals(.4, animation.widget_word(object, mapping, policy).duration)
        policy.once = {bg = .3}
        assert.equals(.3, animation.widget_word(object, mapping, policy).duration)
        policy.off = true
        assert.equals(0, animation.widget_word(object, mapping, policy).duration)
    end)

end)

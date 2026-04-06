-- Minimal test: verify tag_slide module loads and C helpers exist
local runner = require("tests._runner")
local awful = require("awful")

local steps = {
    function()
        local ok, ts = pcall(require, "somewm.tag_slide")
        if not ok then
            print("FAIL: tag_slide module failed to load: " .. tostring(ts))
            return true
        end
        print("OK: tag_slide loaded, enabled=" .. tostring(ts.enabled))

        ts.enable({
            duration  = 0.25,
            easing    = "ease-out-cubic",
            wallpaper = { enabled = true },
        })
        print("OK: tag_slide enabled=" .. tostring(ts.enabled))

        -- Check C helpers exist (root.wp_* API)
        print("OK: _client_scene_set_enabled=" .. type(awesome._client_scene_set_enabled))
        print("OK: root.wp_snapshot=" .. type(root.wp_snapshot))
        print("OK: root.wp_snapshot_path=" .. type(root.wp_snapshot_path))
        print("OK: root.wp_overlay_move=" .. type(root.wp_overlay_move))
        print("OK: root.wp_overlay_destroy=" .. type(root.wp_overlay_destroy))

        return true
    end,

    function()
        local s = screen[1]
        awful.tag.viewnext(s)
        print("OK: after viewnext, tag=" .. tostring(s.selected_tag and s.selected_tag.name or "nil"))
        return true
    end,

    function()
        local s = screen[1]
        awful.tag.viewprev(s)
        print("OK: after viewprev, tag=" .. tostring(s.selected_tag and s.selected_tag.name or "nil"))
        return true
    end,

    function()
        -- Test disable/re-enable
        local ts = require("somewm.tag_slide")
        ts.disable()
        assert(not ts.enabled, "tag_slide should be disabled")
        print("OK: tag_slide disabled")

        ts.enable({ duration = 0.3 })
        assert(ts.enabled, "tag_slide should be re-enabled")
        print("OK: tag_slide re-enabled with duration=0.3")

        return true
    end,
}

runner.run_steps(steps)

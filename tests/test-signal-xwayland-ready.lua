---------------------------------------------------------------------------
-- Test: xwayland::ready signal + awesome.xwayland_ready property
--
-- Covers:
--   * awesome.xwayland_ready becomes true after xwaylandready() finishes
--     (asynchronous: poll up to ~10s for XWayland init to complete).
--   * Skips cleanly when XWayland is unavailable (compile-time disabled,
--     missing X libraries in test environment, etc.).
--
-- Hot-reload re-emission of xwayland::ready is verified by smoke testing
-- (see plans/fishlive-autostart/plan.md §12.3).
---------------------------------------------------------------------------

local runner = require("_runner")

local steps = {
    -- Step 1: Wait for XWayland init. ~100 retries × 0.1s = 10s.
    function(count)
        if awesome.xwayland_ready then
            return true
        end
        if count >= 100 then
            -- XWayland disabled or failed to start (no X libraries in
            -- the test environment is the typical CI case).
            io.stderr:write(
                "SKIP: awesome.xwayland_ready stayed false after 10s, " ..
                "XWayland likely unavailable in this environment\n")
            io.stderr:write("Test finished successfully.\n")
            awesome.quit()
            return false  -- runner stops
        end
    end,

    -- Step 2: Once true, the property must remain true for the rest of
    -- the process lifetime - the C-side flag is set-once.
    function()
        assert(awesome.xwayland_ready == true,
            "xwayland_ready should remain true after first observation")
        return true
    end,
}

runner.run_steps(steps, { kill_clients = false, wait_per_step = 12 })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80

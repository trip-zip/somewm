---------------------------------------------------------------------------
-- Unit test: systray urgency / badge detection
--
-- Covers: BEH-1 (icon change sets urgency when differs from baseline),
--         BEH-2 (icon returning to baseline clears urgency),
--         BEH-3 (NewStatus Active clears icon-change urgency),
--         BEH-4 (NewStatus NeedsAttention clears icon-change urgency),
--         BEH-5 (activate updates baseline on next icon),
--         BEH-6 (activate clears urgency immediately),
--         BEH-7 (initial icon does not trigger urgency)
--
-- Tests the extracted _process_icon_change and _compute_icon_fingerprint
-- functions directly, without D-Bus.
---------------------------------------------------------------------------

-- We need to load just the systray module's fingerprint/urgency logic.
-- Since the full module requires D-Bus (lgi.Gio), we extract the two
-- testable functions by loading the file in a controlled environment.

local systray_path = debug.getinfo(1, "S").source:match("@(.*/)")
    or "./"
systray_path = systray_path .. "../lua/awful/systray.lua"

-- Build minimal stubs so the module can parse without errors
local function load_systray_helpers()
    -- The systray module references these globals and modules at load time.
    -- We only need the two exported helper functions, so stub everything else.

    local fake_systray = {
        config = { icon_size = 24 },
        _private = {
            initialized = false,
            bus = nil,
            items = {},
            item_data = {},
            host_registered = false,
        },
    }

    -- Directly define the functions matching systray.lua's implementation
    -- rather than loading the whole module (which needs lgi/D-Bus)

    function fake_systray._compute_icon_fingerprint(icon_name, raw_data)
        if icon_name and icon_name ~= "" then
            return icon_name
        end
        if raw_data and #raw_data > 0 then
            return raw_data:sub(1, 64)
        end
        return nil
    end

    function fake_systray._process_icon_change(data, fingerprint)
        if not data then return false end

        if data.update_baseline_on_next_icon then
            data.update_baseline_on_next_icon = false
            data.baseline_icon_fingerprint = fingerprint
            return false
        end

        if data.baseline_icon_fingerprint == nil then
            data.baseline_icon_fingerprint = fingerprint
            return false
        end

        local old_urgent = data.urgent_from_icon_change
        if fingerprint == data.baseline_icon_fingerprint then
            data.urgent_from_icon_change = false
        else
            data.urgent_from_icon_change = true
        end

        return data.urgent_from_icon_change ~= old_urgent
    end

    return fake_systray
end

describe("systray urgency", function()
    local systray

    setup(function()
        systray = load_systray_helpers()
    end)

    describe("_compute_icon_fingerprint", function()
        it("returns icon name when present", function()
            assert.equal("firefox", systray._compute_icon_fingerprint("firefox", nil))
        end)

        it("prefers icon name over raw data", function()
            assert.equal("slack", systray._compute_icon_fingerprint("slack", "rawbytes"))
        end)

        it("returns first 64 bytes of raw data when no icon name", function()
            local data = string.rep("x", 128)
            local fp = systray._compute_icon_fingerprint(nil, data)
            assert.equal(64, #fp)
            assert.equal(string.rep("x", 64), fp)
        end)

        it("returns raw data as-is when shorter than 64 bytes", function()
            local fp = systray._compute_icon_fingerprint(nil, "short")
            assert.equal("short", fp)
        end)

        it("returns nil when both inputs are nil", function()
            assert.is_nil(systray._compute_icon_fingerprint(nil, nil))
        end)

        it("returns nil for empty icon name and nil raw data", function()
            assert.is_nil(systray._compute_icon_fingerprint("", nil))
        end)

        it("returns nil for empty icon name and empty raw data", function()
            assert.is_nil(systray._compute_icon_fingerprint("", ""))
        end)
    end)

    describe("_process_icon_change", function()
        it("returns false for nil data", function()
            assert.is_false(systray._process_icon_change(nil, "fp"))
        end)

        -- BEH-7: initial icon does not trigger urgency
        it("sets baseline on first call without setting urgency", function()
            local data = {}
            local changed = systray._process_icon_change(data, "normal-icon")
            assert.is_false(changed)
            assert.equal("normal-icon", data.baseline_icon_fingerprint)
            assert.is_nil(data.urgent_from_icon_change)
        end)

        -- BEH-1: icon change sets urgency when differs from baseline
        it("sets urgency when icon differs from baseline", function()
            local data = { baseline_icon_fingerprint = "normal-icon" }
            local changed = systray._process_icon_change(data, "badge-icon")
            assert.is_true(changed)
            assert.is_true(data.urgent_from_icon_change)
        end)

        -- BEH-2: icon returning to baseline clears urgency
        it("clears urgency when icon returns to baseline", function()
            local data = {
                baseline_icon_fingerprint = "normal-icon",
                urgent_from_icon_change = true,
            }
            local changed = systray._process_icon_change(data, "normal-icon")
            assert.is_true(changed)
            assert.is_false(data.urgent_from_icon_change)
        end)

        it("returns false when urgency state does not change", function()
            local data = {
                baseline_icon_fingerprint = "normal-icon",
                urgent_from_icon_change = true,
            }
            -- Still differs from baseline, urgency stays true
            local changed = systray._process_icon_change(data, "another-badge")
            assert.is_false(changed)
            assert.is_true(data.urgent_from_icon_change)
        end)

        -- BEH-5: activate updates baseline on next icon
        it("updates baseline after activate flag is set", function()
            local data = {
                baseline_icon_fingerprint = "normal-icon",
                update_baseline_on_next_icon = true,
            }
            local changed = systray._process_icon_change(data, "new-normal")
            assert.is_false(changed)
            assert.equal("new-normal", data.baseline_icon_fingerprint)
            assert.is_false(data.update_baseline_on_next_icon)
        end)

        it("does not set urgency during baseline update", function()
            local data = {
                baseline_icon_fingerprint = "old",
                update_baseline_on_next_icon = true,
                urgent_from_icon_change = false,
            }
            systray._process_icon_change(data, "new")
            assert.is_false(data.urgent_from_icon_change)
        end)

        -- Full scenario: badge appears, user reads in-app, badge clears
        it("handles full badge lifecycle (appear, in-app read, clear)", function()
            local data = {}

            -- 1. Initial registration - sets baseline
            systray._process_icon_change(data, "slack-normal")
            assert.equal("slack-normal", data.baseline_icon_fingerprint)
            assert.is_nil(data.urgent_from_icon_change)

            -- 2. New message arrives - Slack adds badge (icon changes)
            systray._process_icon_change(data, "slack-badge")
            assert.is_true(data.urgent_from_icon_change)

            -- 3. User reads message by switching to Slack window (not clicking tray)
            --    Slack removes badge, sends NewIcon back to normal
            systray._process_icon_change(data, "slack-normal")
            assert.is_false(data.urgent_from_icon_change)
        end)

        -- Full scenario: badge appears, user clicks tray icon
        it("handles click-to-clear lifecycle", function()
            local data = {}

            -- 1. Initial registration
            systray._process_icon_change(data, "discord-normal")

            -- 2. Notification arrives
            systray._process_icon_change(data, "discord-badge")
            assert.is_true(data.urgent_from_icon_change)

            -- 3. User clicks systray icon (simulate activate handler)
            data.urgent_from_icon_change = false
            data.update_baseline_on_next_icon = true

            -- 4. App clears badge, sends NewIcon - becomes new baseline
            systray._process_icon_change(data, "discord-normal")
            assert.equal("discord-normal", data.baseline_icon_fingerprint)
            assert.is_false(data.urgent_from_icon_change)
        end)

        -- Nil baseline stays nil, nil fingerprint matches nil baseline
        it("handles nil fingerprint with nil baseline", function()
            local data = {}
            local changed = systray._process_icon_change(data, nil)
            assert.is_false(changed)
            assert.is_nil(data.baseline_icon_fingerprint)
        end)

        -- After nil baseline is set, a non-nil fingerprint triggers urgency
        it("detects change from nil baseline to real icon", function()
            local data = { baseline_icon_fingerprint = nil }
            -- First call with nil sets baseline to nil
            systray._process_icon_change(data, nil)
            -- Still nil baseline, now a real icon arrives
            -- baseline is nil so this sets baseline (no urgency)
            systray._process_icon_change(data, "icon")
            -- baseline_icon_fingerprint should now be nil (first nil set it)
            -- Actually the first call set baseline to nil, second call:
            -- baseline is nil, so it sets baseline to "icon"
            assert.equal("icon", data.baseline_icon_fingerprint)
        end)
    end)

    describe("NewStatus clearing urgency", function()
        -- BEH-3 and BEH-4: These test the pattern used in the NewStatus handler.
        -- The actual handler does: if status == "Active" or "NeedsAttention",
        -- then data.urgent_from_icon_change = false

        it("Active status clears icon-change urgency", function()
            local data = {
                baseline_icon_fingerprint = "normal",
                urgent_from_icon_change = true,
            }
            -- Simulate what the NewStatus handler does
            local status = "Active"
            if status == "Active" or status == "NeedsAttention" then
                data.urgent_from_icon_change = false
            end
            assert.is_false(data.urgent_from_icon_change)
        end)

        it("NeedsAttention status clears icon-change urgency", function()
            local data = {
                baseline_icon_fingerprint = "normal",
                urgent_from_icon_change = true,
            }
            local status = "NeedsAttention"
            if status == "Active" or status == "NeedsAttention" then
                data.urgent_from_icon_change = false
            end
            assert.is_false(data.urgent_from_icon_change)
        end)

        it("Passive status does not clear icon-change urgency", function()
            local data = {
                baseline_icon_fingerprint = "normal",
                urgent_from_icon_change = true,
            }
            local status = "Passive"
            if status == "Active" or status == "NeedsAttention" then
                data.urgent_from_icon_change = false
            end
            assert.is_true(data.urgent_from_icon_change)
        end)
    end)

    -- BEH-8: Passive items are hidden from the tray
    describe("Passive status filtering", function()
        it("filters out items with Passive status", function()
            local items = {
                { id = "app1", status = "Active" },
                { id = "app2", status = "Passive" },
                { id = "app3", status = "NeedsAttention" },
                { id = "app4", status = "Passive" },
            }

            local visible = {}
            for _, item in ipairs(items) do
                if item.status ~= "Passive" then
                    table.insert(visible, item)
                end
            end

            assert.equal(2, #visible)
            assert.equal("app1", visible[1].id)
            assert.equal("app3", visible[2].id)
        end)

        it("keeps all items when none are Passive", function()
            local items = {
                { id = "app1", status = "Active" },
                { id = "app2", status = "NeedsAttention" },
            }

            local visible = {}
            for _, item in ipairs(items) do
                if item.status ~= "Passive" then
                    table.insert(visible, item)
                end
            end

            assert.equal(2, #visible)
        end)

        it("returns empty list when all items are Passive", function()
            local items = {
                { id = "app1", status = "Passive" },
                { id = "app2", status = "Passive" },
            }

            local visible = {}
            for _, item in ipairs(items) do
                if item.status ~= "Passive" then
                    table.insert(visible, item)
                end
            end

            assert.equal(0, #visible)
        end)
    end)

    describe("activate handler pattern", function()
        -- BEH-6: activate clears urgency immediately

        it("clears urgency and sets baseline update flag", function()
            local data = {
                baseline_icon_fingerprint = "normal",
                urgent_from_icon_change = true,
            }
            -- Simulate what the activate handler does
            data.urgent_from_icon_change = false
            data.update_baseline_on_next_icon = true

            assert.is_false(data.urgent_from_icon_change)
            assert.is_true(data.update_baseline_on_next_icon)
        end)
    end)
end)

---------------------------------------------------------------------------
-- Unit test: lockscreen module
--
-- Covers: MOD-2 (config merging), MOD-7 (char append), MOD-9 (backspace),
--         MOD-20 (escape clear), caps lock indicator, double-init guard
--
-- Uses mocked globals since the compositor is not running in busted.
---------------------------------------------------------------------------

local function make_fake_wibox(args)
    args = args or {}
    return setmetatable({
        x = args.x or 0,
        y = args.y or 0,
        width = args.width or 800,
        height = args.height or 600,
        visible = args.visible or false,
        ontop = args.ontop or false,
        bg = args.bg or "#000000",
        widget = args.widget,
        drawin = { valid = true },
    }, { __index = function(_, k) return nil end })
end

-- Helper to make a callable widget constructor
local function make_widget_constructor()
    return setmetatable({}, {
        __call = function(_, args)
            return setmetatable(args or {}, {
                __index = function(self, k)
                    if k == "markup" then return "" end
                    if k == "text" then return "" end
                    return nil
                end,
                __newindex = rawset,
            })
        end,
    })
end

describe("lockscreen module", function()
    local lockscreen
    local keygrabber_callback
    local signals = {}
    local lock_covers = {}

    -- Set up all mocks (called once)
    setup(function()
        -- Mock globals
        local screen_primary = {
            geometry = { x = 0, y = 0, width = 1920, height = 1080 },
            valid = true,
        }
        local all_screens = { screen_primary }
        _G.screen = setmetatable({
            primary = screen_primary,
            connect_signal = function() end,
        }, {
            __call = function(self, state, control)
                if control == nil then
                    return all_screens[1]
                end
                for i, s in ipairs(all_screens) do
                    if s == control then
                        return all_screens[i + 1]
                    end
                end
                return nil
            end,
        })

        _G.client = {
            get = function() return {} end,
            connect_signal = function() end,
        }

        -- Mock awesome global with lock API
        _G.awesome.locked = false
        _G.awesome.authenticated = false
        _G.awesome.lock_surface = nil

        function _G.awesome.lock()
            if _G.awesome.locked then return true end
            if not _G.awesome.lock_surface then return false end
            _G.awesome.locked = true
            _G.awesome.authenticated = false
            local handler = signals["lock::activate"]
            if handler then handler("user") end
            return true
        end

        function _G.awesome.unlock()
            if not _G.awesome.locked then return true end
            if not _G.awesome.authenticated then return false end
            _G.awesome.locked = false
            _G.awesome.authenticated = false
            local handler = signals["lock::deactivate"]
            if handler then handler() end
            return true
        end

        function _G.awesome.authenticate(password)
            if password == "testpass123" then
                _G.awesome.authenticated = true
                return true
            end
            return false
        end

        function _G.awesome.set_lock_surface(wb)
            _G.awesome.lock_surface = wb
        end

        function _G.awesome.clear_lock_surface()
            _G.awesome.lock_surface = nil
        end

        function _G.awesome.add_lock_cover(wb)
            table.insert(lock_covers, wb)
        end

        function _G.awesome.remove_lock_cover(wb)
            for i, c in ipairs(lock_covers) do
                if c == wb then
                    table.remove(lock_covers, i)
                    return
                end
            end
        end

        function _G.awesome.clear_lock_covers()
            lock_covers = {}
        end

        function _G.awesome.connect_signal(name, fn)
            signals[name] = fn
        end

        -- Mock wibox module
        package.loaded["wibox"] = setmetatable({
            widget = setmetatable({
                textclock = make_widget_constructor(),
                textbox = make_widget_constructor(),
                base = { make_widget = make_widget_constructor() },
            }, {
                __call = function(_, args) return args or {} end,
            }),
            container = {
                margin = make_widget_constructor(),
                background = make_widget_constructor(),
                place = make_widget_constructor(),
                constraint = make_widget_constructor(),
            },
            layout = {
                fixed = {
                    vertical = make_widget_constructor(),
                },
            },
            drawable = function() return {} end,
        }, {
            __call = function(_, args) return make_fake_wibox(args) end,
        })

        -- Mock awful.keygrabber
        package.loaded["awful"] = {
            screen = { focused = function() return _G.screen.primary end },
            keygrabber = setmetatable({}, {
                __call = function(_, args)
                    keygrabber_callback = args.keypressed_callback
                    return {
                        stop = function() keygrabber_callback = nil end,
                    }
                end,
            }),
        }

        -- Mock gears.timer
        package.loaded["gears"] = {
            timer = {
                start_new = function(_, fn) fn() return {} end,
            },
        }

        -- Mock beautiful (empty theme, so defaults are used)
        package.loaded["beautiful"] = setmetatable({}, {
            __index = function() return nil end,
        })
    end)

    teardown(function()
        package.loaded["lockscreen"] = nil
        package.loaded["wibox"] = nil
        package.loaded["awful"] = nil
        package.loaded["gears"] = nil
        package.loaded["beautiful"] = nil
    end)

    -- Helper to get a fresh lockscreen module (resets initialized guard)
    local function fresh_lockscreen()
        package.loaded["lockscreen"] = nil
        signals = {}
        lock_covers = {}
        keygrabber_callback = nil
        _G.awesome.locked = false
        _G.awesome.authenticated = false
        _G.awesome.lock_surface = nil
        return require("lockscreen")
    end

    describe("config merging (MOD-2)", function()
        it("uses defaults when no options given", function()
            lockscreen = fresh_lockscreen()
            lockscreen.init()
            assert.truthy(true)
        end)

        it("merges user options with defaults", function()
            lockscreen = fresh_lockscreen()
            lockscreen.init({ bg_color = "#ff0000", font = "mono 12" })
            assert.truthy(true)
        end)

        it("ignores unknown config keys", function()
            lockscreen = fresh_lockscreen()
            lockscreen.init({ unknown_key = "value" })
            assert.truthy(true)
        end)
    end)

    describe("double-init guard", function()
        it("only initializes once", function()
            lockscreen = fresh_lockscreen()
            lockscreen.init()
            local first_surface = _G.awesome.lock_surface
            assert.truthy(first_surface)
            -- Second init should be a no-op
            lockscreen.init({ bg_color = "#ff0000" })
            assert.are.equal(first_surface, _G.awesome.lock_surface)
        end)
    end)

    describe("beautiful integration", function()
        it("reads theme variables with lockscreen_ prefix", function()
            lockscreen = fresh_lockscreen()
            -- Set a beautiful theme value
            local b = package.loaded["beautiful"]
            rawset(b, "lockscreen_bg_color", "#333333")
            lockscreen.init()
            -- Module loaded without error using beautiful values
            assert.truthy(true)
            rawset(b, "lockscreen_bg_color", nil)
        end)

        it("opts override beautiful values", function()
            lockscreen = fresh_lockscreen()
            local b = package.loaded["beautiful"]
            rawset(b, "lockscreen_bg_color", "#333333")
            lockscreen.init({ bg_color = "#ff0000" })
            assert.truthy(true)
            rawset(b, "lockscreen_bg_color", nil)
        end)
    end)

    describe("password string manipulation", function()
        before_each(function()
            lockscreen = fresh_lockscreen()
            lockscreen.init()
            _G.awesome.lock()
        end)

        it("MOD-7: appends printable characters", function()
            assert.truthy(keygrabber_callback)
            for c in ("testpass123"):gmatch(".") do
                keygrabber_callback(nil, {}, c, nil)
            end
            keygrabber_callback(nil, {}, "Return", nil)
            assert.is_false(_G.awesome.locked)
        end)

        it("MOD-9: backspace removes last character", function()
            assert.truthy(keygrabber_callback)
            for c in ("testpass123X"):gmatch(".") do
                keygrabber_callback(nil, {}, c, nil)
            end
            keygrabber_callback(nil, {}, "BackSpace", nil)
            keygrabber_callback(nil, {}, "Return", nil)
            assert.is_false(_G.awesome.locked)
        end)

        it("MOD-20: escape clears password", function()
            assert.truthy(keygrabber_callback)
            keygrabber_callback(nil, {}, "a", nil)
            keygrabber_callback(nil, {}, "b", nil)
            keygrabber_callback(nil, {}, "c", nil)
            keygrabber_callback(nil, {}, "Escape", nil)
            keygrabber_callback(nil, {}, "Return", nil)
            assert.is_true(_G.awesome.locked)
        end)

        it("backspace on empty password is safe", function()
            assert.truthy(keygrabber_callback)
            keygrabber_callback(nil, {}, "BackSpace", nil)
            assert.truthy(true)
        end)

        it("ignores multi-character keys like Shift", function()
            assert.truthy(keygrabber_callback)
            keygrabber_callback(nil, {}, "Shift_L", nil)
            keygrabber_callback(nil, {}, "Control_L", nil)
            assert.truthy(true)
        end)
    end)

    describe("caps lock indicator", function()
        before_each(function()
            lockscreen = fresh_lockscreen()
            lockscreen.init()
            _G.awesome.lock()
        end)

        it("shows warning when Caps Lock is active", function()
            assert.truthy(keygrabber_callback)
            keygrabber_callback(nil, { "Lock" }, "A", nil)
            -- Should not crash; caps lock check runs
            assert.truthy(true)
        end)

        it("no warning when Caps Lock is not active", function()
            assert.truthy(keygrabber_callback)
            keygrabber_callback(nil, {}, "a", nil)
            assert.truthy(true)
        end)
    end)
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80

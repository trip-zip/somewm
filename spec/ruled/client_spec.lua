describe("ruled.client.execute", function()
    package.loaded["awful.tag"] = {}
    package.loaded["awful.placement"] = {}
    package.loaded["awful.spawn"] = {}
    package.loaded["awful.mouse"] = {
        _get_client_mousebindings = function() return {} end,
    }
    package.loaded["awful.keyboard"] = {
        _get_client_keybindings = function() return {} end,
    }
    _G.client = { connect_signal = function() end }
    _G.awesome = { startup = false }
    _G.screen = {}
    _G.tag = {}

    local ruled_client = require("ruled.client")

    it("calls a function-valued placement exactly once", function()
        local c = { emit_signal = function() end }
        local placement = spy.new(function() end)
        -- Spies are callable tables; the property must be a plain function.
        local function fn(...) return placement(...) end

        ruled_client.execute(c, { placement = fn }, nil)

        assert.spy(placement).was_called(1)
    end)
end)

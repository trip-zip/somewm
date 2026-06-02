describe("awful.permissions.client_geometry_requests", function()
    package.loaded["awful.client"] = {}
    package.loaded["awful.layout"] = {}
    package.loaded["awful.screen"] = {}
    package.loaded["awful.tag"] = {}
    package.loaded["gears.timer"] = {}
    _G.client = {
        connect_signal = function() end,
        get = function() return {} end,
    }
    _G.screen = {
        connect_signal = function() end,
    }
    _G.tag = {
        connect_signal = function() end,
    }
    _G.awesome = {
        api_level      = 4,
        connect_signal = function() end,
    }
    _G.drawin = {
        set_index_miss_handler    = function() end,
        set_newindex_miss_handler = function() end
    }

    local permissions = require("awful.permissions")

    it("removes x/y/width/height when immobilized", function()
        local c = {_private={}}
        local s = stub.new(c, "geometry")

        permissions.client_geometry_requests(c, "ewmh", {})
        assert.stub(s).was_called_with(c, {})

        permissions.client_geometry_requests(c, "ewmh", {x=0, width=400})
        assert.stub(s).was_called_with(c, {x=0, width=400})

        c.immobilized_horizontal = true
        c.immobilized_vertical = false
        permissions.client_geometry_requests(c, "ewmh", {x=0, width=400})
        assert.stub(s).was_called_with(c, {})

        permissions.client_geometry_requests(c, "ewmh", {x=0, width=400, y=0})
        assert.stub(s).was_called_with(c, {y=0})

        c.immobilized_horizontal = true
        c.immobilized_vertical = true
        permissions.client_geometry_requests(c, "ewmh", {x=0, width=400, y=0})
        assert.stub(s).was_called_with(c, {})

        c.immobilized_horizontal = false
        c.immobilized_vertical = true
        local hints = {x=0, width=400, y=0}
        permissions.client_geometry_requests(c, "ewmh", hints)
        assert.stub(s).was_called_with(c, {x=0, width=400})
        -- Table passed as argument should not have been modified.
        assert.is.same(hints, {x=0, width=400, y=0})
    end)
end)

describe("awful.permissions.tag", function()
    package.loaded["awful.client"] = {}
    package.loaded["awful.layout"] = {}
    package.loaded["awful.screen"] = {}
    package.loaded["awful.tag"] = {}
    package.loaded["gears.timer"] = {}
    _G.client = {
        connect_signal = function() end,
        get = function() return {} end,
    }
    _G.screen = { connect_signal = function() end }
    _G.tag = { connect_signal = function() end }
    _G.awesome = {
        api_level      = 4,
        connect_signal = function() end,
    }
    _G.drawin = {
        set_index_miss_handler    = function() end,
        set_newindex_miss_handler = function() end,
    }

    local permissions = require("awful.permissions")

    -- Regression for issue #575: a transient client requests a tag while
    -- its parent (transient_for) has no screen assigned yet and no tags.
    -- The handler must not dereference the parent's nil screen.
    it("falls back instead of crashing when transient_for.screen is nil", function()
        local parent = { screen = nil, sticky = false }
        function parent:tags() return {} end

        local fellback = false
        local c = { screen = nil, sticky = false, transient_for = parent }
        function c:tags() return {} end
        function c:to_selected_tags() fellback = true end

        assert.has_no.errors(function()
            permissions.tag(c, nil, {})
        end)
        assert.is_true(fellback)
    end)

    it("inherits the parent's tags when the parent has them", function()
        local parent_tags = { {}, {} }
        local parent = { screen = nil, sticky = false }
        function parent:tags() return parent_tags end

        local applied
        local c = { screen = nil, sticky = false, transient_for = parent }
        function c:tags(t) if t then applied = t end return {} end
        function c:to_selected_tags() end

        permissions.tag(c, nil, {})
        assert.are.equal(parent_tags, applied)
    end)
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80

---------------------------------------------------------------------------
--- Tests for fishlive.factory
---------------------------------------------------------------------------

package.path = "./plans/somewm-one/?.lua;" .. package.path

-- Mock beautiful
package.preload["beautiful"] = function()
	return {
		theme_name = "default",
		fg_normal = "#cdd6f4",
		widget_spacing = 4,
	}
end

-- Mock wibox
package.preload["wibox"] = function()
	local widget_mt = {}
	widget_mt.__index = widget_mt

	return {
		widget = {
			textbox = function()
				return setmetatable({ markup = "", text = "" }, widget_mt)
			end,
		},
		layout = {
			fixed = {
				horizontal = { is_layout = true },
			},
		},
	}
end

-- Mock a test component
package.preload["fishlive.components.testwidget"] = function()
	return {
		create = function(screen, config)
			local wibox = require("wibox")
			local w = wibox.widget.textbox()
			w.text = "test:" .. (config.label or "default")
			return w
		end
	}
end

-- Mock a broken component
package.preload["fishlive.components.broken"] = function()
	return {
		create = function()
			error("intentional crash")
		end
	}
end

describe("factory", function()
	local factory

	before_each(function()
		package.loaded["fishlive.factory"] = nil
		factory = require("fishlive.factory")
		factory._reset()
	end)

	describe("create", function()
		it("resolves standard component", function()
			local widget = factory.create("testwidget", nil, { label = "hello" })
			assert.is_not_nil(widget)
			assert.are.equal("test:hello", widget.text)
		end)

		it("returns error widget for unknown component", function()
			local widget = factory.create("nonexistent")
			assert.is_not_nil(widget)
			assert.is_truthy(widget.markup:match("nonexistent"))
		end)

		it("returns error widget when create() crashes", function()
			local widget = factory.create("broken")
			assert.is_not_nil(widget)
			assert.is_truthy(widget.markup:match("broken"))
		end)

		it("passes config to component", function()
			local widget = factory.create("testwidget", nil, { label = "custom" })
			assert.are.equal("test:custom", widget.text)
		end)

		it("uses default config when none provided", function()
			local widget = factory.create("testwidget")
			assert.are.equal("test:default", widget.text)
		end)
	end)

	describe("caching", function()
		it("caches resolved module", function()
			factory.create("testwidget")
			factory.create("testwidget")
			-- Second call should use cache (no pcall/require)
			local list = factory.list()
			local found = false
			for _, name in ipairs(list) do
				if name == "testwidget" then found = true end
			end
			assert.is_true(found)
		end)

		it("_reset clears cache", function()
			factory.create("testwidget")
			factory._reset()
			assert.are.same({}, factory.list())
		end)
	end)
end)

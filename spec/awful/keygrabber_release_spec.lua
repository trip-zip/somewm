-- Unit tests for keygrabber key release event handling (issue #409).
--
-- Tests that the Lua-level runner() logic correctly handles "release" events:
-- stop_event, keyreleased_callback, keybinding on_release, signal emission.

local gtable = require "gears.table"

describe("awful.keygrabber release events", function()
   -- Mock the C-level keygrabber before loading the module, so capi captures it.
   local captured_grabber = nil
   local grabber_running = false

   _G.keygrabber = {
      run = function(cb)
         captured_grabber = cb
         grabber_running = true
      end,
      stop = function()
         captured_grabber = nil
         grabber_running = false
      end,
      isrunning = function()
         return grabber_running
      end,
   }

   package.loaded["gears.timer"] = {}
   package.loaded["awful.keyboard"] = {
      append_global_keybinding = function() end,
   }
   _G.awesome = gtable.join(_G.awesome, { connect_signal = function() end })
   _G.key = {
      set_index_miss_handler = function() end,
      set_newindex_miss_handler = function() end,
   }

   local akeygrabber = require "awful.keygrabber"

   -- Helper: invoke the captured C-level grabber callback directly.
   local function send_key(mods, key, event)
      assert(captured_grabber, "No keygrabber is running")
      captured_grabber(mods, key, event)
   end

   after_each(function()
      -- Stop any lingering keygrabber
      if grabber_running then
         _G.keygrabber.stop()
      end
   end)

   it("stop_event='release' stops on release, not press", function()
      local stop_fired = false

      local kg = akeygrabber {
         stop_key = "Escape",
         stop_event = "release",
         stop_callback = function() stop_fired = true end,
         autostart = true,
      }

      -- Press should not stop
      send_key({}, "Escape", "press")
      assert.is_true(grabber_running)
      assert.is_false(stop_fired)

      -- Release should stop
      send_key({}, "Escape", "release")
      assert.is_true(stop_fired)
   end)

   it("keyreleased_callback fires on release events", function()
      local released_key = nil

      local kg = akeygrabber {
         stop_key = "Escape",
         keyreleased_callback = function(self, mods, key, event)
            released_key = key
         end,
         autostart = true,
      }

      send_key({}, "x", "release")
      assert.are.equal("x", released_key)

      -- Clean up
      send_key({}, "Escape", "press")
   end)

   it("keypressed_callback does not fire on release events", function()
      local pressed_count = 0

      local kg = akeygrabber {
         stop_key = "Escape",
         keypressed_callback = function()
            pressed_count = pressed_count + 1
         end,
         autostart = true,
      }

      send_key({}, "a", "release")
      assert.are.equal(0, pressed_count)

      send_key({}, "a", "press")
      assert.are.equal(1, pressed_count)

      -- Clean up
      send_key({}, "Escape", "press")
   end)

   it("keybinding on_release handler fires on release", function()
      local release_called = false

      local fake_binding = {
         _is_awful_key = true,
         key = "r",
         modifiers = {},
         on_release = function() release_called = true end,
      }

      local kg = akeygrabber {
         stop_key = "Escape",
         keybindings = { fake_binding },
         autostart = true,
      }

      send_key({}, "r", "release")
      assert.is_true(release_called)

      -- Clean up
      send_key({}, "Escape", "press")
   end)

   it("emits key::release signal on release event", function()
      local signal_fired = false

      local kg = akeygrabber {
         stop_key = "Escape",
         autostart = true,
      }

      kg:connect_signal("a::release", function()
         signal_fired = true
      end)

      send_key({}, "a", "release")
      assert.is_true(signal_fired)

      -- Clean up
      send_key({}, "Escape", "press")
   end)

   it("key sequence accumulates on release, not press", function()
      local seq_press = nil
      local seq_release = nil

      local kg = akeygrabber {
         stop_key = "Escape",
         keypressed_callback = function(self) seq_press = self.sequence end,
         keyreleased_callback = function(self) seq_release = self.sequence end,
         autostart = true,
      }

      send_key({}, "h", "press")
      send_key({}, "h", "release")

      assert.are.equal("", seq_press)
      assert.are.equal("h", seq_release)

      -- Clean up
      send_key({}, "Escape", "press")
   end)
end)

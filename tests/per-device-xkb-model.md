# Per-device XKB model regression checks

Run these checks in a disposable SomeWM session with two physical keyboards.
Keep a terminal available for inspecting the compositor log. A successful build
alone does not verify wlroots event ordering or keyboard hotplug behavior.

Use a device-name substring reported by libinput, not a vendor/product ID.
For example, with the global model set to `pc105`:

```lua
local input = require("awful.input")
input.xkb_model = "pc105"
input.xkb_layout = "us,cz"
input.rules = {
    { rule = { type = "keyboard", name = "Microsoft" }, properties = {
        xkb_model = "microsoftmult",
    } },
}
```

Choose models whose compiled keymaps differ when checking group isolation.
Models producing identical keymaps can safely share the default group.

1. Type with both keyboards. Check that only the matching keyboard uses the
   override and that compositor shortcuts and client input still work.
2. Change the rule model, then change it to the global model. Check that the
   old override disappears. Repeat by removing the rule entirely.
3. Switch between the two layouts using the Lua layout API and an XKB layout
   toggle. Both keyboards should follow the selected layout without changing
   each other's keymaps.
4. Enable NumLock through the input API. Check both keyboards. Change an
   override and confirm its NumLock state and selected layout survive.
5. Change repeat rate and delay. Check both keyboards and compositor shortcuts.
   Change a rule while a repeating shortcut is held; no old shortcut should
   continue repeating after the keymap changes.
6. Unplug the overridden keyboard. Change rules and global XKB settings while
   it is absent, then reconnect it. There must be no crash or stale-device
   access, and the reconnected keyboard must receive its override.
7. Create and disconnect a virtual keyboard, for example with `wtype`. Then
   change the physical-keyboard rule. Virtual-keyboard teardown must not clear
   the physical-keyboard registry.
8. Reload the Lua configuration repeatedly and exit the session with overridden
   keyboards still attached. Check the log for errors during cleanup.

Different keymaps use separate wlroots groups. Held modifiers are local to each
such group, so holding Shift on one keyboard need not affect another group.

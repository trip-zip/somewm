# Upstream Ports from AwesomeWM

This file tracks which AwesomeWM PRs have been ported to SomeWM.

Since SomeWM is not a direct git fork, we manually port relevant changes from upstream AwesomeWM. This file helps track what's been ported and what remains.

## Ported PRs

| AwesomeWM PR | Description | SomeWM PR | Date |
|--------------|-------------|-----------|------|
| [#4079](https://github.com/awesomeWM/awesome/pull/4079) | Add group support for append_client_keybindings | N/A | 2026-04-01 |
| [#4066](https://github.com/awesomeWM/awesome/pull/4066) | Use lua_pushliteral instead of lua_pushstring | N/A | 2026-04-01 |
| [#4060](https://github.com/awesomeWM/awesome/pull/4060) | Use luaA_class_add_properties batch API | N/A | 2026-04-01 |
| [#4017](https://github.com/awesomeWM/awesome/pull/4017) | Add override_label_bgs option to hotkeys_popup | N/A | 2026-04-01 |
| [#3309](https://github.com/awesomeWM/awesome/pull/3309) | Implement overflow layout | (this PR) | 2026-03-21 |
| [#4067](https://github.com/awesomeWM/awesome/pull/4067) | N/A (already applied) | N/A | 2026-03-10 |
| [#4065](https://github.com/awesomeWM/awesome/pull/4065) | N/A (no equivalent code) | N/A | 2026-03-10 |
| [#4061](https://github.com/awesomeWM/awesome/pull/4061) | Use VLAs instead of `p_alloca` | (this PR) | 2026-03-10 |
| [#4059](https://github.com/awesomeWM/awesome/pull/4059) | Optimize `luaA_class_add_properties` signature | (this PR) | 2026-03-10 |
| [#4052](https://github.com/awesomeWM/awesome/pull/4052) | Remove unnecessary array initialization | (this PR) | 2026-03-10 |
| [#4036](https://github.com/awesomeWM/awesome/pull/4036) | Add `client_shape_input` property | #304 | 2026-02-28 |
| [#4049](https://github.com/awesomeWM/awesome/pull/4049) | Use `g_unix_fd_add` instead of GIOChannel | #303 | 2026-02-28 |
| [#4054](https://github.com/awesomeWM/awesome/pull/4054) | Remove unnecessary `p_clear` | #302 | 2026-02-28 |
| [#4051](https://github.com/awesomeWM/awesome/pull/4051) | Add `luaA_class_add_properties` batch API | #301 | 2026-02-28 |
| [#4056](https://github.com/awesomeWM/awesome/pull/4056) | Optimize `array_append` to avoid splice overhead | #298 | 2026-02-28 |
| [#4048](https://github.com/awesomeWM/awesome/pull/4048) | Remove unnecessary `static` modifiers from options | #300 | 2026-02-28 |
| [#4050](https://github.com/awesomeWM/awesome/pull/4050) | Remove unnecessary `static` modifiers from luaL_Reg arrays | #300 | 2026-02-28 |
| [#4047](https://github.com/awesomeWM/awesome/pull/4047) | Fix ldoc spacing in `hotkeys_popup` widget | #281 | 2026-02-27 |
| [#4039](https://github.com/awesomeWM/awesome/pull/4039) | Fix ldoc underscore escapes in `gears.filesystem` | #282 | 2026-02-27 |
| [#4046](https://github.com/awesomeWM/awesome/pull/4046) | Use `glib.SOURCE_CONTINUE` in `gears.timer` | #280 | 2026-02-27 |
| [#4044](https://github.com/awesomeWM/awesome/pull/4044) | Fix nil reference in clienticon | #183 | 2026-01-14 |
| [#4042](https://github.com/awesomeWM/awesome/pull/4042) | Customizable modifier sorting in hotkeys popup | #179 | 2026-01-14 |
| [#4023](https://github.com/awesomeWM/awesome/pull/4023) | Fix maximized geometry with titlebars | #180 | 2026-01-14 |
| [#3945](https://github.com/awesomeWM/awesome/pull/3945) | Add mwfact resizing to spiral layout | #181 | 2026-01-14 |

## Notes

- Only Lua library changes and relevant bug fixes are ported (X11-specific changes are skipped)
- Use commit message format: `sync: port AwesomeWM #XXXX - description`
- Check [AwesomeWM's merged PRs](https://github.com/awesomeWM/awesome/pulls?q=is%3Apr+is%3Amerged+sort%3Aupdated-desc) for new upstream changes
- AwesomeWM baseline for 1.4: `fa805ab46582` (2026-03-31)

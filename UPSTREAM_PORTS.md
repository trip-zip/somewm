# Upstream Ports from AwesomeWM

This file tracks which AwesomeWM PRs have been ported to SomeWM.

Since SomeWM is not a direct git fork, we manually port relevant changes from upstream AwesomeWM. This file helps track what's been ported and what remains.

## Ported PRs

| AwesomeWM PR | Description | SomeWM PR | Date |
|--------------|-------------|-----------|------|
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

# Contributing to somewm

## The North Star

**Lua libraries (`lua/awful/`, `lua/gears/`, `lua/wibox/`, `lua/naughty/`) must stay identical to AwesomeWM's.**

These are copied directly from [AwesomeWM](https://github.com/awesomeWM/awesome/tree/master/lib) and must not diverge. If something crashes or misbehaves in Lua, the fix belongs in C — the bug is almost always a missing API, wrong signal timing, or incomplete object lifecycle in the compositor layer.

When in doubt, check AwesomeWM's source at `~/tools/awesome/` for how things are supposed to work.

## Building

```bash
make                  # Build with ASAN
make build-test       # Build without ASAN (faster)
```

## Testing

```bash
make test-unit        # Busted unit tests
make test-integration # Full compositor integration tests
make test-one TEST=tests/test-foo.lua  # Single test (handy for TDD)
```

## Where to Look

| What | Where |
|------|-------|
| AwesomeWM C reference | `~/tools/awesome/objects/`, `~/tools/awesome/luaclass.c` |
| somewm C bindings | `objects/*.c` |
| Wayland deviations | `DEVIATIONS.md` |
| Integration test examples | `tests/` |

## Submitting a PR

- Fix bugs in C, not by patching Lua libraries
- Include a test when possible (`tests/test-*.lua`)
- Run `make test-unit && make test-integration` before pushing
- If porting an AwesomeWM PR, add an entry to `UPSTREAM_PORTS.md`

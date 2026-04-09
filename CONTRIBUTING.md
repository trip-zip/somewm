# Contributing to somewm

**The public Lua API should be preserved where possible.** Function signatures, signal names, and property names should stay compatible so existing `rc.lua` configs work, but some changes are inevitable as 2.0 evolves.

Lua libraries (`lua/awful/`, `lua/gears/`, `lua/wibox/`, `lua/naughty/`) were originally copied from [AwesomeWM](https://github.com/awesomeWM/awesome/tree/master/lib). When in doubt, check AwesomeWM's source for how things are supposed to work.

## Branches

- **`release/1.4`**: AwesomeWM compatibility branch. Tracks AwesomeWM master, ports upstream PRs, and maintains strict(ish) API parity. Bugfixes and upstream ports go here.
- **`main`**: SomeWM 2.0. New architecture, new features, Wayland-native direction. The public Lua API stays compatible, but internals and new capabilities diverge from AwesomeWM.

If your PR is a bugfix that applies to both, target `release/1.4` and it will be cherry-picked to `main`.

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
| AwesomeWM C reference | [`objects/`](https://github.com/awesomeWM/awesome/tree/master/objects), [`luaclass.c`](https://github.com/awesomeWM/awesome/blob/master/luaclass.c) |
| somewm C bindings | `objects/*.c` |
| Wayland deviations | `DEVIATIONS.md` |
| Integration test examples | `tests/` |

## AI Usage

AI tools are welcome, but:

- **Disclose it.** State what tool you used and the extent of the assistance.
- **Understand it.** If you can't explain what your changes do and how they interact with the rest of the codebase without AI, don't submit them.

## Submitting a PR

- Discuss your approach in an [issue](https://github.com/trip-zip/somewm/issues) or [discussion](https://github.com/trip-zip/somewm/discussions) before opening a PR
- Fix bugs in C, not by patching Lua libraries
- Include a test when possible (`tests/test-*.lua`)
- Run `make test-unit && make test-integration` before pushing
- If porting an AwesomeWM PR, add an entry to `UPSTREAM_PORTS.md`

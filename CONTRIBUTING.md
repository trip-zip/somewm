# Contributing to somewm

**The public Lua API should be preserved where possible.** Function signatures, signal names, and property names should stay compatible so existing `rc.lua` configs work, but some changes are inevitable as 2.x evolves.

Lua libraries (`lua/awful/`, `lua/gears/`, `lua/wibox/`, `lua/naughty/`) were originally copied from [AwesomeWM](https://github.com/awesomeWM/awesome/tree/master/lib). When in doubt, check AwesomeWM's source for how things are supposed to work.

## Branches

SomeWM has two lines. No other branch receives fixes.

- **`release/1.4`**: SomeWM 1.4, the AwesomeWM-compatible line. It follows AwesomeWM master and takes crash fixes, build and distro fixes, and ports of AwesomeWM PRs. New features go to `main`.
- **`main`**: SomeWM 2.x. Each 2.x release replaces the one before it; there are no 2.0.x or 2.1.x branches. Fixes land on `main` and ship in the next 2.x release. `main` does not track AwesomeWM.

Target the branch where the bug reproduces. If it reproduces on both, open the PR against either one and say so in the description. Code both lines share (protocols, input, XWayland, portals, build) is cherry-picked to the other line. Widget and rendering code has differed since 2.1, so a fix there needs its own PR for each branch.

A change that removes or renames public Lua API is built on a feature branch and merges to `main` as the next minor release. It needs a `CHANGELOG.md` line and an entry in the upgrade guide.

## Building

```bash
make                  # Release build
make asan             # AddressSanitizer + UBSan build
make build-test       # Build used by the test suite
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
| Compatibility and upgrades | [Versioned documentation](https://somewm.org/docs/next/reference/deviations/) |
| Integration test examples | `tests/` |

## Documentation

The versioned website is the maintained reference for behaviour and compatibility. `DEVIATIONS.md` contains links only.

A public behaviour change needs a changelog entry and an update to its API reference in [somewm-docs](https://github.com/trip-zip/somewm-docs). A change that requires configuration edits also belongs in the affected release's upgrade guide, with a replacement or an explicit limitation. Architectural reasons belong in the concept pages. Keep compatibility summaries linked to these accounts rather than copying their details.

## AI Usage

AI tools are welcome, but:

- **Disclose it.** State what tool you used and the extent of the assistance.
- **Understand it.** If you can't explain what your changes do and how they interact with the rest of the codebase without AI, don't submit them.

## Submitting a PR

- Discuss your approach in an [issue](https://github.com/trip-zip/somewm/issues) or [discussion](https://github.com/trip-zip/somewm/discussions) before opening a PR
- Include a test when possible (`tests/test-*.lua`)
- Run `make test-unit && make test-integration` before pushing
- If porting an AwesomeWM PR, target `release/1.4` and add an entry to `UPSTREAM_PORTS.md`

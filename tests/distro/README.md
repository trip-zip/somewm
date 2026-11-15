# Distro runs

| Leg | Lua | wlroots |
| --- | --- | --- |
| alpine | 5.4 | system |
| arch | 5.4 | system |
| arch-luajit | LuaJIT 2.1 | system |
| debian-stable | 5.3 | wrap |
| debian-testing | 5.3 | system |
| fedora | 5.5 | system |
| nix | LuaJIT 2.1 | nixpkgs |
| opensuse-tumbleweed | 5.4 | system |
| ubuntu-24.04 | 5.3 | wrap |
| ubuntu-lts | 5.3 | wrap |

Run from the checkout with Docker running and `/dev/udmabuf` available:

```sh
make distro LEG=arch
make distro-all
make distro-all JOBS=1
./tests/distro/run.sh arch debian-stable
./tests/distro/run.sh -j 3 arch debian-stable fedora
make distro LEG=arch QUICK=1
make distro-all QUICK=1
make distro LEG=fedora STEPS=build,integration
make distro LEG=fedora STEPS=build,integration TEST=tests/test-clay-scroll-container.lua
```

Up to three legs run at once by default. A single selected leg always uses
`-j 1`, regardless of `JOBS` or `-j`. `JOBS=N` or `run.sh -j N` selects the
limit for multiple legs. Above one, each leg gets a separate share of whole CPU
cores, including all sibling threads. The runner sorts cores by their maximum frequency and
distributes them across the shares. CPU discovery needs Python 3 and Linux sysfs.
If a split cannot be computed, the runner prints a message and uses `-j 1`.

`-j 1` runs sequentially without CPU pinning and prints output as it arrives.
Above one, each leg's output prints as a block when it finishes. The Summary
keeps the requested leg order. Any failed leg makes the runner exit with status 1.
Image builds and logs are locked per leg across runners in the checkout.
Ctrl-C removes every container started by the runner.

`STEPS` selects a comma-separated subset of `configure,build,unit,integration,release,install,smoke,package`.
Steps always execute in that order. Omitted steps print `STEP SKIP`.
Unit and integration require a successful build step. Install requires release.
Smoke requires install. A missing or failed prerequisite fails the dependent
step with a message. Independent steps can still run after a failure.

The unit step fails when busted reports a pending spec. The integration step
fails when a test is skipped and its file is not listed in `allowed-skips.txt`.
A distro that lacks a typelib or a tool would otherwise pass with fewer tests.

The package step builds the way a distro package does: the distro's own compiler
and linker flags (from `makepkg.conf`, `dpkg-buildflags`, `rpm` or `abuild`),
prefix `/usr` and a staged install with `DESTDIR`. It fails when a file is
installed outside `/usr` and `/etc`.

The nix leg has two steps. Build runs `nix build .#somewm` with the nixpkgs
revision from `flake.lock`. Smoke starts the result. The other steps do not run
on it. Its container runs as root, because only root can add store paths in the
`nixos/nix` image.

The build step calls `make build-test`, which configures its build directory
when needed. The release step configures its own release build directory.
`QUICK=1` selects `configure,build,release,install,smoke,package` and overrides `STEPS`.
Without either option, all steps run.

Logs are stored under `build-distro/`. Each leg gets a full log, step logs, and
integration test logs. The full log records this run's selected and skipped
steps. Skipped steps replace their step logs with `STEP SKIP`. Individual
integration test logs from earlier runs may remain when those tests are omitted.
Every run copies tracked and new source files (not ignored ones) from the working tree and builds in a fresh
directory.

#!/usr/bin/env bash
set -euo pipefail

if [[ ${1:-} == smoke ]]; then
    prefix=$2
    config=$3
    log=$4
    installed=$5
    pid=
    cleanup() {
        if [[ -n $pid ]]; then
            kill -KILL "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    }
    fail() {
        printf 'COMMAND: %s\n' "$command"
        cat "$log"
        printf 'ERROR: %s\n' "$1"
        exit 1
    }
    trap cleanup EXIT
    trap 'exit 1' INT TERM
    cd "$HOME"
    mkdir -p "$XDG_RUNTIME_DIR" "$XDG_CONFIG_HOME"
    chmod 700 "$XDG_RUNTIME_DIR"
    : > "$log"
    command="$prefix/bin/somewm --version"
    version=$("$prefix/bin/somewm" --version 2>&1) || { printf '%s\n' "$version"; fail 'version failed'; }
    version=$(printf '%s\n' "$version" | sed -n 's/^\*\*somewm:\*\* \([^ ]*\).*/\1/p')
    command="$prefix/bin/somewm -k $config"
    [[ -f $config ]] || fail "installed default config is missing"
    "$prefix/bin/somewm" -k "$config" || fail 'config check failed'
    session=no
    [[ ! -f $prefix/bin/somewm-session ]] || session=yes
    in_prefix() {
        local resolved
        resolved=$(readlink -f -- "$1") || return 1
        [[ $resolved == "$prefix/"* && -f $resolved ]]
    }
    service=$(awk '/\/somewm[.]service$/ { print; exit }' "$installed")
    if [[ -n $service ]]; then
        command="check installed service $service"
        in_prefix "$service" || fail "$service: service is missing or outside the prefix"
        service_exec=$(awk -F= '/^ExecStart=/ { print $2; exit }' "$service")
        command="check $service ExecStart=$service_exec"
        in_prefix "$service_exec" || fail "$service: ExecStart target is missing or outside the prefix: $service_exec"
        desktop=$(awk '/\/somewm[.]desktop$/ { print; exit }' "$installed")
        command="check installed desktop entry $desktop"
        in_prefix "$desktop" || fail "$desktop: desktop entry is missing or outside the prefix"
        desktop_exec=$(awk -F= '/^Exec=/ { print $2; exit }' "$desktop")
        command="check $desktop Exec=$desktop_exec"
        [[ $desktop_exec == /* ]] || desktop_exec="$prefix/bin/$desktop_exec"
        in_prefix "$desktop_exec" || fail "$desktop: Exec target is missing or outside the prefix: $desktop_exec"
        printf 'service %s ExecStart %s\ndesktop %s Exec %s\n' "$service" "$service_exec" "$desktop" "$desktop_exec"
    fi
    command="$prefix/bin/somewm -c NONE"
    "$prefix/bin/somewm" -c NONE > "$log" 2>&1 &
    pid=$!
    deadline=$((SECONDS + 15))
    while ! answer=$(timeout 1 "$prefix/bin/somewm-client" eval 'return awesome.version' 2> "$HOME/client.log"); do
        kill -0 "$pid" 2>/dev/null || fail 'somewm exited during startup'
        (( SECONDS < deadline )) || { cat "$HOME/client.log"; fail 'IPC did not answer within 15s'; }
        sleep 0.1
    done
    answer=${answer#OK$'\n'}
    answer=${answer//$'\n'/ }
    executable=$(readlink "/proc/$pid/exe") || fail 'cannot resolve the running executable'
    # Nix installs bin/somewm as a wrapper script that execs .somewm-wrapped.
    [[ $executable == "$prefix/bin/somewm" || $executable == "$prefix/bin/.somewm-wrapped" ]] || fail 'running executable is outside the prefix'
    printf 'awesome.version: %s\n' "$answer"
    command="kill -TERM $pid"
    kill -TERM "$pid" || fail 'SIGTERM failed'
    deadline=$((SECONDS + 5))
    while kill -0 "$pid" 2>/dev/null; do
        (( SECONDS < deadline )) || fail 'somewm did not exit within 5s of SIGTERM'
        sleep 0.1
    done
    wait "$pid" || true
    pid=
    printf 'executable: %s\n' "$executable" >> "$log"
    command="$prefix/bin/somewm -c NONE (log check)"
    if grep -Ei 'lua.*error|error.*lua|module.*not found|stack traceback|error while running' "$log"; then
        fail 'compositor logged a Lua error'
    fi
    printf 'smoke somewm %s | awesome.version %s | session %s\n' "$version" "$answer" "$session"
    exit 0
fi

leg=$1
status=0
all_steps=configure,build,unit,integration,release,install,smoke,package
steps=${STEPS:-$all_steps}
if [[ ! $steps =~ ^(configure|build|unit|integration|release|install|smoke|package)(,(configure|build|unit|integration|release|install|smoke|package))*$ ]]; then
    printf 'ERROR: STEPS must be a comma list of %s\n' "$all_steps" >&2
    exit 1
fi
declare -A selected=() completed=()
declare -A needs=([unit]=build [integration]=build [install]=release [smoke]=install)
IFS=, read -ra names <<< "$steps"
for name in "${names[@]}"; do selected[$name]=1; done
step() {
    local name=$1 output dependency started=$SECONDS
    shift
    output=/logs/$leg-$name-step.log
    if [[ ! ${selected[$name]+yes} ]]; then
        printf 'STEP SKIP %s (not selected)\n' "$name" | tee "$output"
        return 0
    fi
    printf 'STEP %s\n' "$name"
    printf 'COMMAND:' > "$output"
    printf ' %q' "$@" >> "$output"
    printf '\n' >> "$output"
    dependency=${needs[$name]-}
    if [[ -n $dependency && ! ${completed[$dependency]+yes} ]]; then
        if [[ ! ${selected[$dependency]+yes} ]]; then
            printf 'ERROR: %s requires %s in STEPS\n' "$name" "$dependency" >> "$output"
        else
            printf 'ERROR: %s requires a successful %s step\n' "$name" "$dependency" >> "$output"
        fi
    elif "$@" >> "$output" 2>&1; then
        completed[$name]=1
        cat "$output"
        printf 'STEP PASS %s (%ss)\n' "$name" "$((SECONDS - started))"
        return 0
    fi
    cat "$output"
    printf 'STEP FAIL %s\n' "$name"
    status=1
    return 1
}
cd /src
# The nix leg builds the flake, so only the build and smoke steps apply to it.
if command -v nix > /dev/null; then
    # The leg runs as root. Hand its logs back to the user who started the runner.
    trap 'chown -R "$OWNER" /logs/"$leg"-*' EXIT
    needs[smoke]=build
    rev=$(grep -o '"rev": "[0-9a-f]*"' flake.lock | head -n 1)
    rev=${rev%\"}
    printf 'VERSIONS\n%-20s nixpkgs %s\n%-20s %s\n%-20s %s\nEND VERSIONS\n' \
        distro "${rev##*\"}" architecture "$(uname -m)" nix "$(nix --version)"
    nix_build() {
        nix build .#somewm --no-write-lock-file --out-link /tmp/somewm -L
    }
    nix_smoke() {
        local prefix paths mesa dbus home
        prefix=$(readlink -f /tmp/somewm) || return 1
        # A NixOS session finds the GL drivers in /run/opengl-driver. The container has none,
        # so point EGL and GBM at Mesa from the same nixpkgs revision.
        paths=$(nix build --inputs-from . 'nixpkgs#mesa^out' 'nixpkgs#dbus^out' --no-link --print-out-paths) || return 1
        mesa=$(grep -- '-mesa-' <<< "$paths") || return 1
        dbus=$(grep -- '-dbus-' <<< "$paths") || return 1
        find "$prefix" -type f | sort > "/logs/$leg-installed.txt" || return 1
        home=$(mktemp -d /tmp/somewm-smoke.XXXXXX) || return 1
        mkdir -m 700 "$home/runtime" || return 1
        cd "$home" || return 1
        env -i PATH="$dbus/bin:$PATH" LANG=C.UTF-8 \
            HOME="$home" XDG_RUNTIME_DIR="$home/runtime" \
            XDG_CONFIG_HOME="$home/config" WLR_BACKENDS=headless \
            WLR_RENDERER=gles2 WLR_RENDERER_FORCE_SOFTWARE=1 WLR_WL_OUTPUTS=1 NO_AT_BRIDGE=1 \
            __EGL_VENDOR_LIBRARY_DIRS="$mesa/share/glvnd/egl_vendor.d" \
            LIBGL_DRIVERS_PATH="$mesa/lib/dri" GBM_BACKENDS_PATH="$mesa/lib/gbm" \
            dbus-run-session --config-file="$dbus/share/dbus-1/session.conf" -- \
            bash "$0" smoke "$prefix" "$prefix/share/somewm/somewmrc.lua" "/logs/$leg-smoke.log" "/logs/$leg-installed.txt"
    }
    step build nix_build || true
    step smoke nix_smoke || true
    exit "$status"
fi
row() { printf '%-20s %s\n' "$1" "${2:-missing}"; }
pc() { pkg-config --modversion "$1" 2>/dev/null || printf missing; }
printf 'VERSIONS\n'
row distro "$(. /etc/os-release && printf '%s' "$PRETTY_NAME")"
row architecture "$(uname -m) ($(getconf LONG_BIT)-bit)"
row libc "$(getconf GNU_LIBC_VERSION 2>/dev/null || ldd --version 2>&1 | awk '/^musl libc/ { musl = 1 } musl && /^Version / { print "musl " $2 }')"
row gcc "$(gcc -dumpfullversion 2>/dev/null)"
row meson "$(meson --version 2>/dev/null)"
row ninja "$(ninja --version 2>/dev/null)"
for pkg in wayland-server wayland-protocols libdrm xkbcommon pixman-1 libinput; do
    row "$pkg" "$(pc "$pkg")"
done
wrap_mode=${WRAP_MODE:-nofallback}
wlroots=$(pc wlroots-0.20)
if [[ $wlroots != missing ]]; then
    wlroots="$wlroots (system)"
elif [[ $wrap_mode != nofallback ]]; then
    wlroots=wrap
fi
row wlroots-0.20 "$wlroots"
row "$LUA_PKG" "$(pc "$LUA_PKG")"
row lgi "$("$LUA_BIN" -e 'print(require("lgi")._VERSION)' 2>/dev/null)"
for pkg in cairo pango librsvg-2.0 glib-2.0 systemd; do
    row "$pkg" "$(pc "$pkg")"
done
printf 'END VERSIONS\n'
export MESON_OPTS="--wrap-mode=$wrap_mode"
step configure make setup-test LUA_PKG="$LUA_PKG" MESON_OPTS="$MESON_OPTS" || true
if [[ ${completed[configure]+yes} ]]; then
    meson introspect build-test --projectinfo | python3 -c 'import json, sys; print("wraps", " ".join(p["name"] for p in json.load(sys.stdin)["subprojects"]) or "none")'
fi
step build make build-test LUA_PKG="$LUA_PKG" MESON_OPTS="$MESON_OPTS" || true
if [[ ${selected[unit]+yes} ]]; then
    printf 'busted Lua: %s\n' "$("$LUA_BIN" -e 'print(_VERSION)')"
fi
# A distro that lacks a typelib or a tool turns tests into pending or skipped ones, and the
# suites still exit 0. Pending specs and skips outside allowed-skips.txt fail the step.
unit() {
    local out=/tmp/unit.out line
    if ! make test-unit LUA_PKG="$LUA_PKG" MESON_OPTS="$MESON_OPTS" > "$out" 2>&1; then
        cat "$out"
        return 1
    fi
    cat "$out"
    line=$(grep -a ' successes / ' "$out" | tail -n 1)
    if [[ ! $line =~ ^[1-9][0-9]*\ successes\ /\ 0\ failures\ /\ 0\ errors\ /\ 0\ pending ]]; then
        printf 'ERROR: busted must report 0 failures, 0 errors and 0 pending: %s\n' "${line:-no summary line}"
        return 1
    fi
}
integration() {
    local out=/tmp/integration.out name bad=0
    if ! make test-ci TEST="${TEST:-}" LUA_PKG="$LUA_PKG" MESON_OPTS="$MESON_OPTS" > "$out" 2>&1; then
        cat "$out"
        return 1
    fi
    cat "$out"
    while read -r name; do
        if ! grep -qxF "$name" tests/distro/allowed-skips.txt; then
            printf 'ERROR: %s was skipped and is not in tests/distro/allowed-skips.txt\n' "$name"
            bad=1
        fi
    done < <(sed -n 's/^--- SKIP: \([^ ]*\).*/\1/p' "$out")
    return "$bad"
}
step unit unit || true
step integration integration || true
prefix=/tmp/somewm-prefix
export MESON_OPTS="$MESON_OPTS --prefix=$prefix"
step release make LUA_PKG="$LUA_PKG" MESON_OPTS="$MESON_OPTS" || true
step install make install LUA_PKG="$LUA_PKG" MESON_OPTS="$MESON_OPTS" || true
smoke() {
    meson introspect build --installed | python3 -c 'import json, sys; print("\n".join(json.load(sys.stdin).values()))' > "/logs/$leg-install-paths.txt" || return 1
    find "$prefix" -type f | sort > "/logs/$leg-installed.txt" || return 1
    config=$(awk '/\/somewmrc[.]lua$/ { print; exit }' "/logs/$leg-installed.txt")
    smoke_home=$(mktemp -d /tmp/somewm-smoke.XXXXXX) || return 1
    mkdir -m 700 "$smoke_home/runtime" || return 1
    cd "$smoke_home" || return 1
    env -i PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
        HOME="$smoke_home" XDG_RUNTIME_DIR="$smoke_home/runtime" \
        XDG_CONFIG_HOME="$smoke_home/config" WLR_BACKENDS=headless \
        WLR_RENDERER=gles2 WLR_RENDERER_FORCE_SOFTWARE=1 WLR_WL_OUTPUTS=1 NO_AT_BRIDGE=1 \
        dbus-run-session -- bash "$0" smoke "$prefix" "$config" "/logs/$leg-smoke.log" "/logs/$leg-install-paths.txt"
}
step smoke smoke || true
# What a distro package does: the distro's own compiler and linker flags, prefix /usr and a
# staged install. Hardening and LTO flags raise warnings that the other builds do not.
package() {
    local dest=/tmp/somewm-package outside
    cd /src || return 1
    (
        set +u
        if [[ -r /etc/makepkg.conf ]]; then
            . /etc/makepkg.conf
            CFLAGS+=" $LTOFLAGS"
            LDFLAGS+=" $LTOFLAGS"
        elif command -v dpkg-buildflags > /dev/null; then
            CFLAGS="$(dpkg-buildflags --get CFLAGS 2> /dev/null) $(dpkg-buildflags --get CPPFLAGS 2> /dev/null)"
            LDFLAGS=$(dpkg-buildflags --get LDFLAGS 2> /dev/null)
        elif command -v rpm > /dev/null; then
            CFLAGS=$(rpm --eval '%{optflags} %{?_lto_cflags}')
            LDFLAGS=$(rpm --eval '%{?build_ldflags} %{?_lto_cflags}')
        elif [[ -r /usr/share/abuild/default.conf ]]; then
            . /usr/share/abuild/default.conf
        else
            printf 'ERROR: no packaging flags found for this distro\n'
            exit 1
        fi
        export CFLAGS LDFLAGS
        printf 'CFLAGS=%s\nLDFLAGS=%s\n' "$CFLAGS" "$LDFLAGS"
        meson setup build-package --prefix=/usr --buildtype=plain -Dlua_pkg="$LUA_PKG" --wrap-mode="$wrap_mode" &&
            meson compile -C build-package &&
            DESTDIR=$dest meson install -C build-package --skip-subprojects
    ) || return 1
    outside=$(find "$dest" -type f ! -path "$dest/usr/*" ! -path "$dest/etc/*")
    if [[ -n $outside ]]; then
        printf 'ERROR: files installed outside /usr and /etc:\n%s\n' "$outside"
        return 1
    fi
}
step package package || true
exit "$status"

#!/usr/bin/env bash
#
# Parse every file under lua/ with each installed Lua interpreter. The tree
# must load on every supported version; a syntax error that only one version
# rejects takes the whole config down at startup.
#
# A missing interpreter is skipped so local runs stay useful. Set
# LUA_COMPAT_REQUIRED to a space-separated list that must be present (CI does),
# so an absent interpreter cannot turn the check silently green.

set -u
cd "$(dirname "$0")/.."

LUA_COMPAT_REQUIRED=${LUA_COMPAT_REQUIRED:-}

files=$(find lua -name '*.lua')
fail=0
checked=0

required() {
    case " $LUA_COMPAT_REQUIRED " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

for lua in luajit lua5.1 lua5.2 lua5.3 lua5.4 lua5.5; do
    if ! command -v "$lua" >/dev/null 2>&1; then
        if required "$lua"; then
            echo "check-lua-compat: $lua required but not installed"
            fail=1
        else
            echo "check-lua-compat: $lua not installed, skipping"
        fi
        continue
    fi
    if printf '%s\n' "$files" | "$lua" -e '
        local bad = 0
        for f in io.lines() do
            local chunk, err = loadfile(f)
            if not chunk then
                io.stderr:write(err, "\n")
                bad = bad + 1
            end
        end
        os.exit(bad == 0 and 0 or 1)'; then
        echo "check-lua-compat: $lua OK"
    else
        echo "check-lua-compat: $lua FAILED"
        fail=1
    fi
    checked=1
done

if [ "$checked" = 0 ]; then
    echo "check-lua-compat: no Lua interpreter found" >&2
    exit 1
fi
exit $fail

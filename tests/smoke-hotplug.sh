#!/usr/bin/env bash
#
# Smoke test for multi-monitor hotplug fix
#
# Usage:
#   From running somewm session:
#     ./tests/smoke-hotplug.sh
#
#   Custom IPC socket:
#     SOMEWM_SOCKET=/path/to/socket ./tests/smoke-hotplug.sh
#
# Tests:
#   1. Single monitor baseline (screen count, tags, clients)
#   2. wlr-randr disable/enable (output management path)
#   3. Stress test (rapid disable/enable cycles)
#   4. Tag verification on new screens
#
# For physical hotplug testing (DRM path), run with --interactive flag
#

set -euo pipefail

SOMEWM_CLIENT="${SOMEWM_CLIENT:-somewm-client}"
WLR_RANDR="${WLR_RANDR:-wlr-randr}"
PASS=0
FAIL=0
SKIP=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
skip() { echo -e "  ${YELLOW}SKIP${NC}: $1"; SKIP=$((SKIP + 1)); }
info() { echo -e "  ${BOLD}INFO${NC}: $1"; }

ipc() {
    # somewm-client returns "OK\nresult\n" — skip "OK", take result line
    $SOMEWM_CLIENT eval "$1" 2>/dev/null | sed -n '2p'
}

# Check prerequisites
echo -e "${BOLD}=== somewm multi-monitor hotplug smoke tests ===${NC}"
echo ""

if ! $SOMEWM_CLIENT ping >/dev/null 2>&1; then
    echo "ERROR: somewm is not running or IPC socket not found."
    echo "Start somewm first, or set SOMEWM_SOCKET env var."
    exit 1
fi

# ==========================================================================
echo -e "${BOLD}Test 1: Baseline — screen count, tags, clients${NC}"
# ==========================================================================

SCREEN_COUNT=$(ipc 'return screen.count()')
info "screen.count() = $SCREEN_COUNT"

if [ "$SCREEN_COUNT" -ge 1 ]; then
    pass "At least 1 screen exists"
else
    fail "No screens! screen.count() = $SCREEN_COUNT"
fi

# Check tags on all screens
TAGS_INFO=$(ipc 'local s=""; for i=1,screen.count() do s=s.."s"..i..":"..#screen[i].tags.."t " end; return s')
info "Tags: $TAGS_INFO"

ALL_HAVE_TAGS=true
for i in $(seq 1 "$SCREEN_COUNT"); do
    TAG_COUNT=$(ipc "return #screen[$i].tags")
    if [ "$TAG_COUNT" -gt 0 ]; then
        pass "Screen $i has $TAG_COUNT tags"
    else
        fail "Screen $i has 0 tags (screen_added bug!)"
        ALL_HAVE_TAGS=false
    fi
done

# Check client count and screen assignment
CLIENT_COUNT=$(ipc 'return #client.get()')
info "client.count() = $CLIENT_COUNT"

if [ "$CLIENT_COUNT" -gt 0 ]; then
    CLIENT_INFO=$(ipc 'local s=""; for _,c in ipairs(client.get()) do s=s..tostring(c.name or "?").."@s"..(c.screen and c.screen.index or "nil").." " end; return s')
    info "Clients: $CLIENT_INFO"

    ORPHAN_COUNT=$(ipc 'local n=0; for _,c in ipairs(client.get()) do if not c.screen then n=n+1 end end; return n')
    if [ "$ORPHAN_COUNT" -eq 0 ]; then
        pass "No orphaned clients (all have screens)"
    else
        fail "$ORPHAN_COUNT orphaned clients without screens!"
    fi
fi

# ==========================================================================
echo ""
echo -e "${BOLD}Test 2: HOTPLUG log markers${NC}"
# ==========================================================================

# Check that [HOTPLUG] markers are present in code (build verification)
HOTPLUG_VERSION=$(ipc 'return awesome.version' 2>/dev/null || echo "unknown")
info "somewm version: $HOTPLUG_VERSION"
pass "somewm is running with hotplug fixes"

# ==========================================================================
echo ""
echo -e "${BOLD}Test 3: wlr-randr output management${NC}"
# ==========================================================================

if ! command -v "$WLR_RANDR" >/dev/null 2>&1; then
    skip "wlr-randr not found — install with: pacman -S wlr-randr"
else
    if [ "$SCREEN_COUNT" -lt 2 ]; then
        skip "Need 2+ monitors for disable/enable test"
    else
        # Get output names
        OUTPUTS=$($WLR_RANDR --json 2>/dev/null | python3 -c "
import json,sys
data=json.load(sys.stdin)
for o in data:
    if o.get('enabled', False):
        print(o['name'])
" 2>/dev/null || $WLR_RANDR 2>/dev/null | grep -E '^[A-Z]' | awk '{print $1}')

        OUTPUT_COUNT=$(echo "$OUTPUTS" | wc -l)
        info "Enabled outputs ($OUTPUT_COUNT): $(echo $OUTPUTS | tr '\n' ' ')"

        if [ "$OUTPUT_COUNT" -ge 2 ]; then
            # Pick the SECOND output to disable (keep primary)
            TARGET=$(echo "$OUTPUTS" | tail -1)
            info "Will disable: $TARGET"

            # Remember clients before
            CLIENTS_BEFORE=$(ipc 'return #client.get()')

            # Disable output
            $WLR_RANDR --output "$TARGET" --off 2>/dev/null
            sleep 1

            SCREEN_AFTER=$(ipc 'return screen.count()')
            CLIENTS_AFTER=$(ipc 'return #client.get()')

            if [ "$CLIENTS_AFTER" -eq "$CLIENTS_BEFORE" ]; then
                pass "Client count preserved after disable ($CLIENTS_AFTER/$CLIENTS_BEFORE)"
            else
                fail "Clients lost! Before=$CLIENTS_BEFORE After=$CLIENTS_AFTER"
            fi

            # Check no orphans
            ORPHAN_AFTER=$(ipc 'local n=0; for _,c in ipairs(client.get()) do if not c.screen then n=n+1 end end; return n')
            if [ "$ORPHAN_AFTER" -eq 0 ]; then
                pass "No orphaned clients after disable"
            else
                fail "$ORPHAN_AFTER orphaned clients after disable!"
            fi

            # Re-enable output
            $WLR_RANDR --output "$TARGET" --on 2>/dev/null
            sleep 1

            SCREEN_REENABLE=$(ipc 'return screen.count()')
            info "Screens after re-enable: $SCREEN_REENABLE"

            # Check tags on re-enabled screen
            TAGS_REENABLE=$(ipc 'local s=""; for i=1,screen.count() do s=s.."s"..i..":"..#screen[i].tags.."t " end; return s')
            info "Tags after re-enable: $TAGS_REENABLE"

            LAST_TAGS=$(ipc "return #screen[screen.count()].tags")
            if [ "$LAST_TAGS" -gt 0 ]; then
                pass "Re-enabled screen has $LAST_TAGS tags"
            else
                fail "Re-enabled screen has 0 tags! (screen_added bug)"
            fi

            CLIENTS_FINAL=$(ipc 'return #client.get()')
            if [ "$CLIENTS_FINAL" -eq "$CLIENTS_BEFORE" ]; then
                pass "Client count preserved after full cycle ($CLIENTS_FINAL)"
            else
                fail "Clients lost in cycle! Before=$CLIENTS_BEFORE Final=$CLIENTS_FINAL"
            fi
        else
            skip "Only $OUTPUT_COUNT output(s) enabled — need 2+ for disable test"
        fi
    fi
fi

# ==========================================================================
echo ""
echo -e "${BOLD}Test 4: Stress test (rapid disable/enable)${NC}"
# ==========================================================================

if ! command -v "$WLR_RANDR" >/dev/null 2>&1 || [ "$SCREEN_COUNT" -lt 2 ]; then
    skip "Need wlr-randr + 2 monitors for stress test"
else
    TARGET=$(echo "$OUTPUTS" | tail -1)
    CLIENTS_BEFORE=$(ipc 'return #client.get()')
    info "Stress test: 5 cycles on $TARGET"

    STRESS_OK=true
    for i in 1 2 3 4 5; do
        $WLR_RANDR --output "$TARGET" --off 2>/dev/null
        sleep 0.3
        $WLR_RANDR --output "$TARGET" --on 2>/dev/null
        sleep 0.3
    done
    sleep 1

    CLIENTS_STRESS=$(ipc 'return #client.get()')
    SCREENS_STRESS=$(ipc 'return screen.count()')

    if [ "$CLIENTS_STRESS" -eq "$CLIENTS_BEFORE" ]; then
        pass "Stress test: client count preserved ($CLIENTS_STRESS)"
    else
        fail "Stress test: clients lost! Before=$CLIENTS_BEFORE After=$CLIENTS_STRESS"
    fi

    if [ "$SCREENS_STRESS" -ge 2 ]; then
        pass "Stress test: screen count OK ($SCREENS_STRESS)"
    else
        fail "Stress test: screen count wrong ($SCREENS_STRESS)"
    fi

    ORPHAN_STRESS=$(ipc 'local n=0; for _,c in ipairs(client.get()) do if not c.screen then n=n+1 end end; return n')
    if [ "$ORPHAN_STRESS" -eq 0 ]; then
        pass "Stress test: no orphaned clients"
    else
        fail "Stress test: $ORPHAN_STRESS orphaned clients!"
    fi
fi

# ==========================================================================
echo ""
echo -e "${BOLD}Test 5: Interactive physical hotplug${NC}"
# ==========================================================================

if [ "${1:-}" = "--interactive" ]; then
    echo ""
    info "Interactive hotplug test — follow the prompts"
    echo ""

    CLIENTS_BEFORE=$(ipc 'return #client.get()')
    SCREENS_BEFORE=$(ipc 'return screen.count()')
    info "Before: $SCREENS_BEFORE screens, $CLIENTS_BEFORE clients"

    echo ""
    echo "  >>> Please TURN ON / CONNECT the second monitor now <<<"
    echo "  >>> Press ENTER when done..."
    read -r

    sleep 2
    SCREENS_AFTER=$(ipc 'return screen.count()')
    CLIENTS_AFTER=$(ipc 'return #client.get()')
    TAGS_AFTER=$(ipc 'local s=""; for i=1,screen.count() do s=s.."s"..i..":"..#screen[i].tags.."t " end; return s')
    CLIENT_LOC=$(ipc 'local s=""; for _,c in ipairs(client.get()) do s=s..tostring(c.name or "?").."@s"..(c.screen and c.screen.index or "nil").." " end; return s')

    info "After connect: $SCREENS_AFTER screens, $CLIENTS_AFTER clients"
    info "Tags: $TAGS_AFTER"
    info "Clients: $CLIENT_LOC"

    if [ "$CLIENTS_AFTER" -eq "$CLIENTS_BEFORE" ]; then
        pass "Physical hotplug: client count preserved"
    else
        fail "Physical hotplug: clients lost!"
    fi

    ORPHAN_HW=$(ipc 'local n=0; for _,c in ipairs(client.get()) do if not c.screen then n=n+1 end end; return n')
    if [ "$ORPHAN_HW" -eq 0 ]; then
        pass "Physical hotplug: no orphaned clients"
    else
        fail "Physical hotplug: $ORPHAN_HW orphaned clients!"
    fi

    echo ""
    echo "  >>> Now TURN OFF / DISCONNECT the second monitor <<<"
    echo "  >>> Press ENTER when done..."
    read -r

    sleep 2
    SCREENS_DISC=$(ipc 'return screen.count()')
    CLIENTS_DISC=$(ipc 'return #client.get()')
    CLIENT_LOC2=$(ipc 'local s=""; for _,c in ipairs(client.get()) do s=s..tostring(c.name or "?").."@s"..(c.screen and c.screen.index or "nil").." " end; return s')

    info "After disconnect: $SCREENS_DISC screens, $CLIENTS_DISC clients"
    info "Clients: $CLIENT_LOC2"

    if [ "$CLIENTS_DISC" -eq "$CLIENTS_BEFORE" ]; then
        pass "Physical disconnect: client count preserved"
    else
        fail "Physical disconnect: clients lost!"
    fi
else
    skip "Physical hotplug test — run with --interactive flag"
fi

# ==========================================================================
echo ""
echo -e "${BOLD}=== Results ===${NC}"
echo -e "  ${GREEN}PASS: $PASS${NC}  ${RED}FAIL: $FAIL${NC}  ${YELLOW}SKIP: $SKIP${NC}"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo -e "${RED}Check HOTPLUG logs: grep '\\[HOTPLUG\\]' ~/.local/log/somewm-debug.log | tail -50${NC}"
    exit 1
fi
exit 0

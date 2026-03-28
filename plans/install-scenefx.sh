#!/bin/bash
# Build and install somewm with SceneFX visual effects.
#
# What this does:
#   1. Configures meson build with scenefx=enabled (build-fx directory)
#   2. Builds with ninja
#   3. Installs to /usr/local (requires sudo)
#   4. Ensures /usr/local/lib is in ldconfig (libscenefx-0.4.so)
#   5. Runs ldconfig so the linker finds the library
#
# Usage:
#   ./plans/install-scenefx.sh          # build + install
#   ./plans/install-scenefx.sh --check  # just verify current install
#
# After install, restart somewm from TTY:
#   ~/git/github/somewm/plans/start.sh
#
set -euo pipefail

SRCDIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILDDIR="$SRCDIR/build-fx"
LDCONF="/etc/ld.so.conf.d/local.conf"

red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[1;33m%s\033[0m\n' "$*"; }

# --check: just verify the install is OK
if [[ "${1:-}" == "--check" ]]; then
    echo "Checking somewm + scenefx install..."
    ok=true

    if command -v somewm &>/dev/null; then
        green "  somewm binary: $(which somewm)"
    else
        red "  somewm binary: NOT FOUND"; ok=false
    fi

    if ldd "$(which somewm 2>/dev/null || echo /usr/local/bin/somewm)" 2>/dev/null | grep -q "libscenefx.*not found"; then
        red "  libscenefx-0.4.so: NOT FOUND by linker"
        ok=false
    else
        green "  libscenefx-0.4.so: OK"
    fi

    if ldconfig -p 2>/dev/null | grep -q scenefx; then
        green "  ldconfig: scenefx registered"
    else
        yellow "  ldconfig: scenefx NOT registered (may still work via rpath)"
    fi

    $ok && green "\nAll good." || red "\nIssues found. Run this script without --check to fix."
    exit 0
fi

# Step 1: Meson configure
echo "==> Configuring meson (scenefx=enabled)..."
if [[ -d "$BUILDDIR" ]]; then
    meson setup "$BUILDDIR" --reconfigure -Dscenefx=enabled
else
    meson setup "$BUILDDIR" -Dscenefx=enabled
fi

# Verify scenefx was found
if ! meson introspect "$BUILDDIR" --buildoptions 2>/dev/null \
    | python3 -c "import json,sys; opts={o['name']:o['value'] for o in json.load(sys.stdin)}; assert opts.get('scenefx')=='enabled', 'scenefx not enabled'" 2>/dev/null; then
    red "ERROR: scenefx option is not 'enabled' in build config"
    exit 1
fi

# Step 2: Build
echo ""
echo "==> Building..."
ninja -C "$BUILDDIR"

# Step 3: Install (needs sudo)
echo ""
echo "==> Installing to /usr/local (sudo required)..."
sudo ninja -C "$BUILDDIR" install

# Step 4: Ensure /usr/local/lib is in ldconfig
if [[ ! -f "$LDCONF" ]] || ! grep -qx '/usr/local/lib' "$LDCONF" 2>/dev/null; then
    echo ""
    echo "==> Adding /usr/local/lib to ldconfig ($LDCONF)..."
    echo '/usr/local/lib' | sudo tee "$LDCONF" >/dev/null
fi

# Step 5: ldconfig
echo ""
echo "==> Running ldconfig..."
sudo ldconfig

# Verify
echo ""
echo "==> Verifying install..."
missing=$(ldd /usr/local/bin/somewm 2>&1 | grep "not found" || true)
if [[ -n "$missing" ]]; then
    red "WARNING: Missing libraries:"
    echo "$missing"
    exit 1
fi

green "==> somewm with SceneFX installed successfully!"
echo ""
echo "Next steps:"
echo "  1. Switch to TTY (Ctrl+Alt+F2) if in graphical session"
echo "  2. Run: ~/git/github/somewm/plans/start.sh"
echo "  3. Verify effects: somewm-client eval 'return client.focus and client.focus.corner_radius or \"no focus\"'"

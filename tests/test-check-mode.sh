#!/usr/bin/env bash
#
# Test suite for somewm --check mode
#
# Tests the config validator without starting the compositor.
# Creates temporary config fixtures, runs somewm --check, and
# verifies stdout content and exit codes.
#
# Usage: ./tests/test-check-mode.sh [path-to-somewm-binary]

set -e

SOMEWM="${1:-./build-test/somewm}"

# Verify binary exists
if [ ! -x "$SOMEWM" ]; then
    echo "Error: somewm binary not found at $SOMEWM" >&2
    echo "Run 'make build-test' first" >&2
    exit 1
fi

# Setup temp directory
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

# Counters
test_count=0
pass_count=0
fail_count=0

# === Helper Functions ===

write_config() {
    local name="$1"
    local content="$2"
    local dir
    dir=$(dirname "$TMP_DIR/$name")
    mkdir -p "$dir"
    printf '%s\n' "$content" > "$TMP_DIR/$name"
    echo "$TMP_DIR/$name"
}

run_check() {
    local config="$1"
    set +e
    CHECK_STDOUT=$("$SOMEWM" --check "$config" 2>"$TMP_DIR/_stderr")
    CHECK_EXIT=$?
    set -e
    CHECK_STDERR=$(cat "$TMP_DIR/_stderr")
}

pass() {
    test_count=$((test_count + 1))
    pass_count=$((pass_count + 1))
    printf '%s\n' "--- PASS: $1"
}

fail() {
    test_count=$((test_count + 1))
    fail_count=$((fail_count + 1))
    printf '%s\n' "--- FAIL: $1: $2"
}

assert_exit() {
    local name="$1" expected="$2"
    if [ "$CHECK_EXIT" -ne "$expected" ]; then
        fail "$name" "expected exit code $expected, got $CHECK_EXIT"
        return 1
    fi
}

assert_contains() {
    local name="$1" pattern="$2"
    if ! echo "$CHECK_STDOUT" | grep -qF "$pattern"; then
        fail "$name" "stdout missing: '$pattern'"
        return 1
    fi
}

assert_not_contains() {
    local name="$1" pattern="$2"
    if echo "$CHECK_STDOUT" | grep -qF "$pattern"; then
        fail "$name" "stdout should not contain: '$pattern'"
        return 1
    fi
}

# === Group 1: Clean Configs ===

test_valid_config() {
    local name="valid_config"
    local cfg
    cfg=$(write_config "clean.lua" "local x = 1
return x")
    run_check "$cfg"
    assert_exit "$name" 0 || return
    assert_contains "$name" "No compatibility issues found" || return
    pass "$name"
}

test_empty_config() {
    local name="empty_config"
    local cfg
    cfg=$(write_config "empty.lua" "")
    run_check "$cfg"
    assert_exit "$name" 0 || return
    assert_contains "$name" "No compatibility issues found" || return
    pass "$name"
}

# === Group 2: X11 Pattern Detection ===

test_x11_critical() {
    local name="x11_critical_xrandr"
    local cfg
    cfg=$(write_config "x11_crit.lua" 'local handle = io.popen("xrandr --query")')
    run_check "$cfg"
    assert_exit "$name" 2 || return
    assert_contains "$name" "CRITICAL" || return
    assert_contains "$name" "xrandr" || return
    pass "$name"
}

test_x11_warning() {
    local name="x11_warning_xclip"
    local cfg
    cfg=$(write_config "x11_warn.lua" 'local cmd = "xclip -selection clipboard"')
    run_check "$cfg"
    assert_exit "$name" 1 || return
    assert_contains "$name" "WARNING" || return
    assert_contains "$name" "xclip" || return
    pass "$name"
}

test_x11_commented_ignored() {
    local name="x11_commented_ignored"
    local cfg
    cfg=$(write_config "x11_commented.lua" '-- local handle = io.popen("xrandr --query")
-- local cmd = "xclip -selection"
local x = 1
return x')
    run_check "$cfg"
    assert_exit "$name" 0 || return
    assert_not_contains "$name" "xrandr" || return
    assert_not_contains "$name" "xclip" || return
    pass "$name"
}

test_x11_mixed_severity() {
    local name="x11_mixed_severity"
    local cfg
    cfg=$(write_config "x11_mixed.lua" 'local handle = io.popen("xrandr --query")
local cmd = "xclip -selection clipboard"')
    run_check "$cfg"
    assert_exit "$name" 2 || return
    assert_contains "$name" "CRITICAL" || return
    pass "$name"
}

# === Group 3: Require Scanning ===

test_require_commented_ignored() {
    local name="require_commented_ignored"
    local cfg
    cfg=$(write_config "req_comment.lua" '-- require("nonexistent_module_xyz")
local x = 1
return x')
    run_check "$cfg"
    assert_exit "$name" 0 || return
    assert_not_contains "$name" "nonexistent_module_xyz" || return
    pass "$name"
}

test_require_missing_reported() {
    local name="require_missing_reported"
    local cfg
    cfg=$(write_config "req_missing.lua" 'local _m = require("totally_missing_module_xyz")
return true')
    run_check "$cfg"
    assert_contains "$name" "totally_missing_module_xyz" || return
    assert_contains "$name" "not found on this system" || return
    pass "$name"
}

test_require_stdlib_skipped() {
    local name="require_stdlib_skipped"
    local cfg
    # Verify none of these stdlib modules are reported missing
    cfg=$(write_config "req_stdlib.lua" 'require("string")
require("table")
require("math")
require("io")
require("os")
require("debug")
require("coroutine")
require("package")')
    run_check "$cfg"
    assert_not_contains "$name" "not found on this system" || return
    pass "$name"
}

test_require_awesomewm_skipped() {
    local name="require_awesomewm_skipped"
    local cfg
    # Verify none of these AwesomeWM modules are reported missing
    cfg=$(write_config "req_awesome.lua" 'require("awful")
require("gears")
require("wibox")
require("naughty")
require("beautiful")
require("menubar")
require("ruled")')
    run_check "$cfg"
    assert_not_contains "$name" "not found on this system" || return
    pass "$name"
}

test_require_somewm_module_found() {
    local name="require_somewm_module_found"
    local cfg
    # somewm's own bundled modules resolve through package.path like any other
    cfg=$(write_config "req_somewm.lua" 'require("somewm.layout_animation")')
    run_check "$cfg"
    assert_not_contains "$name" "not found on this system" || return
    pass "$name"
}

test_require_library_not_scanned() {
    local name="require_library_not_scanned"
    local cfg
    # A resolved library is not the user's code: report that it exists, but do
    # not walk into it. awful/screen.lua and awful/client.lua both mention X11
    # tools, so a leak shows up as findings in files the user cannot fix.
    cfg=$(write_config "req_lib_scan.lua" 'require("awful")')
    run_check "$cfg"
    assert_not_contains "$name" "awful/screen.lua" || return
    assert_not_contains "$name" "awful/client.lua" || return
    pass "$name"
}

test_require_method_skipped() {
    local name="require_method_skipped"
    local cfg
    # .require method calls should not be flagged as missing modules
    cfg=$(write_config "req_method.lua" 'local lgi = require("lgi")
local GLib = lgi.require("GLib")
return GLib')
    run_check "$cfg"
    assert_not_contains "$name" "GLib" || return
    pass "$name"
}

test_require_local_module() {
    local name="require_local_module"
    mkdir -p "$TMP_DIR/local_mod"
    printf 'local mymod = require("mymodule")\nreturn mymod\n' > "$TMP_DIR/local_mod/rc.lua"
    printf 'return { version = 1 }\n' > "$TMP_DIR/local_mod/mymodule.lua"
    run_check "$TMP_DIR/local_mod/rc.lua"
    assert_exit "$name" 0 || return
    assert_not_contains "$name" "mymodule" || return
    pass "$name"
}

test_require_init_module() {
    local name="require_init_module"
    mkdir -p "$TMP_DIR/init_mod/mypkg"
    printf 'local mypkg = require("mypkg")\nreturn mypkg\n' > "$TMP_DIR/init_mod/rc.lua"
    printf 'return { version = 1 }\n' > "$TMP_DIR/init_mod/mypkg/init.lua"
    run_check "$TMP_DIR/init_mod/rc.lua"
    assert_exit "$name" 0 || return
    assert_not_contains "$name" "mypkg" || return
    pass "$name"
}

test_require_indented_comment() {
    local name="require_indented_comment"
    local cfg
    cfg=$(write_config "req_indent.lua" '    -- require("nonexistent_indented_xyz")
	-- require("nonexistent_tabbed_xyz")
local x = 1
return x')
    run_check "$cfg"
    assert_exit "$name" 0 || return
    assert_not_contains "$name" "nonexistent_indented_xyz" || return
    assert_not_contains "$name" "nonexistent_tabbed_xyz" || return
    pass "$name"
}

test_require_both_quotes() {
    local name="require_both_quotes"
    local cfg
    cfg=$(write_config "req_quotes.lua" "local _m1 = require(\"missing_double_xyz\")
local _m2 = require('missing_single_xyz')
return true")
    run_check "$cfg"
    assert_contains "$name" "missing_double_xyz" || return
    assert_contains "$name" "missing_single_xyz" || return
    pass "$name"
}

# === Group 4: Syntax Errors ===

test_syntax_error() {
    local name="syntax_error"
    local cfg
    cfg=$(write_config "syntax_err.lua" 'local x = {
    foo = "bar"
    baz = "qux"
}')
    run_check "$cfg"
    assert_exit "$name" 2 || return
    assert_contains "$name" "CRITICAL" || return
    pass "$name"
}

test_syntax_unterminated() {
    local name="syntax_unterminated_string"
    local cfg
    cfg=$(write_config "syntax_unterm.lua" 'local x = "unterminated string')
    run_check "$cfg"
    assert_exit "$name" 2 || return
    assert_contains "$name" "CRITICAL" || return
    pass "$name"
}

# === Group 5: Report Format ===

test_report_header() {
    local name="report_header"
    local cfg
    cfg=$(write_config "header.lua" 'local _m = require("totally_missing_header_xyz")
return true')
    run_check "$cfg"
    assert_contains "$name" "somewm config compatibility report" || return
    assert_contains "$name" "====================================" || return
    pass "$name"
}

test_report_summary() {
    local name="report_summary"
    local cfg
    cfg=$(write_config "summary.lua" 'local _m = require("totally_missing_summary_xyz")
return true')
    run_check "$cfg"
    assert_contains "$name" "Summary:" || return
    pass "$name"
}

test_no_ansi_codes() {
    local name="no_ansi_codes"
    local cfg
    cfg=$(write_config "ansi.lua" 'local handle = io.popen("xrandr --query")')
    run_check "$cfg"
    # ESC character should not appear in piped output
    if echo "$CHECK_STDOUT" | grep -qP '\x1b\['; then
        fail "$name" "stdout contains ANSI escape codes"
        return
    fi
    pass "$name"
}

# === Group 6: Edge Cases ===

test_nonexistent_file() {
    local name="nonexistent_file"
    run_check "$TMP_DIR/does_not_exist.lua"
    assert_exit "$name" 2 || return
    assert_contains "$name" "CRITICAL" || return
    pass "$name"
}

# === Group 7: Inline Suppression ===

test_inline_suppression() {
    local name="inline_suppression"
    local cfg
    cfg=$(write_config "suppress.lua" 'local cmd = "xclip -selection clipboard" -- somewm:ignore
local handle = io.popen("xrandr --query") -- somewm:ignore
return cmd or handle')
    run_check "$cfg"
    assert_exit "$name" 0 || return
    assert_not_contains "$name" "xclip" || return
    assert_not_contains "$name" "xrandr" || return
    pass "$name"
}

test_suppression_scoped() {
    local name="suppression_scoped"
    local cfg
    cfg=$(write_config "suppress_scoped.lua" 'local cmd = "xclip -selection clipboard" -- somewm:ignore
local handle = io.popen("xrandr --query")
return cmd or handle')
    run_check "$cfg"
    assert_exit "$name" 2 || return
    assert_not_contains "$name" "xclip" || return
    assert_contains "$name" "xrandr" || return
    pass "$name"
}

test_suppression_with_reason() {
    local name="suppression_with_reason"
    local cfg
    cfg=$(write_config "suppress_reason.lua" 'local cmd = "xclip -selection" -- somewm:ignore guarded by runtime check
return cmd')
    run_check "$cfg"
    assert_exit "$name" 0 || return
    assert_not_contains "$name" "xclip" || return
    pass "$name"
}

# === Group 8: Check Level ===

test_check_level_critical_only() {
    local name="check_level_critical"
    local cfg
    # Config with only warnings - should pass with --check-level=critical
    cfg=$(write_config "level_warn.lua" 'local cmd = "xclip -selection clipboard"')
    set +e
    CHECK_STDOUT=$("$SOMEWM" --check "$cfg" --check-level=critical 2>"$TMP_DIR/_stderr")
    CHECK_EXIT=$?
    set -e
    CHECK_STDERR=$(cat "$TMP_DIR/_stderr")
    assert_exit "$name" 0 || return
    # Report should still show the warning
    assert_contains "$name" "xclip" || return
    pass "$name"
}

test_check_level_critical_with_critical() {
    local name="check_level_critical_with_crit"
    local cfg
    # Config with critical issue - should fail even with --check-level=critical
    cfg=$(write_config "level_crit.lua" 'local handle = io.popen("xrandr --query")')
    set +e
    CHECK_STDOUT=$("$SOMEWM" --check "$cfg" --check-level=critical 2>"$TMP_DIR/_stderr")
    CHECK_EXIT=$?
    set -e
    CHECK_STDERR=$(cat "$TMP_DIR/_stderr")
    assert_exit "$name" 2 || return
    pass "$name"
}

test_check_level_default() {
    local name="check_level_default"
    local cfg
    # Default behavior unchanged - warnings still cause exit 1
    cfg=$(write_config "level_default.lua" 'local cmd = "xclip -selection clipboard"')
    run_check "$cfg"
    assert_exit "$name" 1 || return
    pass "$name"
}

# === Group 9: GTK/GDK Detection ===

test_gtk_lgi_warning() {
    local name="gtk_lgi_warning"
    local cfg
    cfg=$(write_config "gtk_warn.lua" 'local lgi = require("lgi")
local Gtk = lgi.require("Gtk")
return Gtk')
    run_check "$cfg"
    assert_exit "$name" 1 || return
    assert_contains "$name" "WARNING" || return
    assert_contains "$name" "GTK" || return
    pass "$name"
}

test_gdk_lgi_critical() {
    local name="gdk_lgi_critical"
    local cfg
    cfg=$(write_config "gdk_crit.lua" 'local lgi = require("lgi")
local Gdk = lgi.require("Gdk")
return Gdk')
    run_check "$cfg"
    assert_exit "$name" 2 || return
    assert_contains "$name" "CRITICAL" || return
    assert_contains "$name" "GDK" || return
    pass "$name"
}

# === Run All Tests ===

test_valid_config
test_empty_config
test_x11_critical
test_x11_warning
test_x11_commented_ignored
test_x11_mixed_severity
test_require_commented_ignored
test_require_missing_reported
test_require_stdlib_skipped
test_require_awesomewm_skipped
test_require_somewm_module_found
test_require_library_not_scanned
test_require_method_skipped
test_require_local_module
test_require_init_module
test_require_indented_comment
test_require_both_quotes
test_syntax_error
test_syntax_unterminated
test_report_header
test_report_summary
test_no_ansi_codes
test_nonexistent_file
test_inline_suppression
test_suppression_scoped
test_suppression_with_reason
test_check_level_critical_only
test_check_level_critical_with_critical
test_check_level_default
test_gtk_lgi_warning
test_gdk_lgi_critical

# A pattern named in a comment must not hide a real use further down the file.
# Only the first occurrence used to be examined, so the comment consumed it.
test_comment_does_not_mask_later_use() {
    local name="comment_does_not_mask_later_use"
    local cfg
    cfg=$(write_config "masked.lua" '-- we used to spawn "picom here
local cmd = "picom -b"
return cmd')
    run_check "$cfg"
    assert_contains "$name" "masked.lua:2" || return
    pass "$name"
}
test_comment_does_not_mask_later_use

# GdkPixbuf decodes images and opens no display, so it is not the GDK hazard.
test_gdkpixbuf_is_not_gdk() {
    local name="gdkpixbuf_is_not_gdk"
    local cfg
    cfg=$(write_config "pixbuf.lua" 'local lgi = require("lgi")
local GdkPixbuf = lgi.require("GdkPixbuf", "2.0")
return GdkPixbuf')
    run_check "$cfg"
    assert_exit "$name" 0 || return
    assert_not_contains "$name" "GDK initialization deadlock" || return
    pass "$name"
}
test_gdkpixbuf_is_not_gdk

# A GTK main loop started inside the compositor never hands control back.
test_gtk_application_is_critical() {
    local name="gtk_application_is_critical"
    local cfg
    cfg=$(write_config "gtkapp.lua" 'local lgi = require("lgi")
local Gtk = lgi.require("Gtk", "3.0")
local app = Gtk.Application({ application_id = "test.app" })
return app:run()')
    run_check "$cfg"
    assert_exit "$name" 2 || return
    assert_contains "$name" "GTK app inside the compositor" || return
    assert_contains "$name" "separate process" || return
    pass "$name"
}
test_gtk_application_is_critical

# get_default() needs gtk_init, which the compositor stubs out, so it is nil.
test_icontheme_get_default_warns() {
    local name="icontheme_get_default_warns"
    local cfg
    cfg=$(write_config "icontheme.lua" 'local lgi = require("lgi")
local Gtk = lgi.require("Gtk", "3.0")
local theme = Gtk.IconTheme.get_default()
return theme')
    run_check "$cfg"
    assert_exit "$name" 1 || return
    assert_contains "$name" "IconTheme.get_default() - returns nil" || return
    assert_contains "$name" "IconTheme.new()" || return
    pass "$name"
}
test_icontheme_get_default_warns

# xrdb was only detected inside io.popen, so os.execute and a plain spawn
# went unreported. It now has a bare form like xset and xclip.
test_xrdb_bare_warns() {
    local name="xrdb_bare_warns"
    local cfg
    cfg=$(write_config "xrdb.lua" 'os.execute("xrdb " .. os.getenv("HOME") .. "/.Xresources")')
    run_check "$cfg"
    assert_exit "$name" 1 || return
    assert_contains "$name" "xrdb Xresources loading" || return
    pass "$name"
}
test_xrdb_bare_warns

# Wayland has no _NET_WM_ICON equivalent, so c.icon is nil and a tasklist or
# dock draws the same fallback for every client.
test_client_icon_info() {
    local name="client_icon_info"
    local cfg
    cfg=$(write_config "clienticon.lua" 'client.connect_signal("request::manage", function(c)
    if not c.icon then return end
end)')
    run_check "$cfg"
    assert_exit "$name" 0 || return
    assert_contains "$name" "clients have no icon" || return
    assert_contains "$name" "c.class" || return
    pass "$name"
}
test_client_icon_info

# Four patterns describe xclip ("xclip, 'xclip, | xclip, " xclip "), and more
# than one can match the same line. The report should name it once.
test_overlapping_patterns_report_once() {
    local name="overlapping_patterns_report_once"
    local cfg
    cfg=$(write_config "dupe.lua" 'local cmd = "xclip -selection clipboard | xclip -i"')
    run_check "$cfg"
    local hits
    hits=$(echo "$CHECK_STDOUT" | grep -c "xclip clipboard tool")
    if [ "$hits" -ne 1 ]; then
        fail "$name" "expected 1 xclip finding, got $hits"
        return
    fi
    pass "$name"
}
test_overlapping_patterns_report_once

# require("pkg.mod." .. name) yields a trailing dot, which used to resolve to
# <dir>/pkg/mod//init.lua and scan the same file a second time.
test_dynamic_require_not_scanned_twice() {
    local name="dynamic_require_not_scanned_twice"
    local cfg
    mkdir -p "$TMP_DIR/widgets"
    printf '%s\n' 'local cmd = "maim -s"' > "$TMP_DIR/widgets/init.lua"
    cfg=$(write_config "dyn.lua" 'local w = require("widgets")
for _, k in ipairs({"a"}) do w[k] = require("widgets." .. k) end')
    run_check "$cfg"
    assert_not_contains "$name" "//init.lua" || return
    local hits
    hits=$(echo "$CHECK_STDOUT" | grep -c "maim screenshot tool")
    if [ "$hits" -ne 1 ]; then
        fail "$name" "expected 1 maim finding, got $hits"
        return
    fi
    pass "$name"
}
test_dynamic_require_not_scanned_twice

# xsettingsd is a different program from xset, and needs different advice.
test_xsettingsd_is_not_xset() {
    local name="xsettingsd_is_not_xset"
    local cfg
    cfg=$(write_config "xsd.lua" 'os.execute("xsettingsd --config /etc/xsettingsd &")')
    run_check "$cfg"
    assert_contains "$name" "xsettingsd XSETTINGS daemon" || return
    assert_not_contains "$name" "xset display settings" || return
    pass "$name"
}
test_xsettingsd_is_not_xset

# A path or a local named xsettingsd is not a spawn of it.
test_xsettingsd_name_is_not_a_spawn() {
    local name="xsettingsd_name_is_not_a_spawn"
    local cfg
    cfg=$(write_config "xsdname.lua" 'local xsettingsd = dir .. "xsettingsd"
local f = io.open(xsettingsd, "r")')
    run_check "$cfg"
    assert_not_contains "$name" "xsettingsd XSETTINGS daemon" || return
    pass "$name"
}
test_xsettingsd_name_is_not_a_spawn

# A real xset call still has to be caught.
test_xset_still_warns() {
    local name="xset_still_warns"
    local cfg
    cfg=$(write_config "xset.lua" 'awful.spawn("xset s on +dpms")')
    run_check "$cfg"
    assert_contains "$name" "xset display settings" || return
    pass "$name"
}
test_xset_still_warns

# A missing module used to be reported at line 0.
test_missing_module_has_line_number() {
    local name="missing_module_has_line_number"
    local cfg
    cfg=$(write_config "modline.lua" '-- padding
-- padding
local _m = require("totally_missing_module_xyz")')
    run_check "$cfg"
    assert_contains "$name" "modline.lua:3" || return
    assert_not_contains "$name" "modline.lua:0" || return
    pass "$name"
}
test_missing_module_has_line_number

# get_xproperty and set_xproperty are not bound at all, so calling either
# raises and the config never loads. register_xproperty is a real no-op stub.
test_xproperty_get_is_critical() {
    local name="xproperty_get_is_critical"
    local cfg
    cfg=$(write_config "xprop_get.lua" 'local seen = awesome.get_xproperty("restarted")')
    run_check "$cfg"
    assert_exit "$name" 2 || return
    assert_contains "$name" "awesome.get_xproperty() - not defined" || return
    assert_contains "$name" "awesome._restart" || return
    pass "$name"
}
test_xproperty_get_is_critical

test_xproperty_register_stays_warning() {
    local name="xproperty_register_stays_warning"
    local cfg
    cfg=$(write_config "xprop_reg.lua" 'awesome.register_xproperty("restarted", "boolean")')
    run_check "$cfg"
    assert_exit "$name" 1 || return
    assert_contains "$name" "does nothing" || return
    pass "$name"
}
test_xproperty_register_stays_warning

# === Summary ===

echo ""
if [ $fail_count -eq 0 ]; then
    echo "PASS"
else
    echo "FAIL"
fi
printf "ok\t%d tests\t%d passed\t%d failed\n" "$test_count" "$pass_count" "$fail_count"
[ $fail_count -gt 0 ] && exit 1
exit 0

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
    assert_contains "$name" "module not found" || return
    pass "$name"
}

test_require_stdlib_skipped() {
    local name="require_stdlib_skipped"
    local cfg
    # Verify none of these stdlib modules appear as "module not found"
    cfg=$(write_config "req_stdlib.lua" 'require("string")
require("table")
require("math")
require("io")
require("os")
require("debug")
require("coroutine")
require("package")')
    run_check "$cfg"
    assert_not_contains "$name" "module not found" || return
    pass "$name"
}

test_require_awesomewm_skipped() {
    local name="require_awesomewm_skipped"
    local cfg
    # Verify none of these AwesomeWM modules appear as "module not found"
    cfg=$(write_config "req_awesome.lua" 'require("awful")
require("gears")
require("wibox")
require("naughty")
require("beautiful")
require("menubar")
require("ruled")')
    run_check "$cfg"
    assert_not_contains "$name" "module not found" || return
    pass "$name"
}

test_require_thirdparty_skipped() {
    local name="require_thirdparty_skipped"
    local cfg
    # Verify none of these known third-party modules appear as "module not found"
    cfg=$(write_config "req_thirdparty.lua" 'require("lgi")
require("cairo")
require("inspect")
require("lain")
require("dkjson")')
    run_check "$cfg"
    assert_not_contains "$name" "module not found" || return
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
    assert_not_contains "$name" "module not found" || return
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
test_require_thirdparty_skipped
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

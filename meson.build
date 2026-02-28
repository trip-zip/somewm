project(
  'somewm',
  'c',
  version: '0.5.0',
  license: 'MIT',
  default_options: [
    'c_std=gnu11',
    'warning_level=2',
    'werror=true',
  ],
)

# Get version info from git if available
git = find_program('git', required: false)
if git.found()
  version_result = run_command(git, 'describe', '--tags', '--dirty', check: false)
  if version_result.returncode() == 0
    version = version_result.stdout().strip()
  else
    version = meson.project_version()
  endif

  date_result = run_command(git, 'log', '-1', '--format=%cs', check: false)
  if date_result.returncode() == 0
    commit_date = date_result.stdout().strip()
  else
    commit_date = 'unknown'
  endif
else
  version = meson.project_version()
  commit_date = 'unknown'
endif

cc = meson.get_compiler('c')

# Math library (for round(), etc.)
m_dep = cc.find_library('m', required: false)

# ==============================================================================
# Options
# ==============================================================================

xwayland_option = get_option('xwayland')

# ==============================================================================
# Dependencies
# ==============================================================================

# Core dependencies
wayland_server = dependency('wayland-server')
wayland_protocols = dependency('wayland-protocols')
xkbcommon = dependency('xkbcommon')
libinput = dependency('libinput')
# Check for 3-finger drag support (libinput 1.27+)
have_3fg_drag = cc.has_function('libinput_device_config_3fg_drag_get_finger_count',
                                 dependencies: libinput)
libdrm = dependency('libdrm')
dbus = dependency('dbus-1')
glib = dependency('glib-2.0')

# Cairo and Pango for widget rendering
cairo = dependency('cairo')
cairo_xlib = dependency('cairo-xlib')
pangocairo = dependency('pangocairo')
gdk_pixbuf = dependency('gdk-pixbuf-2.0')

# Xwayland dependencies (optional)
if xwayland_option.enabled() or xwayland_option.auto()
  xcb = dependency('xcb', required: xwayland_option)
  xcb_icccm = dependency('xcb-icccm', required: xwayland_option)
  have_xwayland = xcb.found() and xcb_icccm.found()
else
  have_xwayland = false
endif

# Lua detection - LuaJIT preferred, then 5.4 > 5.3 > 5.2 > 5.1
lua_dep = dependency('luajit', required: false)
if not lua_dep.found()
  lua_dep = dependency('lua5.4', required: false)
endif
if not lua_dep.found()
  lua_dep = dependency('lua-5.4', required: false)
endif
if not lua_dep.found()
  lua_dep = dependency('lua5.3', required: false)
endif
if not lua_dep.found()
  lua_dep = dependency('lua-5.3', required: false)
endif
if not lua_dep.found()
  lua_dep = dependency('lua5.2', required: false)
endif
if not lua_dep.found()
  lua_dep = dependency('lua-5.2', required: false)
endif
if not lua_dep.found()
  lua_dep = dependency('lua5.1', required: false)
endif
if not lua_dep.found()
  lua_dep = dependency('lua-5.1', required: false)
endif
if not lua_dep.found()
  lua_dep = dependency('lua', required: true)
endif

# LGI detection - compile and run lgi-check.c to verify lgi is installed
# This approach only requires the Lua library, not the interpreter executable
lgi_check_result = cc.run(files('lgi-check.c'), dependencies: [lua_dep], name: 'LGI check')
if lgi_check_result.returncode() != 0
  error('LGI (Lua GObject Introspection) not found for ' + lua_dep.name() + '.\n' +
        lgi_check_result.stderr() + '\n' +
        'Install the matching lgi package:\n' +
        '  Arch Linux: sudo pacman -S lua-lgi (Lua 5.4) or lua51-lgi (LuaJIT)\n' +
        '  Debian/Ubuntu: sudo apt install lua-lgi\n' +
        '  Fedora: sudo dnf install lua-lgi')
endif
# Parse lgi version from output (format: "Found lgi X.Y.Z")
lgi_output = lgi_check_result.stdout().strip()
lgi_version = lgi_output.split('Found lgi ')[-1].split('\n')[0]
message('Found LGI version: ' + lgi_version)

# wlroots 0.19 only - use system if available, otherwise build from subproject
# We only support 0.19+ due to Xwayland bugs in earlier versions
wlroots = dependency('wlroots-0.19', static: false, required: false)

if not wlroots.found()
  message('System wlroots 0.19 not found, building from subproject...')

  wlroots_options = [
    'examples=false',
    'default_library=static',
  ]
  if have_xwayland
    wlroots_options += 'xwayland=enabled'
  else
    wlroots_options += 'xwayland=disabled'
  endif

  wlroots_proj = subproject('wlroots', default_options: wlroots_options)
  wlroots = wlroots_proj.get_variable('wlroots')
endif

wlroots_version = '0.19'
message('Using wlroots version: ' + wlroots_version)

# ==============================================================================
# Wayland Protocol Generation
# ==============================================================================

wayland_scanner = find_program('wayland-scanner')
wayland_protocols_dir = wayland_protocols.get_variable('pkgdatadir')

# Protocol files to generate
protocols = [
  # From wayland-protocols
  [wayland_protocols_dir / 'staging/cursor-shape/cursor-shape-v1.xml', 'enum-header'],
  [wayland_protocols_dir / 'unstable/pointer-constraints/pointer-constraints-unstable-v1.xml', 'enum-header'],
  [wayland_protocols_dir / 'stable/xdg-shell/xdg-shell.xml', 'server-header'],
  # Local protocols
  ['protocols/wlr-layer-shell-unstable-v1.xml', 'enum-header'],
  ['protocols/wlr-output-power-management-unstable-v1.xml', 'server-header'],
]

protocol_headers = []
foreach p : protocols
  xml_file = p[0]
  header_type = p[1]

  # Get base name for output file
  if xml_file.startswith(wayland_protocols_dir)
    # External protocol - extract just the filename
    parts = xml_file.split('/')
    base_name = parts[parts.length() - 1].replace('.xml', '')
  else
    # Local protocol
    base_name = xml_file.split('/')[-1].replace('.xml', '')
  endif

  output_name = base_name + '-protocol.h'

  protocol_headers += custom_target(
    output_name,
    input: xml_file,
    output: output_name,
    command: [wayland_scanner, header_type, '@INPUT@', '@OUTPUT@'],
  )
endforeach

# Client protocol headers for test utilities
wayland_client = dependency('wayland-client')

layer_shell_client_header = custom_target(
  'wlr-layer-shell-unstable-v1-client-protocol.h',
  input: 'protocols/wlr-layer-shell-unstable-v1.xml',
  output: 'wlr-layer-shell-unstable-v1-client-protocol.h',
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@'],
)

layer_shell_client_code = custom_target(
  'wlr-layer-shell-unstable-v1-client-protocol.c',
  input: 'protocols/wlr-layer-shell-unstable-v1.xml',
  output: 'wlr-layer-shell-unstable-v1-client-protocol.c',
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@'],
)

# xdg-shell client protocol (header + code) for test clients
xdg_shell_client_header = custom_target(
  'xdg-shell-client-protocol.h',
  input: wayland_protocols_dir / 'stable/xdg-shell/xdg-shell.xml',
  output: 'xdg-shell-client-protocol.h',
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@'],
)

xdg_shell_client_code = custom_target(
  'xdg-shell-client-protocol.c',
  input: wayland_protocols_dir / 'stable/xdg-shell/xdg-shell.xml',
  output: 'xdg-shell-client-protocol.c',
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@'],
)

# ==============================================================================
# Compiler Flags
# ==============================================================================

add_project_arguments(
  '-DWLR_USE_UNSTABLE',
  '-D_POSIX_C_SOURCE=200809L',
  '-DVERSION="' + version + '"',
  '-DCOMMIT_DATE="' + commit_date + '"',
  '-DDATADIR="' + get_option('prefix') / get_option('datadir') + '"',
  '-DSYSCONFDIR="' + get_option('sysconfdir') + '"',
  '-DWLROOTS_VERSION="' + wlroots_version + '"',
  '-DLGI_VERSION="' + lgi_version + '"',
  '-DWITH_DBUS',
  language: 'c',
)

# Always 0.19 - we only support this version
add_project_arguments('-DWLR_VERSION_0_19', language: 'c')

if have_xwayland
  add_project_arguments('-DXWAYLAND', language: 'c')
endif

if have_3fg_drag
  add_project_arguments('-DHAVE_LIBINPUT_3FG_DRAG', language: 'c')
endif

# Development flags
add_project_arguments(
  '-Wno-unused-parameter',
  '-Wshadow',
  '-Wunused-macros',
  '-Wstringop-truncation',
  '-Wformat-truncation',
  # Note: -Wfloat-conversion omitted because dbus.c needs it disabled
  language: 'c',
)

# ==============================================================================
# Source Files
# ==============================================================================

somewm_sources = [
  'somewm.c',
  'somewm_api.c',
  'ipc.c',
  'color.c',
  'draw.c',
  'stack.c',
  'banning.c',
  'ewmh.c',
  'event.c',
  'xkb.c',
  'systray.c',
  'shadow.c',
  'strut.c',
  'property.c',
  'dbus.c',
  'luaa.c',
  'root.c',
  'mouse.c',
  'spawn.c',
  'keygrabber.c',
  'mousegrabber.c',
  'selection.c',
  # Common
  'common/luaclass.c',
  'common/luaobject.c',
  'common/lualib.c',
  'common/buffer.c',
  'common/util.c',
  # Objects
  'objects/window.c',
  'objects/tag.c',
  'objects/client.c',
  'objects/screen.c',
  'objects/output.c',
  'objects/drawable.c',
  'objects/drawin.c',
  'objects/layer_surface.c',
  'objects/signal.c',
  'objects/timer.c',
  'objects/key.c',
  'objects/keybinding.c',
  # objects/awesome.c merged into luaa.c
  'objects/button.c',
  'objects/wibox.c',
  'objects/ipc.c',
  'objects/selection_getter.c',
  'objects/selection_acquire.c',
  'objects/selection_transfer.c',
  'objects/selection_watcher.c',
  'objects/systray.c',
]

# ==============================================================================
# Build Targets
# ==============================================================================

all_deps = [
  wayland_server,
  xkbcommon,
  libinput,
  libdrm,
  dbus,
  glib,
  cairo,
  cairo_xlib,
  pangocairo,
  gdk_pixbuf,
  lua_dep,
  wlroots,
  m_dep,
]

if have_xwayland
  all_deps += [xcb, xcb_icccm]
endif

somewm_exe = executable(
  'somewm',
  somewm_sources,
  protocol_headers,
  dependencies: all_deps,
  include_directories: include_directories('.'),
  install: true,
)

somewm_client = executable(
  'somewm-client',
  'somewm-client.c',
  install: true,
)

# Test layer-shell client for deterministic integration tests
test_layer_client = executable(
  'test-layer-client',
  ['tests/test-layer-client.c', layer_shell_client_code, xdg_shell_client_code],
  layer_shell_client_header,
  dependencies: [wayland_client],
  install: false,
)

# Test XDG transient client for stacking regression tests (issue #276)
test_transient_client = executable(
  'test-transient-client',
  ['tests/test-transient-client.c', xdg_shell_client_code],
  xdg_shell_client_header,
  dependencies: [wayland_client],
  install: false,
)

# ==============================================================================
# Install Data
# ==============================================================================

# Man page
install_man('somewm.1')

# Desktop file
install_data(
  'somewm.desktop',
  install_dir: get_option('datadir') / 'wayland-sessions',
)

# Lua libraries
install_subdir(
  'lua',
  install_dir: get_option('datadir') / 'somewm',
)

# Themes
install_subdir(
  'themes',
  install_dir: get_option('datadir') / 'somewm',
)

# Icons
install_subdir(
  'icons',
  install_dir: get_option('datadir') / 'somewm',
)

# Default config
install_data(
  'somewmrc.lua',
  install_dir: get_option('datadir') / 'somewm',
)

install_data(
  'somewm.portal',
  install_dir: get_option('datadir') / 'xdg-desktop-portal/portals'
)

install_data(
  'somewmrc.lua',
  rename: 'rc.lua',
  install_dir: get_option('sysconfdir') / 'xdg/somewm',
)

# ==============================================================================
# Summary
# ==============================================================================

summary({
  'Version': version,
  'wlroots': wlroots_version + (wlroots.type_name() == 'internal' ? ' (subproject)' : ' (system)'),
  'Lua': lua_dep.name() + ' ' + lua_dep.version(),
  'LGI': lgi_version,
  'Xwayland': have_xwayland,
}, section: 'Configuration')

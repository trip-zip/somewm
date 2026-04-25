local theme_assets = require("beautiful.theme_assets")
local xresources = require("beautiful.xresources")
local rnotification = require("ruled.notification")
local dpi = xresources.apply_dpi
local gears = require("gears")
local gfs = require("gears.filesystem")
local themes_path = gfs.get_themes_dir()

local theme = {}

-- Catppuccin Mocha palette
local base      = "#1e1e2e"
local surface0  = "#313244"
local overlay0  = "#6c7086"
local text      = "#cdd6f4"
local subtext1  = "#bac2de"
local red       = "#f38ba8"
local green     = "#a6e3a1"
local yellow    = "#f9e2af"
local blue      = "#89b4fa"
local mauve     = "#cba6f7"
local lavender  = "#b4befe"

theme.font = "sans 10"

theme.bg_normal   = base
theme.bg_focus    = surface0
theme.bg_urgent   = red
theme.bg_minimize = overlay0
theme.bg_systray  = base

theme.fg_normal   = text
theme.fg_focus    = lavender
theme.fg_urgent   = base
theme.fg_minimize = text

theme.useless_gap         = dpi(8)
theme.border_width        = dpi(2)
theme.border_color_normal = base
theme.border_color_active = mauve
theme.border_color_marked = red

-- Hotkeys popup
theme.hotkeys_bg           = base
theme.hotkeys_fg           = text
theme.hotkeys_border_width = dpi(2)
theme.hotkeys_border_color = mauve
theme.hotkeys_modifiers_fg = overlay0
theme.hotkeys_label_bg     = surface0
theme.hotkeys_label_fg     = text
theme.hotkeys_group_margin = dpi(20)
theme.hotkeys_override_label_bgs = true

-- Wibar
theme.wibar_height = dpi(32)
theme.wibar_bg     = base
theme.wibar_shape  = function(cr, w, h) gears.shape.rounded_rect(cr, w, h, dpi(8)) end

-- Clock
theme.clock_bg = surface0

-- Taglist
local taglist_square_size = dpi(4)
theme.taglist_squares_sel   = theme_assets.taglist_squares_sel(taglist_square_size, text)
theme.taglist_squares_unsel = theme_assets.taglist_squares_unsel(taglist_square_size, text)

-- Tasklist
theme.tasklist_bg_normal   = base .. "00"
theme.tasklist_bg_focus    = surface0
theme.tasklist_fg_normal   = text
theme.tasklist_fg_focus    = lavender
theme.tasklist_bg_urgent   = red
theme.tasklist_fg_urgent   = base
theme.tasklist_bg_minimize = base .. "00"
theme.tasklist_fg_minimize = overlay0
theme.tasklist_spacing     = dpi(4)
theme.tasklist_shape       = function(cr, w, h) gears.shape.rounded_rect(cr, w, h, dpi(4)) end
theme.tasklist_icon_size   = dpi(16)
theme.tasklist_plain_task_name = true

-- Menu
theme.menu_submenu_icon = themes_path .. "../icons/lucide/chevron-right.svg"
theme.menu_height = dpi(24)
theme.menu_width  = dpi(200)

-- Titlebar icons (Lucide icons, recolored per state)
local default_path = themes_path .. "default/"
local icons_path = themes_path .. "../icons/lucide/"

theme.titlebar_close_button_normal              = icons_path .. "x.svg"
theme.titlebar_close_button_focus               = icons_path .. "x.svg"
theme.titlebar_minimize_button_normal           = icons_path .. "minus.svg"
theme.titlebar_minimize_button_focus            = icons_path .. "minus.svg"
theme.titlebar_ontop_button_normal_inactive     = icons_path .. "pin-off.svg"
theme.titlebar_ontop_button_focus_inactive      = icons_path .. "pin-off.svg"
theme.titlebar_ontop_button_normal_active       = icons_path .. "pin.svg"
theme.titlebar_ontop_button_focus_active        = icons_path .. "pin.svg"
theme.titlebar_sticky_button_normal_inactive    = icons_path .. "pin-off.svg"
theme.titlebar_sticky_button_focus_inactive     = icons_path .. "pin-off.svg"
theme.titlebar_sticky_button_normal_active      = icons_path .. "pin.svg"
theme.titlebar_sticky_button_focus_active       = icons_path .. "pin.svg"
theme.titlebar_floating_button_normal_inactive  = icons_path .. "move.svg"
theme.titlebar_floating_button_focus_inactive   = icons_path .. "move.svg"
theme.titlebar_floating_button_normal_active    = icons_path .. "move.svg"
theme.titlebar_floating_button_focus_active     = icons_path .. "move.svg"
theme.titlebar_maximized_button_normal_inactive = icons_path .. "maximize-2.svg"
theme.titlebar_maximized_button_focus_inactive  = icons_path .. "maximize-2.svg"
theme.titlebar_maximized_button_normal_active   = icons_path .. "minimize-2.svg"
theme.titlebar_maximized_button_focus_active    = icons_path .. "minimize-2.svg"

theme_assets.recolor_titlebar(theme, overlay0, "normal")
theme_assets.recolor_titlebar(theme, text, "focus")

-- Layout icons (Lucide)
theme.layout_tile       = icons_path .. "panel-left.svg"
theme.layout_tileleft   = icons_path .. "panel-right.svg"
theme.layout_tiletop    = icons_path .. "panel-bottom.svg"
theme.layout_tilebottom = icons_path .. "panel-top.svg"
theme.layout_fairv      = icons_path .. "grid-2x2.svg"
theme.layout_fairh      = icons_path .. "columns-2.svg"
theme.layout_floating   = icons_path .. "move.svg"
theme.layout_max        = icons_path .. "maximize.svg"
theme.layout_fullscreen = icons_path .. "scan.svg"
theme.layout_magnifier  = icons_path .. "search.svg"
theme.layout_spiral     = icons_path .. "orbit.svg"
theme.layout_dwindle    = icons_path .. "shrink.svg"
theme.layout_cornernw   = icons_path .. "panels-top-left.svg"
theme.layout_cornerne   = icons_path .. "panels-top-left.svg"
theme.layout_cornersw   = icons_path .. "panels-top-left.svg"
theme.layout_cornerse   = icons_path .. "panels-top-left.svg"

theme_assets.recolor_layout(theme, text)

-- Wallpaper
theme.wallpaper_colors = { "#1e1e2e", "#313244" }
theme.wallpaper_logo_color = mauve

-- Icon
theme.awesome_icon = theme_assets.awesome_icon(theme.menu_height, mauve, base)
theme.icon_theme = nil

-- Notifications
rnotification.connect_signal("request::rules", function()
    rnotification.append_rule({
        rule       = { urgency = "critical" },
        properties = { bg = red, fg = base },
    })
end)

return theme

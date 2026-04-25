local theme_assets = require("beautiful.theme_assets")
local xresources = require("beautiful.xresources")
local rnotification = require("ruled.notification")
local dpi = xresources.apply_dpi
local gears = require("gears")
local gfs = require("gears.filesystem")
local themes_path = gfs.get_themes_dir()

local theme = {}

-- Nord palette
local polar1    = "#2e3440"
local polar2    = "#3b4252"
local polar4    = "#4c566a"
local snow1     = "#d8dee9"
local snow2     = "#e5e9f0"
local snow3     = "#eceff4"
local frost1    = "#8fbcbb"
local frost2    = "#88c0d0"
local red       = "#bf616a"
local orange    = "#d08770"
local yellow    = "#ebcb8b"
local green     = "#a3be8c"

theme.font = "sans 10"

theme.bg_normal   = polar1
theme.bg_focus    = polar2
theme.bg_urgent   = red
theme.bg_minimize = polar4
theme.bg_systray  = polar1

theme.fg_normal   = snow1
theme.fg_focus    = snow3
theme.fg_urgent   = snow3
theme.fg_minimize = snow1

theme.useless_gap         = dpi(8)
theme.border_width        = dpi(2)
theme.border_color_normal = polar1
theme.border_color_active = frost2
theme.border_color_marked = red

-- Hotkeys popup
theme.hotkeys_bg           = polar1
theme.hotkeys_fg           = snow1
theme.hotkeys_border_width = dpi(2)
theme.hotkeys_border_color = frost2
theme.hotkeys_modifiers_fg = polar4
theme.hotkeys_label_bg     = polar2
theme.hotkeys_label_fg     = snow1
theme.hotkeys_group_margin = dpi(20)
theme.hotkeys_override_label_bgs = true

-- Wibar
theme.wibar_height = dpi(32)
theme.wibar_bg     = polar1
theme.wibar_shape  = function(cr, w, h) gears.shape.rounded_rect(cr, w, h, dpi(8)) end

-- Clock
theme.clock_bg = polar2

-- Taglist
local taglist_square_size = dpi(4)
theme.taglist_squares_sel   = theme_assets.taglist_squares_sel(taglist_square_size, snow1)
theme.taglist_squares_unsel = theme_assets.taglist_squares_unsel(taglist_square_size, snow1)

-- Tasklist
theme.tasklist_bg_normal   = polar1 .. "00"
theme.tasklist_bg_focus    = polar2
theme.tasklist_fg_normal   = snow1
theme.tasklist_fg_focus    = snow3
theme.tasklist_bg_urgent   = red
theme.tasklist_fg_urgent   = snow3
theme.tasklist_bg_minimize = polar1 .. "00"
theme.tasklist_fg_minimize = polar4
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

theme_assets.recolor_titlebar(theme, polar4, "normal")
theme_assets.recolor_titlebar(theme, snow1, "focus")

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

theme_assets.recolor_layout(theme, snow1)

-- Wallpaper
theme.wallpaper_colors = { "#2e3440", "#3b4252" }
theme.wallpaper_logo_color = frost2

-- Icon
theme.awesome_icon = theme_assets.awesome_icon(theme.menu_height, frost2, polar1)
theme.icon_theme = nil

-- Notifications
rnotification.connect_signal("request::rules", function()
    rnotification.append_rule({
        rule       = { urgency = "critical" },
        properties = { bg = red, fg = snow3 },
    })
end)

return theme

local theme_assets = require("beautiful.theme_assets")
local xresources = require("beautiful.xresources")
local rnotification = require("ruled.notification")
local dpi = xresources.apply_dpi
local gears = require("gears")
local gfs = require("gears.filesystem")
local themes_path = gfs.get_themes_dir()

local theme = {}

-- Gruvbox Dark palette
local bg        = "#282828"
local bg1       = "#3c3836"
local grey      = "#928374"
local fg        = "#ebdbb2"
local white     = "#fbf1c7"
local red       = "#cc241d"
local soft_red  = "#fb4934"
local green     = "#98971a"
local yellow    = "#d79921"
local blue      = "#458588"
local orange    = "#d65d0e"

theme.font = "sans 10"

theme.bg_normal   = bg
theme.bg_focus    = bg1
theme.bg_urgent   = soft_red
theme.bg_minimize = grey
theme.bg_systray  = bg

theme.fg_normal   = fg
theme.fg_focus    = white
theme.fg_urgent   = white
theme.fg_minimize = fg

theme.useless_gap         = dpi(8)
theme.border_width        = dpi(2)
theme.border_color_normal = bg
theme.border_color_active = orange
theme.border_color_marked = red

-- Hotkeys popup
theme.hotkeys_bg           = bg
theme.hotkeys_fg           = fg
theme.hotkeys_border_width = dpi(2)
theme.hotkeys_border_color = orange
theme.hotkeys_modifiers_fg = grey
theme.hotkeys_label_bg     = bg1
theme.hotkeys_label_fg     = fg
theme.hotkeys_group_margin = dpi(20)
theme.hotkeys_override_label_bgs = true

-- Wibar
theme.wibar_height = dpi(32)
theme.wibar_bg     = bg
theme.wibar_shape  = function(cr, w, h) gears.shape.rounded_rect(cr, w, h, dpi(8)) end

-- Clock
theme.clock_bg = bg1

-- Taglist
local taglist_square_size = dpi(4)
theme.taglist_squares_sel   = theme_assets.taglist_squares_sel(taglist_square_size, fg)
theme.taglist_squares_unsel = theme_assets.taglist_squares_unsel(taglist_square_size, fg)

-- Tasklist
theme.tasklist_bg_normal   = bg .. "00"
theme.tasklist_bg_focus    = bg1
theme.tasklist_fg_normal   = fg
theme.tasklist_fg_focus    = white
theme.tasklist_bg_urgent   = soft_red
theme.tasklist_fg_urgent   = white
theme.tasklist_bg_minimize = bg .. "00"
theme.tasklist_fg_minimize = grey
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

theme_assets.recolor_titlebar(theme, grey, "normal")
theme_assets.recolor_titlebar(theme, fg, "focus")

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

theme_assets.recolor_layout(theme, fg)

-- Wallpaper
theme.wallpaper_colors = { "#282828", "#3c3836" }
theme.wallpaper_logo_color = "#b8bb26"

-- Icon
theme.awesome_icon = theme_assets.awesome_icon(theme.menu_height, orange, bg)
theme.icon_theme = nil

-- Notifications
rnotification.connect_signal("request::rules", function()
    rnotification.append_rule({
        rule       = { urgency = "critical" },
        properties = { bg = soft_red, fg = white },
    })
end)

return theme

local lgi = require("lgi")
local GLib, Gio = lgi.GLib, lgi.Gio

-- Before the first GSettings object, so the user's own settings stay out.
GLib.setenv("GSETTINGS_BACKEND", "memory", true)

local gtk = require("beautiful.gtk")

describe("beautiful.gtk.get_theme_variables", function()
    local dir = (os.getenv("SOURCE_DIRECTORY") or ".") .. "/spec/beautiful/gtk"

    local function variables(gtk_theme)
        if gtk_theme then
            GLib.setenv("GTK_THEME", gtk_theme, true)
        else
            GLib.unsetenv("GTK_THEME")
        end
        gtk.cached_theme_variables = nil
        return gtk.get_theme_variables()
    end

    before_each(function()
        GLib.setenv("XDG_DATA_HOME", dir, true)
        GLib.setenv("XDG_DATA_DIRS", dir .. "/none", true)
        GLib.setenv("XDG_CONFIG_HOME", dir .. "/none", true)
    end)

    it("reads the built-in Adwaita colors", function()
        local v = variables("Adwaita")
        assert.is_equal("#f6f5f4ff", v.bg_color)
        assert.is_equal("#3584e4ff", v.selected_bg_color)
        assert.is_equal("#dfdcd8ff", v.wm_bg_color)
        assert.is_equal("#cc0000ff", v.error_bg_color)
        assert.is_equal("#353535ff", variables("Adwaita:dark").bg_color)
    end)

    it("falls back to Adwaita for a theme that is not installed", function()
        assert.is_equal("#f6f5f4ff", variables("NotInstalled").bg_color)
    end)

    it("evaluates the theme's color expressions and imports", function()
        local v = variables("Fixture")
        assert.is_equal("#353535ff", v.bg_color)
        assert.is_equal("#babbbbff", v.fg_color)
        assert.is_equal("#404040ff", v.selected_bg_color)
        assert.is_equal("#eeeeec12", v.base_color)
        assert.is_equal("#00000059", v.osd_bg_color)
        assert.is_equal("#353535ff", v.tooltip_bg_color)
    end)

    it("reads the dark variant", function()
        local v = variables("Fixture:dark")
        assert.is_equal("#000000ff", v.bg_color)
        assert.is_equal("#babbbbff", v.fg_color)
    end)

    it("takes the dark preference from settings.ini", function()
        GLib.setenv("XDG_CONFIG_HOME", dir .. "/config", true)
        local source = Gio.SettingsSchemaSource.get_default()
        if source and source:lookup("org.gnome.desktop.interface", true) then
            local settings = Gio.Settings.new("org.gnome.desktop.interface")
            settings:set_string("gtk-theme", "Fixture")
            settings:set_string("font-name", "Fixture Sans 13")
        end
        local v = variables()
        assert.is_equal("#000000ff", v.bg_color)
        assert.is_equal("Fixture Sans", v.font_family)
        assert.is_equal(13, v.font_size)
    end)
end)

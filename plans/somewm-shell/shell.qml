import QtQuick
import Quickshell
import "modules" as Modules
import "modules/dashboard" as DashboardModule
import "modules/border" as BorderModule
import "modules/osd" as OsdModule
import "modules/weather" as WeatherModule
import "modules/wallpapers" as WallpapersModule
import "modules/collage" as CollageModule

ShellRoot {
    // Border frame — always-visible strip at screen edge (Caelestia pattern)
    BorderModule.BorderFrame {}

    // Dashboard — bottom-slide tabbed panel (absorbs sidebar + media)
    Modules.ModuleLoader {
        moduleName: "dashboard"
        sourceComponent: Component { DashboardModule.Dashboard {} }
    }

    // OSD is always enabled (system-level, not user-toggleable)
    OsdModule.OSD {}

    Modules.ModuleLoader {
        moduleName: "weather"
        sourceComponent: Component { WeatherModule.WeatherPanel {} }
    }

    Modules.ModuleLoader {
        moduleName: "wallpapers"
        sourceComponent: Component { WallpapersModule.WallpaperPanel {} }
    }

    Modules.ModuleLoader {
        moduleName: "collage"
        sourceComponent: Component { CollageModule.CollagePanel {} }
    }
}

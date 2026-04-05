import QtQuick
import Quickshell
import "modules" as Modules
import "modules/dashboard" as DashboardModule
import "modules/sidebar" as SidebarModule
import "modules/media" as MediaModule
import "modules/osd" as OsdModule
import "modules/weather" as WeatherModule
import "modules/wallpapers" as WallpapersModule
import "modules/collage" as CollageModule

ShellRoot {
    Modules.ModuleLoader {
        moduleName: "dashboard"
        sourceComponent: Component { DashboardModule.Dashboard {} }
    }

    Modules.ModuleLoader {
        moduleName: "sidebar"
        sourceComponent: Component { SidebarModule.Sidebar {} }
    }

    Modules.ModuleLoader {
        moduleName: "media"
        sourceComponent: Component { MediaModule.MediaPanel {} }
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

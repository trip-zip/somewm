import QtQuick
import Quickshell
import "modules" as Modules
import "modules/dashboard" as DashboardModule
import "modules/osd" as OsdModule
import "modules/weather" as WeatherModule
import "modules/wallpapers" as WallpapersModule
import "modules/collage" as CollageModule
import "modules/controlpanel" as ControlPanelModule
import "modules/dock" as DockModule
import "modules/hotedges" as HotEdgesModule

ShellRoot {
    // Dashboard — Caelestia-style overlay with border strip + panel
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

    // Control panel — quick volume/mic/brightness popout
    Modules.ModuleLoader {
        moduleName: "controlpanel"
        sourceComponent: Component { ControlPanelModule.ControlPanel {} }
    }

    // Dock — running apps with icons, left-side popout
    Modules.ModuleLoader {
        moduleName: "dock"
        sourceComponent: Component { DockModule.Dock {} }
    }

    // Hot screen edges
    HotEdgesModule.HotEdges {}
}

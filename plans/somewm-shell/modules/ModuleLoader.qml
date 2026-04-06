import QtQuick
import "../core" as Core

// Lazy loader: only instantiates module content when enabled in config.
// Wraps a Component that is loaded/unloaded based on Config.isModuleEnabled().
// Usage:
//   ModuleLoader {
//       moduleName: "dashboard"
//       sourceComponent: Component { Dashboard {} }
//   }

Loader {
    id: root

    property string moduleName: ""

    // Explicit dependency on Config.ready ensures binding re-evaluates after async config load
    active: Core.Config.ready && Core.Config.isModuleEnabled(moduleName)
    visible: active

    // Fade in when loaded
    opacity: active && status === Loader.Ready ? 1.0 : 0.0
    Behavior on opacity {
        NumberAnimation {
            duration: Core.Anims.duration.normal
            easing.type: Core.Anims.ease.decel
        }
    }
}

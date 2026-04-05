pragma Singleton
import QtQuick
import Quickshell

Singleton {
    id: root

    // Global speed (1.0 = normal, 0.5 = slow-mo, 2.0 = fast, 0 = reduced motion)
    // Updated by Config.qml after initialization (avoids circular singleton dependency)
    property real scale: 1.0
    readonly property bool reducedMotion: scale === 0

    // === Durations (reactive to scale, child QtObject + alias) ===
    QtObject {
        id: _duration
        property int instant: Math.round(80 * root.scale)
        property int fast:    Math.round(150 * root.scale)
        property int normal:  Math.round(250 * root.scale)
        property int smooth:  Math.round(400 * root.scale)
        property int slow:    Math.round(600 * root.scale)
    }
    readonly property alias duration: _duration

    // === Easing types (Qt built-in — reliable, no custom BezierSpline issues) ===
    QtObject {
        id: _ease
        readonly property int standard:   Easing.OutCubic     // general transitions
        readonly property int expressive: Easing.OutBack      // panel enter (slight overshoot)
        readonly property int decel:      Easing.OutQuart     // fade-in, appear
        readonly property int accel:      Easing.InCubic      // panel exit, dismiss
        readonly property int bounce:     Easing.OutBack      // playful interactions
    }
    readonly property alias ease: _ease

    // Overshoot amount for OutBack curves (Qt default is 1.70158)
    readonly property real overshoot: 1.2
}

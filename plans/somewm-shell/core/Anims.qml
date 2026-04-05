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
        property int expressiveSpatial: Math.round(500 * root.scale)
        property int slow:    Math.round(600 * root.scale)
        property int large:   Math.round(600 * root.scale)
        property int extraLarge: Math.round(1000 * root.scale)
    }
    readonly property alias duration: _duration

    // === Easing types (Qt built-in — for backward compatibility) ===
    QtObject {
        id: _ease
        readonly property int standard:   Easing.OutCubic     // general transitions
        readonly property int expressive: Easing.OutBack      // panel enter (slight overshoot)
        readonly property int decel:      Easing.OutQuart     // fade-in, appear
        readonly property int accel:      Easing.InCubic      // panel exit, dismiss
        readonly property int bounce:     Easing.OutBack      // playful interactions
    }
    readonly property alias ease: _ease

    // === MD3 BezierSpline Curves (premium animations — use with Easing.BezierSpline) ===
    // Trailing [1.0, 1.0] required by Qt's bezierCurve format
    QtObject {
        id: _curves
        // Standard: smooth and natural, no overshoot
        readonly property var standard: [0.2, 0.0, 0.0, 1.0, 1.0, 1.0]
        // Standard accelerate: quick start
        readonly property var standardAccel: [0.3, 0.0, 1.0, 1.0, 1.0, 1.0]
        // Standard decelerate: gentle arrival
        readonly property var standardDecel: [0.0, 0.0, 0.0, 1.0, 1.0, 1.0]
        // Emphasized: complex multi-segment curve for important transitions
        readonly property var emphasized: [0.05, 0.0, 0.133, 0.06, 0.167, 0.4, 0.208, 0.82, 0.25, 1.0, 1.0, 1.0]
        // Emphasized decelerate: soft arrival with character
        readonly property var emphasizedDecel: [0.05, 0.7, 0.1, 1.0, 1.0, 1.0]
        // Emphasized accelerate: strong exit
        readonly property var emphasizedAccel: [0.3, 0.0, 0.8, 0.15, 1.0, 1.0]
        // Expressive spatial: slight overshoot, alive feel — for panels & large elements
        readonly property var expressiveSpatial: [0.38, 1.21, 0.22, 1.0, 1.0, 1.0]
        // Expressive fast: stronger overshoot — for quick spatial moves
        readonly property var expressiveFast: [0.42, 1.67, 0.21, 0.9, 1.0, 1.0]
        // Expressive effects: for color/opacity transitions
        readonly property var expressiveEffects: [0.34, 0.8, 0.34, 1.0, 1.0, 1.0]
    }
    readonly property alias curves: _curves

    // Overshoot amount for OutBack curves (Qt default is 1.70158)
    readonly property real overshoot: 1.2
}

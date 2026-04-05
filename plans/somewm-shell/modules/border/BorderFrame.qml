import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import "../../core" as Core
import "../../services" as Services

// Caelestia border frame — always-visible strip at bottom screen edge.
// Visually "inflates" upward when dashboard opens, wrapping around it.
// Has shadow for depth/visibility against any wallpaper.
Variants {
    model: Quickshell.screens

    PanelWindow {
        id: frame

        required property var modelData
        screen: modelData

        readonly property real sp: Core.Theme.dpiScale

        // Strip sizes
        readonly property real idleHeight: Math.round(8 * sp)
        readonly property real activeHeight: Math.round(14 * sp)

        // Is dashboard open on this screen?
        readonly property bool dashActive: Core.Panels.isOpen("dashboard") &&
            (modelData.name === Services.Compositor.focusedScreenName ||
             String(modelData.index) === Services.Compositor.focusedScreenName)

        color: "transparent"

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "somewm-shell:border"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        WlrLayershell.exclusionMode: ExclusionMode.Ignore

        anchors {
            bottom: true
            left: true
            right: true
        }

        // Dynamic height — inflates when dashboard is active
        implicitHeight: dashActive ? activeHeight : idleHeight

        Behavior on implicitHeight {
            NumberAnimation {
                duration: Core.Anims.duration.expressiveSpatial
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Core.Anims.curves.expressiveSpatial
            }
        }

        visible: true

        // The strip with shadow — layered for visual depth
        Item {
            id: stripVisual
            anchors.fill: parent

            layer.enabled: true
            layer.effect: MultiEffect {
                shadowEnabled: true
                shadowColor: Qt.rgba(0, 0, 0, 0.6)
                shadowVerticalOffset: Math.round(-4 * frame.sp)
                shadowHorizontalOffset: 0
                shadowBlur: 0.8
            }

            Rectangle {
                anchors.fill: parent
                color: Core.Theme.surfaceBase

                // Subtle gradient overlay — lighter at top for depth
                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    height: Math.round(2 * frame.sp)
                    color: Qt.rgba(1, 1, 1, 0.06)
                }
            }
        }

        // Accent glow line at the top edge — makes the strip pop
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: Math.round(1.5 * frame.sp)
            color: Core.Theme.accent
            opacity: dashActive ? 0.5 : 0.15

            Behavior on opacity {
                NumberAnimation {
                    duration: Core.Anims.duration.smooth
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: Core.Anims.curves.standard
                }
            }
        }
    }
}

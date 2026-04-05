import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import "../../core" as Core
import "../../services" as Services
import "../../components" as Components

// Caelestia Drawers.qml pattern — single fullscreen overlay that contains:
// 1. Border frame (inverted mask — thin strip at screen edges)
// 2. Panel background (ShapePath connecting border to dashboard wrapper)
// 3. Dashboard content (animated wrapper)
// Mirrored: Caelestia dashboard is at top, ours is at bottom.
Variants {
    model: Quickshell.screens

    PanelWindow {
        id: panel

        required property var modelData
        screen: modelData

        property bool shouldShow: Core.Panels.isOpen("dashboard") &&
            (modelData.name === Services.Compositor.focusedScreenName ||
             String(modelData.index) === Services.Compositor.focusedScreenName)

        // Visible when open or animating
        visible: shouldShow || wrapper.height > 0.5

        color: "transparent"
        focusable: shouldShow

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "somewm-shell:dashboard"
        WlrLayershell.keyboardFocus: shouldShow
            ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        anchors {
            top: true; bottom: true; left: true; right: true
        }

        // Click-through except on border + dashboard area
        mask: Region {
            item: clickTarget
        }

        readonly property real sp: Core.Theme.dpiScale
        readonly property real borderThickness: Math.round(6 * sp)
        readonly property real borderRounding: Math.round(25 * sp)
        readonly property real padLg: Math.round(15 * sp)
        readonly property real padNorm: Math.round(10 * sp)

        readonly property color borderColor: Core.Theme.surfaceBase

        // Tab state
        property int currentTab: 0
        Connections {
            target: Core.Panels
            function onRequestedTabChanged() {
                if (Core.Panels.requestedTab >= 0) {
                    panel.currentTab = Core.Panels.requestedTab
                    Core.Panels.requestedTab = -1
                }
            }
        }

        // Current tab content sizing
        property var currentLoader: {
            switch (currentTab) {
                case 0: return homeLoader
                case 1: return mediaLoader
                case 2: return perfLoader
                case 3: return notifLoader
                default: return homeLoader
            }
        }
        readonly property real tabContentWidth: currentLoader && currentLoader.item
            ? currentLoader.item.implicitWidth : 400
        readonly property real tabContentHeight: currentLoader && currentLoader.item
            ? currentLoader.item.implicitHeight : 200

        // Click target — covers border strip + dashboard wrapper area
        Item {
            id: clickTarget
            anchors.fill: parent

            // Bottom border strip click area
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: panel.borderThickness
                color: "transparent"
            }

            // Dashboard wrapper click area (only when visible)
            Rectangle {
                visible: wrapper.height > 0
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: panel.borderThickness
                width: wrapper.width
                height: wrapper.height
                color: "transparent"
            }

            // Dismiss area — rest of screen (when dashboard is open)
            MouseArea {
                anchors.fill: parent
                visible: panel.shouldShow
                z: -1
                onClicked: Core.Panels.close("dashboard")
                onWheel: (wheel) => { wheel.accepted = true }
            }
        }

        // ===== Visual layer: Border + Backgrounds with shadow =====
        // Caelestia Drawers.qml pattern: single layer with shadow effect
        Item {
            anchors.fill: parent
            layer.enabled: true
            layer.effect: MultiEffect {
                shadowEnabled: true
                blurMax: 15
                shadowColor: Qt.rgba(0, 0, 0, 0.55)
            }

            // LAYER 1: Border frame (Caelestia Border.qml)
            // Full-screen rect with inverted mask = only thin border strip visible.
            Item {
                id: borderFrame
                anchors.fill: parent

                Rectangle {
                    id: borderRect
                    anchors.fill: parent
                    color: panel.borderColor

                    layer.enabled: true
                    layer.effect: MultiEffect {
                        maskSource: borderMask
                        maskEnabled: true
                        maskInverted: true
                        maskThresholdMin: 0.5
                        maskSpreadAtMin: 1
                    }
                }

                Item {
                    id: borderMask
                    anchors.fill: parent
                    layer.enabled: true
                    visible: false

                    // Mask: rounded rect inset by borderThickness at bottom.
                    // Everything OUTSIDE = border strip visible.
                    Rectangle {
                        anchors.fill: parent
                        anchors.bottomMargin: panel.borderThickness
                        radius: panel.borderRounding
                    }
                }
            }

            // LAYER 2: Panel background (Caelestia Backgrounds.qml + Background.qml)
            // ShapePath connecting border strip to dashboard wrapper.
            // Mirrored from Caelestia (top→down becomes bottom→up).
            Shape {
                id: backgrounds
                anchors.fill: parent
                anchors.bottomMargin: panel.borderThickness
                preferredRendererType: Shape.CurveRenderer

            ShapePath {
                id: dashBg

                readonly property real rounding: panel.borderRounding
                readonly property bool flatten: wrapper.height < rounding * 2
                readonly property real roundingY: flatten ? wrapper.height / 2 : rounding
                readonly property real ww: wrapper.width
                readonly property real wh: wrapper.height

                strokeWidth: -1
                fillColor: panel.borderColor

                // Start at bottom-right of content area, just RIGHT of wrapper
                // (Caelestia starts top-left; we mirror to bottom-right)
                startX: (backgrounds.width + ww) / 2 + rounding
                startY: backgrounds.height

                // Arc: from border bottom edge UP-LEFT to wrapper bottom-right
                PathArc {
                    relativeX: -dashBg.rounding
                    relativeY: -dashBg.roundingY
                    radiusX: dashBg.rounding
                    radiusY: Math.min(dashBg.rounding, dashBg.wh)
                }

                // Up the right side of wrapper
                PathLine {
                    relativeX: 0
                    relativeY: -(dashBg.wh - dashBg.roundingY * 2)
                }

                // Arc: wrapper top-right corner (curves outward = Counterclockwise)
                PathArc {
                    relativeX: -dashBg.rounding
                    relativeY: -dashBg.roundingY
                    radiusX: dashBg.rounding
                    radiusY: Math.min(dashBg.rounding, dashBg.wh)
                    direction: PathArc.Counterclockwise
                }

                // Across the top of wrapper (right to left)
                PathLine {
                    relativeX: -(dashBg.ww - dashBg.rounding * 2)
                    relativeY: 0
                }

                // Arc: wrapper top-left corner (curves outward = Counterclockwise)
                PathArc {
                    relativeX: -dashBg.rounding
                    relativeY: dashBg.roundingY
                    radiusX: dashBg.rounding
                    radiusY: Math.min(dashBg.rounding, dashBg.wh)
                    direction: PathArc.Counterclockwise
                }

                // Down the left side of wrapper
                PathLine {
                    relativeX: 0
                    relativeY: dashBg.wh - dashBg.roundingY * 2
                }

                // Arc: from wrapper bottom-left back DOWN to border bottom edge
                PathArc {
                    relativeX: -dashBg.rounding
                    relativeY: dashBg.roundingY
                    radiusX: dashBg.rounding
                    radiusY: Math.min(dashBg.rounding, dashBg.wh)
                }
            }
        } // end backgrounds Shape
        } // end shadow Item

        // ===== LAYER 3: Dashboard wrapper (Caelestia Wrapper.qml) =====
        // Content that grows from the bottom border upward.
        Item {
            id: wrapper

            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: panel.borderThickness

            width: panel.tabContentWidth + panel.padLg * 2
            height: panel.shouldShow
                ? (tabBar.implicitHeight + panel.padNorm + panel.tabContentHeight + panel.padLg * 2)
                : 0

            visible: height > 0.5
            clip: true

            Behavior on width {
                NumberAnimation {
                    duration: Core.Anims.duration.large
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: Core.Anims.curves.emphasized
                }
            }
            Behavior on height {
                NumberAnimation {
                    id: heightAnim
                    duration: Core.Anims.duration.expressiveSpatial
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: panel.shouldShow
                        ? Core.Anims.curves.expressiveSpatial
                        : Core.Anims.curves.emphasized
                }
            }

            // Tab bar
            Components.TabBar {
                id: tabBar
                anchors.top: parent.top
                anchors.topMargin: panel.padNorm
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: panel.padLg
                anchors.rightMargin: panel.padLg

                currentIndex: panel.currentTab
                tabs: [
                    { icon: "\ue88a", label: "Dashboard" },
                    { icon: "\ue030", label: "Media" },
                    { icon: "\ue1b1", label: "Performance" },
                    { icon: "\ue7f4", label: "Notifications" }
                ]
                onTabChanged: (idx) => { panel.currentTab = idx }
            }

            // Tab content
            Item {
                id: tabContent
                anchors.top: tabBar.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: panel.padLg

                Loader {
                    id: homeLoader
                    active: panel.currentTab === 0 || item !== null
                    visible: panel.currentTab === 0
                    sourceComponent: Component { HomeTab {} }
                }
                Loader {
                    id: mediaLoader
                    active: panel.currentTab === 1 || item !== null
                    visible: panel.currentTab === 1
                    sourceComponent: Component {
                        MediaTab { tabActive: panel.currentTab === 1 }
                    }
                }
                Loader {
                    id: perfLoader
                    active: panel.currentTab === 2 || item !== null
                    visible: panel.currentTab === 2
                    sourceComponent: Component {
                        PerformanceTab { tabActive: panel.currentTab === 2 }
                    }
                }
                Loader {
                    id: notifLoader
                    active: panel.currentTab === 3 || item !== null
                    visible: panel.currentTab === 3
                    sourceComponent: Component { NotificationsTab {} }
                }
            }

            // Escape to close
            Keys.onEscapePressed: Core.Panels.close("dashboard")
        } // wrapper
    } // PanelWindow
} // Variants

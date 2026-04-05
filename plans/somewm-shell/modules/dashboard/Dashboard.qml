import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland
import "../../core" as Core
import "../../services" as Services
import "../../components" as Components

Variants {
    model: Quickshell.screens

    PanelWindow {
        id: panel

        required property var modelData
        screen: modelData

        property bool shouldShow: Core.Panels.isOpen("dashboard") &&
            (modelData.name === Services.Compositor.focusedScreenName ||
             String(modelData.index) === Services.Compositor.focusedScreenName)

        visible: shouldShow || heightAnim.running

        color: "transparent"
        focusable: shouldShow

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "somewm-shell:dashboard"
        WlrLayershell.keyboardFocus: shouldShow
            ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        anchors {
            top: true; bottom: true; left: true; right: true
        }

        mask: Region { item: backdrop }

        readonly property real borderThickness: Math.round(4 * Core.Theme.dpiScale)
        readonly property real borderRounding: Math.round(25 * Core.Theme.dpiScale)
        readonly property real padLg: Math.round(15 * Core.Theme.dpiScale)
        readonly property real padNorm: Math.round(10 * Core.Theme.dpiScale)

        // Tab state — requestedTab overrides, otherwise remember last tab
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

        // Current tab's loaded item (for content-driven sizing)
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

        // ===== BACKDROP =====
        Rectangle {
            id: backdrop
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, 0.35)
            opacity: panel.shouldShow ? 1.0 : 0.0
            focus: panel.shouldShow

            Keys.onEscapePressed: Core.Panels.close("dashboard")

            Behavior on opacity {
                NumberAnimation {
                    duration: Core.Anims.duration.smooth
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: Core.Anims.curves.standard
                }
            }

            MouseArea {
                anchors.fill: parent
                onClicked: Core.Panels.close("dashboard")
                onWheel: (wheel) => { wheel.accepted = true }
            }
        }

        // ===== BORDER STRIP (bottom edge — always visible when dashboard visible) =====
        // Thin strip at the very bottom of the screen, same color as dashboard bg.
        // Creates the visual base that the dashboard "grows from".
        Rectangle {
            id: borderStrip
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: panel.borderThickness
            color: Core.Theme.surfaceBase
            opacity: panel.shouldShow || heightAnim.running ? 1.0 : 0.0

            Behavior on opacity {
                NumberAnimation {
                    duration: Core.Anims.duration.fast
                }
            }
        }

        // ===== WRAPPER (Caelestia Wrapper.qml + Background.qml) =====
        // The dashboard grows from the border strip at the bottom.
        // Background shape connects the panel to the border strip using matching
        // color and rounding, creating the "inflation" effect.
        Item {
            id: wrapper

            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            // Sits on top of the border strip — no gap
            anchors.bottomMargin: 0

            // Explicit width/height from content (no circular anchors)
            width: panel.tabContentWidth + panel.padLg * 2
            height: panel.shouldShow
                ? (tabBar.implicitHeight + panel.padNorm + panel.tabContentHeight + panel.padLg * 2 + panel.borderThickness)
                : 0

            visible: height > 0

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
                    duration: panel.shouldShow
                        ? Core.Anims.duration.expressiveSpatial
                        : Core.Anims.duration.large
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: panel.shouldShow
                        ? Core.Anims.curves.expressiveSpatial
                        : Core.Anims.curves.emphasized
                }
            }

            // ===== Background shape (Caelestia Background.qml pattern) =====
            // Rounded rectangle that connects to the border strip at the bottom.
            // Top corners are rounded, bottom extends to screen edge (into the border strip).
            // This creates the "border wrapping around the panel" illusion.
            Shape {
                id: bgShape
                anchors.fill: parent
                layer.enabled: true
                layer.samples: 4

                ShapePath {
                    id: bgPath
                    fillColor: Core.Theme.surfaceBase
                    strokeWidth: -1

                    // Start at top-left, after the rounded corner
                    startX: 0
                    startY: panel.borderRounding

                    // Top-left rounded corner
                    PathArc {
                        x: panel.borderRounding
                        y: 0
                        radiusX: panel.borderRounding
                        radiusY: panel.borderRounding
                    }

                    // Top edge
                    PathLine {
                        x: bgShape.width - panel.borderRounding
                        y: 0
                    }

                    // Top-right rounded corner
                    PathArc {
                        x: bgShape.width
                        y: panel.borderRounding
                        radiusX: panel.borderRounding
                        radiusY: panel.borderRounding
                    }

                    // Right edge — goes to bottom
                    PathLine {
                        x: bgShape.width
                        y: bgShape.height
                    }

                    // Bottom edge — flat (connects to border strip, no rounding)
                    PathLine {
                        x: 0
                        y: bgShape.height
                    }

                    // Left edge — back to start
                    PathLine {
                        x: 0
                        y: panel.borderRounding
                    }
                }
            }

            // ===== Side border extensions =====
            // Thin strips on left and right of the dashboard that extend down to
            // the border strip, making the border visually wrap around the sides.
            Rectangle {
                id: leftBorder
                anchors.left: parent.left
                anchors.leftMargin: -panel.borderThickness
                anchors.top: parent.top
                anchors.topMargin: panel.borderRounding
                anchors.bottom: parent.bottom
                width: panel.borderThickness
                color: Core.Theme.surfaceBase
            }
            Rectangle {
                id: rightBorder
                anchors.right: parent.right
                anchors.rightMargin: -panel.borderThickness
                anchors.top: parent.top
                anchors.topMargin: panel.borderRounding
                anchors.bottom: parent.bottom
                width: panel.borderThickness
                color: Core.Theme.surfaceBase
            }

            // ===== Top border curve =====
            // Thin strip along the top that follows the rounded shape
            Shape {
                anchors.fill: parent
                layer.enabled: true
                layer.samples: 4

                ShapePath {
                    fillColor: "transparent"
                    strokeColor: Core.Theme.surfaceBase
                    strokeWidth: panel.borderThickness

                    startX: -panel.borderThickness
                    startY: panel.borderRounding + panel.borderThickness / 2

                    // Left side going up
                    PathLine {
                        x: -panel.borderThickness
                        y: panel.borderRounding
                    }

                    // Top-left arc
                    PathArc {
                        x: panel.borderRounding
                        y: -panel.borderThickness / 2
                        radiusX: panel.borderRounding + panel.borderThickness / 2
                        radiusY: panel.borderRounding + panel.borderThickness / 2
                    }

                    // Top edge
                    PathLine {
                        x: bgShape.width - panel.borderRounding
                        y: -panel.borderThickness / 2
                    }

                    // Top-right arc
                    PathArc {
                        x: bgShape.width + panel.borderThickness
                        y: panel.borderRounding
                        radiusX: panel.borderRounding + panel.borderThickness / 2
                        radiusY: panel.borderRounding + panel.borderThickness / 2
                    }

                    // Right side going down
                    PathLine {
                        x: bgShape.width + panel.borderThickness
                        y: panel.borderRounding + panel.borderThickness / 2
                    }
                }
            }

            // ===== Bottom border extensions (left and right of wrapper) =====
            // These extend the border strip from the wrapper edges to the screen edges,
            // so the full bottom edge appears as one continuous strip.
            // wrapper.x = (panel.width - wrapper.width) / 2 (centered)
            Rectangle {
                anchors.bottom: parent.bottom
                anchors.right: parent.left
                width: (panel.width - wrapper.width) / 2 + panel.borderThickness
                height: panel.borderThickness
                color: Core.Theme.surfaceBase
            }
            Rectangle {
                anchors.bottom: parent.bottom
                anchors.left: parent.right
                width: (panel.width - wrapper.width) / 2 + panel.borderThickness
                height: panel.borderThickness
                color: Core.Theme.surfaceBase
            }

            // Tab bar — positioned at top with padding
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

            // Tab content — below tabBar, padded
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
        }
    }
}

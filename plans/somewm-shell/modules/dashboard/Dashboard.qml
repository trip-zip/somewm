import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import "../../core" as Core
import "../../services" as Services
import "../../components" as Components

// Caelestia Drawers.qml pattern — single fullscreen overlay:
// 1. Border strip (rectangle at bottom screen edge)
// 2. Panel background (ShapePath connecting strip to dashboard)
// 3. Dashboard content (animated wrapper)
// Sequenced: strip slides up → dashboard grows → dashboard collapses → strip slides down
Variants {
    model: Quickshell.screens

    PanelWindow {
        id: panel

        required property var modelData
        screen: modelData

        property bool shouldShow: Core.Panels.isOpen("dashboard") &&
            (modelData.name === Services.Compositor.focusedScreenName ||
             String(modelData.index) === Services.Compositor.focusedScreenName)

        color: "transparent"
        focusable: shouldShow

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "somewm-shell:dashboard"
        WlrLayershell.keyboardFocus: shouldShow
            ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        WlrLayershell.exclusionMode: ExclusionMode.Ignore

        anchors {
            top: true; bottom: true; left: true; right: true
        }

        mask: Region { item: clickTarget }

        readonly property real sp: Core.Theme.dpiScale
        readonly property real borderThickness: Math.round(12 * sp)
        readonly property real borderRounding: Math.round(25 * sp)
        readonly property real padLg: Math.round(15 * sp)
        readonly property real padNorm: Math.round(10 * sp)
        readonly property color borderColor: Core.Theme.surfaceBase

        // === Sequenced animation state ===
        // Phase 1: strip slides up from bottom
        // Phase 2: dashboard content grows from strip
        // Close reverses: content collapses → strip slides down
        property bool stripVisible: false
        property bool contentVisible: false

        // Visible while strip or content is shown, or animating
        visible: shouldShow || stripVisible || contentVisible || stripAnim.running || contentAnim.running

        onShouldShowChanged: {
            if (shouldShow) {
                closeAnim.stop()
                openAnim.start()
            } else {
                openAnim.stop()
                closeAnim.start()
            }
        }

        SequentialAnimation {
            id: openAnim
            // Phase 1: strip appears
            PropertyAction { target: panel; property: "stripVisible"; value: true }
            PauseAnimation { duration: 350 }
            // Phase 2: content grows
            PropertyAction { target: panel; property: "contentVisible"; value: true }
        }

        SequentialAnimation {
            id: closeAnim
            // Phase 1: content collapses
            PropertyAction { target: panel; property: "contentVisible"; value: false }
            PauseAnimation { duration: 750 }
            // Phase 2: strip hides
            PropertyAction { target: panel; property: "stripVisible"; value: false }
        }

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
                visible: panel.stripVisible
            }

            // Dashboard wrapper click area — consumes clicks so dismiss doesn't fire
            Rectangle {
                visible: wrapper.height > 0
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: panel.borderThickness
                width: wrapper.width
                height: wrapper.height
                color: "transparent"

                MouseArea {
                    anchors.fill: parent
                    onClicked: {} // consume click
                    onWheel: (wheel) => { wheel.accepted = true }
                }
            }

            // Control panel hover trigger — right end of strip
            MouseArea {
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                width: Math.round(120 * panel.sp)
                height: panel.borderThickness + Math.round(20 * panel.sp)
                hoverEnabled: true
                visible: panel.stripVisible && !Core.Panels.isOpen("controlpanel")
                z: 2
                onEntered: Core.Panels.toggle("controlpanel")
                onClicked: Core.Panels.toggle("controlpanel")
            }

            // Dismiss area
            MouseArea {
                anchors.fill: parent
                visible: panel.shouldShow
                z: -1
                onClicked: Core.Panels.close("dashboard")
                onWheel: (wheel) => { wheel.accepted = true }
            }
        }

        // ===== Visual layer: Strip + Background as one surface with shadow =====
        Item {
            anchors.fill: parent
            layer.enabled: true
            layer.effect: MultiEffect {
                shadowEnabled: true
                blurMax: 15
                shadowColor: Qt.rgba(0, 0, 0, 0.55)
            }

            // Border strip at bottom edge
            Rectangle {
                id: borderStrip
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: panel.stripVisible ? panel.borderThickness : 0
                color: panel.borderColor

                Behavior on height {
                    NumberAnimation {
                        id: stripAnim
                        duration: 350
                        easing.type: Easing.BezierSpline
                        easing.bezierCurve: Core.Anims.curves.expressiveSpatial
                    }
                }
            }

            // Panel background ShapePath (sits above strip)
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

                    // Start bottom-right, just right of wrapper
                    startX: (backgrounds.width + ww) / 2 + rounding
                    startY: backgrounds.height

                    // Arc: border → wrapper bottom-right
                    PathArc {
                        relativeX: -dashBg.rounding
                        relativeY: -dashBg.roundingY
                        radiusX: dashBg.rounding
                        radiusY: Math.min(dashBg.rounding, dashBg.wh)
                    }

                    // Up right side
                    PathLine {
                        relativeX: 0
                        relativeY: -(dashBg.wh - dashBg.roundingY * 2)
                    }

                    // Top-right corner (outward)
                    PathArc {
                        relativeX: -dashBg.rounding
                        relativeY: -dashBg.roundingY
                        radiusX: dashBg.rounding
                        radiusY: Math.min(dashBg.rounding, dashBg.wh)
                        direction: PathArc.Counterclockwise
                    }

                    // Across top (right to left)
                    PathLine {
                        relativeX: -(dashBg.ww - dashBg.rounding * 2)
                        relativeY: 0
                    }

                    // Top-left corner (outward)
                    PathArc {
                        relativeX: -dashBg.rounding
                        relativeY: dashBg.roundingY
                        radiusX: dashBg.rounding
                        radiusY: Math.min(dashBg.rounding, dashBg.wh)
                        direction: PathArc.Counterclockwise
                    }

                    // Down left side
                    PathLine {
                        relativeX: 0
                        relativeY: dashBg.wh - dashBg.roundingY * 2
                    }

                    // Arc: wrapper bottom-left → border
                    PathArc {
                        relativeX: -dashBg.rounding
                        relativeY: dashBg.roundingY
                        radiusX: dashBg.rounding
                        radiusY: Math.min(dashBg.rounding, dashBg.wh)
                    }
                }
            } // Shape
        } // shadow Item

        // ===== LAYER 3: Dashboard wrapper =====
        Item {
            id: wrapper

            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: panel.borderThickness

            width: panel.tabContentWidth + panel.padLg * 2
            height: panel.contentVisible
                ? (tabBar.implicitHeight + panel.padNorm + panel.tabContentHeight + panel.padLg * 2)
                : 0

            visible: height > 0.5
            clip: true

            Behavior on width {
                NumberAnimation {
                    duration: 700
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: Core.Anims.curves.emphasized
                }
            }
            Behavior on height {
                NumberAnimation {
                    id: contentAnim
                    duration: 700
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: panel.contentVisible
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
                    { label: "Dashboard" },
                    { label: "Media" },
                    { label: "Performance" },
                    { label: "Notifications" }
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

            focus: true
            Keys.onEscapePressed: Core.Panels.close("dashboard")
        } // wrapper
    } // PanelWindow
} // Variants

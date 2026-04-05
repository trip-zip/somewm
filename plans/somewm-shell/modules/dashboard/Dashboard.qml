import QtQuick
import QtQuick.Layouts
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

        // ===== WRAPPER (Caelestia Wrapper.qml) =====
        Item {
            id: wrapper

            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Math.round(20 * Core.Theme.dpiScale)

            // Explicit width/height from content (no circular anchors)
            width: panel.tabContentWidth + panel.padLg * 2
            height: panel.shouldShow
                ? (tabBar.implicitHeight + panel.padNorm + panel.tabContentHeight + panel.padLg * 2)
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

            // Background
            Rectangle {
                anchors.fill: parent
                radius: Math.round(25 * Core.Theme.dpiScale)
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

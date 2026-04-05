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

        // Show only on focused screen when dashboard is open
        property bool shouldShow: Core.Panels.isOpen("dashboard") &&
            (modelData.name === Services.Compositor.focusedScreenName ||
             String(modelData.index) === Services.Compositor.focusedScreenName)

        visible: shouldShow || fadeOut.running

        color: "transparent"
        focusable: shouldShow

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "somewm-shell:dashboard"
        WlrLayershell.keyboardFocus: shouldShow ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        anchors {
            top: true; bottom: true; left: true; right: true
        }

        // Click-outside-to-close: backdrop covers full screen
        mask: Region { item: backdrop }

        Rectangle {
            id: backdrop
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, 0.3)
            opacity: panel.shouldShow ? 1.0 : 0.0
            focus: panel.shouldShow
            Keys.onEscapePressed: Core.Panels.close("dashboard")

            Behavior on opacity {
                NumberAnimation {
                    id: fadeOut
                    duration: Core.Anims.duration.normal
                    easing.type: Core.Anims.ease.standard
                }
            }

            MouseArea {
                anchors.fill: parent
                onClicked: Core.Panels.close("dashboard")
                onWheel: (wheel) => { wheel.accepted = true }
            }

            // Centered dashboard card
            Components.GlassCard {
                id: card
                elevated: true
                anchors.centerIn: parent
                width: Math.min(parent.width - 80, Math.round(700 * Core.Theme.dpiScale))
                height: Math.min(parent.height - 80, Math.round(700 * Core.Theme.dpiScale))

                opacity: panel.shouldShow ? 1.0 : 0.0
                scale: panel.shouldShow ? 1.0 : 0.95

                Behavior on opacity {
                    NumberAnimation {
                        duration: Core.Anims.duration.normal
                        easing.type: Core.Anims.ease.decel
                    }
                }
                Behavior on scale {
                    NumberAnimation {
                        duration: Core.Anims.duration.normal
                        easing.type: Core.Anims.ease.expressive
                    }
                }

                // Dashboard content
                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: Core.Theme.spacing.xl
                    spacing: Core.Theme.spacing.lg

                    ClockWidget {
                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.round(120 * Core.Theme.dpiScale)
                    }

                    Components.Separator { Layout.fillWidth: true }

                    StatsGrid {
                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.round(140 * Core.Theme.dpiScale)
                    }

                    Components.Separator { Layout.fillWidth: true }

                    QuickLaunch {
                        Layout.fillWidth: true
                    }

                    Components.Separator { Layout.fillWidth: true }

                    MediaMini {
                        Layout.fillWidth: true
                    }

                    Components.Separator { Layout.fillWidth: true }

                    ClientList {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                    }
                }
            }
        }

    }
}

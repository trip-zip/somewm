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

        property bool shouldShow: Core.Panels.isOpen("media") &&
            (modelData.name === Services.Compositor.focusedScreenName ||
             String(modelData.index) === Services.Compositor.focusedScreenName)

        visible: shouldShow || fadeOut.running

        color: "transparent"
        focusable: shouldShow

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "somewm-shell:media"
        WlrLayershell.keyboardFocus: shouldShow ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        anchors {
            bottom: true; left: true; right: true
        }
        margins.bottom: Math.round(20 * Core.Theme.dpiScale)
        margins.left: Math.round(20 * Core.Theme.dpiScale)
        margins.right: Math.round(20 * Core.Theme.dpiScale)

        implicitHeight: Math.round(360 * Core.Theme.dpiScale)

        // Full panel mask so backdrop click-to-close works
        mask: Region { item: backdrop }

        // Backdrop click to close
        Rectangle {
            id: backdrop
            anchors.fill: parent
            color: "transparent"
            focus: panel.shouldShow
            Keys.onEscapePressed: Core.Panels.close("media")

            MouseArea {
                anchors.fill: parent
                onClicked: Core.Panels.close("media")
                enabled: panel.shouldShow
            }
        }

        Components.GlassCard {
            id: mediaCard
            elevated: true
            anchors.centerIn: parent
            width: Math.min(parent.width - 40, Math.round(600 * Core.Theme.dpiScale))
            height: Math.round(320 * Core.Theme.dpiScale)

            opacity: panel.shouldShow ? 1.0 : 0.0
            scale: panel.shouldShow ? 1.0 : 0.95

            Behavior on opacity {
                NumberAnimation {
                    id: fadeOut
                    duration: Core.Anims.duration.normal
                    easing.type: Core.Anims.ease.decel
                }
            }
            Behavior on scale { Components.Anim {} }

            RowLayout {
                anchors.fill: parent
                anchors.margins: Core.Theme.spacing.lg
                spacing: Core.Theme.spacing.lg

                // Album art
                AlbumArt {
                    Layout.preferredWidth: Math.round(220 * Core.Theme.dpiScale)
                    Layout.fillHeight: true
                }

                // Right side: track info + controls
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: Core.Theme.spacing.md

                    TrackInfo {
                        Layout.fillWidth: true
                    }

                    Item { Layout.fillHeight: true }

                    ProgressBar {
                        Layout.fillWidth: true
                    }

                    Controls {
                        Layout.fillWidth: true
                    }

                    VolumeSlider {
                        Layout.fillWidth: true
                    }
                }
            }
        }

    }
}

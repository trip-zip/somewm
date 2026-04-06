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

        property bool shouldShow: Core.Panels.isOpen("collage") &&
            (modelData.name === Services.Compositor.focusedScreenName ||
             String(modelData.index) === Services.Compositor.focusedScreenName)

        visible: shouldShow || fadeAnim.running

        color: "transparent"
        focusable: shouldShow

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "somewm-shell:collage"
        WlrLayershell.keyboardFocus: shouldShow ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        anchors {
            top: true; bottom: true; left: true; right: true
        }

        mask: Region { item: backdrop }

        Rectangle {
            id: backdrop
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, 0.5)
            opacity: panel.shouldShow ? 1.0 : 0.0
            focus: panel.shouldShow
            Keys.onEscapePressed: {
                if (lightbox.visible) lightbox.close()
                else Core.Panels.close("collage")
            }

            Behavior on opacity {
                NumberAnimation {
                    id: fadeAnim
                    duration: Core.Anims.duration.normal
                    easing.type: Core.Anims.ease.standard
                }
            }

            MouseArea {
                anchors.fill: parent
                onClicked: Core.Panels.close("collage")
                onWheel: (wheel) => { wheel.accepted = true }
            }

            Components.GlassCard {
                id: mainCard
                anchors.centerIn: parent
                width: Math.min(parent.width - 40, Math.round(1200 * Core.Theme.dpiScale))
                height: Math.min(parent.height - 40, Math.round(800 * Core.Theme.dpiScale))

                opacity: panel.shouldShow ? 1.0 : 0.0
                scale: panel.shouldShow ? 1.0 : 0.95

                Behavior on opacity { Components.Anim {} }
                Behavior on scale { Components.Anim {} }

                MouseArea {
                    anchors.fill: parent
                    onWheel: (wheel) => { wheel.accepted = true }  // block wheel pass-through
                }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: Core.Theme.spacing.xl
                    spacing: Core.Theme.spacing.lg

                    // Header
                    RowLayout {
                        Layout.fillWidth: true

                        Components.StyledText {
                            text: "Collage"
                            font.pixelSize: Core.Theme.fontSize.xl
                            font.weight: Font.DemiBold
                            Layout.fillWidth: true
                        }

                        Text {
                            text: Services.Wallpapers.wallpapers.length + " images"
                            font.family: Core.Theme.fontUI
                            font.pixelSize: Core.Theme.fontSize.sm
                            color: Core.Theme.fgMuted
                        }

                        Components.MaterialIcon {
                            icon: "\ue5cd"  // close
                            size: Core.Theme.fontSize.lg
                            color: Core.Theme.fgDim
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: Core.Panels.close("collage")
                            }
                        }
                    }

                    // Masonry grid
                    MasonryGrid {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        onImageClicked: (path) => lightbox.open(path)
                    }
                }
            }

            // Lightbox overlay
            Lightbox {
                id: lightbox
                anchors.fill: parent
            }
        }

    }
}

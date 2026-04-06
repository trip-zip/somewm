import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import "../../core" as Core
import "../../services" as Services
import "../../components" as Components

Variants {
    model: Quickshell.screens

    PanelWindow {
        id: panel

        required property var modelData
        screen: modelData

        property bool shouldShow: Core.Panels.osdVisible &&
            (modelData.name === Services.Compositor.focusedScreenName ||
             String(modelData.index) === Services.Compositor.focusedScreenName)

        visible: shouldShow || fadeAnim.running

        color: "transparent"
        focusable: false

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "somewm-shell:osd"

        anchors {
            bottom: true; left: true; right: true
        }
        margins.bottom: 80

        implicitHeight: 80

        mask: Region { item: osdCard }

        Components.GlassCard {
            id: osdCard
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            width: 280
            height: 60

            opacity: panel.shouldShow ? 1.0 : 0.0
            scale: panel.shouldShow ? 1.0 : 0.9

            Behavior on opacity {
                NumberAnimation {
                    id: fadeAnim
                    duration: Core.Anims.duration.fast
                    easing.type: Core.Anims.ease.decel
                }
            }
            Behavior on scale { Components.Anim {} }

            RowLayout {
                anchors.fill: parent
                anchors.margins: Core.Theme.spacing.md
                spacing: Core.Theme.spacing.md

                // Dynamic content based on OSD type
                Loader {
                    Layout.preferredWidth: 36
                    Layout.preferredHeight: 36
                    sourceComponent: Core.Panels.osdType === "volume" ? volumeOsd :
                                     Core.Panels.osdType === "brightness" ? brightnessOsd : null
                }

                // Progress bar
                Rectangle {
                    Layout.fillWidth: true
                    height: 6
                    radius: 3
                    color: Core.Theme.glass2

                    Rectangle {
                        width: parent.width * Math.min(1.0, Core.Panels.osdValue / 100.0)
                        height: parent.height
                        radius: parent.radius
                        color: Core.Panels.osdType === "volume" ? Core.Theme.widgetVolume :
                               Core.Panels.osdType === "brightness" ? Core.Theme.widgetDisk :
                               Core.Theme.accent

                        Behavior on width { Components.Anim {} }
                    }
                }

                // Percentage
                Text {
                    text: Math.round(Core.Panels.osdValue) + "%"
                    font.family: Core.Theme.fontMono
                    font.pixelSize: Core.Theme.fontSize.sm
                    color: Core.Theme.fgMain
                    Layout.preferredWidth: 36
                    horizontalAlignment: Text.AlignRight
                }
            }
        }
        // OSD type components (inside PanelWindow to avoid Variants modelData injection)
        Component {
            id: volumeOsd
            VolumeOSD {}
        }

        Component {
            id: brightnessOsd
            BrightnessOSD {}
        }
    }
}

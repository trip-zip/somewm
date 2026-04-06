import QtQuick
import "../../core" as Core
import "../../services" as Services
import "../../components" as Components

Item {
    id: root

    Rectangle {
        anchors.fill: parent
        radius: Core.Theme.radius.md
        color: Core.Theme.glass2
        clip: true

        // Album art image (falls back to nocover.jpg)
        Image {
            id: artImage
            anchors.fill: parent
            source: Services.Media.artUrl || Qt.resolvedUrl("../../assets/icons/nocover.jpg")
            fillMode: Image.PreserveAspectCrop

            // Fade in reactively based on load status (no timer needed)
            opacity: status === Image.Ready ? 1.0 : 0.0
            Behavior on opacity {
                NumberAnimation {
                    duration: Core.Anims.duration.normal
                    easing.type: Core.Anims.ease.decel
                }
            }
        }

        // Bottom gradient overlay
        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: parent.height * 0.3
            gradient: Gradient {
                GradientStop { position: 0.0; color: "transparent" }
                GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.5) }
            }
        }
    }
}

import QtQuick
import QtQuick.Layouts
import "../../core" as Core
import "../../services" as Services
import "../../components" as Components

Components.ClickableCard {
    id: root
    implicitHeight: 56
    visible: Services.Media.hasPlayer

    onClicked: Core.Panels.toggle("media")

    RowLayout {
        anchors.fill: parent
        anchors.margins: Core.Theme.spacing.sm
        spacing: Core.Theme.spacing.sm

        // Album art thumbnail
        Rectangle {
            Layout.preferredWidth: 40
            Layout.preferredHeight: 40
            radius: Core.Theme.radius.sm
            color: Core.Theme.glass2
            clip: true

            Image {
                id: thumbImage
                anchors.fill: parent
                source: Services.Media.artUrl
                fillMode: Image.PreserveAspectCrop
                visible: status === Image.Ready
            }

            Components.MaterialIcon {
                anchors.centerIn: parent
                icon: "\ue405"  // music_note
                size: Core.Theme.fontSize.lg
                color: Core.Theme.fgMuted
                visible: thumbImage.status !== Image.Ready
            }
        }

        // Track info
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0

            Text {
                Layout.fillWidth: true
                text: Services.Media.trackTitle || "No media"
                font.family: Core.Theme.fontUI
                font.pixelSize: Core.Theme.fontSize.sm
                font.weight: Font.DemiBold
                color: Core.Theme.fgMain
                elide: Text.ElideRight
                maximumLineCount: 1
            }

            Text {
                Layout.fillWidth: true
                text: Services.Media.trackArtist
                font.family: Core.Theme.fontUI
                font.pixelSize: Core.Theme.fontSize.xs
                color: Core.Theme.fgDim
                elide: Text.ElideRight
                maximumLineCount: 1
                visible: text !== ""
            }
        }

        // Play/pause
        Components.MaterialIcon {
            icon: Services.Media.isPlaying ? "\ue034" : "\ue037"
            size: Core.Theme.fontSize.xl
            color: Core.Theme.accent

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: (mouse) => {
                    mouse.accepted = true
                    Services.Media.playPause()
                }
            }
        }

        // Animated wave indicator
        Components.PulseWave {
            active: Services.Media.isPlaying
            waveColor: Core.Theme.accent
            barCount: 4
        }
    }
}

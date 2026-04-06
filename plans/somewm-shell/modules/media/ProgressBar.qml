import QtQuick
import QtQuick.Layouts
import "../../core" as Core
import "../../services" as Services
import "../../components" as Components

ColumnLayout {
    spacing: Core.Theme.spacing.xs

    // Progress bar with seek thumb
    Item {
        Layout.fillWidth: true
        height: Math.round(16 * Core.Theme.dpiScale)

        // Track
        Rectangle {
            id: progressTrack
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: Core.Theme.slider.trackHeight
            radius: Core.Theme.slider.trackRadius
            color: Core.Theme.slider.trackColor

            // Filled portion
            Rectangle {
                width: parent.width * (Services.Media.progressPercent / 100.0)
                height: parent.height
                radius: parent.radius
                color: Core.Theme.accent

                Behavior on width {
                    NumberAnimation { duration: 1000; easing.type: Easing.Linear }
                }
            }
        }

        // Seek thumb (appears on hover)
        Rectangle {
            x: progressTrack.width * (Services.Media.progressPercent / 100.0) - width / 2
            anchors.verticalCenter: parent.verticalCenter
            width: Math.round(12 * Core.Theme.dpiScale)
            height: Math.round(12 * Core.Theme.dpiScale)
            radius: width / 2
            color: Core.Theme.accent
            border.color: Qt.rgba(1, 1, 1, 0.1)
            border.width: 1
            visible: progressMa.containsMouse || progressMa.pressed
            opacity: visible ? 1.0 : 0.0

            Behavior on opacity { Components.Anim {} }
        }

        // Seek on click
        MouseArea {
            id: progressMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            enabled: Services.Media.canSeek
            onClicked: (mouse) => {
                Services.Media.seekPercent((mouse.x / parent.width) * 100)
            }
            onPositionChanged: (mouse) => {
                if (pressed && Services.Media.canSeek)
                    Services.Media.seekPercent((mouse.x / parent.width) * 100)
            }
        }
    }

    // Time labels
    RowLayout {
        Layout.fillWidth: true

        Text {
            text: Services.Media.positionText
            font.family: Core.Theme.fontMono
            font.pixelSize: Core.Theme.fontSize.xs
            color: Core.Theme.fgMuted
        }

        Item { Layout.fillWidth: true }

        Text {
            text: Services.Media.lengthText
            font.family: Core.Theme.fontMono
            font.pixelSize: Core.Theme.fontSize.xs
            color: Core.Theme.fgMuted
        }
    }
}

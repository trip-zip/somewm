import QtQuick
import QtQuick.Layouts
import "../../core" as Core
import "../../services" as Services
import "../../components" as Components

RowLayout {
    spacing: Core.Theme.spacing.sm

    Components.MaterialIcon {
        icon: Services.Audio.icon
        size: Core.Theme.fontSize.base
        color: Services.Audio.muted ? Core.Theme.fgMuted : Core.Theme.widgetVolume

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: Services.Audio.toggleMute()
        }
    }

    // Slider with thumb
    Item {
        Layout.fillWidth: true
        height: Core.Theme.slider.thumbSize

        // Track
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: Core.Theme.slider.trackHeight
            radius: Core.Theme.slider.trackRadius
            color: Core.Theme.slider.trackColor

            // Filled portion
            Rectangle {
                width: parent.width * Math.min(1.0, Services.Audio.volume)
                height: parent.height
                radius: parent.radius
                color: Services.Audio.muted ? Core.Theme.fgMuted : Core.Theme.widgetVolume

                Behavior on width { Components.Anim {} }
            }
        }

        // Thumb
        Rectangle {
            x: parent.width * Math.min(1.0, Services.Audio.volume) - width / 2
            anchors.verticalCenter: parent.verticalCenter
            width: Math.round(12 * Core.Theme.dpiScale)
            height: Math.round(12 * Core.Theme.dpiScale)
            radius: width / 2
            color: Services.Audio.muted ? Core.Theme.fgMuted : Core.Theme.widgetVolume
            border.color: Qt.rgba(1, 1, 1, 0.1)
            border.width: 1
            visible: !Services.Audio.muted

            Behavior on x { Components.Anim {} }
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: (mouse) => {
                Services.Audio.setVolume(Math.max(0, Math.min(1, mouse.x / parent.width)))
            }
            onPositionChanged: (mouse) => {
                if (pressed)
                    Services.Audio.setVolume(Math.max(0, Math.min(1, mouse.x / parent.width)))
            }
        }
    }

    Text {
        text: Services.Audio.volumePercent + "%"
        font.family: Core.Theme.fontMono
        font.pixelSize: Core.Theme.fontSize.xs
        color: Core.Theme.fgMuted
        Layout.preferredWidth: Math.round(32 * Core.Theme.dpiScale)
        horizontalAlignment: Text.AlignRight
    }
}

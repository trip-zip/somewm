import QtQuick
import QtQuick.Layouts
import "../../core" as Core
import "../../services" as Services
import "../../components" as Components

RowLayout {
    spacing: Core.Theme.spacing.lg
    Layout.alignment: Qt.AlignHCenter

    // Previous
    Components.MaterialIcon {
        icon: "\ue045"  // skip_previous
        size: Core.Theme.fontSize.xxl
        color: Services.Media.canGoPrevious ? Core.Theme.fgMain : Core.Theme.fgMuted
        opacity: Services.Media.canGoPrevious ? 1.0 : 0.4

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            enabled: Services.Media.canGoPrevious
            onClicked: Services.Media.previous()
        }
    }

    // Play/Pause — flat accent circle
    Item {
        width: Math.round(48 * Core.Theme.dpiScale)
        height: Math.round(48 * Core.Theme.dpiScale)

        scale: playMa.pressed ? 0.92 : (playMa.containsMouse ? 1.05 : 1.0)
        Behavior on scale { Components.Anim {} }

        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: playMa.containsMouse ? Core.Theme.accentLight : Core.Theme.accent

            Behavior on color { Components.CAnim {} }
        }

        Components.MaterialIcon {
            anchors.centerIn: parent
            icon: Services.Media.isPlaying ? "\ue034" : "\ue037"  // pause / play_arrow
            size: Core.Theme.fontSize.xxl
            color: Core.Theme.bgBase
        }

        MouseArea {
            id: playMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            enabled: Services.Media.canPlay || Services.Media.canPause
            onClicked: Services.Media.playPause()
        }
    }

    // Next
    Components.MaterialIcon {
        icon: "\ue044"  // skip_next
        size: Core.Theme.fontSize.xxl
        color: Services.Media.canGoNext ? Core.Theme.fgMain : Core.Theme.fgMuted
        opacity: Services.Media.canGoNext ? 1.0 : 0.4

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            enabled: Services.Media.canGoNext
            onClicked: Services.Media.next()
        }
    }
}

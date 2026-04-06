import QtQuick
import QtQuick.Layouts
import "../core" as Core
import "." as Components

Components.GlassCard {
    id: root

    property string label: ""
    property string value: ""
    property string icon: ""
    property color accentColor: Core.Theme.accent

    implicitHeight: 80

    RowLayout {
        anchors.fill: parent
        anchors.margins: Core.Theme.spacing.md
        spacing: Core.Theme.spacing.md

        // Icon
        Components.MaterialIcon {
            icon: root.icon
            size: Core.Theme.fontSize.xxl
            color: root.accentColor
            visible: root.icon !== ""
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Core.Theme.spacing.xs

            // Value
            Text {
                text: root.value
                font.family: Core.Theme.fontMono
                font.pixelSize: Core.Theme.fontSize.xl
                font.weight: Font.Bold
                color: root.accentColor
            }

            // Label
            Text {
                text: root.label
                font.family: Core.Theme.fontUI
                font.pixelSize: Core.Theme.fontSize.sm
                color: Core.Theme.fgDim
            }
        }
    }
}

import QtQuick
import QtQuick.Layouts
import "../core" as Core

RowLayout {
    id: root

    property string title: ""
    property color accentColor: Core.Theme.accent

    spacing: Core.Theme.spacing.sm

    // Accent dot
    Rectangle {
        width: Math.round(8 * Core.Theme.dpiScale)
        height: width
        radius: width / 2
        color: root.accentColor
    }

    Text {
        text: root.title
        font.family: Core.Theme.fontUI
        font.pixelSize: Core.Theme.fontSize.xl
        font.weight: Font.DemiBold
        color: root.accentColor
        Layout.fillWidth: true
    }
}

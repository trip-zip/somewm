import QtQuick
import QtQuick.Layouts
import "../../core" as Core

Item {
    id: root

    property string timeText: ""
    property string dateText: ""

    Timer {
        interval: 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            var now = new Date()
            root.timeText = Qt.formatTime(now, "HH:mm")
            root.dateText = Qt.formatDate(now, "dddd, MMMM d")
        }
    }

    ColumnLayout {
        anchors.centerIn: parent
        spacing: Core.Theme.spacing.xs

        Text {
            Layout.alignment: Qt.AlignHCenter
            text: root.timeText
            font.family: Core.Theme.fontMono
            font.pixelSize: Core.Theme.fontSize.display
            font.weight: Font.DemiBold
            color: Core.Theme.accent
        }

        Text {
            Layout.alignment: Qt.AlignHCenter
            text: root.dateText
            font.family: Core.Theme.fontUI
            font.pixelSize: Core.Theme.fontSize.base
            font.weight: Font.Medium
            font.capitalization: Font.AllUppercase
            font.letterSpacing: 1
            color: Core.Theme.fgDim
        }
    }
}

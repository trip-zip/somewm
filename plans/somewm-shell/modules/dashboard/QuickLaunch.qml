import QtQuick
import QtQuick.Layouts
import "../../core" as Core
import "../../services" as Services
import "../../components" as Components

Item {
    id: root
    implicitHeight: launchRow.implicitHeight

    // Favorite apps — customize this list
    property var apps: [
        { name: "Terminal",  icon: "\ue8b4", cmd: "alacritty" },
        { name: "Browser",   icon: "\ue894", cmd: "firefox" },
        { name: "Files",     icon: "\ue2c7", cmd: "thunar" },
        { name: "Editor",    icon: "\ue3c9", cmd: "code" },
        { name: "Music",     icon: "\ue405", cmd: "spotify" },
    ]

    RowLayout {
        id: launchRow
        anchors.fill: parent
        spacing: Core.Theme.spacing.sm

        Repeater {
            model: root.apps

            Components.ClickableCard {
                Layout.fillWidth: true
                Layout.preferredHeight: Math.round(72 * Core.Theme.dpiScale)

                onClicked: Services.Compositor.spawn(modelData.cmd)

                ColumnLayout {
                    anchors.centerIn: parent
                    spacing: Core.Theme.spacing.xs

                    // Accent circle behind icon
                    Rectangle {
                        Layout.alignment: Qt.AlignHCenter
                        width: Math.round(40 * Core.Theme.dpiScale)
                        height: width
                        radius: width / 2
                        color: Core.Theme.accentFaint

                        Components.MaterialIcon {
                            anchors.centerIn: parent
                            icon: modelData.icon
                            size: Core.Theme.fontSize.xl
                            color: Core.Theme.accent
                        }
                    }

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: modelData.name
                        font.family: Core.Theme.fontUI
                        font.pixelSize: Core.Theme.fontSize.xs
                        color: Core.Theme.fgDim
                    }
                }
            }
        }
    }
}

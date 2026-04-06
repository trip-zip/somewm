import QtQuick
import QtQuick.Layouts
import "../../core" as Core
import "../../services" as Services
import "../../components" as Components

Item {
    id: root

    signal previewRequested(string path)

    Flickable {
        id: flickable
        anchors.fill: parent
        contentHeight: grid.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        GridLayout {
            id: grid
            width: flickable.width
            columns: Math.max(1, Math.floor(root.width / Math.round(200 * Core.Theme.dpiScale)))
            columnSpacing: Core.Theme.spacing.sm
            rowSpacing: Core.Theme.spacing.sm

            Repeater {
                model: Services.Wallpapers.wallpapers

                Rectangle {
                    required property var modelData
                    required property int index

                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.round(140 * Core.Theme.dpiScale)
                    radius: Core.Theme.radius.sm
                    color: Core.Theme.glass2
                    clip: true

                    // Current wallpaper indicator
                    border.color: modelData.path === Services.Wallpapers.currentWallpaper
                        ? Core.Theme.accent : "transparent"
                    border.width: modelData.path === Services.Wallpapers.currentWallpaper ? 2 : 0

                    Image {
                        anchors.fill: parent
                        anchors.margins: 1
                        source: "file://" + modelData.path
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        sourceSize.width: 400
                        sourceSize.height: 280

                        // Fade in on load
                        opacity: status === Image.Ready ? 1.0 : 0.0
                        Behavior on opacity {
                            NumberAnimation {
                                duration: Core.Anims.duration.fast
                                easing.type: Core.Anims.ease.decel
                            }
                        }
                    }

                    // Name overlay
                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width
                        height: Math.round(28 * Core.Theme.dpiScale)
                        color: Qt.rgba(0, 0, 0, 0.6)
                        radius: Core.Theme.radius.sm

                        Text {
                            anchors.centerIn: parent
                            text: modelData.name
                            font.family: Core.Theme.fontUI
                            font.pixelSize: Core.Theme.fontSize.xs
                            color: Core.Theme.fgMain
                            elide: Text.ElideMiddle
                            width: parent.width - Core.Theme.spacing.sm * 2
                            horizontalAlignment: Text.AlignHCenter
                        }
                    }

                    // Hover overlay
                    Rectangle {
                        anchors.fill: parent
                        radius: parent.radius
                        color: ma.containsMouse ? Qt.rgba(1, 1, 1, 0.05) : "transparent"
                    }

                    MouseArea {
                        id: ma
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        onClicked: (mouse) => {
                            if (mouse.button === Qt.RightButton)
                                root.previewRequested(modelData.path)
                            else
                                Services.Wallpapers.setWallpaper(modelData.path)
                        }
                    }
                }
            }
        }

        // Loading state
        Text {
            anchors.centerIn: parent
            text: Services.Wallpapers.loading ? "Scanning wallpapers..." : ""
            font.family: Core.Theme.fontUI
            font.pixelSize: Core.Theme.fontSize.base
            color: Core.Theme.fgMuted
            visible: Services.Wallpapers.wallpapers.length === 0
        }
    }
}

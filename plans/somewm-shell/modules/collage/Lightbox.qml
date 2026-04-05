import QtQuick
import QtQuick.Layouts
import "../../core" as Core
import "../../services" as Services
import "../../components" as Components

Item {
    id: root
    visible: imagePath !== "" || closeAnim.running

    property string imagePath: ""

    function open(path) {
        imagePath = path
    }

    function close() {
        imagePath = ""
    }

    // Full-screen backdrop
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.9)
        opacity: root.imagePath !== "" ? 1.0 : 0.0

        Behavior on opacity {
            NumberAnimation {
                id: closeAnim
                duration: Core.Anims.duration.normal
                easing.type: Core.Anims.ease.standard
            }
        }

        MouseArea {
            anchors.fill: parent
            onClicked: root.close()
        }

        // Full-size image
        Image {
            anchors.centerIn: parent
            width: parent.width - 60
            height: parent.height - 60
            source: root.imagePath ? "file://" + root.imagePath : ""
            fillMode: Image.PreserveAspectFit
            asynchronous: true

            opacity: status === Image.Ready ? 1.0 : 0.0
            Behavior on opacity { Components.Anim {} }
        }

        // Close button
        Rectangle {
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: Core.Theme.spacing.lg
            width: 40
            height: 40
            radius: 20
            color: Core.Theme.glass2

            Components.MaterialIcon {
                anchors.centerIn: parent
                icon: "\ue5cd"  // close
                size: Core.Theme.fontSize.xl
                color: Core.Theme.fgMain
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.close()
            }
        }

        // Image info
        Rectangle {
            anchors.bottom: parent.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.margins: Core.Theme.spacing.lg
            width: nameText.implicitWidth + Core.Theme.spacing.lg * 2
            height: 36
            radius: Core.Theme.radius.sm
            color: Core.Theme.glass1

            Text {
                id: nameText
                anchors.centerIn: parent
                text: root.imagePath.split("/").pop() || ""
                font.family: Core.Theme.fontUI
                font.pixelSize: Core.Theme.fontSize.sm
                color: Core.Theme.fgMain
            }
        }

        // Set as wallpaper button
        Rectangle {
            anchors.bottom: parent.bottom
            anchors.right: parent.right
            anchors.margins: Core.Theme.spacing.lg
            width: setRow.width + Core.Theme.spacing.lg * 2
            height: 36
            radius: Core.Theme.radius.sm
            color: Core.Theme.accent

            RowLayout {
                id: setRow
                anchors.centerIn: parent
                spacing: Core.Theme.spacing.xs

                Components.MaterialIcon {
                    icon: "\ue3f4"  // wallpaper
                    size: Core.Theme.fontSize.base
                    color: Core.Theme.bgBase
                }

                Text {
                    text: "Set wallpaper"
                    font.family: Core.Theme.fontUI
                    font.pixelSize: Core.Theme.fontSize.sm
                    font.weight: Font.DemiBold
                    color: Core.Theme.bgBase
                }
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    Services.Wallpapers.setWallpaper(root.imagePath)
                    root.close()
                }
            }
        }
    }
}

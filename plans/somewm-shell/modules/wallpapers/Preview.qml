import QtQuick
import "../../core" as Core
import "../../components" as Components

Item {
    id: root
    visible: previewImage.source !== ""

    property string previewPath: ""

    // Full overlay background
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.8)
        visible: root.previewPath !== ""

        MouseArea {
            anchors.fill: parent
            onClicked: root.previewPath = ""
        }

        // Full-size preview
        Image {
            id: previewImage
            anchors.centerIn: parent
            width: parent.width - 80
            height: parent.height - 80
            source: root.previewPath ? "file://" + root.previewPath : ""
            fillMode: Image.PreserveAspectFit
            asynchronous: true

            opacity: status === Image.Ready ? 1.0 : 0.0
            Behavior on opacity { Components.Anim {} }
        }

        // Close hint
        Text {
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: Core.Theme.spacing.lg
            text: "Click to close"
            font.family: Core.Theme.fontUI
            font.pixelSize: Core.Theme.fontSize.sm
            color: Core.Theme.fgMuted
        }
    }
}

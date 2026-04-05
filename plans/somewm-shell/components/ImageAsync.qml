import QtQuick
import "../core" as Core

Item {
    id: root

    property alias source: img.source
    property alias fillMode: img.fillMode
    property alias status: img.status
    property alias sourceSize: img.sourceSize
    property color placeholderColor: Core.Theme.glass2
    property int radius: 0

    // Placeholder
    Rectangle {
        anchors.fill: parent
        color: root.placeholderColor
        radius: root.radius
        visible: img.status !== Image.Ready
    }

    Image {
        id: img
        anchors.fill: parent
        asynchronous: true
        fillMode: Image.PreserveAspectCrop
        cache: true

        opacity: status === Image.Ready ? 1.0 : 0.0
        Behavior on opacity {
            NumberAnimation {
                duration: Core.Anims.duration.fast
                easing.type: Core.Anims.ease.decel
            }
        }
    }
}

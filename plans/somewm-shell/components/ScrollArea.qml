import QtQuick
import "../core" as Core

Flickable {
    id: root

    clip: true
    boundsBehavior: Flickable.StopAtBounds
    flickableDirection: Flickable.VerticalFlick

    // Scroll indicator
    Rectangle {
        id: scrollbar
        parent: root
        anchors.right: parent.right
        anchors.rightMargin: 2

        y: root.contentHeight > 0 ? (root.contentY / root.contentHeight * root.height) : 0
        width: 3
        height: root.contentHeight > 0 ? Math.max(20, root.height / root.contentHeight * root.height) : 0
        radius: 1.5
        color: Core.Theme.fgMuted

        visible: root.contentHeight > root.height
        opacity: root.moving ? 0.8 : 0.0

        Behavior on opacity {
            NumberAnimation {
                duration: Core.Anims.duration.fast
                easing.type: Core.Anims.ease.standard
            }
        }
    }
}

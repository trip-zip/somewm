import QtQuick
import "../core" as Core
import "." as Components

MouseArea {
    id: root
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor

    Rectangle {
        anchors.fill: parent
        radius: parent.parent ? parent.parent.radius || 0 : 0
        color: root.pressed ? Qt.rgba(1, 1, 1, 0.08) :
               root.containsMouse ? Qt.rgba(1, 1, 1, 0.04) : "transparent"

        Behavior on color { Components.CAnim {} }
    }
}

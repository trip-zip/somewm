import QtQuick
import "../core" as Core

Item {
    id: root

    property real value: 0       // 0.0 - 1.0
    property color barColor: Core.Theme.accent
    property color trackColor: Core.Theme.glass2
    property int barRadius: 3

    implicitHeight: 6

    Rectangle {
        anchors.fill: parent
        radius: root.barRadius
        color: root.trackColor

        Rectangle {
            id: fill
            height: parent.height
            width: parent.width * root.value
            radius: parent.radius
            color: root.barColor

            Behavior on width {
                NumberAnimation {
                    duration: Core.Anims.duration.normal
                    easing.type: Core.Anims.ease.standard
                }
            }
        }
    }
}

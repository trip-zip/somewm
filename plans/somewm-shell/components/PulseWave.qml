import QtQuick
import "../core" as Core

Item {
    id: root

    property bool active: false
    property color waveColor: Core.Theme.accent
    property int barCount: 5
    property int barWidth: 3
    property int barSpacing: 2

    implicitWidth: barCount * barWidth + Math.max(0, barCount - 1) * barSpacing
    implicitHeight: 24

    Row {
        anchors.centerIn: parent
        spacing: root.barSpacing

        Repeater {
            model: root.barCount

            Rectangle {
                required property int index
                width: root.barWidth
                height: root.active ? root.height * _scale : root.height * 0.2
                radius: root.barWidth / 2
                color: root.waveColor
                anchors.verticalCenter: parent.verticalCenter

                property real _scale: 0.2

                // Staggered animation per bar
                SequentialAnimation on _scale {
                    running: root.active
                    loops: Animation.Infinite

                    PauseAnimation { duration: index * 80 }
                    NumberAnimation {
                        from: 0.2; to: 1.0
                        duration: 300
                        easing.type: Easing.InOutSine
                    }
                    NumberAnimation {
                        from: 1.0; to: 0.2
                        duration: 300
                        easing.type: Easing.InOutSine
                    }
                    PauseAnimation { duration: (root.barCount - index - 1) * 80 }
                }

                // Note: no Behavior on height — SequentialAnimation on _scale
                // already provides smooth transitions; a Behavior here would
                // conflict and cause double-animation jitter every frame.
            }
        }
    }
}

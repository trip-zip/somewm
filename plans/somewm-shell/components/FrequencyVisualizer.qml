import QtQuick
import "../core" as Core

Item {
    id: root

    // Frequency bar values (0.0 - 1.0 per bar)
    property var values: []
    property int barCount: Core.Constants.mediaBarCount
    property real innerRadius: Math.round(80 * Core.Theme.dpiScale)
    property real maxBarHeight: Math.round(60 * Core.Theme.dpiScale)
    property real barWidth: Math.round(4 * Core.Theme.dpiScale)
    property color barColor: Core.Theme.accent
    property bool active: false

    implicitWidth: (innerRadius + maxBarHeight) * 2 + barWidth * 2
    implicitHeight: implicitWidth

    Repeater {
        model: root.barCount

        Rectangle {
            id: bar

            property real barValue: {
                if (!root.active || !root.values || index >= root.values.length) return 0
                return Math.max(0.01, Math.min(1.0, root.values[index]))
            }
            property real animatedValue: 0

            Behavior on animatedValue {
                NumberAnimation {
                    duration: Core.Anims.duration.instant
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: Core.Anims.curves.standard
                }
            }
            onBarValueChanged: animatedValue = barValue

            width: root.barWidth
            height: Math.max(root.barWidth, root.barWidth + root.maxBarHeight * animatedValue)
            radius: width / 2
            color: root.barColor
            opacity: 0.3 + 0.7 * animatedValue

            // Position at center, will be rotated outward
            x: root.width / 2 - width / 2
            y: root.height / 2 - root.innerRadius - height

            transformOrigin: Item.Bottom

            transform: Rotation {
                origin.x: bar.width / 2
                origin.y: root.innerRadius + bar.height
                angle: index * (360 / root.barCount)
            }

            Behavior on opacity {
                NumberAnimation { duration: Core.Anims.duration.instant }
            }
        }
    }

    // Idle state: subtle pulse animation when no audio data
    SequentialAnimation on opacity {
        running: root.active && (!root.values || root.values.length === 0)
        loops: Animation.Infinite
        NumberAnimation { to: 0.4; duration: Core.Anims.duration.extraLarge; easing.type: Easing.BezierSpline; easing.bezierCurve: Core.Anims.curves.emphasized }
        NumberAnimation { to: 1.0; duration: Core.Anims.duration.extraLarge; easing.type: Easing.BezierSpline; easing.bezierCurve: Core.Anims.curves.emphasized }
    }
}

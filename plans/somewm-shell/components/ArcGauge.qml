import QtQuick
import QtQuick.Shapes
import "../core" as Core

Item {
    id: root

    property real value: 0.0          // 0.0 - 1.0
    property real startAngle: -225    // degrees (bottom-left start)
    property real sweepAngle: 270     // degrees (3/4 circle)
    property int lineWidth: Math.round(Core.Constants.arcGaugeLineWidth * Core.Theme.dpiScale)
    property color trackColor: Core.Theme.fade(Core.Theme.fgMuted, 0.12)
    property color progressColor: Core.Theme.accent
    property int animDuration: Core.Anims.duration.large

    implicitWidth: Math.round(Core.Constants.arcGaugeSize * Core.Theme.dpiScale)
    implicitHeight: implicitWidth

    // Animated value for smooth transitions
    property real _animValue: 0.0
    Behavior on _animValue {
        NumberAnimation {
            duration: root.animDuration
            easing.type: Easing.BezierSpline
            easing.bezierCurve: Core.Anims.curves.expressiveSpatial
        }
    }
    onValueChanged: _animValue = value

    Shape {
        anchors.fill: parent
        layer.enabled: true
        layer.samples: 4  // antialiasing

        // Track arc (full background sweep)
        ShapePath {
            fillColor: "transparent"
            strokeColor: root.trackColor
            strokeWidth: root.lineWidth
            capStyle: ShapePath.RoundCap

            PathAngleArc {
                centerX: root.width / 2
                centerY: root.height / 2
                radiusX: root.width / 2 - root.lineWidth
                radiusY: root.height / 2 - root.lineWidth
                startAngle: root.startAngle
                sweepAngle: root.sweepAngle
            }
        }

        // Progress arc (animated value)
        ShapePath {
            fillColor: "transparent"
            strokeColor: root.progressColor
            strokeWidth: root.lineWidth
            capStyle: ShapePath.RoundCap

            PathAngleArc {
                centerX: root.width / 2
                centerY: root.height / 2
                radiusX: root.width / 2 - root.lineWidth
                radiusY: root.height / 2 - root.lineWidth
                startAngle: root.startAngle
                sweepAngle: root.sweepAngle * root._animValue
            }
        }
    }

    // Subtle glow behind progress endpoint
    Rectangle {
        visible: root._animValue > 0.01
        width: root.lineWidth * 2.5
        height: width
        radius: width / 2
        color: root.progressColor
        opacity: 0.15

        // Position at the end of the progress arc
        x: root.width / 2 + (root.width / 2 - root.lineWidth) *
           Math.cos((root.startAngle + root.sweepAngle * root._animValue) * Math.PI / 180) - width / 2
        y: root.height / 2 + (root.height / 2 - root.lineWidth) *
           Math.sin((root.startAngle + root.sweepAngle * root._animValue) * Math.PI / 180) - height / 2

        Behavior on x { NumberAnimation { duration: root.animDuration; easing.type: Easing.BezierSpline; easing.bezierCurve: Core.Anims.curves.expressiveSpatial } }
        Behavior on y { NumberAnimation { duration: root.animDuration; easing.type: Easing.BezierSpline; easing.bezierCurve: Core.Anims.curves.expressiveSpatial } }
    }

    // Center content slot
    default property alias content: centerItem.data
    Item {
        id: centerItem
        anchors.centerIn: parent
        width: parent.width - root.lineWidth * 4
        height: parent.height - root.lineWidth * 4
    }
}

import QtQuick
import "../core" as Core

Item {
    id: root

    property real value: 0       // 0.0 - 1.0
    property int lineWidth: 4
    property color trackColor: Core.Theme.glass2
    property color progressColor: Core.Theme.accent
    property int animDuration: Core.Anims.duration.normal

    implicitWidth: 64
    implicitHeight: 64

    Canvas {
        id: canvas
        anchors.fill: parent
        antialiasing: true

        property real animatedValue: root.value
        Behavior on animatedValue {
            NumberAnimation {
                duration: root.animDuration
                easing.type: Core.Anims.ease.standard
            }
        }

        onAnimatedValueChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()

        onPaint: {
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)

            var cx = width / 2
            var cy = height / 2
            var r = Math.min(cx, cy) - root.lineWidth
            var startAngle = -Math.PI / 2

            // Track
            ctx.beginPath()
            ctx.arc(cx, cy, r, 0, 2 * Math.PI)
            ctx.lineWidth = root.lineWidth
            ctx.strokeStyle = root.trackColor.toString()
            ctx.stroke()

            // Progress
            if (canvas.animatedValue > 0) {
                var endAngle = startAngle + (2 * Math.PI * canvas.animatedValue)
                ctx.beginPath()
                ctx.arc(cx, cy, r, startAngle, endAngle)
                ctx.lineWidth = root.lineWidth
                ctx.strokeStyle = root.progressColor.toString()
                ctx.lineCap = "round"
                ctx.stroke()
            }
        }
    }

    // Center text slot
    default property alias content: centerItem.data
    Item {
        id: centerItem
        anchors.centerIn: parent
    }
}

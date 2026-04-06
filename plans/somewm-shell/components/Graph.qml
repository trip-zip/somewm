import QtQuick
import "../core" as Core

Item {
    id: root

    property var dataPoints: []    // array of numbers (0.0 - 1.0)
    property int maxPoints: 60
    property color lineColor: Core.Theme.accent
    property color fillColor: Qt.rgba(lineColor.r, lineColor.g, lineColor.b, 0.15)
    property int lineWidth: 2

    implicitHeight: 40

    function addPoint(value) {
        var pts = dataPoints.slice()
        pts.push(Math.max(0, Math.min(1, value)))
        if (pts.length > maxPoints) pts.shift()
        dataPoints = pts
        canvas.requestPaint()
    }

    Canvas {
        id: canvas
        anchors.fill: parent
        antialiasing: true

        onPaint: {
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)

            var pts = root.dataPoints
            if (pts.length < 2) return

            var step = width / (root.maxPoints - 1)
            var startX = width - (pts.length - 1) * step

            // Fill
            ctx.beginPath()
            ctx.moveTo(startX, height)
            for (var i = 0; i < pts.length; i++) {
                var x = startX + i * step
                var y = height - pts[i] * height
                if (i === 0) ctx.lineTo(x, y)
                else ctx.lineTo(x, y)
            }
            ctx.lineTo(startX + (pts.length - 1) * step, height)
            ctx.closePath()
            ctx.fillStyle = root.fillColor.toString()
            ctx.fill()

            // Line
            ctx.beginPath()
            for (var j = 0; j < pts.length; j++) {
                var lx = startX + j * step
                var ly = height - pts[j] * height
                if (j === 0) ctx.moveTo(lx, ly)
                else ctx.lineTo(lx, ly)
            }
            ctx.lineWidth = root.lineWidth
            ctx.strokeStyle = root.lineColor.toString()
            ctx.lineJoin = "round"
            ctx.stroke()
        }
    }
}

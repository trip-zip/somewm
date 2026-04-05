import QtQuick
import QtQuick.Shapes
import "../core" as Core

Item {
    id: root

    property real curveHeight: Math.round(Core.Constants.dashboardTopCurveHeight * Core.Theme.dpiScale)
    property color fillColor: Core.Theme.surfaceBase
    property real cornerRadius: Math.round(Core.Theme.radius.xl)

    Shape {
        anchors.fill: parent
        layer.enabled: true
        layer.samples: 4

        ShapePath {
            strokeWidth: -1
            fillColor: root.fillColor

            // Start at bottom-left corner (with radius)
            startX: 0
            startY: root.height

            // Left edge up to where the corner starts
            PathLine {
                x: 0
                y: root.curveHeight + root.cornerRadius
            }

            // Top-left corner (rounded)
            PathArc {
                x: root.cornerRadius
                y: root.curveHeight
                radiusX: root.cornerRadius
                radiusY: root.cornerRadius
            }

            // Concave curve across the top — the signature "punch inward" effect
            PathArc {
                x: root.width - root.cornerRadius
                y: root.curveHeight
                radiusX: (root.width - root.cornerRadius * 2) / 2
                radiusY: root.curveHeight
                direction: PathArc.Counterclockwise
            }

            // Top-right corner (rounded)
            PathArc {
                x: root.width
                y: root.curveHeight + root.cornerRadius
                radiusX: root.cornerRadius
                radiusY: root.cornerRadius
            }

            // Right edge down to bottom
            PathLine {
                x: root.width
                y: root.height
            }

            // Bottom edge back to start
            PathLine {
                x: 0
                y: root.height
            }
        }
    }

    // Border overlay for subtle edge definition
    Shape {
        anchors.fill: parent
        layer.enabled: true
        layer.samples: 4

        ShapePath {
            strokeWidth: 1
            strokeColor: Core.Theme.glassBorder
            fillColor: "transparent"

            startX: 0
            startY: root.height

            PathLine {
                x: 0
                y: root.curveHeight + root.cornerRadius
            }
            PathArc {
                x: root.cornerRadius
                y: root.curveHeight
                radiusX: root.cornerRadius
                radiusY: root.cornerRadius
            }
            PathArc {
                x: root.width - root.cornerRadius
                y: root.curveHeight
                radiusX: (root.width - root.cornerRadius * 2) / 2
                radiusY: root.curveHeight
                direction: PathArc.Counterclockwise
            }
            PathArc {
                x: root.width
                y: root.curveHeight + root.cornerRadius
                radiusX: root.cornerRadius
                radiusY: root.cornerRadius
            }
            PathLine {
                x: root.width
                y: root.height
            }
        }
    }
}

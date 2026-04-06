import QtQuick
import "../core" as Core
import "." as Components

Item {
    id: root

    property bool hovered: false
    property bool elevated: false
    property bool accentTint: false
    property color tintColor: Core.Theme.accent

    // Aliases to inner rect for backwards compatibility
    property alias color: innerRect.color
    property alias border: innerRect.border
    property alias radius: innerRect.radius

    // Children go inside the inner rectangle
    default property alias content: innerRect.data

    // Main rectangle — depth through color layering, not shadow
    Rectangle {
        id: innerRect
        anchors.fill: parent

        color: {
            if (root.accentTint) {
                var c = root.tintColor
                return root.hovered ? Qt.rgba(c.r, c.g, c.b, 0.14)
                                    : Qt.rgba(c.r, c.g, c.b, 0.08)
            }
            if (root.elevated) {
                return root.hovered ? Core.Theme.surfaceContainerHigh
                                    : Core.Theme.surfaceContainer
            }
            return root.hovered ? Core.Theme.surfaceContainer
                                : Core.Theme.surfaceBase
        }
        radius: Core.Theme.radius.md
        border.color: {
            if (root.accentTint) {
                var c = root.tintColor
                return Qt.rgba(c.r, c.g, c.b, 0.25)
            }
            return root.hovered ? Qt.rgba(1, 1, 1, 0.14)
                                : Qt.rgba(1, 1, 1, 0.06)
        }
        border.width: 1

        Behavior on color { Components.CAnim {} }
        Behavior on border.color { Components.CAnim {} }
    }
}

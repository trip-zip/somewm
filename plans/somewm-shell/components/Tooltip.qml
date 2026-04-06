import QtQuick
import "../core" as Core

Item {
    id: root

    property string text: ""
    property Item target: parent
    property int delay: 500

    visible: false

    // Tooltip popup
    Rectangle {
        id: popup
        visible: root.visible && root.text !== ""

        width: label.implicitWidth + Core.Theme.spacing.md * 2
        height: label.implicitHeight + Core.Theme.spacing.sm * 2
        radius: Core.Theme.radius.sm
        color: Core.Theme.bgOverlay
        border.color: Core.Theme.glassBorder
        border.width: 1

        // Position above the target
        x: root.target ? (root.target.width - width) / 2 : 0
        y: root.target ? -height - Core.Theme.spacing.xs : 0

        opacity: root.visible ? 1.0 : 0.0
        Behavior on opacity {
            NumberAnimation {
                duration: Core.Anims.duration.fast
                easing.type: Core.Anims.ease.decel
            }
        }

        Text {
            id: label
            anchors.centerIn: parent
            text: root.text
            font.family: Core.Theme.fontUI
            font.pixelSize: Core.Theme.fontSize.xs
            color: Core.Theme.fgMain
        }
    }

    // Show/hide logic with delay
    Timer {
        id: showTimer
        interval: root.delay
        onTriggered: root.visible = true
    }

    function show() { showTimer.start() }
    function hide() { showTimer.stop(); root.visible = false }
}

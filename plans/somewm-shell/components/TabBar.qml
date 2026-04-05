import QtQuick
import QtQuick.Layouts
import "../core" as Core

Item {
    id: root

    property int currentIndex: 0
    // Each tab: { icon: "\ue88a", label: "Home" }
    property var tabs: []

    signal tabChanged(int index)

    implicitHeight: Math.round(Core.Constants.tabBarHeight * Core.Theme.dpiScale)

    // Tab buttons
    RowLayout {
        id: tabRow
        anchors.fill: parent
        anchors.leftMargin: Core.Theme.spacing.xl
        anchors.rightMargin: Core.Theme.spacing.xl
        anchors.bottomMargin: indicatorHeight + separatorHeight + indicatorSpacing
        spacing: 0

        property real indicatorHeight: Math.round(Core.Constants.tabIndicatorHeight * Core.Theme.dpiScale)
        property real separatorHeight: 1
        property real indicatorSpacing: Math.round(5 * Core.Theme.dpiScale)

        Repeater {
            model: root.tabs

            Item {
                id: tabDelegate
                Layout.fillWidth: true
                Layout.fillHeight: true

                required property int index
                required property var modelData

                property bool isActive: index === root.currentIndex
                property bool isHovered: tabMouse.containsMouse
                property bool isPressed: tabMouse.pressed

                // Hover/press state layer
                Rectangle {
                    anchors.centerIn: parent
                    width: tabLabel.implicitWidth + Core.Theme.spacing.lg * 2
                    height: parent.height
                    radius: Core.Theme.radius.sm
                    color: tabDelegate.isActive ? Core.Theme.accent :
                           Core.Theme.fgMain
                    opacity: tabDelegate.isPressed ? 0.10 :
                             tabDelegate.isHovered ? 0.08 : 0

                    Behavior on opacity {
                        NumberAnimation { duration: Core.Anims.duration.fast }
                    }
                }

                Text {
                    id: tabLabel
                    anchors.centerIn: parent
                    text: modelData.label || ""
                    font.family: Core.Theme.fontUI
                    font.pixelSize: Core.Theme.fontSize.sm
                    font.weight: Font.DemiBold
                    color: tabDelegate.isActive ? Core.Theme.accent : Core.Theme.fgDim

                    Behavior on color {
                        ColorAnimation { duration: Core.Anims.duration.fast }
                    }
                }

                MouseArea {
                    id: tabMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        root.currentIndex = tabDelegate.index
                        root.tabChanged(tabDelegate.index)
                    }
                }
            }
        }
    }

    // Sliding indicator bar
    Rectangle {
        id: indicator

        property var activeTab: tabRow.children[root.currentIndex] || null

        y: parent.height - height - 1  // above separator
        height: Math.round(Core.Constants.tabIndicatorHeight * Core.Theme.dpiScale)
        radius: height
        color: Core.Theme.accent
        clip: true

        width: activeTab ? activeTab.width : 0
        x: activeTab ? activeTab.x + tabRow.anchors.leftMargin : 0

        Behavior on x {
            NumberAnimation {
                duration: Core.Anims.duration.smooth
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Core.Anims.curves.emphasized
            }
        }
        Behavior on width {
            NumberAnimation {
                duration: Core.Anims.duration.smooth
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Core.Anims.curves.emphasized
            }
        }
    }

    // Separator line
    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 1
        color: Core.Theme.fade(Core.Theme.fgMuted, 0.12)
    }

    // Mouse wheel tab cycling
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.NoButton
        onWheel: (wheel) => {
            if (wheel.angleDelta.y > 0 && root.currentIndex > 0)
                root.currentIndex--
            else if (wheel.angleDelta.y < 0 && root.currentIndex < root.tabs.length - 1)
                root.currentIndex++
            wheel.accepted = true
        }
    }
}

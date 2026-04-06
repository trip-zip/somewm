import QtQuick
import "../core" as Core

Item {
    id: root

    property var wallpapers: []   // Array of { path, name }
    property int currentIndex: 0
    property string selectedPath: ""

    signal wallpaperSelected(string path)
    signal wallpaperApplied(string path)

    implicitHeight: Math.round(Core.Constants.carouselItemHeight * Core.Theme.dpiScale * Core.Constants.carouselFocusScale) + Core.Theme.spacing.xl

    ListView {
        id: carousel
        anchors.fill: parent
        orientation: ListView.Horizontal
        model: root.wallpapers
        spacing: Math.round(-60 * Core.Theme.dpiScale)  // negative for overlap
        snapMode: ListView.SnapToItem
        highlightMoveDuration: Core.Anims.duration.expressiveSpatial
        highlightRangeMode: ListView.StrictlyEnforceRange
        preferredHighlightBegin: width / 2 - Math.round(Core.Constants.carouselItemWidth * Core.Theme.dpiScale * Core.Constants.carouselFocusScale) / 2
        preferredHighlightEnd: width / 2 + Math.round(Core.Constants.carouselItemWidth * Core.Theme.dpiScale * Core.Constants.carouselFocusScale) / 2
        currentIndex: root.currentIndex
        clip: true
        cacheBuffer: 3000

        onCurrentIndexChanged: {
            root.currentIndex = currentIndex
            if (currentItem) {
                root.selectedPath = root.wallpapers[currentIndex].path
                root.wallpaperSelected(root.selectedPath)
            }
        }

        delegate: Item {
            id: cardDelegate
            width: Math.round(Core.Constants.carouselItemWidth * Core.Theme.dpiScale)
            height: Math.round(Core.Constants.carouselItemHeight * Core.Theme.dpiScale)

            property bool isCurrent: ListView.isCurrentItem
            property bool isHovered: cardMouse.containsMouse

            // Dynamic Z for layering
            z: isCurrent ? 10 : 0

            // Animated properties
            property real animScale: isCurrent ? Core.Constants.carouselFocusScale : 1.0
            property real animOpacity: isCurrent ? 1.0 : (isHovered ? 0.75 : 0.5)
            property real animSkew: {
                if (isCurrent) return 0.0
                var offset = (cardDelegate.x + width / 2) - (carousel.contentX + carousel.width / 2)
                return offset > 0 ? Core.Constants.carouselSkew : -Core.Constants.carouselSkew
            }

            Behavior on animScale {
                NumberAnimation {
                    duration: Core.Anims.duration.expressiveSpatial
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: Core.Anims.curves.expressiveSpatial
                }
            }
            Behavior on animOpacity {
                NumberAnimation {
                    duration: Core.Anims.duration.smooth
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: Core.Anims.curves.standard
                }
            }
            Behavior on animSkew {
                NumberAnimation {
                    duration: Core.Anims.duration.expressiveSpatial
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: Core.Anims.curves.emphasized
                }
            }

            transform: [
                Matrix4x4 {
                    matrix: Qt.matrix4x4(
                        1, 0, 0, 0,
                        cardDelegate.animSkew, 1, 0, 0,
                        0, 0, 1, 0,
                        0, 0, 0, 1
                    )
                },
                Scale {
                    origin.x: cardDelegate.width / 2
                    origin.y: cardDelegate.height / 2
                    xScale: cardDelegate.animScale
                    yScale: cardDelegate.animScale
                }
            ]

            // Card with rounded image
            Rectangle {
                anchors.fill: parent
                radius: Math.round(Core.Theme.radius.xl)
                clip: true
                color: Core.Theme.surfaceBase

                Image {
                    anchors.fill: parent
                    source: modelData.path ? "file://" + modelData.path : ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    opacity: cardDelegate.animOpacity
                    sourceSize.width: 800  // limit memory for thumbnails
                    sourceSize.height: 600

                    Behavior on opacity {
                        NumberAnimation { duration: Core.Anims.duration.fast }
                    }
                }

                // Gradient overlay at bottom for name label
                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: parent.height * 0.3
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: "transparent" }
                        GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.6) }
                    }
                    visible: cardDelegate.isCurrent
                }

                // Wallpaper name
                Text {
                    anchors.bottom: parent.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.margins: Core.Theme.spacing.md
                    text: modelData.name || ""
                    font.family: Core.Theme.fontUI
                    font.pixelSize: Core.Theme.fontSize.sm
                    font.weight: Font.Medium
                    color: "#ffffff"
                    elide: Text.ElideRight
                    visible: cardDelegate.isCurrent
                    opacity: cardDelegate.isCurrent ? 1.0 : 0.0

                    Behavior on opacity {
                        NumberAnimation { duration: Core.Anims.duration.normal }
                    }
                }

                // Active border
                Rectangle {
                    anchors.fill: parent
                    radius: parent.radius
                    color: "transparent"
                    border.width: cardDelegate.isCurrent ? 2 : 0
                    border.color: Core.Theme.accent
                    opacity: cardDelegate.isCurrent ? 1.0 : 0.0

                    Behavior on opacity {
                        NumberAnimation { duration: Core.Anims.duration.fast }
                    }
                }
            }

            MouseArea {
                id: cardMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    if (cardDelegate.isCurrent) {
                        root.wallpaperApplied(modelData.path)
                    } else {
                        carousel.currentIndex = index
                    }
                }
            }
        }
    }

    // Keyboard navigation
    Keys.onLeftPressed: {
        if (carousel.currentIndex > 0) carousel.currentIndex--
    }
    Keys.onRightPressed: {
        if (carousel.currentIndex < root.wallpapers.length - 1) carousel.currentIndex++
    }
    Keys.onReturnPressed: {
        if (root.selectedPath) root.wallpaperApplied(root.selectedPath)
    }
}

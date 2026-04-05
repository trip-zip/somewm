import QtQuick
import QtQuick.Layouts
import "../../core" as Core
import "../../services" as Services
import "../../components" as Components

Item {
    id: root

    // Signal to parent Lightbox
    signal imageClicked(string path)

    Flickable {
        id: flickable
        anchors.fill: parent
        contentHeight: flow.height
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        // Flow layout for masonry-like effect
        Flow {
            id: flow
            width: flickable.width
            spacing: Core.Theme.spacing.sm

            Repeater {
                model: Services.Wallpapers.wallpapers

                Rectangle {
                    required property var modelData
                    required property int index

                    // Vary height for masonry effect
                    width: (root.width - Core.Theme.spacing.sm * 2) / 3 - 1
                    height: 140 + (index % 3) * 60  // 140, 200, 260 repeating
                    radius: Core.Theme.radius.sm
                    color: Core.Theme.glass2
                    clip: true

                    Image {
                        anchors.fill: parent
                        anchors.margins: 1
                        source: "file://" + modelData.path
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        sourceSize.width: 400
                        sourceSize.height: 400

                        opacity: status === Image.Ready ? 1.0 : 0.0
                        Behavior on opacity {
                            NumberAnimation {
                                duration: Core.Anims.duration.fast
                                easing.type: Core.Anims.ease.decel
                            }
                        }
                    }

                    // Hover overlay
                    Rectangle {
                        anchors.fill: parent
                        radius: parent.radius
                        color: imgMa.containsMouse ? Qt.rgba(0, 0, 0, 0.2) : "transparent"

                        // Show name on hover
                        Text {
                            anchors.bottom: parent.bottom
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.margins: Core.Theme.spacing.sm
                            text: modelData.name
                            font.family: Core.Theme.fontUI
                            font.pixelSize: Core.Theme.fontSize.xs
                            color: "white"
                            elide: Text.ElideMiddle
                            visible: imgMa.containsMouse
                        }
                    }

                    MouseArea {
                        id: imgMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.imageClicked(modelData.path)
                    }
                }
            }
        }

        // Empty state
        Text {
            anchors.centerIn: parent
            text: Services.Wallpapers.loading ? "Loading images..." : "No images found"
            font.family: Core.Theme.fontUI
            font.pixelSize: Core.Theme.fontSize.base
            color: Core.Theme.fgMuted
            visible: Services.Wallpapers.wallpapers.length === 0
        }
    }
}

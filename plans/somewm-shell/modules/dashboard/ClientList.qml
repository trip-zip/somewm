import QtQuick
import QtQuick.Layouts
import "../../core" as Core
import "../../services" as Services
import "../../components" as Components

Item {
    id: root

    ColumnLayout {
        anchors.fill: parent
        spacing: Core.Theme.spacing.sm

        // Header
        Text {
            text: "Open Windows"
            font.family: Core.Theme.fontUI
            font.pixelSize: Core.Theme.fontSize.base
            font.weight: Font.DemiBold
            color: Core.Theme.fgDim
        }

        // Scrollable client list
        Flickable {
            id: flickable
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentHeight: clientColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            ColumnLayout {
                id: clientColumn
                width: flickable.width
                spacing: Core.Theme.spacing.xs

                Repeater {
                    model: Services.Compositor.clients

                    Components.ClickableCard {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 44

                        onClicked: {
                            Services.Compositor.focusClient(modelData.wid)
                            Core.Panels.close("dashboard")
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: Core.Theme.spacing.sm
                            spacing: Core.Theme.spacing.sm

                            Components.MaterialIcon {
                                icon: "\uef3d"  // web_asset icon
                                size: Core.Theme.fontSize.lg
                                color: Core.Theme.accent
                            }

                            // Window name
                            Text {
                                Layout.fillWidth: true
                                text: modelData.name || modelData.class || "Unknown"
                                font.family: Core.Theme.fontUI
                                font.pixelSize: Core.Theme.fontSize.sm
                                color: Core.Theme.fgMain
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }

                            // Tag badge
                            Rectangle {
                                visible: modelData.tag !== ""
                                width: tagText.implicitWidth + Core.Theme.spacing.sm * 2
                                height: 20
                                radius: Core.Theme.radius.sm
                                color: Core.Theme.glass2

                                Text {
                                    id: tagText
                                    anchors.centerIn: parent
                                    text: modelData.tag
                                    font.family: Core.Theme.fontUI
                                    font.pixelSize: Core.Theme.fontSize.xs
                                    color: Core.Theme.fgDim
                                }
                            }
                        }
                    }
                }

                // Empty state
                Text {
                    visible: Services.Compositor.clients.length === 0
                    Layout.fillWidth: true
                    Layout.topMargin: Core.Theme.spacing.lg
                    horizontalAlignment: Text.AlignHCenter
                    text: "No open windows"
                    font.family: Core.Theme.fontUI
                    font.pixelSize: Core.Theme.fontSize.sm
                    color: Core.Theme.fgMuted
                }
            }
        }
    }
}

import QtQuick
import QtQuick.Layouts
import "../../../somewm-shell/core" as Core
import "../../../somewm-shell/components" as Components
import "../../services" as AiServices

Item {
    id: root

    Flickable {
        id: flickable
        anchors.fill: parent
        contentHeight: messageColumn.height
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        // Auto-scroll to bottom on new messages
        onContentHeightChanged: {
            if (contentHeight > height) {
                contentY = contentHeight - height
            }
        }

        ColumnLayout {
            id: messageColumn
            width: parent.width
            spacing: Core.Theme.spacing.sm

            Repeater {
                model: AiServices.Ollama.messages

                Rectangle {
                    required property var modelData
                    required property int index

                    Layout.fillWidth: true
                    Layout.preferredHeight: msgContent.implicitHeight + Core.Theme.spacing.md * 2

                    radius: Core.Theme.radius.md
                    color: modelData.role === "user" ? Core.Theme.glass2 : Core.Theme.glass1
                    border.color: modelData.role === "assistant" ? Core.Theme.glassBorder : "transparent"
                    border.width: modelData.role === "assistant" ? 1 : 0

                    ColumnLayout {
                        id: msgContent
                        anchors.fill: parent
                        anchors.margins: Core.Theme.spacing.md
                        spacing: Core.Theme.spacing.xs

                        // Role label
                        Text {
                            text: modelData.role === "user" ? "You" : AiServices.Ollama.model
                            font.family: Core.Theme.fontUI
                            font.pixelSize: Core.Theme.fontSize.xs
                            font.weight: Font.DemiBold
                            color: modelData.role === "user" ? Core.Theme.accent : Core.Theme.green
                        }

                        // Message content
                        Text {
                            Layout.fillWidth: true
                            text: modelData.content
                            font.family: modelData.role === "assistant" ? Core.Theme.fontMono : Core.Theme.fontUI
                            font.pixelSize: Core.Theme.fontSize.sm
                            color: Core.Theme.fgMain
                            wrapMode: Text.WordWrap
                            textFormat: Text.PlainText
                        }
                    }
                }
            }

            // Generating indicator
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 40
                radius: Core.Theme.radius.md
                color: Core.Theme.glass1
                visible: AiServices.Ollama.generating

                RowLayout {
                    anchors.centerIn: parent
                    spacing: Core.Theme.spacing.sm

                    Components.PulseWave {
                        active: true
                        waveColor: Core.Theme.green
                        barCount: 3
                    }

                    Text {
                        text: "Thinking..."
                        font.family: Core.Theme.fontUI
                        font.pixelSize: Core.Theme.fontSize.sm
                        color: Core.Theme.fgDim
                    }
                }
            }

            // Empty state
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 200
                visible: AiServices.Ollama.messages.length === 0 && !AiServices.Ollama.generating

                ColumnLayout {
                    anchors.centerIn: parent
                    spacing: Core.Theme.spacing.md

                    Components.MaterialIcon {
                        Layout.alignment: Qt.AlignHCenter
                        icon: "\ue90b"  // smart_toy
                        size: 48
                        color: Core.Theme.fgMuted
                    }

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: "Ask me anything"
                        font.family: Core.Theme.fontUI
                        font.pixelSize: Core.Theme.fontSize.base
                        color: Core.Theme.fgMuted
                    }

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: "Model: " + AiServices.Ollama.model
                        font.family: Core.Theme.fontMono
                        font.pixelSize: Core.Theme.fontSize.xs
                        color: Core.Theme.fgMuted
                    }
                }
            }
        }
    }
}

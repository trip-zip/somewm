import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import "../../../somewm-shell/core" as Core
import "../../../somewm-shell/services" as Services
import "../../../somewm-shell/components" as Components
import "../../services" as AiServices

Variants {
    model: Quickshell.screens

    Components.SlidePanel {
        id: panel

        required property var modelData
        screen: modelData

        edge: "right"
        panelWidth: 500

        shown: Core.Panels.isOpen("ai-chat") &&
            (modelData.name === Services.Compositor.focusedScreenName ||
             String(modelData.index) === Services.Compositor.focusedScreenName)

        ColumnLayout {
            anchors.fill: parent
            spacing: Core.Theme.spacing.md

            // Header (z-elevated so ModelSelector dropdown paints above MessageList)
            RowLayout {
                z: 10
                Layout.fillWidth: true
                spacing: Core.Theme.spacing.sm

                Components.MaterialIcon {
                    icon: "\ue90b"  // smart_toy (robot)
                    size: Core.Theme.fontSize.xl
                    color: Core.Theme.accent
                }

                Components.StyledText {
                    text: "AI Chat"
                    font.pixelSize: Core.Theme.fontSize.lg
                    font.weight: Font.DemiBold
                    Layout.fillWidth: true
                }

                // Model selector
                ModelSelector {
                    Layout.preferredWidth: 120
                }

                // Clear button
                Components.MaterialIcon {
                    icon: "\ue872"  // delete
                    size: Core.Theme.fontSize.lg
                    color: Core.Theme.fgDim
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: AiServices.Ollama.clearHistory()
                    }
                }

                Components.MaterialIcon {
                    icon: "\ue5cd"  // close
                    size: Core.Theme.fontSize.lg
                    color: Core.Theme.fgDim
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Core.Panels.close("ai-chat")
                    }
                }
            }

            Components.Separator { Layout.fillWidth: true }

            // Message list
            MessageList {
                Layout.fillWidth: true
                Layout.fillHeight: true
            }

            // Error message
            Text {
                Layout.fillWidth: true
                text: AiServices.Ollama.error
                font.family: Core.Theme.fontUI
                font.pixelSize: Core.Theme.fontSize.sm
                color: Core.Theme.urgent
                wrapMode: Text.WordWrap
                visible: AiServices.Ollama.error !== ""
            }

            Components.Separator { Layout.fillWidth: true }

            // Input bar
            InputBar {
                Layout.fillWidth: true
            }
        }
    }
}

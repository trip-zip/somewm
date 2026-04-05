import QtQuick
import QtQuick.Layouts
import "../../../somewm-shell/core" as Core
import "../../../somewm-shell/components" as Components
import "../../services" as AiServices

Rectangle {
    id: root
    height: 28
    radius: Core.Theme.radius.sm
    color: selectorMa.containsMouse ? Core.Theme.glass2 : Core.Theme.glass1
    border.color: Core.Theme.glassBorder
    border.width: 1

    property bool expanded: false

    Behavior on color { Components.CAnim {} }

    // Current model display
    RowLayout {
        anchors.fill: parent
        anchors.margins: Core.Theme.spacing.xs
        spacing: Core.Theme.spacing.xs

        Text {
            Layout.fillWidth: true
            text: AiServices.Ollama.model
            font.family: Core.Theme.fontMono
            font.pixelSize: Core.Theme.fontSize.xs
            color: Core.Theme.fgDim
            elide: Text.ElideRight
        }

        Components.MaterialIcon {
            icon: root.expanded ? "\ue5c7" : "\ue5c5"  // expand_less / expand_more
            size: Core.Theme.fontSize.sm
            color: Core.Theme.fgMuted
        }
    }

    MouseArea {
        id: selectorMa
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.expanded = !root.expanded
    }

    // Dropdown
    Rectangle {
        visible: root.expanded
        anchors.top: parent.bottom
        anchors.topMargin: Core.Theme.spacing.xs
        anchors.left: parent.left
        width: Math.max(parent.width, 180)
        height: modelList.height + Core.Theme.spacing.sm * 2
        radius: Core.Theme.radius.sm
        color: Core.Theme.bgOverlay
        border.color: Core.Theme.glassBorder
        border.width: 1
        z: 100

        ColumnLayout {
            id: modelList
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: Core.Theme.spacing.sm
            anchors.top: parent.top
            anchors.topMargin: Core.Theme.spacing.sm
            spacing: Core.Theme.spacing.xs

            Repeater {
                model: AiServices.Ollama.availableModels

                Rectangle {
                    required property var modelData
                    Layout.fillWidth: true
                    height: 28
                    radius: Core.Theme.radius.sm
                    color: itemMa.containsMouse ? Core.Theme.glass2 : "transparent"

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.margins: Core.Theme.spacing.xs
                        text: modelData.name
                        font.family: Core.Theme.fontMono
                        font.pixelSize: Core.Theme.fontSize.xs
                        color: modelData.name === AiServices.Ollama.model
                            ? Core.Theme.accent : Core.Theme.fgMain
                    }

                    MouseArea {
                        id: itemMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            AiServices.Ollama.model = modelData.name
                            root.expanded = false
                        }
                    }
                }
            }

            // Empty state
            Text {
                visible: AiServices.Ollama.availableModels.length === 0
                text: "No models found"
                font.family: Core.Theme.fontUI
                font.pixelSize: Core.Theme.fontSize.xs
                color: Core.Theme.fgMuted
            }
        }
    }
}

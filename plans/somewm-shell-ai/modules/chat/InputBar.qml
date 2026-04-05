import QtQuick
import QtQuick.Layouts
import "../../../somewm-shell/core" as Core
import "../../../somewm-shell/components" as Components
import "../../services" as AiServices

RowLayout {
    id: root
    spacing: Core.Theme.spacing.sm

    Rectangle {
        Layout.fillWidth: true
        height: Math.min(inputField.contentHeight + Core.Theme.spacing.md * 2, 120)
        radius: Core.Theme.radius.md
        color: Core.Theme.glass2
        border.color: inputField.activeFocus ? Core.Theme.accent : Core.Theme.glassBorder
        border.width: 1

        Behavior on border.color { Components.CAnim {} }

        Flickable {
            anchors.fill: parent
            anchors.margins: Core.Theme.spacing.md
            contentHeight: inputField.contentHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            TextEdit {
                id: inputField
                width: parent.width
                color: Core.Theme.fgMain
                font.family: Core.Theme.fontUI
                font.pixelSize: Core.Theme.fontSize.base
                wrapMode: TextEdit.Wrap
                selectByMouse: true
                selectionColor: Core.Theme.accent

                // Placeholder
                Text {
                    anchors.fill: parent
                    text: "Type a message..."
                    font: inputField.font
                    color: Core.Theme.fgMuted
                    visible: !inputField.text && !inputField.activeFocus
                }

                // Send on Enter (Shift+Enter for newline)
                Keys.onReturnPressed: (event) => {
                    if (event.modifiers & Qt.ShiftModifier) {
                        event.accepted = false  // allow newline
                    } else {
                        root.send()
                        event.accepted = true
                    }
                }
            }
        }
    }

    // Send button
    Rectangle {
        Layout.preferredWidth: 40
        Layout.preferredHeight: 40
        radius: 20
        color: inputField.text.trim() && !AiServices.Ollama.generating
            ? Core.Theme.accent : Core.Theme.glass2

        Behavior on color { Components.CAnim {} }

        Components.MaterialIcon {
            anchors.centerIn: parent
            icon: AiServices.Ollama.generating ? "\ue047" : "\ue163"  // stop / send
            size: Core.Theme.fontSize.xl
            color: inputField.text.trim() || AiServices.Ollama.generating
                ? Core.Theme.bgBase : Core.Theme.fgMuted
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                if (AiServices.Ollama.generating)
                    AiServices.Ollama.cancel()
                else
                    root.send()
            }
        }
    }

    function send() {
        var msg = inputField.text.trim()
        if (!msg || AiServices.Ollama.generating) return
        AiServices.Ollama.send(msg)
        inputField.text = ""
    }
}

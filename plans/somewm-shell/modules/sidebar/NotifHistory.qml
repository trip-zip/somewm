import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../../core" as Core
import "../../components" as Components

Item {
    id: root

    property var notifications: []
    property int expandedIndex: -1

    // Fetch notifications from compositor via IPC.
    // Uses _somewm_notif_history if available, else falls back to naughty.active.
    function refresh() {
        fetchProc.running = true
    }

    function clearAll() {
        clearProc.running = true
    }

    function dismissOne(idx) {
        dismissProc.command = ["somewm-client", "eval",
            "if _somewm_notif_history then table.remove(_somewm_notif_history, " + (idx + 1) + ") end; return 'ok'"]
        dismissProc.running = true
    }

    function copyToClipboard(title, message) {
        var content = title
        if (message) content += "\\n" + message
        copyProc.command = ["sh", "-c", "printf '%s' '" + content.replace(/'/g, "'\\''") + "' | wl-copy"]
        copyProc.running = true
    }

    Process {
        id: fetchProc
        command: ["somewm-client", "eval",
            "local n = require('naughty'); " +
            "local function esc(s) return s:gsub('\\\\','\\\\\\\\'):gsub('\"','\\\\\"'):gsub('\\n','\\\\n'):gsub('\\t','\\\\t'):gsub('\\r','') end " +
            "local json='[' local sep='' " +
            "local all = {} " +
            "if _somewm_notif_history and #_somewm_notif_history > 0 then " +
            "for _,v in ipairs(_somewm_notif_history) do all[#all+1]=v end " +
            "else " +
            "for _,v in ipairs(n.active or {}) do all[#all+1]=v end " +
            "end " +
            "for i=#all,1,-1 do local v=all[i] " +
            "json=json..sep..'{\"title\":\"'..esc(v.title or '')..'\",\"message\":\"'..esc(v.message or '')..'\",\"app\":\"'..esc(v.app_name or '')..'\"}'  " +
            "sep=',' end " +
            "return json..']'"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    // somewm-client eval returns "OK\n<value>" — strip prefix
                    var raw = text.trim()
                    var nl = raw.indexOf("\n")
                    var jsonStr = nl >= 0 ? raw.substring(nl + 1) : raw
                    var data = JSON.parse(jsonStr)
                    root.notifications = data || []
                } catch (e) {
                    console.error("NotifHistory parse error:", e)
                    root.notifications = []
                }
            }
        }
    }

    Process {
        id: clearProc
        command: ["somewm-client", "eval",
            "_somewm_notif_history = {}; " +
            "for _,n in ipairs(require('naughty').active or {}) do n:destroy() end; return 'ok'"]
        onRunningChanged: {
            if (!running) {
                root.notifications = []
                root.expandedIndex = -1
            }
        }
    }

    Process {
        id: dismissProc
        onRunningChanged: {
            if (!running) root.refresh()
        }
    }

    Process { id: copyProc }

    // IPC: refresh when new notifications arrive
    IpcHandler {
        target: "somewm-shell:notifications"
        function refresh(): void { root.refresh() }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: Core.Theme.spacing.sm

        // Header
        RowLayout {
            Layout.fillWidth: true

            Components.StyledText {
                text: "Notifications"
                font.pixelSize: Core.Theme.fontSize.base
                font.weight: Font.DemiBold
                color: Core.Theme.fgDim
                Layout.fillWidth: true
            }

            // Notification count badge
            Text {
                visible: root.notifications.length > 0
                text: root.notifications.length
                font.family: Core.Theme.fontMono
                font.pixelSize: Core.Theme.fontSize.xs
                color: Core.Theme.accent
            }

            // Clear all button
            Components.MaterialIcon {
                visible: root.notifications.length > 0
                icon: "\ue872"  // delete_sweep
                size: Core.Theme.fontSize.lg
                color: hovered ? Core.Theme.urgent : Core.Theme.fgMuted
                property bool hovered: false

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    hoverEnabled: true
                    onEntered: parent.hovered = true
                    onExited: parent.hovered = false
                    onClicked: root.clearAll()
                }
            }

            Components.MaterialIcon {
                icon: "\ue863"  // refresh
                size: Core.Theme.fontSize.lg
                color: Core.Theme.fgMuted
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.refresh()
                }
            }
        }

        // Notification list
        Flickable {
            id: flickable
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentHeight: notifColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            ColumnLayout {
                id: notifColumn
                width: flickable.width
                spacing: Core.Theme.spacing.xs

                Repeater {
                    model: root.notifications

                    Components.GlassCard {
                        id: notifCard
                        Layout.fillWidth: true
                        Layout.preferredHeight: notifContent.implicitHeight + Core.Theme.spacing.md * 2

                        required property var modelData
                        required property int index

                        property bool isExpanded: root.expandedIndex === index
                        property bool isHovered: false

                        // Subtle hover highlight
                        border.color: isHovered ? Core.Theme.glassBorder : "transparent"
                        border.width: isHovered ? 1 : 0

                        Behavior on border.color { ColorAnimation { duration: 150 } }

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onEntered: notifCard.isHovered = true
                            onExited: notifCard.isHovered = false
                            onClicked: {
                                root.expandedIndex = notifCard.isExpanded ? -1 : notifCard.index
                            }
                        }

                        ColumnLayout {
                            id: notifContent
                            anchors.fill: parent
                            anchors.margins: Core.Theme.spacing.md
                            spacing: Core.Theme.spacing.xs

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Core.Theme.spacing.xs

                                Components.MaterialIcon {
                                    icon: "\ue7f4"  // notifications
                                    size: Core.Theme.fontSize.base
                                    color: Core.Theme.accent
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: modelData.title
                                    font.family: Core.Theme.fontUI
                                    font.pixelSize: Core.Theme.fontSize.sm
                                    font.weight: Font.DemiBold
                                    color: Core.Theme.fgMain
                                    elide: Text.ElideRight
                                }

                                Text {
                                    visible: modelData.app !== ""
                                    text: modelData.app
                                    font.family: Core.Theme.fontUI
                                    font.pixelSize: Core.Theme.fontSize.xs
                                    color: Core.Theme.fgMuted
                                }

                                // Action buttons (visible on hover)
                                Row {
                                    visible: notifCard.isHovered
                                    spacing: Core.Theme.spacing.xs

                                    // Copy to clipboard
                                    Components.MaterialIcon {
                                        icon: "\ue14d"  // content_copy
                                        size: Core.Theme.fontSize.sm
                                        color: copyMa.containsMouse ? Core.Theme.accent : Core.Theme.fgMuted
                                        MouseArea {
                                            id: copyMa
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.copyToClipboard(modelData.title, modelData.message)
                                        }
                                    }

                                    // Dismiss
                                    Components.MaterialIcon {
                                        icon: "\ue5cd"  // close
                                        size: Core.Theme.fontSize.sm
                                        color: dismissMa.containsMouse ? Core.Theme.urgent : Core.Theme.fgMuted
                                        MouseArea {
                                            id: dismissMa
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.dismissOne(notifCard.index)
                                        }
                                    }
                                }
                            }

                            // Message (collapsed: 2 lines, expanded: full)
                            Text {
                                visible: modelData.message !== ""
                                Layout.fillWidth: true
                                text: modelData.message
                                font.family: Core.Theme.fontUI
                                font.pixelSize: Core.Theme.fontSize.sm
                                color: Core.Theme.fgDim
                                wrapMode: Text.WordWrap
                                maximumLineCount: notifCard.isExpanded ? 999 : 2
                                elide: notifCard.isExpanded ? Text.ElideNone : Text.ElideRight
                            }

                            // Expand hint
                            Text {
                                visible: !notifCard.isExpanded && modelData.message.length > 80
                                text: "Click to expand..."
                                font.family: Core.Theme.fontUI
                                font.pixelSize: Core.Theme.fontSize.xs
                                font.italic: true
                                color: Core.Theme.fgMuted
                            }
                        }
                    }
                }

                // Empty state
                Text {
                    visible: root.notifications.length === 0
                    Layout.fillWidth: true
                    Layout.topMargin: Core.Theme.spacing.lg
                    horizontalAlignment: Text.AlignHCenter
                    text: "No notifications"
                    font.family: Core.Theme.fontUI
                    font.pixelSize: Core.Theme.fontSize.sm
                    color: Core.Theme.fgMuted
                }
            }
        }
    }

    Component.onCompleted: refresh()
}

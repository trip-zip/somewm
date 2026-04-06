import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import "../../core" as Core
import "../../services" as Services
import "../../components" as Components

Item {
    id: root
    implicitHeight: settingsColumn.implicitHeight

    ColumnLayout {
        id: settingsColumn
        anchors.fill: parent
        spacing: Core.Theme.spacing.md

        // Volume slider
        RowLayout {
            Layout.fillWidth: true
            spacing: Core.Theme.spacing.sm

            Components.MaterialIcon {
                icon: Services.Audio.icon
                size: Core.Theme.fontSize.xl
                color: Services.Audio.muted ? Core.Theme.fgMuted : Core.Theme.accent

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Services.Audio.toggleMute()
                }
            }

            // Volume bar with thumb
            Item {
                Layout.fillWidth: true
                height: Core.Theme.slider.thumbSize

                // Track
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    height: Core.Theme.slider.trackHeight
                    radius: Core.Theme.slider.trackRadius
                    color: Core.Theme.slider.trackColor

                    // Filled portion
                    Rectangle {
                        width: parent.width * Math.min(1.0, Services.Audio.volume)
                        height: parent.height
                        radius: parent.radius
                        color: Services.Audio.muted ? Core.Theme.fgMuted : Core.Theme.accent

                        Behavior on width { Components.Anim {} }
                        Behavior on color { Components.CAnim {} }
                    }
                }

                // Thumb circle
                Rectangle {
                    x: parent.width * Math.min(1.0, Services.Audio.volume) - width / 2
                    anchors.verticalCenter: parent.verticalCenter
                    width: Core.Theme.slider.thumbSize
                    height: Core.Theme.slider.thumbSize
                    radius: Core.Theme.slider.thumbRadius
                    color: Services.Audio.muted ? Core.Theme.fgMuted : Core.Theme.accent
                    border.color: Qt.rgba(1, 1, 1, 0.1)
                    border.width: 1
                    visible: !Services.Audio.muted

                    Behavior on x { Components.Anim {} }
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: (mouse) => {
                        Services.Audio.setVolume(Math.max(0, Math.min(1, mouse.x / parent.width)))
                    }
                    onPositionChanged: (mouse) => {
                        if (pressed)
                            Services.Audio.setVolume(Math.max(0, Math.min(1, mouse.x / parent.width)))
                    }
                }
            }

            Components.StyledText {
                text: Services.Audio.volumePercent + "%"
                font.family: Core.Theme.fontMono
                font.pixelSize: Core.Theme.fontSize.sm
                color: Core.Theme.fgDim
                Layout.preferredWidth: Math.round(40 * Core.Theme.dpiScale)
                horizontalAlignment: Text.AlignRight
            }
        }

        // Brightness slider
        RowLayout {
            Layout.fillWidth: true
            spacing: Core.Theme.spacing.sm

            Components.MaterialIcon {
                icon: "\ue518"  // brightness_medium
                size: Core.Theme.fontSize.xl
                color: Core.Theme.widgetDisk
            }

            // Brightness bar with thumb
            Item {
                Layout.fillWidth: true
                height: Core.Theme.slider.thumbSize

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    height: Core.Theme.slider.trackHeight
                    radius: Core.Theme.slider.trackRadius
                    color: Core.Theme.slider.trackColor

                    Rectangle {
                        width: parent.width * (Services.Brightness.percent / 100.0)
                        height: parent.height
                        radius: parent.radius
                        color: Core.Theme.widgetDisk

                        Behavior on width { Components.Anim {} }
                    }
                }

                Rectangle {
                    x: parent.width * (Services.Brightness.percent / 100.0) - width / 2
                    anchors.verticalCenter: parent.verticalCenter
                    width: Core.Theme.slider.thumbSize
                    height: Core.Theme.slider.thumbSize
                    radius: Core.Theme.slider.thumbRadius
                    color: Core.Theme.widgetDisk
                    border.color: Qt.rgba(1, 1, 1, 0.1)
                    border.width: 1

                    Behavior on x { Components.Anim {} }
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: (mouse) => {
                        Services.Brightness.setPercent(Math.round(Math.max(0, Math.min(1, mouse.x / parent.width)) * 100))
                    }
                    onPositionChanged: (mouse) => {
                        if (pressed)
                            Services.Brightness.setPercent(Math.round(Math.max(0, Math.min(1, mouse.x / parent.width)) * 100))
                    }
                }
            }

            Components.StyledText {
                text: Services.Brightness.percent + "%"
                font.family: Core.Theme.fontMono
                font.pixelSize: Core.Theme.fontSize.sm
                color: Core.Theme.fgDim
                Layout.preferredWidth: Math.round(40 * Core.Theme.dpiScale)
                horizontalAlignment: Text.AlignRight
            }
        }

        // Toggle buttons row
        RowLayout {
            Layout.fillWidth: true
            spacing: Core.Theme.spacing.sm

            // WiFi toggle
            Components.ClickableCard {
                Layout.fillWidth: true
                Layout.preferredHeight: Math.round(52 * Core.Theme.dpiScale)
                active: Services.Network.wifiEnabled

                onClicked: Services.Network.toggleWifi()

                RowLayout {
                    anchors.centerIn: parent
                    spacing: Core.Theme.spacing.xs

                    Components.MaterialIcon {
                        icon: Services.Network.wifiEnabled ? "\ue63e" : "\ue648"  // wifi / wifi_off
                        size: Core.Theme.fontSize.lg
                        color: Services.Network.wifiEnabled ? Core.Theme.widgetNetwork : Core.Theme.fgMuted
                    }
                    Components.StyledText {
                        text: "WiFi"
                        font.pixelSize: Core.Theme.fontSize.sm
                        font.weight: Services.Network.wifiEnabled ? Font.DemiBold : Font.Normal
                    }
                }
            }

            // Bluetooth toggle
            Components.ClickableCard {
                id: btCard
                Layout.fillWidth: true
                Layout.preferredHeight: Math.round(52 * Core.Theme.dpiScale)
                property bool btOn: true
                active: btOn

                onClicked: {
                    btCard.btOn = !btCard.btOn
                    btToggleProc.command = ["bluetoothctl", "power", btCard.btOn ? "on" : "off"]
                    btToggleProc.running = true
                }

                RowLayout {
                    anchors.centerIn: parent
                    spacing: Core.Theme.spacing.xs

                    Components.MaterialIcon {
                        icon: btCard.btOn ? "\ue1a7" : "\ue1a8"  // bluetooth / bluetooth_disabled
                        size: Core.Theme.fontSize.lg
                        color: btCard.btOn ? Core.Theme.accent : Core.Theme.fgMuted
                    }
                    Components.StyledText {
                        text: "BT"
                        font.pixelSize: Core.Theme.fontSize.sm
                        font.weight: btCard.btOn ? Font.DemiBold : Font.Normal
                    }
                }
            }

            // DND toggle
            Components.ClickableCard {
                id: dndCard
                Layout.fillWidth: true
                Layout.preferredHeight: Math.round(52 * Core.Theme.dpiScale)
                property bool dndActive: false
                active: dndActive
                tintColor: Core.Theme.urgent

                onClicked: {
                    if (!dndInitialized) return
                    dndCard.dndActive = !dndCard.dndActive
                    dndProc.command = ["somewm-client", "eval",
                        "require('naughty').suspended = " + dndCard.dndActive]
                    dndProc.running = true
                }

                RowLayout {
                    anchors.centerIn: parent
                    spacing: Core.Theme.spacing.xs

                    Components.MaterialIcon {
                        icon: dndCard.dndActive ? "\ue7f5" : "\ue7f4"  // notifications_off / notifications
                        size: Core.Theme.fontSize.lg
                        color: dndCard.dndActive ? Core.Theme.urgent : Core.Theme.fgDim
                    }
                    Components.StyledText {
                        text: "DND"
                        font.pixelSize: Core.Theme.fontSize.sm
                        font.weight: dndCard.dndActive ? Font.DemiBold : Font.Normal
                    }
                }
            }
        }
    }

    // Helper processes for toggles
    Process { id: btToggleProc }
    Process { id: dndProc }

    property bool dndInitialized: false

    // Initialize BT state from system
    Process {
        id: btInitProc
        command: ["bluetoothctl", "show"]
        stdout: StdioCollector {
            onStreamFinished: {
                btCard.btOn = text.indexOf("Powered: yes") >= 0
            }
        }
    }

    // Initialize DND state from system
    Process {
        id: dndInitProc
        command: ["somewm-client", "eval", "return tostring(require('naughty').suspended)"]
        stdout: StdioCollector {
            onStreamFinished: {
                // somewm-client eval returns "OK\n<value>" — strip prefix
                var raw = text.trim()
                var nl = raw.indexOf("\n")
                var val = nl >= 0 ? raw.substring(nl + 1) : raw
                dndCard.dndActive = val === "true"
                root.dndInitialized = true
            }
        }
    }

    Component.onCompleted: {
        btInitProc.running = true
        dndInitProc.running = true
    }
}

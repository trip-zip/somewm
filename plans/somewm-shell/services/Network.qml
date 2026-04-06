pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    // Public properties
    property bool wifiEnabled: false
    property bool wifiConnected: false
    property string wifiSsid: ""
    property int wifiSignal: 0        // 0-100
    property bool ethernetConnected: false
    property bool vpnConnected: false
    property string ipAddress: ""

    // Derived
    readonly property string icon: {
        if (!wifiEnabled) return "\ue648"              // wifi_off
        if (!wifiConnected) return "\ue648"            // wifi_off
        if (wifiSignal > 75) return "\ue1d8"           // signal_wifi_4_bar
        if (wifiSignal > 50) return "\uebd5"           // network_wifi_3_bar
        if (wifiSignal > 25) return "\uebd4"           // network_wifi_2_bar
        return "\uebd3"                                 // network_wifi_1_bar
    }

    readonly property string statusText: {
        if (ethernetConnected) return "Ethernet"
        if (wifiConnected) return wifiSsid
        return "Disconnected"
    }

    Timer {
        interval: 5000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    function refresh() {
        wifiProc.running = true
    }

    // nmcli: get wifi status
    Process {
        id: wifiProc
        command: ["nmcli", "-t", "-f", "TYPE,STATE,CONNECTION,DEVICE", "connection", "show", "--active"]
        stdout: StdioCollector {
            onStreamFinished: {
                var lines = text.trim().split("\n")
                root.wifiConnected = false
                root.ethernetConnected = false
                root.vpnConnected = false
                root.wifiSsid = ""

                lines.forEach(function(line) {
                    // nmcli -t escapes literal colons as \: in values
                    var safe = line.replace(/\\:/g, "\x00")
                    var parts = safe.split(":")
                    if (parts.length < 3) return
                    var type = parts[0]
                    var state = parts[1]
                    var name = parts.slice(2, -1).join(":").replace(/\x00/g, ":")

                    if (type === "802-11-wireless" && state === "activated") {
                        root.wifiConnected = true
                        root.wifiSsid = name
                    } else if (type === "802-3-ethernet" && state === "activated") {
                        root.ethernetConnected = true
                    } else if (type === "vpn" && state === "activated") {
                        root.vpnConnected = true
                    }
                })

                // Get signal strength if connected
                if (root.wifiConnected) signalProc.running = true

                // Check wifi radio state
                radioProc.running = true
            }
        }
    }

    // Get wifi signal strength
    Process {
        id: signalProc
        command: ["nmcli", "-t", "-f", "IN-USE,SIGNAL", "device", "wifi", "list", "--rescan", "no"]
        stdout: StdioCollector {
            onStreamFinished: {
                var lines = text.trim().split("\n")
                // Find the connected AP (marked with *)
                for (var i = 0; i < lines.length; i++) {
                    if (lines[i].indexOf("*") === 0) {
                        var parts = lines[i].split(":")
                        root.wifiSignal = parseInt(parts[1]) || 0
                        return
                    }
                }
                // Fallback: first line
                if (lines.length > 0) {
                    var fallback = lines[0].split(":")
                    root.wifiSignal = parseInt(fallback[fallback.length - 1]) || 0
                }
            }
        }
    }

    // Check wifi radio enabled
    Process {
        id: radioProc
        command: ["nmcli", "radio", "wifi"]
        stdout: StdioCollector {
            onStreamFinished: {
                root.wifiEnabled = text.trim() === "enabled"
            }
        }
    }

    // Toggle wifi
    function toggleWifi() {
        var action = wifiEnabled ? "off" : "on"
        toggleProc.command = ["nmcli", "radio", "wifi", action]
        toggleProc.running = true
    }

    Process {
        id: toggleProc
        onRunningChanged: {
            if (!running) root.refresh()
        }
    }
}

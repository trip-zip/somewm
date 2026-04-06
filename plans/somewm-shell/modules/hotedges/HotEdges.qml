import QtQuick
import Quickshell
import Quickshell.Wayland
import "../../core" as Core
import "../../services" as Services

/**
 * HotEdges -- invisible hover zones along the bottom screen edge.
 *
 * Three zones are created on the focused screen only:
 *
 *   [ Left corner |    Center strip    | Right corner ]
 *   [   -> Dock   |   -> Dashboard     | -> Control   ]
 *
 * The center zone is declared first so it sits at the bottom of the
 * layer stack; the two corner zones overlay it and take priority.
 * Each zone toggles its panel after a short hover delay.
 */
Scope {
    id: root
    readonly property real sp: Core.Theme.dpiScale
    readonly property real cornerW: Math.round(140 * sp)
    readonly property real zoneH: Math.round(6 * sp)

    // Center strip -> Dashboard (declared first = bottom of layer stack)
    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: centerZone

            required property var modelData
            screen: modelData

            readonly property bool isActiveScreen:
                modelData.name === Services.Compositor.focusedScreenName ||
                String(modelData.index) === Services.Compositor.focusedScreenName

            color: "transparent"
            visible: isActiveScreen

            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "somewm-shell:hotedge-center"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            WlrLayershell.exclusionMode: ExclusionMode.Ignore

            anchors { bottom: true; left: true; right: true }
            margins.bottom: -1
            implicitHeight: root.zoneH

            mask: Region { item: centerArea }

            MouseArea {
                id: centerArea
                anchors.fill: parent
                anchors.leftMargin: root.cornerW
                anchors.rightMargin: root.cornerW
                hoverEnabled: true
                onEntered: {
                    if (!Core.Panels.isOpen("dashboard"))
                        centerTimer.restart()
                }
                onExited: centerTimer.stop()
            }

            Timer {
                id: centerTimer
                interval: 300
                onTriggered: Core.Panels.toggle("dashboard")
            }
        }
    }

    // Left corner -> Dock
    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: leftZone

            required property var modelData
            screen: modelData

            readonly property bool isActiveScreen:
                modelData.name === Services.Compositor.focusedScreenName ||
                String(modelData.index) === Services.Compositor.focusedScreenName

            color: "transparent"
            visible: isActiveScreen

            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "somewm-shell:hotedge-left"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            WlrLayershell.exclusionMode: ExclusionMode.Ignore

            anchors { bottom: true; left: true }
            margins.bottom: -1
            implicitWidth: root.cornerW
            implicitHeight: root.zoneH

            mask: Region { item: leftArea }

            MouseArea {
                id: leftArea
                anchors.fill: parent
                hoverEnabled: true
                onEntered: {
                    if (!Core.Panels.isOpen("dock"))
                        leftTimer.restart()
                }
                onExited: leftTimer.stop()
            }

            Timer {
                id: leftTimer
                interval: 250
                onTriggered: Core.Panels.toggle("dock")
            }
        }
    }

    // Right corner -> Control Panel
    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: rightZone

            required property var modelData
            screen: modelData

            readonly property bool isActiveScreen:
                modelData.name === Services.Compositor.focusedScreenName ||
                String(modelData.index) === Services.Compositor.focusedScreenName

            color: "transparent"
            visible: isActiveScreen

            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "somewm-shell:hotedge-right"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            WlrLayershell.exclusionMode: ExclusionMode.Ignore

            anchors { bottom: true; right: true }
            margins.bottom: -1
            implicitWidth: root.cornerW
            implicitHeight: root.zoneH

            mask: Region { item: rightArea }

            MouseArea {
                id: rightArea
                anchors.fill: parent
                hoverEnabled: true
                onEntered: {
                    if (!Core.Panels.isOpen("controlpanel"))
                        rightTimer.restart()
                }
                onExited: rightTimer.stop()
            }

            Timer {
                id: rightTimer
                interval: 250
                onTriggered: Core.Panels.toggle("controlpanel")
            }
        }
    }
}

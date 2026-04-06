import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import "../../core" as Core
import "../../services" as Services
import "../../components" as Components

Variants {
    model: Quickshell.screens

    Components.SlidePanel {
        id: panel

        required property var modelData
        screen: modelData

        edge: "right"
        panelWidth: Math.round(420 * Core.Theme.dpiScale)

        shown: Core.Panels.isOpen("sidebar") &&
            (modelData.name === Services.Compositor.focusedScreenName ||
             String(modelData.index) === Services.Compositor.focusedScreenName)

        // Sidebar content
        ColumnLayout {
            anchors.fill: parent
            spacing: Core.Theme.spacing.lg

            // Header
            RowLayout {
                Layout.fillWidth: true
                spacing: Core.Theme.spacing.sm

                Components.SectionHeader {
                    title: "Quick Settings"
                    Layout.fillWidth: true
                }

                Components.MaterialIcon {
                    icon: "\ue5cd"  // close
                    size: Core.Theme.fontSize.xl
                    color: Core.Theme.fgDim

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Core.Panels.close("sidebar")
                    }
                }
            }

            QuickSettings {
                Layout.fillWidth: true
            }

            Components.Separator { Layout.fillWidth: true }

            CalendarWidget {
                Layout.fillWidth: true
                Layout.preferredHeight: Math.round(260 * Core.Theme.dpiScale)
            }

            Components.Separator { Layout.fillWidth: true }

            NotifHistory {
                Layout.fillWidth: true
                Layout.fillHeight: true
            }
        }
    }
}

import QtQuick
import QtQuick.Layouts
import "../../core" as Core
import "../../services" as Services
import "../../components" as Components

Item {
    id: root

    RowLayout {
        anchors.fill: parent
        spacing: Core.Theme.spacing.md

        // CPU ring
        Components.GlassCard {
            Layout.fillWidth: true
            Layout.fillHeight: true

            ColumnLayout {
                anchors.centerIn: parent
                spacing: Core.Theme.spacing.sm

                Components.CircularProgress {
                    Layout.alignment: Qt.AlignHCenter
                    value: Services.SystemStats.cpuPercent / 100.0
                    lineWidth: Math.round(5 * Core.Theme.dpiScale)
                    progressColor: Core.Theme.widgetCpu
                    trackColor: Core.Theme.fade(Core.Theme.widgetCpu, 0.15)
                    implicitWidth: Math.round(56 * Core.Theme.dpiScale)
                    implicitHeight: Math.round(56 * Core.Theme.dpiScale)

                    Text {
                        anchors.centerIn: parent
                        text: Services.SystemStats.cpuPercent + "%"
                        font.family: Core.Theme.fontMono
                        font.pixelSize: Core.Theme.fontSize.sm
                        font.weight: Font.Bold
                        color: Core.Theme.widgetCpu
                    }
                }

                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: "CPU"
                    font.family: Core.Theme.fontUI
                    font.pixelSize: Core.Theme.fontSize.sm
                    color: Core.Theme.fgDim
                }
            }
        }

        // Memory ring
        Components.GlassCard {
            Layout.fillWidth: true
            Layout.fillHeight: true

            ColumnLayout {
                anchors.centerIn: parent
                spacing: Core.Theme.spacing.sm

                Components.CircularProgress {
                    Layout.alignment: Qt.AlignHCenter
                    value: Services.SystemStats.memPercent / 100.0
                    lineWidth: Math.round(5 * Core.Theme.dpiScale)
                    progressColor: Core.Theme.widgetMemory
                    trackColor: Core.Theme.fade(Core.Theme.widgetMemory, 0.15)
                    implicitWidth: Math.round(56 * Core.Theme.dpiScale)
                    implicitHeight: Math.round(56 * Core.Theme.dpiScale)

                    Text {
                        anchors.centerIn: parent
                        text: Services.SystemStats.memPercent + "%"
                        font.family: Core.Theme.fontMono
                        font.pixelSize: Core.Theme.fontSize.sm
                        font.weight: Font.Bold
                        color: Core.Theme.widgetMemory
                    }
                }

                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: Services.SystemStats.memUsedGB.toFixed(1) + " / " +
                          Services.SystemStats.memTotalGB.toFixed(1) + " GB"
                    font.family: Core.Theme.fontUI
                    font.pixelSize: Core.Theme.fontSize.xs
                    color: Core.Theme.fgDim
                }
            }
        }
    }
}

import QtQuick
import QtQuick.Layouts
import "../../core" as Core
import "../../services" as Services
import "../../components" as Components

Item {
    id: root

    RowLayout {
        anchors.fill: parent
        spacing: Core.Theme.spacing.sm

        Repeater {
            model: Services.Weather.forecast

            Components.GlassCard {
                Layout.fillWidth: true
                Layout.fillHeight: true

                ColumnLayout {
                    anchors.centerIn: parent
                    spacing: Core.Theme.spacing.xs

                    // Day name
                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: {
                            var parts = modelData.date.split("-")
                            var d = new Date(parseInt(parts[0]), parseInt(parts[1]) - 1, parseInt(parts[2]))
                            return Qt.formatDate(d, "ddd")
                        }
                        font.family: Core.Theme.fontUI
                        font.pixelSize: Core.Theme.fontSize.xs
                        font.weight: Font.DemiBold
                        color: Core.Theme.fgDim
                    }

                    // Weather icon
                    Components.MaterialIcon {
                        Layout.alignment: Qt.AlignHCenter
                        icon: modelData.icon
                        size: Core.Theme.fontSize.xxl
                        color: Core.Theme.accent
                    }

                    // Max temp
                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: modelData.tempMaxC + "\u00b0"
                        font.family: Core.Theme.fontMono
                        font.pixelSize: Core.Theme.fontSize.base
                        font.weight: Font.Bold
                        color: Core.Theme.fgMain
                    }

                    // Min temp
                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: modelData.tempMinC + "\u00b0"
                        font.family: Core.Theme.fontMono
                        font.pixelSize: Core.Theme.fontSize.sm
                        color: Core.Theme.fgMuted
                    }
                }
            }
        }
    }
}

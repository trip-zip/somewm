import QtQuick
import QtQuick.Layouts
import "../../core" as Core
import "../../services" as Services
import "../../components" as Components

Item {
    id: root
    implicitHeight: content.implicitHeight

    ColumnLayout {
        id: content
        anchors.fill: parent
        spacing: Core.Theme.spacing.md

        // Location
        Text {
            text: Services.Weather.location
            font.family: Core.Theme.fontUI
            font.pixelSize: Core.Theme.fontSize.sm
            color: Core.Theme.fgDim
        }

        // Main display: icon + temperature
        RowLayout {
            Layout.fillWidth: true
            spacing: Core.Theme.spacing.lg

            // Weather icon
            Components.MaterialIcon {
                icon: Services.Weather.conditionIcon
                size: 56
                color: Core.Theme.accent
            }

            // Temperature
            ColumnLayout {
                spacing: 0

                Text {
                    text: Services.Weather.tempC + "\u00b0C"
                    font.family: Core.Theme.fontMono
                    font.pixelSize: 42
                    font.weight: Font.Light
                    color: Core.Theme.fgMain
                }

                Text {
                    text: Services.Weather.condition
                    font.family: Core.Theme.fontUI
                    font.pixelSize: Core.Theme.fontSize.sm
                    color: Core.Theme.fgDim
                }
            }
        }

        // Details row
        RowLayout {
            Layout.fillWidth: true
            spacing: Core.Theme.spacing.lg

            // Feels like
            RowLayout {
                spacing: Core.Theme.spacing.xs
                Components.MaterialIcon {
                    icon: "\uf07d"  // thermostat
                    size: Core.Theme.fontSize.base
                    color: Core.Theme.fgMuted
                }
                Text {
                    text: "Feels " + Services.Weather.feelsLikeC + "\u00b0"
                    font.family: Core.Theme.fontUI
                    font.pixelSize: Core.Theme.fontSize.sm
                    color: Core.Theme.fgDim
                }
            }

            // Humidity
            RowLayout {
                spacing: Core.Theme.spacing.xs
                Components.MaterialIcon {
                    icon: "\ue798"  // water_drop
                    size: Core.Theme.fontSize.base
                    color: Core.Theme.fgMuted
                }
                Text {
                    text: Services.Weather.humidity + "%"
                    font.family: Core.Theme.fontUI
                    font.pixelSize: Core.Theme.fontSize.sm
                    color: Core.Theme.fgDim
                }
            }

            // Wind
            RowLayout {
                spacing: Core.Theme.spacing.xs
                Components.MaterialIcon {
                    icon: "\uf1cd"  // air
                    size: Core.Theme.fontSize.base
                    color: Core.Theme.fgMuted
                }
                Text {
                    text: Services.Weather.windKmh + " km/h " + Services.Weather.windDir
                    font.family: Core.Theme.fontUI
                    font.pixelSize: Core.Theme.fontSize.sm
                    color: Core.Theme.fgDim
                }
            }
        }
    }
}

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import "../../core" as Core
import "../../services" as Services
import "../../components" as Components

Variants {
    model: Quickshell.screens

    PanelWindow {
        id: panel

        required property var modelData
        screen: modelData

        property bool shouldShow: Core.Panels.isOpen("weather") &&
            (modelData.name === Services.Compositor.focusedScreenName ||
             String(modelData.index) === Services.Compositor.focusedScreenName)

        visible: shouldShow || fadeAnim.running

        color: "transparent"
        focusable: shouldShow

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "somewm-shell:weather"
        WlrLayershell.keyboardFocus: shouldShow ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        anchors {
            top: true; right: true
        }
        margins.top: 50
        margins.right: 20

        implicitWidth: 360
        implicitHeight: 400

        mask: Region { item: weatherCard }

        Components.GlassCard {
            id: weatherCard
            anchors.fill: parent
            focus: panel.shouldShow
            Keys.onEscapePressed: Core.Panels.close("weather")

            opacity: panel.shouldShow ? 1.0 : 0.0
            scale: panel.shouldShow ? 1.0 : 0.95

            Behavior on opacity {
                NumberAnimation {
                    id: fadeAnim
                    duration: Core.Anims.duration.normal
                    easing.type: Core.Anims.ease.decel
                }
            }
            Behavior on scale { Components.Anim {} }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Core.Theme.spacing.lg
                spacing: Core.Theme.spacing.lg

                // Header
                RowLayout {
                    Layout.fillWidth: true

                    Components.StyledText {
                        text: "Weather"
                        font.pixelSize: Core.Theme.fontSize.lg
                        font.weight: Font.DemiBold
                        Layout.fillWidth: true
                    }

                    Components.MaterialIcon {
                        icon: "\ue863"  // refresh
                        size: Core.Theme.fontSize.lg
                        color: Core.Theme.fgDim
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: Services.Weather.forceRefresh()
                        }
                    }

                    Components.MaterialIcon {
                        icon: "\ue5cd"  // close
                        size: Core.Theme.fontSize.lg
                        color: Core.Theme.fgDim
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: Core.Panels.close("weather")
                        }
                    }
                }

                // Current weather
                CurrentWeather {
                    Layout.fillWidth: true
                    visible: Services.Weather.hasData
                }

                // Loading state
                Text {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: Services.Weather.loading ? "Loading..." :
                          Services.Weather.error ? "Error: " + Services.Weather.error : ""
                    font.family: Core.Theme.fontUI
                    font.pixelSize: Core.Theme.fontSize.sm
                    color: Core.Theme.fgMuted
                    visible: !Services.Weather.hasData
                }

                // Separator
                Rectangle {
                    Layout.fillWidth: true
                    height: 1
                    color: Core.Theme.glassBorder
                    visible: Services.Weather.hasData
                }

                // Forecast
                Forecast {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: Services.Weather.hasData
                }
            }
        }

    }
}

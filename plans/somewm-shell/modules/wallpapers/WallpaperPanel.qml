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

        property bool shouldShow: Core.Panels.isOpen("wallpapers") &&
            (modelData.name === Services.Compositor.focusedScreenName ||
             String(modelData.index) === Services.Compositor.focusedScreenName)

        visible: shouldShow || fadeAnim.running

        color: "transparent"
        focusable: shouldShow

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "somewm-shell:wallpapers"
        WlrLayershell.keyboardFocus: shouldShow ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        anchors {
            top: true; bottom: true; left: true; right: true
        }

        mask: Region { item: backdrop }

        Rectangle {
            id: backdrop
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, 0.5)
            opacity: panel.shouldShow ? 1.0 : 0.0
            focus: panel.shouldShow
            Keys.onEscapePressed: Core.Panels.close("wallpapers")

            Behavior on opacity {
                NumberAnimation {
                    id: fadeAnim
                    duration: Core.Anims.duration.normal
                    easing.type: Core.Anims.ease.standard
                }
            }

            MouseArea {
                anchors.fill: parent
                onClicked: Core.Panels.close("wallpapers")
                onWheel: (wheel) => { wheel.accepted = true }
            }

            // Main content card
            Components.GlassCard {
                id: mainCard
                anchors.centerIn: parent
                width: Math.min(parent.width - 60, Math.round(1200 * Core.Theme.dpiScale))
                height: Math.min(parent.height - 60, Math.round(780 * Core.Theme.dpiScale))

                opacity: panel.shouldShow ? 1.0 : 0.0
                scale: panel.shouldShow ? 1.0 : 0.95

                Behavior on opacity { Components.Anim {} }
                Behavior on scale { Components.Anim {} }

                MouseArea {
                    anchors.fill: parent
                    onWheel: (wheel) => { wheel.accepted = true }
                }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: Core.Theme.spacing.xl
                    spacing: Core.Theme.spacing.lg

                    // Header row
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Core.Theme.spacing.md

                        Components.StyledText {
                            text: "Wallpapers"
                            font.pixelSize: Core.Theme.fontSize.xl
                            font.weight: Font.DemiBold
                            Layout.fillWidth: true
                        }

                        Text {
                            text: Services.Wallpapers.wallpapers.length + " images"
                            font.family: Core.Theme.fontUI
                            font.pixelSize: Core.Theme.fontSize.sm
                            color: Core.Theme.fgMuted
                        }

                        // Apply Theme toggle
                        Components.ClickableCard {
                            Layout.preferredWidth: applyThemeRow.implicitWidth + Core.Theme.spacing.md * 2
                            Layout.preferredHeight: Math.round(32 * Core.Theme.dpiScale)
                            color: Services.Wallpapers.applyTheme ? Qt.rgba(
                                Core.Theme.accentR, Core.Theme.accentG, Core.Theme.accentB, 0.15
                            ) : Core.Theme.glass2
                            radius: Core.Theme.radius.sm
                            border.width: Services.Wallpapers.applyTheme ? 1 : 0
                            border.color: Core.Theme.accent

                            onClicked: Services.Wallpapers.setApplyTheme(!Services.Wallpapers.applyTheme)

                            RowLayout {
                                id: applyThemeRow
                                anchors.centerIn: parent
                                spacing: Core.Theme.spacing.xs

                                Components.MaterialIcon {
                                    icon: Services.Wallpapers.applyTheme ? "\ue3ab" : "\ue3ac"  // palette / palette_off
                                    size: Core.Theme.fontSize.base
                                    color: Services.Wallpapers.applyTheme ? Core.Theme.accent : Core.Theme.fgDim
                                }

                                Text {
                                    text: "Apply Theme"
                                    font.family: Core.Theme.fontUI
                                    font.pixelSize: Core.Theme.fontSize.xs
                                    font.weight: Font.Medium
                                    color: Services.Wallpapers.applyTheme ? Core.Theme.accent : Core.Theme.fgDim
                                }
                            }
                        }

                        // View toggle: carousel vs grid
                        Components.ClickableCard {
                            Layout.preferredWidth: Math.round(32 * Core.Theme.dpiScale)
                            Layout.preferredHeight: Math.round(32 * Core.Theme.dpiScale)
                            color: Core.Theme.glass2
                            radius: Core.Theme.radius.sm

                            onClicked: viewStack.currentIndex = viewStack.currentIndex === 0 ? 1 : 0

                            Components.MaterialIcon {
                                anchors.centerIn: parent
                                icon: viewStack.currentIndex === 0 ? "\ue8f0" : "\ue871"  // view_carousel / view_module
                                size: Core.Theme.fontSize.base
                                color: Core.Theme.fgDim
                            }
                        }

                        Components.MaterialIcon {
                            icon: "\ue863"  // refresh
                            size: Core.Theme.fontSize.lg
                            color: Core.Theme.fgDim
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: Services.Wallpapers.refresh()
                            }
                        }

                        Components.MaterialIcon {
                            icon: "\ue5cd"  // close
                            size: Core.Theme.fontSize.lg
                            color: Core.Theme.fgDim
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: Core.Panels.close("wallpapers")
                            }
                        }
                    }

                    // Content: carousel or grid view
                    StackLayout {
                        id: viewStack
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        currentIndex: 0  // 0 = carousel, 1 = grid

                        // Carousel view
                        Item {
                            Layout.fillWidth: true
                            Layout.fillHeight: true

                            ColumnLayout {
                                anchors.fill: parent
                                spacing: Core.Theme.spacing.lg

                                // Carousel in center
                                Components.WallpaperCarousel {
                                    id: wpCarousel
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    wallpapers: Services.Wallpapers.wallpapers

                                    onWallpaperApplied: (path) => {
                                        Services.Wallpapers.setWallpaper(path)
                                    }
                                }

                                // Action bar below carousel
                                RowLayout {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: Math.round(44 * Core.Theme.dpiScale)
                                    spacing: Core.Theme.spacing.md

                                    // Selected wallpaper info
                                    Text {
                                        Layout.fillWidth: true
                                        text: wpCarousel.selectedPath
                                            ? wpCarousel.selectedPath.split("/").pop()
                                            : "Select a wallpaper"
                                        font.family: Core.Theme.fontUI
                                        font.pixelSize: Core.Theme.fontSize.sm
                                        color: Core.Theme.fgDim
                                        elide: Text.ElideMiddle
                                    }

                                    // Current indicator
                                    Rectangle {
                                        visible: wpCarousel.selectedPath === Services.Wallpapers.currentWallpaper
                                        width: currentLabel.implicitWidth + Core.Theme.spacing.sm * 2
                                        height: Math.round(24 * Core.Theme.dpiScale)
                                        radius: Core.Theme.radius.sm
                                        color: Qt.rgba(Core.Theme.accentR, Core.Theme.accentG, Core.Theme.accentB, 0.15)

                                        Text {
                                            id: currentLabel
                                            anchors.centerIn: parent
                                            text: "Current"
                                            font.family: Core.Theme.fontUI
                                            font.pixelSize: Core.Theme.fontSize.xs
                                            color: Core.Theme.accent
                                        }
                                    }

                                    // Apply button
                                    Components.ClickableCard {
                                        Layout.preferredWidth: applyRow.implicitWidth + Core.Theme.spacing.lg * 2
                                        Layout.preferredHeight: Math.round(36 * Core.Theme.dpiScale)
                                        color: Core.Theme.accent
                                        radius: Core.Theme.radius.md
                                        enabled: wpCarousel.selectedPath !== ""

                                        onClicked: Services.Wallpapers.setWallpaper(wpCarousel.selectedPath)

                                        RowLayout {
                                            id: applyRow
                                            anchors.centerIn: parent
                                            spacing: Core.Theme.spacing.xs

                                            Components.MaterialIcon {
                                                icon: "\ue876"  // check
                                                size: Core.Theme.fontSize.base
                                                color: Core.Theme.surfaceBase
                                            }

                                            Text {
                                                text: "Apply"
                                                font.family: Core.Theme.fontUI
                                                font.pixelSize: Core.Theme.fontSize.sm
                                                font.weight: Font.DemiBold
                                                color: Core.Theme.surfaceBase
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // Grid view (fallback — original layout)
                        WallpaperGrid {
                            id: wpGrid
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            onPreviewRequested: (path) => wpPreview.previewPath = path
                        }
                    }
                }
            }

            // Preview overlay (works in both views)
            Preview {
                id: wpPreview
                anchors.fill: parent
            }
        }

    }
}

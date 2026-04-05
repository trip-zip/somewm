import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import "../../core" as Core
import "../../services" as Services

// Quick control panel — bottom-right corner, same border strip pattern as Dashboard
// Strip slides up → content grows from right corner
// Horizontal layout: Volume | Mic | Brightness
Variants {
    model: Quickshell.screens

    PanelWindow {
        id: panel

        required property var modelData
        screen: modelData

        property bool shouldShow: Core.Panels.isOpen("controlpanel") &&
            (modelData.name === Services.Compositor.focusedScreenName ||
             String(modelData.index) === Services.Compositor.focusedScreenName)

        color: "transparent"
        focusable: shouldShow

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "somewm-shell:controlpanel"
        WlrLayershell.keyboardFocus: shouldShow
            ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        WlrLayershell.exclusionMode: ExclusionMode.Ignore

        anchors {
            top: true; bottom: true; left: true; right: true
        }

        mask: Region { item: clickTarget }

        readonly property real sp: Core.Theme.dpiScale
        readonly property real borderThickness: Math.round(12 * sp)
        readonly property real borderRounding: Math.round(25 * sp)
        readonly property real padLg: Math.round(15 * sp)
        readonly property real padNorm: Math.round(10 * sp)
        readonly property color borderColor: Core.Theme.surfaceBase

        // Auto-close when mouse leaves (for hover-triggered mode)
        property bool hoverMode: Core.Panels.isOpen("dashboard")

        Timer {
            id: autoCloseTimer
            interval: 400
            onTriggered: {
                if (panel.hoverMode && !contentHover.containsMouse)
                    Core.Panels.close("controlpanel")
            }
        }

        // === Sequenced animation (same as Dashboard) ===
        property bool stripVisible: false
        property bool contentVisible: false

        visible: shouldShow || stripVisible || contentVisible || stripAnim.running || contentAnim.running

        onShouldShowChanged: {
            if (shouldShow) {
                closeAnim.stop()
                openAnim.start()
            } else {
                openAnim.stop()
                closeAnim.start()
            }
        }

        SequentialAnimation {
            id: openAnim
            PropertyAction { target: panel; property: "stripVisible"; value: true }
            PauseAnimation { duration: 350 }
            PropertyAction { target: panel; property: "contentVisible"; value: true }
        }

        SequentialAnimation {
            id: closeAnim
            PropertyAction { target: panel; property: "contentVisible"; value: false }
            PauseAnimation { duration: 750 }
            PropertyAction { target: panel; property: "stripVisible"; value: false }
        }

        // Content sizing
        readonly property real contentWidth: sliderRow.implicitWidth + padLg * 2
        readonly property real contentHeight: sliderRow.implicitHeight + padLg * 2

        // === Click target (mask) ===
        Item {
            id: clickTarget
            anchors.fill: parent

            // Border strip hit area
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: panel.borderThickness
                color: "transparent"
                visible: panel.stripVisible
            }

            // Content wrapper hit area + hover tracking
            Rectangle {
                visible: wrapper.height > 0
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.bottomMargin: panel.borderThickness
                width: wrapper.width + Math.round(20 * panel.sp)
                height: wrapper.height + Math.round(20 * panel.sp)
                color: "transparent"

                MouseArea {
                    id: contentHover
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: {}
                    onWheel: (wheel) => { wheel.accepted = true }
                    onExited: {
                        if (panel.hoverMode) autoCloseTimer.restart()
                    }
                    onEntered: autoCloseTimer.stop()
                }
            }

            // Dismiss area
            MouseArea {
                anchors.fill: parent
                visible: panel.shouldShow
                z: -1
                onClicked: Core.Panels.close("controlpanel")
                onWheel: (wheel) => { wheel.accepted = true }
            }
        }

        // ===== Visual layer: Strip + ShapePath background with shadow =====
        Item {
            anchors.fill: parent
            layer.enabled: true
            layer.effect: MultiEffect {
                shadowEnabled: true
                blurMax: 15
                shadowColor: Qt.rgba(0, 0, 0, 0.55)
            }

            // Border strip at bottom edge (full width, same as dashboard)
            Rectangle {
                id: borderStrip
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: panel.stripVisible ? panel.borderThickness : 0
                color: panel.borderColor

                Behavior on height {
                    NumberAnimation {
                        id: stripAnim
                        duration: 350
                        easing.type: Easing.BezierSpline
                        easing.bezierCurve: Core.Anims.curves.expressiveSpatial
                    }
                }
            }

            // ShapePath background — grows from right corner
            Shape {
                id: bgShape
                anchors.fill: parent
                anchors.bottomMargin: panel.borderThickness
                preferredRendererType: Shape.CurveRenderer

                ShapePath {
                    id: cpBg

                    readonly property real rounding: panel.borderRounding
                    readonly property bool flatten: wrapper.height < rounding * 2
                    readonly property real roundingY: flatten ? wrapper.height / 2 : rounding
                    readonly property real ww: wrapper.width
                    readonly property real wh: wrapper.height

                    strokeWidth: -1
                    fillColor: panel.borderColor

                    // Start: bottom-right corner of screen (where strip meets right edge)
                    startX: bgShape.width
                    startY: bgShape.height

                    // Go up along right edge
                    PathLine {
                        relativeX: 0
                        relativeY: -cpBg.wh
                    }

                    // Top-right corner (outward curve — content meets strip)
                    PathArc {
                        relativeX: -cpBg.rounding
                        relativeY: -cpBg.roundingY
                        radiusX: cpBg.rounding
                        radiusY: Math.min(cpBg.rounding, cpBg.wh)
                        direction: PathArc.Counterclockwise
                    }

                    // Across top (right to left)
                    PathLine {
                        relativeX: -(cpBg.ww - cpBg.rounding * 2)
                        relativeY: 0
                    }

                    // Top-left corner (outward curve)
                    PathArc {
                        relativeX: -cpBg.rounding
                        relativeY: cpBg.roundingY
                        radiusX: cpBg.rounding
                        radiusY: Math.min(cpBg.rounding, cpBg.wh)
                        direction: PathArc.Counterclockwise
                    }

                    // Down left side
                    PathLine {
                        relativeX: 0
                        relativeY: cpBg.wh - cpBg.roundingY
                    }

                    // Bottom-left arc back to strip
                    PathArc {
                        relativeX: -cpBg.rounding
                        relativeY: cpBg.roundingY
                        radiusX: cpBg.rounding
                        radiusY: Math.min(cpBg.rounding, cpBg.wh)
                    }

                    // Back along strip to right edge
                    PathLine {
                        x: bgShape.width
                        y: bgShape.height
                    }
                }
            }
        }

        // ===== Content wrapper — right-aligned =====
        Item {
            id: wrapper

            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.bottomMargin: panel.borderThickness

            width: panel.contentWidth
            height: panel.contentVisible ? panel.contentHeight : 0

            visible: height > 0.5
            clip: true

            Behavior on width {
                NumberAnimation {
                    duration: 700
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: Core.Anims.curves.emphasized
                }
            }
            Behavior on height {
                NumberAnimation {
                    id: contentAnim
                    duration: 700
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: panel.contentVisible
                        ? Core.Anims.curves.expressiveSpatial
                        : Core.Anims.curves.emphasized
                }
            }

            // Horizontal slider layout
            RowLayout {
                id: sliderRow
                anchors.fill: parent
                anchors.margins: panel.padLg
                spacing: Math.round(20 * panel.sp)

                // Volume
                ControlSlider {
                    label: "Volume"
                    icon: Services.Audio.icon
                    sliderValue: Services.Audio.volume
                    percent: Services.Audio.volumePercent
                    isMuted: Services.Audio.muted
                    accentColor: Core.Theme.accent
                    onSliderMoved: (v) => Services.Audio.setVolume(v)
                    onMuteToggled: Services.Audio.toggleMute()
                }

                // Separator
                Rectangle {
                    Layout.preferredWidth: 1
                    Layout.fillHeight: true
                    Layout.topMargin: Math.round(8 * panel.sp)
                    Layout.bottomMargin: Math.round(8 * panel.sp)
                    color: Qt.rgba(Core.Theme.fgMuted.r, Core.Theme.fgMuted.g, Core.Theme.fgMuted.b, 0.2)
                }

                // Mic Input
                ControlSlider {
                    label: "Mic"
                    icon: Services.Audio.inputIcon
                    sliderValue: Services.Audio.inputVolume
                    percent: Services.Audio.inputVolumePercent
                    isMuted: Services.Audio.inputMuted
                    accentColor: Core.Theme.widgetCpu
                    onSliderMoved: (v) => Services.Audio.setInputVolume(v)
                    onMuteToggled: Services.Audio.toggleInputMute()
                }

                // Separator
                Rectangle {
                    Layout.preferredWidth: 1
                    Layout.fillHeight: true
                    Layout.topMargin: Math.round(8 * panel.sp)
                    Layout.bottomMargin: Math.round(8 * panel.sp)
                    color: Qt.rgba(Core.Theme.fgMuted.r, Core.Theme.fgMuted.g, Core.Theme.fgMuted.b, 0.2)
                }

                // Brightness
                ControlSlider {
                    label: "Bright"
                    icon: "\ue518"  // brightness_medium
                    sliderValue: Services.Brightness.percent / 100.0
                    percent: Services.Brightness.percent
                    isMuted: false
                    accentColor: Core.Theme.widgetDisk
                    onSliderMoved: (v) => Services.Brightness.setPercent(Math.round(v * 100))
                    onMuteToggled: {}
                }
            }

            Keys.onEscapePressed: Core.Panels.close("controlpanel")
        }
    }

    // === Inline component: vertical slider column (label, icon, vertical track, %) ===
    component ControlSlider: ColumnLayout {
        property string label
        property string icon
        property real sliderValue: 0
        property int percent: 0
        property bool isMuted: false
        property color accentColor: Core.Theme.accent

        signal sliderMoved(real v)
        signal muteToggled()

        readonly property real sp: Core.Theme.dpiScale

        Layout.preferredWidth: Math.round(64 * sp)
        spacing: Math.round(6 * sp)

        // Label
        Text {
            Layout.alignment: Qt.AlignHCenter
            text: parent.label
            font.family: Core.Theme.fontUI
            font.pixelSize: Math.round(10 * sp)
            font.weight: Font.DemiBold
            color: Core.Theme.fgDim
        }

        // Icon (clickable for mute)
        Text {
            Layout.alignment: Qt.AlignHCenter
            text: parent.icon
            font.family: Core.Theme.fontIcon
            font.pixelSize: Math.round(20 * sp)
            color: parent.isMuted ? Core.Theme.fgMuted : parent.accentColor

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: parent.parent.muteToggled()
            }
        }

        // Vertical slider track
        Item {
            id: sliderTrack
            Layout.fillHeight: true
            Layout.preferredWidth: Math.round(32 * sp)
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredHeight: Math.round(120 * sp)

            property bool dragging: sliderDragArea.pressed

            // Track background
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.round(4 * sp)
                height: parent.height
                radius: 1000
                color: Core.Theme.fade(parent.parent.accentColor, 0.15)

                // Filled portion (from bottom)
                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: parent.height * Math.min(1.0, parent.parent.parent.sliderValue)
                    radius: parent.radius
                    color: parent.parent.parent.isMuted ? Core.Theme.fgMuted : parent.parent.parent.accentColor

                    Behavior on height {
                        enabled: !sliderTrack.dragging
                        NumberAnimation { duration: Core.Anims.duration.fast }
                    }
                }
            }

            // Thumb
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                y: parent.height * (1.0 - Math.min(1.0, parent.parent.sliderValue)) - width / 2
                width: Math.round(14 * sp)
                height: width
                radius: width / 2
                color: parent.parent.isMuted ? Core.Theme.fgMuted : parent.parent.accentColor
                border.color: Qt.rgba(1, 1, 1, 0.1)
                border.width: 1
                visible: !parent.parent.isMuted

                Behavior on y {
                    enabled: !sliderTrack.dragging
                    NumberAnimation { duration: Core.Anims.duration.fast }
                }
            }

            // Click/drag area
            MouseArea {
                id: sliderDragArea
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: (mouse) => {
                    var val = 1.0 - Math.max(0, Math.min(1, mouse.y / parent.height))
                    parent.parent.sliderMoved(val)
                }
                onPositionChanged: (mouse) => {
                    if (pressed) {
                        var val = 1.0 - Math.max(0, Math.min(1, mouse.y / parent.height))
                        parent.parent.sliderMoved(val)
                    }
                }
            }
        }

        // Percentage
        Text {
            Layout.alignment: Qt.AlignHCenter
            text: parent.percent + "%"
            font.family: Core.Theme.fontMono
            font.pixelSize: Math.round(10 * sp)
            color: Core.Theme.fgDim
        }
    }
}

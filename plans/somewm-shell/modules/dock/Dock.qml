import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import "../../core" as Core
import "../../services" as Services

// Advanced app dock — bottom-left corner
// Features: pinned favorites, multi-instance preview with live thumbnails,
// zoom+glow hover, right-click pin/unpin, separator between pinned/running
Variants {
    model: Quickshell.screens

    PanelWindow {
        id: panel

        required property var modelData
        screen: modelData

        property bool shouldShow: Core.Panels.isOpen("dock") &&
            (modelData.name === Services.Compositor.focusedScreenName ||
             String(modelData.index) === Services.Compositor.focusedScreenName)

        color: "transparent"
        focusable: shouldShow

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "somewm-shell:dock"
        WlrLayershell.keyboardFocus: shouldShow
            ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        WlrLayershell.exclusionMode: ExclusionMode.Ignore

        anchors {
            top: true; bottom: true; left: true; right: true
        }

        mask: Region { item: clickTarget }

        readonly property real sp: Core.Theme.dpiScale
        readonly property real borderThickness: Math.round(12 * sp)
        readonly property real borderRounding: Math.round(16 * sp)
        readonly property real padLg: Math.round(15 * sp)
        readonly property real padNorm: Math.round(10 * sp)
        readonly property color borderColor: Core.Theme.surfaceBase

        // Auto-close when mouse leaves (for hover-triggered mode)
        property bool hoverMode: Core.Panels.isOpen("dashboard")

        // True when mouse is in the preview popup area
        readonly property bool previewAreaHovered: previewPopupHover.hovered

        Timer {
            id: autoCloseTimer
            interval: 400
            onTriggered: {
                if (panel.hoverMode && !contentHover.containsMouse && !wrapperHover.hovered
                    && !panel.previewAreaHovered)
                    Core.Panels.close("dock")
            }
        }

        // === Sequenced animation (same as Dashboard/ControlPanel) ===
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
                panel.previewAppId = ""
                panel.tooltipText = ""
                panel.tooltipX = 0
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
        readonly property real buttonSize: Math.round(48 * sp)
        readonly property real buttonSpacing: Math.round(8 * sp)
        readonly property real dotAreaHeight: Math.round(14 * sp)
        readonly property real contentHeight: buttonSize + dotAreaHeight + padLg * 2
        readonly property real contentWidth: Math.max(
            Math.round(80 * sp),
            Services.DockApps.itemCount * (buttonSize + buttonSpacing) - buttonSpacing + padLg * 2
        )

        // Preview state — which app's windows to show (by appId)
        property string previewAppId: ""
        property var previewToplevels: {
            void Services.DockApps.modelVersion
            return previewAppId.length > 0
                ? Services.DockApps.getToplevels(previewAppId) : []
        }
        property real previewAnchorX: 0

        // Tooltip state — rendered at panel level (outside clipped wrapper)
        property string tooltipText: ""
        property real tooltipX: 0
        property real tooltipY: 0
        property bool tooltipVisible: tooltipText.length > 0

        // === Click target (mask) ===
        // Everything interactive MUST be inside clickTarget — it defines the
        // Wayland input region via `mask: Region { item: clickTarget }`.
        // Preview popup is a child here so it naturally gets hover/click events.
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

            // Content wrapper hover padding (extends mask slightly beyond wrapper)
            Rectangle {
                id: contentHoverPad
                visible: wrapper.height > 0
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                width: wrapper.width + Math.round(20 * panel.sp)
                height: wrapper.height + panel.borderThickness + Math.round(20 * panel.sp)
                color: "transparent"

                MouseArea {
                    id: contentHover
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.NoButton
                    onExited: {
                        if (panel.hoverMode) autoCloseTimer.restart()
                    }
                    onEntered: autoCloseTimer.stop()
                }
            }

            // Tooltip hit area
            Rectangle {
                visible: tooltipOverlay.visible
                x: tooltipOverlay.x - Math.round(4 * panel.sp)
                y: tooltipOverlay.y - Math.round(4 * panel.sp)
                width: tooltipOverlay.width + Math.round(8 * panel.sp)
                height: tooltipOverlay.height + Math.round(8 * panel.sp)
                color: "transparent"
            }

            // ===== Content wrapper — inside clickTarget for unified z-order =====
            Item {
                id: wrapper

                anchors.left: parent.left
                anchors.bottom: parent.bottom
                anchors.bottomMargin: panel.borderThickness

                width: panel.contentWidth
                height: panel.contentVisible ? panel.contentHeight : 0

                visible: height > 0.5
                clip: true

                HoverHandler {
                    id: wrapperHover
                    onHoveredChanged: {
                        if (hovered) {
                            autoCloseTimer.stop()
                        } else if (panel.hoverMode) {
                            autoCloseTimer.restart()
                        }
                    }
                }

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

                // App icons row
                Row {
                    id: appRow
                    anchors.fill: parent
                    anchors.margins: panel.padLg
                    spacing: panel.buttonSpacing

                    Repeater {
                        model: Services.DockApps.dockItems

                        Item {
                            required property string appId
                            required property string icon
                            required property bool isPinned
                            required property bool isRunning
                            required property bool isActive
                            required property bool isSeparator
                            required property int toplevelCount
                            required property int index

                            height: panel.buttonSize + panel.dotAreaHeight
                            width: isSeparator ? sep.width : appBtn.width

                            DockSeparator {
                                id: sep
                                sp: panel.sp
                                visible: parent.isSeparator
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            DockAppButton {
                                id: appBtn
                                visible: !parent.isSeparator
                                appId: parent.appId
                                appIcon: parent.icon
                                appIsPinned: parent.isPinned
                                appIsRunning: parent.isRunning
                                appIsActive: parent.isActive
                                appToplevelCount: parent.toplevelCount
                                buttonSize: panel.buttonSize
                                dotAreaHeight: panel.dotAreaHeight
                                sp: panel.sp
                                height: panel.buttonSize + panel.dotAreaHeight
                            }
                        }
                    }
                }

                focus: true
                Keys.onEscapePressed: {
                    panel.previewAppId = ""
                    Core.Panels.close("dock")
                }
            }

            // ===== Preview popup — z:200 so it's ABOVE wrapper for hover priority =====
            // Visibility is PERMISSIVE: stays visible (in the mask) while mouse is
            // anywhere in the padded area. This prevents the Wayland mask from toggling
            // and causing a hover flicker loop. Visual content fades via opacity instead.
            Item {
                id: previewPopup
                z: 200

                readonly property bool shouldBeVisible: panel.previewAppId.length > 0
                    && panel.previewToplevels.length > 1

                // Keep mask alive while: content should show, OR close timer pending,
                // OR mouse is physically in the area (prevents mask toggle → flicker)
                visible: shouldBeVisible || previewCloseTimer.running || previewPopupHover.hovered

                x: Math.max(Math.round(4 * panel.sp), Math.min(
                    panel.previewAnchorX - width / 2,
                    panel.width - width - Math.round(20 * panel.sp)
                ))
                y: panel.height - panel.borderThickness - wrapper.height - height - Math.round(2 * panel.sp)
                width: previewContent.width + Math.round(40 * panel.sp)
                height: previewContent.height + Math.round(40 * panel.sp)

                // HoverHandler doesn't compete with child MouseAreas (unlike MouseArea)
                HoverHandler {
                    id: previewPopupHover
                    onHoveredChanged: {
                        if (hovered) {
                            previewCloseTimer.stop()
                        } else {
                            previewCloseTimer.restart()
                        }
                    }
                }

                // Glass background (centered in padded Item)
                Rectangle {
                    id: previewContent
                    anchors.centerIn: parent
                    width: previewRow.implicitWidth + Math.round(16 * panel.sp)
                    height: previewRow.implicitHeight + Math.round(16 * panel.sp)
                    radius: Math.round(14 * panel.sp)
                    color: Core.Theme.glass1
                    border.color: Core.Theme.glassBorder
                    border.width: 1

                    scale: previewPopup.shouldBeVisible ? 1.0 : 0.9
                    opacity: previewPopup.shouldBeVisible ? 1.0 : 0.0

                    Behavior on scale {
                        NumberAnimation {
                            duration: Core.Anims.duration.normal
                            easing.type: Easing.OutBack
                            easing.overshoot: 1.1
                        }
                    }
                    Behavior on opacity {
                        NumberAnimation {
                            duration: Core.Anims.duration.fast
                            easing.type: Easing.BezierSpline
                            easing.bezierCurve: Core.Anims.curves.expressiveEffects
                        }
                    }

                    layer.enabled: true
                    layer.effect: MultiEffect {
                        shadowEnabled: true
                        blurMax: 12
                        shadowColor: Qt.rgba(0, 0, 0, 0.45)
                    }

                    Row {
                        id: previewRow
                        anchors.centerIn: parent
                        spacing: Math.round(8 * panel.sp)

                        Repeater {
                            model: panel.previewToplevels

                            PreviewCard {
                                required property var modelData
                                required property int index
                                toplevel: modelData
                                appIcon: Services.DockApps.resolveIcon(
                                    panel.previewAppId)
                                sp: panel.sp
                                onActivated: {
                                    modelData.activate()
                                    panel.previewAppId = ""
                                    Core.Panels.close("dock")
                                }
                                onClosed: modelData.close()
                            }
                        }
                    }
                }
            }

            // Dismiss area (lowest z — behind everything)
            MouseArea {
                anchors.fill: parent
                visible: panel.shouldShow
                z: -1
                onClicked: {
                    panel.previewAppId = ""
                    Core.Panels.close("dock")
                }
                onWheel: (wheel) => { wheel.accepted = true }
            }
        }

        Timer {
            id: previewCloseTimer
            interval: 400
            onTriggered: {
                // Only close if mouse is NOT on the preview popup
                if (!previewPopupHover.hovered)
                    panel.previewAppId = ""
                // else: mouse is interacting with preview, keep it open.
                // When they leave, onHoveredChanged will restart this timer.
            }
        }

        // ===== Visual layer: Strip + ShapePath background with shadow =====
        // z:-1 so it renders BEHIND clickTarget (which now contains the wrapper)
        Item {
            z: -1
            anchors.fill: parent
            layer.enabled: true
            layer.effect: MultiEffect {
                shadowEnabled: true
                blurMax: 15
                shadowColor: Qt.rgba(0, 0, 0, 0.55)
            }

            // Border strip at bottom edge (full width)
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

            // ShapePath background — grows from LEFT corner
            Shape {
                id: bgShape
                anchors.fill: parent
                anchors.bottomMargin: panel.borderThickness
                preferredRendererType: Shape.CurveRenderer

                ShapePath {
                    id: dockBg

                    readonly property real rounding: panel.borderRounding
                    readonly property bool flatten: wrapper.height < rounding * 2
                    readonly property real roundingY: flatten ? wrapper.height / 2 : rounding
                    readonly property real ww: wrapper.width
                    readonly property real wh: wrapper.height

                    strokeWidth: -1
                    fillColor: panel.borderColor

                    startX: 0
                    startY: bgShape.height

                    PathLine {
                        relativeX: 0
                        relativeY: -dockBg.wh
                    }
                    PathArc {
                        relativeX: dockBg.rounding
                        relativeY: -dockBg.roundingY
                        radiusX: dockBg.rounding
                        radiusY: Math.min(dockBg.rounding, dockBg.wh)
                        direction: PathArc.Clockwise
                    }
                    PathLine {
                        relativeX: Math.max(0, dockBg.ww - dockBg.rounding * 2)
                        relativeY: 0
                    }
                    PathArc {
                        relativeX: dockBg.rounding
                        relativeY: dockBg.roundingY
                        radiusX: dockBg.rounding
                        radiusY: Math.min(dockBg.rounding, dockBg.wh)
                        direction: PathArc.Clockwise
                    }
                    PathLine {
                        relativeX: 0
                        relativeY: dockBg.wh - dockBg.roundingY
                    }
                    PathArc {
                        relativeX: dockBg.rounding
                        relativeY: dockBg.roundingY
                        radiusX: dockBg.rounding
                        radiusY: Math.min(dockBg.rounding, dockBg.wh)
                        direction: PathArc.Counterclockwise
                    }
                    PathLine {
                        x: 0
                        y: bgShape.height
                    }
                }
            }
        }


        // ===== Tooltip overlay — rendered OUTSIDE clipped wrapper =====
        Rectangle {
            id: tooltipOverlay
            visible: panel.tooltipVisible
            x: panel.tooltipX - width / 2
            y: panel.tooltipY - height - Math.round(8 * panel.sp)
            width: tooltipOverlayText.implicitWidth + Math.round(16 * panel.sp)
            height: tooltipOverlayText.implicitHeight + Math.round(10 * panel.sp)
            radius: Math.round(8 * panel.sp)
            color: Core.Theme.glass1
            border.color: Core.Theme.glassBorder
            border.width: 1
            z: 300

            opacity: panel.tooltipVisible ? 1.0 : 0.0
            Behavior on opacity {
                NumberAnimation { duration: Core.Anims.duration.fast }
            }

            Text {
                id: tooltipOverlayText
                anchors.centerIn: parent
                text: panel.tooltipText
                font.family: Core.Theme.fontUI
                font.pixelSize: Math.round(11 * panel.sp)
                color: Core.Theme.fgMain
                maximumLineCount: 1
                elide: Text.ElideRight
            }
        }

        // Timer for hover-to-preview (slight delay to avoid flicker)
        Timer {
            id: previewHoverTimer
            interval: 150
            property string targetAppId: ""
            property var btnRef: null
            onTriggered: {
                // Don't check btnRef.hovered — scale animation shifts hit area
                // and can falsely report not-hovered during the zoom
                if (targetAppId.length > 0 && btnRef) {
                    var globalPos = btnRef.mapToItem(clickTarget, btnRef.width / 2, 0)
                    panel.previewAnchorX = globalPos.x
                    panel.previewAppId = targetAppId
                }
            }
        }

        onPreviewAppIdChanged: {
            // Force re-evaluation of preview state
            void previewToplevels.length
        }
    } // PanelWindow

    // ═══════════════════════════════════════════════════
    // Inline component: Separator between pinned and running
    // ═══════════════════════════════════════════════════
    component DockSeparator: Item {
        property real sp: 1
        width: Math.round(12 * sp)

        Rectangle {
            anchors.centerIn: parent
            width: Math.round(2 * sp)
            height: Math.round(32 * sp)
            radius: 1000
            color: Qt.rgba(Core.Theme.fgMuted.r, Core.Theme.fgMuted.g, Core.Theme.fgMuted.b, 0.3)
        }
    }

    // ═══════════════════════════════════════════════════
    // Inline component: App button with icon, dots, hover zoom, glow
    // ═══════════════════════════════════════════════════
    component DockAppButton: Item {
        id: btn
        property string appId
        property string appIcon
        property bool appIsPinned: false
        property bool appIsRunning: false
        property bool appIsActive: false
        property int appToplevelCount: 0
        property real buttonSize: 48
        property real dotAreaHeight: 14
        property real sp: 1

        width: buttonSize

        property bool hovered: btnMouse.containsMouse
        property bool pressed: btnMouse.pressed
        property bool hasMultiple: appToplevelCount > 1

        // ── Hover zoom with spring overshoot ──
        scale: pressed ? 0.85 : (hovered ? 1.25 : 1.0)
        Behavior on scale {
            NumberAnimation {
                duration: btn.pressed ? 80 : Core.Anims.duration.normal
                easing.type: btn.pressed ? Easing.OutQuad : Easing.OutBack
                easing.overshoot: 1.6
            }
        }

        // Dim non-running favorites
        opacity: appIsRunning ? 1.0 : 0.55
        Behavior on opacity {
            NumberAnimation { duration: Core.Anims.duration.fast }
        }

        // Update panel-level tooltip on hover change
        onHoveredChanged: {
            if (hovered && !hasMultiple) {
                var globalPos = btn.mapToItem(clickTarget, btn.width / 2, 0)
                panel.tooltipX = globalPos.x
                panel.tooltipY = panel.height - panel.borderThickness - wrapper.height
                if (appIsRunning) {
                    var tls = Services.DockApps.getToplevels(appId)
                    panel.tooltipText = (tls.length > 0 && tls[0].title) ? tls[0].title : appId
                } else {
                    panel.tooltipText = appId
                }
            } else if (!hovered) {
                panel.tooltipText = ""
            }
        }

        // Icon container with glow on hover
        Rectangle {
            id: iconBg
            anchors.top: parent.top
            anchors.horizontalCenter: parent.horizontalCenter
            width: btn.buttonSize
            height: btn.buttonSize
            radius: Math.round(12 * btn.sp)
            color: btn.hovered
                ? (btn.appIsRunning ? Core.Theme.glassAccentHover : Core.Theme.surfaceContainerHigh)
                : "transparent"

            Behavior on color {
                ColorAnimation { duration: Core.Anims.duration.fast }
            }

            // Accent glow behind icon on hover
            Rectangle {
                anchors.fill: parent
                anchors.margins: Math.round(-4 * btn.sp)
                radius: parent.radius + Math.round(4 * btn.sp)
                color: "transparent"
                border.color: btn.hovered && btn.appIsRunning
                    ? Qt.rgba(Core.Theme.accent.r, Core.Theme.accent.g, Core.Theme.accent.b, 0.3)
                    : "transparent"
                border.width: Math.round(2 * btn.sp)
                visible: btn.hovered && btn.appIsRunning

                Behavior on border.color {
                    ColorAnimation { duration: Core.Anims.duration.fast }
                }
            }

            // App icon via IconImage
            IconImage {
                id: iconImg
                anchors.centerIn: parent
                source: Quickshell.iconPath(btn.appIcon || "application-x-executable")
                implicitSize: Math.round(36 * btn.sp)
                visible: status === Image.Ready
            }

            // Fallback: Material icon
            Text {
                anchors.centerIn: parent
                text: "\ue5c3"
                font.family: Core.Theme.fontIcon
                font.pixelSize: Math.round(28 * btn.sp)
                color: btn.appIsRunning ? Core.Theme.fgMain : Core.Theme.fgMuted
                visible: iconImg.status !== Image.Ready
            }
        }

        // ── Activity indicator dots ──
        Row {
            id: dotRow
            anchors.top: iconBg.bottom
            anchors.topMargin: Math.round(3 * btn.sp)
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Math.round(3 * btn.sp)

            // Pinned but not running: single outline dot
            Rectangle {
                visible: btn.appIsPinned && !btn.appIsRunning
                width: Math.round(6 * btn.sp)
                height: Math.round(4 * btn.sp)
                radius: height / 2
                color: "transparent"
                border.color: Core.Theme.fgMuted
                border.width: 1
            }

            // Running: filled dots per instance (max 4)
            Repeater {
                model: btn.appIsRunning ? Math.min(btn.appToplevelCount, 4) : 0
                Rectangle {
                    width: btn.appToplevelCount <= 3
                        ? Math.round(8 * btn.sp) : Math.round(5 * btn.sp)
                    height: Math.round(4 * btn.sp)
                    radius: height / 2
                    color: btn.appIsActive ? Core.Theme.accent : Core.Theme.fgMuted
                }
            }
        }

        // ── Click / hover area ──
        MouseArea {
            id: btnMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

            onClicked: (mouse) => {
                if (mouse.button === Qt.RightButton) {
                    Services.DockApps.togglePin(btn.appId)
                    return
                }
                if (mouse.button === Qt.MiddleButton) {
                    Services.DockApps.launchApp(btn.appId)
                    return
                }
                if (!btn.appIsRunning) {
                    Services.DockApps.launchApp(btn.appId)
                    Core.Panels.close("dock")
                    return
                }
                if (btn.hasMultiple) {
                    var globalPos = btn.mapToItem(clickTarget, btn.width / 2, 0)
                    panel.previewAnchorX = globalPos.x
                    // Store appId for preview — getToplevels will provide live data
                    panel.previewAppId = btn.appId
                } else {
                    Services.DockApps.activateApp(btn.appId)
                    Core.Panels.close("dock")
                }
            }

            onEntered: {
                previewCloseTimer.stop()
                if (btn.hasMultiple) {
                    // Switch preview to this app if different — close old immediately
                    if (panel.previewAppId.length > 0 && panel.previewAppId !== btn.appId) {
                        panel.previewAppId = ""
                    }
                    previewHoverTimer.targetAppId = btn.appId
                    previewHoverTimer.btnRef = btn
                    previewHoverTimer.restart()
                } else if (panel.previewAppId.length > 0) {
                    // Different icon — close preview immediately, no timer delay
                    panel.previewAppId = ""
                }
            }
            onExited: {
                previewHoverTimer.stop()
                // Don't close preview if mouse is already over the preview area
                // (user moved from icon → preview → back toward icon edge)
                if (panel.previewAppId.length > 0 && !panel.previewAreaHovered)
                    previewCloseTimer.restart()
            }
        }
    }

    // ═══════════════════════════════════════════════════
    // Inline component: Window preview card with info + optional live thumbnail
    // NOTE: ScreencopyView toplevel capture requires Hyprland protocol.
    // On wlroots compositors (somewm), shows rich info cards instead.
    // ═══════════════════════════════════════════════════
    component PreviewCard: Item {
        id: card
        property var toplevel
        property string appIcon: ""
        property real sp: 1

        signal activated()
        signal closed()

        readonly property real cardW: Math.round(240 * sp)
        readonly property bool isActivated: toplevel && toplevel.activated

        implicitWidth: cardBg.implicitWidth
        implicitHeight: cardBg.implicitHeight

        Rectangle {
            id: cardBg
            implicitWidth: cardW + Math.round(12 * card.sp)
            implicitHeight: cardCol.implicitHeight + Math.round(12 * card.sp)
            radius: Math.round(12 * card.sp)
            color: cardMouse.containsMouse
                ? Core.Theme.surfaceContainerHigh
                : Core.Theme.surfaceContainer
            border.color: card.isActivated
                ? Core.Theme.accent
                : (cardMouse.containsMouse ? Core.Theme.accentBorder : Core.Theme.glassBorder)
            border.width: card.isActivated ? 2 : 1

            Behavior on color {
                ColorAnimation { duration: Core.Anims.duration.fast }
            }
            Behavior on border.color {
                ColorAnimation { duration: Core.Anims.duration.fast }
            }

            Column {
                id: cardCol
                anchors.centerIn: parent
                width: card.cardW
                spacing: Math.round(6 * card.sp)

                // Header: icon + title + close
                Item {
                    width: parent.width
                    height: Math.round(28 * card.sp)

                    // App icon
                    IconImage {
                        id: cardIcon
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        source: card.appIcon.length > 0
                            ? Quickshell.iconPath(card.appIcon)
                            : ""
                        implicitSize: Math.round(20 * card.sp)
                        visible: status === Image.Ready
                    }

                    // Fallback icon
                    Text {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: "\ue5c3"
                        font.family: Core.Theme.fontIcon
                        font.pixelSize: Math.round(18 * card.sp)
                        color: Core.Theme.fgMuted
                        visible: cardIcon.status !== Image.Ready
                    }

                    // Title
                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: Math.round(26 * card.sp)
                        anchors.right: closeBtn.left
                        anchors.rightMargin: Math.round(4 * card.sp)
                        anchors.verticalCenter: parent.verticalCenter
                        text: card.toplevel
                            ? (card.toplevel.title || card.toplevel.appId || "")
                            : ""
                        font.family: Core.Theme.fontUI
                        font.pixelSize: Math.round(11 * card.sp)
                        font.weight: Font.Medium
                        color: card.isActivated ? Core.Theme.accent : Core.Theme.fgMain
                        elide: Text.ElideRight
                        maximumLineCount: 1
                    }

                    // Close button
                    Rectangle {
                        id: closeBtn
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.round(22 * card.sp)
                        height: width
                        radius: width / 2
                        color: closeMouse.containsMouse ? Core.Theme.urgent : "transparent"

                        Behavior on color {
                            ColorAnimation { duration: 100 }
                        }

                        Text {
                            anchors.centerIn: parent
                            text: "\ue5cd"  // close
                            font.family: Core.Theme.fontIcon
                            font.pixelSize: Math.round(14 * card.sp)
                            color: closeMouse.containsMouse ? "#ffffff" : Core.Theme.fgMuted
                        }

                        MouseArea {
                            id: closeMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: card.closed()
                        }
                    }
                }

                // ScreencopyView (works on Hyprland, graceful fallback elsewhere)
                Item {
                    width: parent.width
                    height: Math.round(130 * card.sp)
                    clip: true
                    visible: screencopy.paintedWidth > 0

                    ScreencopyView {
                        id: screencopy
                        anchors.fill: parent
                        captureSource: card.toplevel
                        live: true
                        paintCursor: false
                        constraintSize: Qt.size(parent.width, parent.height)
                    }

                    // Rounded corners mask
                    layer.enabled: true
                    layer.effect: MultiEffect {
                        maskEnabled: true
                        maskSource: ShaderEffectSource {
                            sourceItem: Rectangle {
                                width: card.cardW
                                height: Math.round(130 * card.sp)
                                radius: Math.round(8 * card.sp)
                            }
                        }
                    }
                }

                // Status row (always visible — primary info when no screencopy)
                Row {
                    width: parent.width
                    spacing: Math.round(8 * card.sp)

                    // Active indicator
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.round(8 * card.sp)
                        height: Math.round(8 * card.sp)
                        radius: width / 2
                        color: card.isActivated ? Core.Theme.accent : Core.Theme.fgMuted
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: card.isActivated ? "Active" : "Click to focus"
                        font.family: Core.Theme.fontUI
                        font.pixelSize: Math.round(10 * card.sp)
                        color: card.isActivated ? Core.Theme.accent : Core.Theme.fgDim
                    }
                }
            }

            MouseArea {
                id: cardMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: card.activated()
            }
        }

        // Entry animation (staggered by index)
        scale: 0.85
        opacity: 0.0
        Component.onCompleted: {
            scale = 1.0
            opacity = 1.0
        }
        Behavior on scale {
            NumberAnimation {
                duration: Core.Anims.duration.normal
                easing.type: Easing.OutBack
                easing.overshoot: 1.2
            }
        }
        Behavior on opacity {
            NumberAnimation { duration: Core.Anims.duration.fast }
        }
    }
} // Variants

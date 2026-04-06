import QtQuick
import QtQuick.Layouts
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Wayland
import "../../core" as Core
import "../../services" as Services
import "../../components" as Components

// Wallpaper Picker — faithful ilyamiro-nixos WallpaperPicker.qml port
// Full-width horizontal ListView carousel with skewed 3D perspective
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
        WlrLayershell.exclusionMode: ExclusionMode.Ignore

        anchors {
            top: true; bottom: true; left: true; right: true
        }

        mask: Region { item: pickerArea }

        // === Constants (ilyamiro-faithful) ===
        readonly property real sp: Core.Theme.dpiScale
        readonly property int itemWidth: 400
        readonly property int itemHeight: 420
        readonly property int borderWidth: 3
        readonly property int itemSpacing: 10
        readonly property real skewFactor: -0.35
        readonly property int pickerHeight: Math.round(650 * sp)

        // === State ===
        property string currentFilter: "All"
        property bool initialFocusSet: false
        property int scrollAccum: 0
        readonly property int scrollThreshold: 300

        // Color filtering (HSV bucketing — ilyamiro pattern)
        readonly property var filterData: [
            { name: "All", hex: "", label: "All" },
            { name: "Red", hex: "#FF4500", label: "" },
            { name: "Orange", hex: "#FFA500", label: "" },
            { name: "Yellow", hex: "#FFD700", label: "" },
            { name: "Green", hex: "#32CD32", label: "" },
            { name: "Blue", hex: "#1E90FF", label: "" },
            { name: "Purple", hex: "#8A2BE2", label: "" },
            { name: "Pink", hex: "#FF69B4", label: "" },
            { name: "Monochrome", hex: "#A9A9A9", label: "" }
        ]

        function getHexBucket(hexStr) {
            if (!hexStr) return "Monochrome"
            hexStr = String(hexStr).trim().replace(/#/g, '')
            if (hexStr.length > 6) hexStr = hexStr.substring(0, 6)
            if (hexStr.length !== 6) return "Monochrome"

            var r = parseInt(hexStr.substring(0,2), 16) / 255
            var g = parseInt(hexStr.substring(2,4), 16) / 255
            var b = parseInt(hexStr.substring(4,6), 16) / 255
            if (isNaN(r) || isNaN(g) || isNaN(b)) return "Monochrome"

            var max = Math.max(r, g, b), min = Math.min(r, g, b)
            var d = max - min
            var h = 0, s = max === 0 ? 0 : d / max

            if (max !== min) {
                if (max === r) h = (g - b) / d + (g < b ? 6 : 0)
                else if (max === g) h = (b - r) / d + 2
                else h = (r - g) / d + 4
                h /= 6
            }
            h = h * 360

            if (s < 0.05 || max < 0.08) return "Monochrome"
            if (h >= 345 || h < 15) return "Red"
            if (h >= 15 && h < 45) return "Orange"
            if (h >= 45 && h < 75) return "Yellow"
            if (h >= 75 && h < 165) return "Green"
            if (h >= 165 && h < 260) return "Blue"
            if (h >= 260 && h < 315) return "Purple"
            if (h >= 315 && h < 345) return "Pink"
            return "Monochrome"
        }

        function matchesFilter(fileName) {
            if (currentFilter === "All") return true
            var hexColor = Services.Wallpapers.colorMap[String(fileName)]
            if (!hexColor) return currentFilter === "Monochrome"
            return getHexBucket(hexColor) === currentFilter
        }

        function stepToNextValid(direction) {
            var model = Services.Wallpapers.wallpapers
            if (!model || model.length === 0) return
            var start = view.currentIndex
            for (var i = start + direction; i >= 0 && i < model.length; i += direction) {
                if (matchesFilter(model[i].name)) {
                    view.currentIndex = i
                    return
                }
            }
        }

        function cycleFilter(direction) {
            var idx = -1
            for (var i = 0; i < filterData.length; i++) {
                if (filterData[i].name === currentFilter) { idx = i; break }
            }
            if (idx !== -1) {
                var next = (idx + direction + filterData.length) % filterData.length
                currentFilter = filterData[next].name
            }
        }

        onCurrentFilterChanged: {
            // Jump to first matching item after filter change
            var model = Services.Wallpapers.wallpapers
            if (!model) return
            for (var i = 0; i < model.length; i++) {
                if (matchesFilter(model[i].name)) {
                    view.currentIndex = i
                    break
                }
            }
        }

        onShouldShowChanged: {
            if (shouldShow) {
                initialFocusSet = false
                view.forceActiveFocus()
                // Focus on current wallpaper
                _focusCurrentWallpaper()
            }
        }

        function _focusCurrentWallpaper() {
            var model = Services.Wallpapers.wallpapers
            if (!model) return
            var current = Services.Wallpapers.currentWallpaper
            for (var i = 0; i < model.length; i++) {
                if (model[i].path === current) {
                    view.currentIndex = i
                    initialFocusSet = true
                    return
                }
            }
            if (model.length > 0) initialFocusSet = true
        }

        Timer {
            id: scrollThrottle
            interval: 150
        }

        // === Keyboard shortcuts (ilyamiro-faithful) ===
        Shortcut { sequence: "Left"; onActivated: panel.stepToNextValid(-1) }
        Shortcut { sequence: "Right"; onActivated: panel.stepToNextValid(1) }
        Shortcut { sequence: "Tab"; onActivated: panel.cycleFilter(1) }
        Shortcut { sequence: "Backtab"; onActivated: panel.cycleFilter(-1) }
        Shortcut { sequence: "Escape"; onActivated: Core.Panels.close("wallpapers") }
        Shortcut {
            sequence: "Return"
            onActivated: {
                var model = Services.Wallpapers.wallpapers
                if (view.currentIndex >= 0 && view.currentIndex < model.length) {
                    Services.Wallpapers.setWallpaper(model[view.currentIndex].path)
                }
            }
        }

        // === Picker area (mask target) ===
        Item {
            id: pickerArea
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: panel.pickerHeight
        }

        // === Backdrop (semi-transparent, dismiss on click) ===
        Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, 0.35)
            opacity: panel.shouldShow ? 1.0 : 0.0

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
        }

        // === Main carousel area ===
        Item {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: panel.pickerHeight

            opacity: panel.shouldShow ? 1.0 : 0.0
            Behavior on opacity { NumberAnimation { duration: 600; easing.type: Easing.OutQuart } }

            // === ListView (ilyamiro-faithful horizontal carousel) ===
            ListView {
                id: view
                anchors.fill: parent
                spacing: 0
                orientation: ListView.Horizontal
                clip: false
                cacheBuffer: 2000
                focus: true

                highlightRangeMode: ListView.StrictlyEnforceRange
                preferredHighlightBegin: (width / 2) - ((panel.itemWidth * 1.5 + panel.itemSpacing) / 2)
                preferredHighlightEnd: (width / 2) + ((panel.itemWidth * 1.5 + panel.itemSpacing) / 2)
                highlightMoveDuration: panel.initialFocusSet ? 500 : 0

                header: Item { width: Math.max(0, (view.width / 2) - ((panel.itemWidth * 1.5) / 2)) }
                footer: Item { width: Math.max(0, (view.width / 2) - ((panel.itemWidth * 1.5) / 2)) }

                model: Services.Wallpapers.wallpapers

                add: Transition {
                    enabled: panel.initialFocusSet
                    ParallelAnimation {
                        NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 400; easing.type: Easing.OutCubic }
                        NumberAnimation { property: "scale"; from: 0.5; to: 1; duration: 400; easing.type: Easing.OutBack }
                    }
                }
                addDisplaced: Transition {
                    enabled: panel.initialFocusSet
                    NumberAnimation { property: "x"; duration: 400; easing.type: Easing.OutCubic }
                }

                // Mouse wheel navigation (ilyamiro pattern)
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.NoButton

                    onWheel: (wheel) => {
                        if (scrollThrottle.running) { wheel.accepted = true; return }

                        var dx = wheel.angleDelta.x
                        var dy = wheel.angleDelta.y
                        var delta = Math.abs(dx) > Math.abs(dy) ? dx : dy
                        panel.scrollAccum += delta

                        if (Math.abs(panel.scrollAccum) >= panel.scrollThreshold) {
                            panel.stepToNextValid(panel.scrollAccum > 0 ? -1 : 1)
                            panel.scrollAccum = 0
                            scrollThrottle.start()
                        }
                        wheel.accepted = true
                    }
                }

                delegate: Item {
                    id: delegateRoot

                    readonly property string safeFileName: modelData.name || ""
                    readonly property string filePath: modelData.path || ""
                    readonly property bool isCurrent: ListView.isCurrentItem
                    readonly property bool isMatch: panel.matchesFilter(safeFileName)

                    readonly property real targetWidth: isCurrent ? (panel.itemWidth * 1.5) : (panel.itemWidth * 0.5)
                    readonly property real targetHeight: isCurrent ? (panel.itemHeight + 30) : panel.itemHeight

                    width: isMatch ? (targetWidth + panel.itemSpacing) : 0
                    height: isMatch ? targetHeight : 0
                    visible: width > 0.1
                    opacity: isMatch ? (isCurrent ? 1.0 : 0.6) : 0.0
                    scale: isMatch ? 1.0 : 0.5

                    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
                    anchors.verticalCenterOffset: 15

                    z: isCurrent ? 10 : 1

                    Behavior on scale { enabled: panel.initialFocusSet; NumberAnimation { duration: 500; easing.type: Easing.InOutQuad } }
                    Behavior on width { enabled: panel.initialFocusSet; NumberAnimation { duration: 500; easing.type: Easing.InOutQuad } }
                    Behavior on height { enabled: panel.initialFocusSet; NumberAnimation { duration: 500; easing.type: Easing.InOutQuad } }
                    Behavior on opacity { enabled: panel.initialFocusSet; NumberAnimation { duration: 500; easing.type: Easing.InOutQuad } }

                    Item {
                        anchors.centerIn: parent
                        anchors.horizontalCenterOffset: ((panel.itemHeight - height) / 2) * panel.skewFactor
                        width: parent.width > 0 ? parent.width * (delegateRoot.targetWidth / (delegateRoot.targetWidth + panel.itemSpacing)) : 0
                        height: parent.height

                        transform: Matrix4x4 {
                            property real s: panel.skewFactor
                            matrix: Qt.matrix4x4(1, s, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)
                        }

                        MouseArea {
                            anchors.fill: parent
                            enabled: delegateRoot.isMatch
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                view.currentIndex = index
                                Services.Wallpapers.setWallpaper(delegateRoot.filePath)
                            }
                        }

                        // Outer blurry border image (ilyamiro: stretch 1x1 sourceSize)
                        Image {
                            anchors.fill: parent
                            source: delegateRoot.filePath ? "file://" + delegateRoot.filePath : ""
                            sourceSize: Qt.size(1, 1)
                            fillMode: Image.Stretch
                            asynchronous: true
                        }

                        // Inner clipped image with inverse skew
                        Item {
                            anchors.fill: parent
                            anchors.margins: panel.borderWidth
                            clip: true

                            Rectangle { anchors.fill: parent; color: "black" }

                            Image {
                                anchors.centerIn: parent
                                anchors.horizontalCenterOffset: -50
                                width: (panel.itemWidth * 1.5) + ((panel.itemHeight + 30) * Math.abs(panel.skewFactor)) + 50
                                height: panel.itemHeight + 30
                                fillMode: Image.PreserveAspectCrop
                                source: {
                                    // Use thumbnail if available, otherwise original
                                    var thumbPath = Services.Wallpapers.thumbDir + "/" + delegateRoot.safeFileName
                                    return delegateRoot.filePath ? "file://" + delegateRoot.filePath : ""
                                }
                                asynchronous: true

                                transform: Matrix4x4 {
                                    property real s: -panel.skewFactor
                                    matrix: Qt.matrix4x4(1, s, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)
                                }
                            }
                        }
                    }
                }
            }

            // === Floating filter bar (ilyamiro-faithful) ===
            Rectangle {
                id: filterBar
                anchors.top: parent.top
                anchors.topMargin: panel.shouldShow ? Math.round(40 * panel.sp) : Math.round(-100 * panel.sp)
                anchors.horizontalCenter: parent.horizontalCenter
                z: 20

                height: Math.round(56 * panel.sp)
                width: filterRow.width + Math.round(24 * panel.sp)
                radius: Math.round(14 * panel.sp)

                color: Qt.rgba(Core.Theme.bgBase.r, Core.Theme.bgBase.g, Core.Theme.bgBase.b, 0.90)
                border.color: Qt.rgba(Core.Theme.fgMuted.r, Core.Theme.fgMuted.g, Core.Theme.fgMuted.b, 0.3)
                border.width: 1

                opacity: panel.shouldShow ? 1.0 : 0.0
                Behavior on anchors.topMargin { NumberAnimation { duration: 600; easing.type: Easing.OutExpo } }
                Behavior on opacity { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }

                Row {
                    id: filterRow
                    anchors.centerIn: parent
                    spacing: Math.round(12 * panel.sp)

                    // Apply Theme toggle
                    Rectangle {
                        width: applyThemeLabel.implicitWidth + Math.round(20 * panel.sp)
                        height: Math.round(36 * panel.sp)
                        radius: Math.round(10 * panel.sp)
                        anchors.verticalCenter: parent.verticalCenter
                        color: Services.Wallpapers.applyTheme
                            ? Qt.rgba(Core.Theme.accent.r, Core.Theme.accent.g, Core.Theme.accent.b, 0.2)
                            : "transparent"
                        border.color: Services.Wallpapers.applyTheme
                            ? Core.Theme.accent
                            : Qt.rgba(Core.Theme.fgMuted.r, Core.Theme.fgMuted.g, Core.Theme.fgMuted.b, 0.3)
                        border.width: Services.Wallpapers.applyTheme ? 2 : 1

                        Behavior on color { ColorAnimation { duration: 300 } }
                        Behavior on border.color { ColorAnimation { duration: 300 } }

                        Text {
                            id: applyThemeLabel
                            anchors.centerIn: parent
                            text: "\ue3ab"  // palette icon
                            font.family: Core.Theme.fontIcon
                            font.pixelSize: Math.round(18 * panel.sp)
                            color: Services.Wallpapers.applyTheme ? Core.Theme.accent : Core.Theme.fgDim
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: Services.Wallpapers.setApplyTheme(!Services.Wallpapers.applyTheme)
                        }
                    }

                    // Separator
                    Rectangle {
                        width: 1; height: Math.round(28 * panel.sp)
                        anchors.verticalCenter: parent.verticalCenter
                        color: Qt.rgba(Core.Theme.fgMuted.r, Core.Theme.fgMuted.g, Core.Theme.fgMuted.b, 0.3)
                    }

                    // Filter buttons (All + color circles)
                    Repeater {
                        model: panel.filterData

                        delegate: Item {
                            width: modelData.hex === "" ? Math.max(filterBtnText.contentWidth + Math.round(16 * panel.sp), Math.round(44 * panel.sp)) : Math.round(36 * panel.sp)
                            height: Math.round(36 * panel.sp)
                            anchors.verticalCenter: parent.verticalCenter

                            Rectangle {
                                anchors.fill: parent
                                radius: Math.round(10 * panel.sp)
                                color: modelData.hex === ""
                                    ? (panel.currentFilter === modelData.name ? Core.Theme.surfaceContainerHigh : "transparent")
                                    : modelData.hex
                                border.color: panel.currentFilter === modelData.name
                                    ? Core.Theme.fgMain
                                    : Qt.rgba(Core.Theme.fgMuted.r, Core.Theme.fgMuted.g, Core.Theme.fgMuted.b, 0.4)
                                border.width: panel.currentFilter === modelData.name ? 2 : 1
                                scale: panel.currentFilter === modelData.name ? 1.15 : (filterBtnMa.containsMouse ? 1.08 : 1.0)

                                Behavior on scale { NumberAnimation { duration: 400; easing.type: Easing.OutBack; easing.overshoot: 1.2 } }
                                Behavior on border.color { ColorAnimation { duration: 300 } }

                                // "All" or other text label
                                Text {
                                    id: filterBtnText
                                    visible: modelData.hex === ""
                                    text: modelData.label || modelData.name
                                    anchors.centerIn: parent
                                    color: panel.currentFilter === modelData.name ? Core.Theme.fgMain : Core.Theme.fgDim
                                    font.family: Core.Theme.fontUI
                                    font.pixelSize: Math.round(12 * panel.sp)
                                    font.weight: panel.currentFilter === modelData.name ? Font.Bold : Font.Normal
                                }
                            }

                            MouseArea {
                                id: filterBtnMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: panel.currentFilter = modelData.name
                            }
                        }
                    }

                    // Separator
                    Rectangle {
                        width: 1; height: Math.round(28 * panel.sp)
                        anchors.verticalCenter: parent.verticalCenter
                        color: Qt.rgba(Core.Theme.fgMuted.r, Core.Theme.fgMuted.g, Core.Theme.fgMuted.b, 0.3)
                    }

                    // Refresh button
                    Rectangle {
                        width: Math.round(36 * panel.sp); height: width
                        radius: Math.round(10 * panel.sp)
                        anchors.verticalCenter: parent.verticalCenter
                        color: refreshMa.containsMouse ? Core.Theme.surfaceContainerHigh : "transparent"
                        border.color: Qt.rgba(Core.Theme.fgMuted.r, Core.Theme.fgMuted.g, Core.Theme.fgMuted.b, 0.3)
                        border.width: 1

                        Text {
                            anchors.centerIn: parent
                            text: "\ue863"  // refresh
                            font.family: Core.Theme.fontIcon
                            font.pixelSize: Math.round(16 * panel.sp)
                            color: refreshMa.containsMouse ? Core.Theme.accent : Core.Theme.fgDim
                        }

                        MouseArea {
                            id: refreshMa; anchors.fill: parent
                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: Services.Wallpapers.refresh()
                        }
                    }

                    // Close button
                    Rectangle {
                        width: Math.round(36 * panel.sp); height: width
                        radius: Math.round(10 * panel.sp)
                        anchors.verticalCenter: parent.verticalCenter
                        color: closePanelMa.containsMouse ? Qt.rgba(Core.Theme.urgent.r, Core.Theme.urgent.g, Core.Theme.urgent.b, 0.15) : "transparent"
                        border.color: Qt.rgba(Core.Theme.fgMuted.r, Core.Theme.fgMuted.g, Core.Theme.fgMuted.b, 0.3)
                        border.width: 1

                        Text {
                            anchors.centerIn: parent
                            text: "\ue5cd"  // close
                            font.family: Core.Theme.fontIcon
                            font.pixelSize: Math.round(16 * panel.sp)
                            color: closePanelMa.containsMouse ? Core.Theme.urgent : Core.Theme.fgDim
                        }

                        MouseArea {
                            id: closePanelMa; anchors.fill: parent
                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: Core.Panels.close("wallpapers")
                        }
                    }
                }
            }
        }
    }
}

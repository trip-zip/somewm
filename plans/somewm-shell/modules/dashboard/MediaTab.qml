import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import QtQuick.Effects
import "../../core" as Core
import "../../services" as Services
import "../../components" as Components

// Caelestia Media.qml — horizontal: visualizer+cover | details | (no bongocat)
Item {
    id: root

    property bool tabActive: false

    readonly property real sp: Core.Theme.dpiScale
    readonly property real spacNorm: Math.round(12 * sp)
    readonly property real spacSm: Math.round(7 * sp)
    readonly property real padLg: Math.round(15 * sp)

    readonly property real coverSize: Math.round(150 * sp)
    readonly property real visSize: Math.round(80 * sp)
    readonly property real sliderWidth: Math.round(280 * sp)

    Component.onCompleted: _updateActive()
    onTabActiveChanged: _updateActive()
    function _updateActive() {
        Services.CavaService.mediaTabActive = tabActive && Core.Panels.isOpen("dashboard")
    }
    Connections {
        target: Core.Panels
        function onOpenPanelsChanged() { root._updateActive() }
    }
    Component.onDestruction: Services.CavaService.mediaTabActive = false

    property real playerProgress: Services.Media.progressPercent / 100.0
    Behavior on playerProgress {
        NumberAnimation { duration: Core.Anims.duration.large }
    }

    // Content-driven size (Caelestia pattern)
    implicitWidth: coverSize + visSize * 2 + details.implicitWidth + spacNorm + padLg * 2
    implicitHeight: Math.max(coverSize + visSize * 2, details.implicitHeight) + padLg * 2

    // === Visualizer bars (Canvas-based circular frequency display) ===
    Canvas {
        id: visualiser
        z: 1
        anchors.fill: coverWrapper
        anchors.margins: -visSize
        renderStrategy: Canvas.Threaded

        property var cavaValues: Services.CavaService.values
        onCavaValuesChanged: requestPaint()

        readonly property real cx: width / 2
        readonly property real cy: height / 2
        readonly property real innerR: coverSize / 2 + spacSm
        readonly property int barCount: Core.Constants.mediaBarCount
        readonly property real barWidth: Math.round(360 / barCount - spacSm / 4)
        readonly property color barColor: Core.Theme.accent

        onPaint: {
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            ctx.strokeStyle = barColor
            ctx.lineWidth = barWidth
            ctx.lineCap = "round"

            var vals = cavaValues
            if (!vals || vals.length === 0) return

            for (var i = 0; i < barCount; i++) {
                var v = i < vals.length ? Math.max(0.001, Math.min(1, vals[i])) : 0.001
                var angle = i * 2 * Math.PI / barCount
                var magnitude = v * visSize
                var cosA = Math.cos(angle)
                var sinA = Math.sin(angle)
                var startR = innerR + barWidth / 2
                var endR = startR + magnitude

                ctx.beginPath()
                ctx.moveTo(cx + startR * cosA, cy + startR * sinA)
                ctx.lineTo(cx + endR * cosA, cy + endR * sinA)
                ctx.stroke()
            }
        }
    }

    // === Album art (circular clip — MultiEffect mask) ===
    Item {
        id: coverWrapper
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.leftMargin: padLg + visSize
        width: coverSize
        height: coverSize

        Rectangle {
            anchors.fill: parent
            radius: coverSize / 2
            color: Core.Theme.surfaceContainerHigh
        }

        Image {
            id: mediaArtImg
            anchors.fill: parent
            source: Services.Media.artUrl || Qt.resolvedUrl("../../assets/icons/nocover.jpg")
            asynchronous: true
            fillMode: Image.PreserveAspectCrop
            visible: false
            layer.enabled: true
        }
        Item {
            id: mediaCoverMask
            anchors.fill: parent
            visible: false
            layer.enabled: true
            Rectangle { anchors.fill: parent; radius: coverSize / 2 }
        }
        MultiEffect {
            anchors.fill: parent
            source: mediaArtImg
            maskEnabled: true
            maskSource: mediaCoverMask
            visible: mediaArtImg.status === Image.Ready
        }
    }

    // === Details column (Caelestia: title, album, artist, controls, slider, time) ===
    ColumnLayout {
        id: details
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: visualiser.right
        anchors.leftMargin: spacNorm
        spacing: spacSm

        // Title
        Text {
            Layout.fillWidth: true
            Layout.maximumWidth: sliderWidth
            horizontalAlignment: Text.AlignHCenter
            text: Services.Media.trackTitle || "No media"
            font.family: Core.Theme.fontUI
            font.pixelSize: Math.round(13 * sp)
            color: Services.Media.hasPlayer ? Core.Theme.accent : Core.Theme.fgMain
            elide: Text.ElideRight
        }

        // Album
        Text {
            Layout.fillWidth: true
            Layout.maximumWidth: sliderWidth
            horizontalAlignment: Text.AlignHCenter
            text: Services.Media.trackAlbum || ""
            font.family: Core.Theme.fontUI
            font.pixelSize: Math.round(11 * sp)
            color: Core.Theme.fgMuted
            elide: Text.ElideRight
            visible: text !== "" && Services.Media.hasPlayer
        }

        // Artist
        Text {
            Layout.fillWidth: true
            Layout.maximumWidth: sliderWidth
            horizontalAlignment: Text.AlignHCenter
            text: Services.Media.trackArtist || "Play some music"
            font.family: Core.Theme.fontUI
            font.pixelSize: Math.round(12 * sp)
            color: Services.Media.hasPlayer ? Core.Theme.fgDim : Core.Theme.fgMuted
            elide: Text.ElideRight
        }

        // Transport controls (Caelestia: shuffle, prev, play, next, lyrics)
        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: spacSm
            Layout.bottomMargin: Math.round(5 * sp)
            spacing: spacSm

            TransportBtn { icon: "\ue045"; canUse: Services.Media.canGoPrevious; onClicked: Services.Media.previous() }

            // Play/pause — accent circle (Caelestia pattern)
            Rectangle {
                width: Math.round(44 * sp); height: width; radius: width / 2
                color: playMa.pressed ? Core.Theme.accentDim :
                       playMa.containsMouse ? Qt.lighter(Core.Theme.accent, 1.15) : Core.Theme.accent
                scale: playMa.pressed ? 0.92 : 1.0
                Behavior on scale { NumberAnimation { duration: Core.Anims.duration.fast } }
                Text {
                    anchors.centerIn: parent
                    text: Services.Media.isPlaying ? "\ue034" : "\ue037"
                    font.family: Core.Theme.fontIcon; font.pixelSize: Math.round(22 * sp)
                    color: Core.Theme.bgBase
                }
                MouseArea {
                    id: playMa; anchors.fill: parent; hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor; onClicked: Services.Media.playPause()
                }
            }

            TransportBtn { icon: "\ue044"; canUse: Services.Media.canGoNext; onClicked: Services.Media.next() }
        }

        // Progress slider (Caelestia: StyledSlider, 280px)
        Item {
            Layout.preferredWidth: sliderWidth
            height: Math.round(24 * sp)

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width; height: Math.round(4 * sp)
                radius: 1000; color: Core.Theme.fade(Core.Theme.accent, 0.15)

                Rectangle {
                    width: parent.width * playerProgress; height: parent.height
                    radius: parent.radius; color: Core.Theme.accent
                }
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Services.Media.canSeek ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: (mouse) => {
                    if (Services.Media.canSeek)
                        Services.Media.seekPercent(Math.round(mouse.x / parent.width * 100))
                }
            }
        }

        // Time labels
        Item {
            Layout.preferredWidth: sliderWidth
            implicitHeight: Math.max(posText.implicitHeight, lenText.implicitHeight)

            Text {
                id: posText; anchors.left: parent.left
                text: Services.Media.positionText || "0:00"
                font.family: Core.Theme.fontMono; font.pixelSize: Math.round(11 * sp)
                color: Core.Theme.fgMuted
            }
            Text {
                id: lenText; anchors.right: parent.right
                text: Services.Media.lengthText || "0:00"
                font.family: Core.Theme.fontMono; font.pixelSize: Math.round(11 * sp)
                color: Core.Theme.fgMuted
            }
        }

        // Volume
        RowLayout {
            Layout.preferredWidth: sliderWidth
            spacing: spacSm

            Text {
                text: Services.Audio.icon; font.family: Core.Theme.fontIcon
                font.pixelSize: Math.round(18 * sp)
                color: Services.Audio.muted ? Core.Theme.fgMuted : Core.Theme.fgDim
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: Services.Audio.toggleMute() }
            }

            Item {
                Layout.fillWidth: true; height: Math.round(20 * sp)
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter; width: parent.width
                    height: Math.round(4 * sp); radius: 1000
                    color: Core.Theme.fade(Core.Theme.accent, 0.15)
                    Rectangle {
                        width: parent.width * Math.min(1.0, Services.Audio.volume)
                        height: parent.height; radius: parent.radius
                        color: Services.Audio.muted ? Core.Theme.fgMuted : Core.Theme.accent
                        Behavior on width { NumberAnimation { duration: Core.Anims.duration.large } }
                    }
                }
                MouseArea {
                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: (mouse) => Services.Audio.setVolume(Math.max(0, Math.min(1, mouse.x / parent.width)))
                    onPositionChanged: (mouse) => { if (pressed) Services.Audio.setVolume(Math.max(0, Math.min(1, mouse.x / parent.width))) }
                }
            }

            Text {
                text: Services.Audio.volumePercent + "%"
                font.family: Core.Theme.fontMono; font.pixelSize: Math.round(11 * sp)
                color: Core.Theme.fgDim
                Layout.preferredWidth: Math.round(36 * sp)
                horizontalAlignment: Text.AlignRight
            }
        }
    }

    component TransportBtn: Item {
        property string icon; property bool canUse: true; signal clicked()
        implicitWidth: Math.round(32 * sp); implicitHeight: implicitWidth
        Text {
            anchors.centerIn: parent; text: parent.icon
            font.family: Core.Theme.fontIcon; font.pixelSize: Math.round(24 * sp)
            color: parent.canUse ? Core.Theme.fgMain : Core.Theme.fgMuted
            opacity: parent.canUse ? 1.0 : 0.4
        }
        MouseArea {
            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
            enabled: parent.canUse; onClicked: parent.clicked()
        }
    }
}

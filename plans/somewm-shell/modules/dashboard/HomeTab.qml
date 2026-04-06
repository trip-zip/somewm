import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import QtQuick.Effects
import Quickshell
import "../../core" as Core
import "../../services" as Services
import "../../components" as Components

// Caelestia Dash.qml — GridLayout with Weather, User, DateTime, Calendar, Resources, Media
GridLayout {
    id: root

    // Spacing from Caelestia AppearanceConfig (spacing.normal = 12, padding.large = 15)
    readonly property real sp: Core.Theme.dpiScale
    readonly property real spacNorm: Math.round(12 * sp)
    readonly property real padLg: Math.round(15 * sp)
    readonly property real roundNorm: Math.round(17 * sp)
    readonly property real roundLg: Math.round(25 * sp)

    rowSpacing: spacNorm
    columnSpacing: spacNorm

    // ===== ROW 0, COL 0-1: Weather (Caelestia SmallWeather.qml) =====
    Rect {
        Layout.row: 0
        Layout.columnSpan: 2
        Layout.preferredWidth: Math.round(250 * sp)  // Config.dashboard.sizes.weatherWidth
        Layout.fillHeight: true
        radius: roundLg * 1.5

        Item {
            anchors.centerIn: parent
            implicitWidth: weatherIcon.implicitWidth + weatherInfo.implicitWidth + weatherInfo.anchors.leftMargin

            Text {
                id: weatherIcon
                anchors.verticalCenter: parent.verticalCenter
                text: Services.Weather.conditionIcon || "\ue2bd"
                font.family: Core.Theme.fontIcon
                font.pixelSize: Math.round(56 * sp)
                color: Core.Theme.accent
            }

            Column {
                id: weatherInfo
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: weatherIcon.right
                anchors.leftMargin: Math.round(20 * sp)
                spacing: Math.round(7 * sp)

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Services.Weather.hasData ? Services.Weather.tempC + "°C" : "—"
                    font.family: Core.Theme.fontUI
                    font.pixelSize: Math.round(28 * sp)
                    font.weight: Font.Medium
                    color: Core.Theme.accent
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Services.Weather.condition || "—"
                    font.family: Core.Theme.fontUI
                    font.pixelSize: Math.round(13 * sp)
                    color: Core.Theme.fgDim
                }
            }
        }
    }

    // ===== ROW 0, COL 2-4: User (Caelestia User.qml) =====
    Rect {
        Layout.column: 2
        Layout.columnSpan: 3
        Layout.preferredWidth: userRow.implicitWidth
        Layout.preferredHeight: userRow.implicitHeight
        radius: roundLg

        Row {
            id: userRow
            padding: padLg
            spacing: spacNorm

            // Avatar (MultiEffect mask for rounded clipping)
            Item {
                width: infoCol.implicitHeight
                height: infoCol.implicitHeight

                // Background + placeholder (visible when no image)
                Rectangle {
                    anchors.fill: parent
                    radius: roundLg
                    color: Core.Theme.fade(Core.Theme.accent, 0.12)
                    Text {
                        anchors.centerIn: parent
                        text: "\ue7fd"  // person
                        font.family: Core.Theme.fontIcon
                        font.pixelSize: Math.floor(parent.height / 2)
                        color: Core.Theme.fgDim
                        visible: avatarImg.status !== Image.Ready
                    }
                }

                Image {
                    id: avatarImg
                    anchors.fill: parent
                    anchors.margins: Math.round(2 * sp)
                    source: "file://" + Quickshell.env("HOME") + "/.face"
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    visible: false
                    layer.enabled: true
                }
                Item {
                    id: avatarMask
                    anchors.fill: parent
                    visible: false
                    layer.enabled: true
                    Rectangle { anchors.fill: parent; radius: roundLg }
                }
                MultiEffect {
                    anchors.fill: parent
                    source: avatarImg
                    maskEnabled: true
                    maskSource: avatarMask
                    visible: avatarImg.status === Image.Ready
                }
            }

            // Info lines (Caelestia pattern: icon + ": text")
            Column {
                id: infoCol
                anchors.verticalCenter: parent.verticalCenter
                spacing: spacNorm

                InfoLine { icon: "\ue30a"; label: "Arch Linux"; lineColor: Core.Theme.accent }
                InfoLine { icon: "\ue8b8"; label: "somewm"; lineColor: Core.Theme.fgDim }
                InfoLine { icon: "\ue425"; label: "up " + Services.SystemStats.uptime; lineColor: Core.Theme.fgMuted }
            }
        }
    }

    // ===== ROW 0-1, COL 5: Mini Media (Caelestia dash/Media.qml) =====
    Rect {
        Layout.row: 0
        Layout.column: 5
        Layout.rowSpan: 2
        Layout.preferredWidth: miniMedia.implicitWidth
        Layout.fillHeight: true
        radius: roundLg * 2

        MiniMedia { id: miniMedia }
    }

    // ===== ROW 1, COL 0: DateTime (Caelestia DateTime.qml) =====
    Rect {
        Layout.row: 1
        Layout.preferredWidth: dateTimeInner.implicitWidth
        Layout.fillHeight: true
        radius: roundNorm

        Item {
            id: dateTimeInner
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            implicitWidth: Math.round(110 * sp)  // Config.dashboard.sizes.dateTimeWidth

            ColumnLayout {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 0

                property string hourStr: {
                    var d = new Date(); return d.getHours().toString().padStart(2, '0')
                }
                property string minStr: {
                    var d = new Date(); return d.getMinutes().toString().padStart(2, '0')
                }

                Timer {
                    interval: 1000; running: true; repeat: true
                    onTriggered: {
                        parent.hourStr = Qt.binding(function(){ var d=new Date(); return d.getHours().toString().padStart(2,'0') })
                        parent.minStr = Qt.binding(function(){ var d=new Date(); return d.getMinutes().toString().padStart(2,'0') })
                    }
                }

                Text {
                    Layout.bottomMargin: -(font.pixelSize * 0.4)
                    Layout.alignment: Qt.AlignHCenter
                    text: parent.hourStr
                    font.family: Core.Theme.fontMono
                    font.pixelSize: Math.round(28 * sp)
                    font.weight: Font.DemiBold
                    color: Core.Theme.fgMain
                }
                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: "•••"
                    font.family: Core.Theme.fontUI
                    font.pixelSize: Math.round(25 * sp)
                    color: Core.Theme.accent
                }
                Text {
                    Layout.topMargin: -(font.pixelSize * 0.4)
                    Layout.alignment: Qt.AlignHCenter
                    text: parent.minStr
                    font.family: Core.Theme.fontMono
                    font.pixelSize: Math.round(28 * sp)
                    font.weight: Font.DemiBold
                    color: Core.Theme.fgMain
                }
                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: {
                        var d = new Date()
                        var days = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"]
                        return days[d.getDay()] + ", " + d.getDate()
                    }
                    font.family: Core.Theme.fontUI
                    font.pixelSize: Math.round(11 * sp)
                    color: Core.Theme.fgMuted
                }
            }
        }
    }

    // ===== ROW 1, COL 1-3: Calendar (Caelestia Calendar.qml) =====
    Rect {
        Layout.row: 1
        Layout.column: 1
        Layout.columnSpan: 3
        Layout.fillWidth: true
        Layout.preferredHeight: calWidget.implicitHeight
        radius: roundLg

        CalendarWidget {
            id: calWidget
            anchors.left: parent.left
            anchors.right: parent.right
        }
    }

    // ===== ROW 1, COL 4: Resources (Caelestia Resources.qml) =====
    Rect {
        Layout.row: 1
        Layout.column: 4
        Layout.preferredWidth: resRow.implicitWidth
        Layout.fillHeight: true
        radius: roundNorm

        Row {
            id: resRow
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            padding: padLg
            spacing: spacNorm

            ResourceBar { icon: "\ue640"; value: Services.SystemStats.cpuPercent / 100.0; barColor: Core.Theme.widgetCpu }    // developer_board (CPU)
            ResourceBar { icon: "\ue322"; value: Services.SystemStats.memPercent / 100.0; barColor: Core.Theme.widgetMemory }  // memory (RAM)
            ResourceBar { icon: "\ue1db"; value: Services.SystemStats.diskPercent / 100.0; barColor: Core.Theme.widgetDisk }   // storage (disk)
        }
    }

    // ===== Inline components =====

    // Caelestia StyledRect wrapper
    component Rect: Rectangle {
        color: Core.Theme.surfaceContainer
    }

    // Caelestia User.qml InfoLine
    component InfoLine: Item {
        property string icon
        property string label
        property color lineColor: Core.Theme.fgMain
        readonly property real iconSize: Math.round(25 * sp)
        readonly property real textWidth: Math.round(200 * sp)

        implicitWidth: iconSize + textItem.implicitWidth + iconItem.anchors.leftMargin
        implicitHeight: Math.max(iconItem.implicitHeight, textItem.implicitHeight)

        Text {
            id: iconItem
            anchors.left: parent.left
            anchors.leftMargin: (iconSize - implicitWidth) / 2
            text: parent.icon
            font.family: Core.Theme.fontIcon
            font.pixelSize: Math.round(13 * sp)
            color: parent.lineColor
        }
        Text {
            id: textItem
            anchors.verticalCenter: iconItem.verticalCenter
            anchors.left: iconItem.right
            anchors.leftMargin: iconItem.anchors.leftMargin
            text: ":  " + parent.label
            font.family: Core.Theme.fontUI
            font.pixelSize: Math.round(13 * sp)
            color: Core.Theme.fgMain
            width: textWidth
            elide: Text.ElideRight
        }
    }

    // Caelestia Resources.qml Resource bar
    component ResourceBar: Item {
        property string icon
        property real value: 0
        property color barColor: Core.Theme.accent
        readonly property real barThickness: Math.round(10 * sp)

        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.margins: padLg
        implicitWidth: barIcon.implicitWidth

        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.bottom: barIcon.top
            anchors.bottomMargin: Math.round(7 * sp)
            width: barThickness
            radius: 1000
            color: Core.Theme.fade(barColor, 0.12)

            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: parent.height * value
                radius: parent.radius
                color: barColor

                Behavior on height {
                    NumberAnimation {
                        duration: Core.Anims.duration.large
                        easing.type: Easing.BezierSpline
                        easing.bezierCurve: Core.Anims.curves.emphasized
                    }
                }
            }
        }

        Text {
            id: barIcon
            anchors.bottom: parent.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            text: icon
            font.family: Core.Theme.fontIcon
            font.pixelSize: Math.round(18 * sp)
            color: barColor
        }
    }

    // Caelestia dash/Media.qml — mini player with progress ring
    component MiniMedia: Item {
        readonly property real coverArtSize: Math.round(150 * sp)
        readonly property real progressThk: Math.round(6 * sp)
        readonly property real mediaWidth: Math.round(200 * sp)
        readonly property real progressSweep: 180

        anchors.top: parent.top
        anchors.bottom: parent.bottom
        implicitWidth: mediaWidth

        property real playerProgress: Services.Media.progressPercent / 100.0

        Behavior on playerProgress {
            NumberAnimation { duration: Core.Anims.duration.large }
        }

        // Progress ring (Caelestia: Shape with two ShapePaths)
        Shape {
            anchors.fill: parent

            ShapePath {
                fillColor: "transparent"
                strokeColor: Core.Theme.fade(Core.Theme.accent, 0.12)
                strokeWidth: progressThk
                capStyle: ShapePath.RoundCap
                PathAngleArc {
                    centerX: coverWrapper.x + coverWrapper.width / 2
                    centerY: coverWrapper.y + coverWrapper.height / 2
                    radiusX: (coverWrapper.width + progressThk) / 2 + Math.round(7 * sp)
                    radiusY: radiusX
                    startAngle: -90 - progressSweep / 2
                    sweepAngle: progressSweep
                }
            }

            ShapePath {
                fillColor: "transparent"
                strokeColor: Core.Theme.accent
                strokeWidth: progressThk
                capStyle: ShapePath.RoundCap
                PathAngleArc {
                    centerX: coverWrapper.x + coverWrapper.width / 2
                    centerY: coverWrapper.y + coverWrapper.height / 2
                    radiusX: (coverWrapper.width + progressThk) / 2 + Math.round(7 * sp)
                    radiusY: radiusX
                    startAngle: -90 - progressSweep / 2
                    sweepAngle: progressSweep * playerProgress
                }
            }
        }

        // Cover art (circular — MultiEffect mask for clipping)
        Item {
            id: coverWrapper
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: padLg + progressThk + Math.round(7 * sp)
            height: width

            Rectangle {
                anchors.fill: parent
                radius: width / 2
                color: Core.Theme.surfaceContainerHigh
            }

            Image {
                id: coverImg
                anchors.fill: parent
                source: Services.Media.artUrl || Qt.resolvedUrl("../../assets/icons/nocover.jpg")
                asynchronous: true
                fillMode: Image.PreserveAspectCrop
                visible: false
                layer.enabled: true
            }
            Item {
                id: coverMask
                anchors.fill: parent
                visible: false
                layer.enabled: true
                Rectangle { anchors.fill: parent; radius: parent.width / 2 }
            }
            MultiEffect {
                anchors.fill: parent
                source: coverImg
                maskEnabled: true
                maskSource: coverMask
                visible: coverImg.status === Image.Ready
            }
        }

        // Title
        Text {
            id: mediaTitle
            anchors.top: coverWrapper.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.topMargin: spacNorm
            width: mediaWidth - padLg * 2
            horizontalAlignment: Text.AlignHCenter
            text: Services.Media.trackTitle || "No media"
            font.family: Core.Theme.fontUI
            font.pixelSize: Math.round(13 * sp)
            color: Core.Theme.accent
            elide: Text.ElideRight
        }

        // Album
        Text {
            id: mediaAlbum
            anchors.top: mediaTitle.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.topMargin: Math.round(7 * sp)
            width: mediaWidth - padLg * 2
            horizontalAlignment: Text.AlignHCenter
            text: Services.Media.trackAlbum || ""
            font.family: Core.Theme.fontUI
            font.pixelSize: Math.round(11 * sp)
            color: Core.Theme.fgMuted
            elide: Text.ElideRight
            visible: text !== ""
        }

        // Artist
        Text {
            id: mediaArtist
            anchors.top: mediaAlbum.visible ? mediaAlbum.bottom : mediaTitle.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.topMargin: Math.round(7 * sp)
            width: mediaWidth - padLg * 2
            horizontalAlignment: Text.AlignHCenter
            text: Services.Media.trackArtist || ""
            font.family: Core.Theme.fontUI
            font.pixelSize: Math.round(12 * sp)
            color: Core.Theme.fgDim
            elide: Text.ElideRight
            visible: text !== ""
        }

        // Transport controls (Caelestia Control component)
        Row {
            id: transportRow
            anchors.top: mediaArtist.visible ? mediaArtist.bottom : (mediaAlbum.visible ? mediaAlbum.bottom : mediaTitle.bottom)
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.topMargin: Math.round(5 * sp)
            spacing: Math.round(7 * sp)

            MiniControl { icon: "\ue045"; canUse: Services.Media.canGoPrevious; onClicked: Services.Media.previous() }
            MiniControl { icon: Services.Media.isPlaying ? "\ue034" : "\ue037"; canUse: true; onClicked: Services.Media.playPause() }
            MiniControl { icon: "\ue044"; canUse: Services.Media.canGoNext; onClicked: Services.Media.next() }
        }

        // Compact volume control
        Row {
            anchors.top: transportRow.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.topMargin: Math.round(3 * sp)
            spacing: Math.round(5 * sp)
            width: mediaWidth - padLg * 2

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: Services.Audio.icon
                font.family: Core.Theme.fontIcon
                font.pixelSize: Math.round(14 * sp)
                color: Services.Audio.muted ? Core.Theme.fgMuted : Core.Theme.fgDim
                MouseArea {
                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: Services.Audio.toggleMute()
                }
            }
            Item {
                width: parent.width - Math.round(14 * sp) - Math.round(5 * sp) * 2 - volPct.implicitWidth
                height: Math.round(16 * sp)
                anchors.verticalCenter: parent.verticalCenter
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width; height: Math.round(3 * sp)
                    radius: 1000; color: Core.Theme.fade(Core.Theme.accent, 0.15)
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
                id: volPct
                anchors.verticalCenter: parent.verticalCenter
                text: Services.Audio.volumePercent + "%"
                font.family: Core.Theme.fontMono
                font.pixelSize: Math.round(9 * sp)
                color: Core.Theme.fgMuted
            }
        }
    }

    component MiniControl: Item {
        property string icon
        property bool canUse: true
        signal clicked()
        implicitWidth: Math.max(ctrlIcon.implicitHeight, ctrlIcon.implicitHeight) + Math.round(5 * sp)
        implicitHeight: implicitWidth
        Text {
            id: ctrlIcon
            anchors.centerIn: parent
            text: parent.icon
            font.family: Core.Theme.fontIcon
            font.pixelSize: Math.round(18 * sp)
            color: parent.canUse ? Core.Theme.fgMain : Core.Theme.fgMuted
        }
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            enabled: parent.canUse
            onClicked: parent.clicked()
        }
    }
}

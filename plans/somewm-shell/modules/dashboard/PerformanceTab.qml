import QtQuick
import QtQuick.Layouts
import "../../core" as Core
import "../../services" as Services
import "../../components" as Components

// Caelestia Performance.qml — faithfully adapted
// Row 1: HeroCards (GPU + CPU) with usage fill background
// Row 2: GaugeCards (Memory + Storage) with ArcGauge
Item {
    id: root

    property bool tabActive: false

    readonly property real sp: Core.Theme.dpiScale
    readonly property real spacNorm: Math.round(12 * sp)
    readonly property real padLg: Math.round(15 * sp)
    readonly property real roundLg: Math.round(25 * sp)

    Component.onCompleted: _updateActive()
    onTabActiveChanged: _updateActive()
    function _updateActive() { Services.SystemStats.perfTabActive = tabActive && Core.Panels.isOpen("dashboard") }
    Connections { target: Core.Panels; function onOpenPanelsChanged() { root._updateActive() } }
    Component.onDestruction: Services.SystemStats.perfTabActive = false

    implicitWidth: content.implicitWidth
    implicitHeight: content.implicitHeight

    ColumnLayout {
        id: content
        spacing: spacNorm

        // Row 1: HeroCards (GPU + CPU)
        RowLayout {
            Layout.fillWidth: true
            spacing: spacNorm

            HeroCard {
                Layout.fillWidth: true
                Layout.minimumWidth: Math.round(400 * sp)
                Layout.preferredHeight: Math.round(150 * sp)
                icon: "\ue30b"  // desktop_windows
                title: Services.SystemStats.gpuName ? "GPU - " + Services.SystemStats.gpuName : "GPU"
                mainValue: Services.SystemStats.gpuPercent + "%"
                mainLabel: "Usage"
                secondaryValue: Services.SystemStats.gpuTemp > 0 ? Services.SystemStats.gpuTemp + "\u00B0C" : "\u2014"
                secondaryLabel: "Temp"
                usage: Services.SystemStats.gpuPercent / 100.0
                temperature: Services.SystemStats.gpuTemp
                accentColor: Core.Theme.widgetGpu
            }

            HeroCard {
                Layout.fillWidth: true
                Layout.minimumWidth: Math.round(400 * sp)
                Layout.preferredHeight: Math.round(150 * sp)
                icon: "\ue322"  // memory
                title: "CPU"
                mainValue: Services.SystemStats.cpuPercent + "%"
                mainLabel: "Usage"
                secondaryValue: Services.SystemStats.cpuTemp > 0 ? Services.SystemStats.cpuTemp + "\u00B0C" : "\u2014"
                secondaryLabel: "Temp"
                usage: Services.SystemStats.cpuPercent / 100.0
                temperature: Services.SystemStats.cpuTemp
                accentColor: Core.Theme.widgetCpu
            }
        }

        // Row 2: GaugeCards (Memory + Storage)
        RowLayout {
            Layout.fillWidth: true
            spacing: spacNorm

            GaugeCard {
                Layout.fillWidth: true
                Layout.minimumWidth: Math.round(250 * sp)
                Layout.preferredHeight: Math.round(220 * sp)
                icon: "\ue1db"  // memory_alt
                title: "Memory"
                percentage: Services.SystemStats.memPercent / 100.0
                subtitle: Services.SystemStats.memUsedGB.toFixed(1) + " / " + Services.SystemStats.memTotalGB.toFixed(0) + " GiB"
                accentColor: Core.Theme.widgetMemory
            }

            GaugeCard {
                Layout.fillWidth: true
                Layout.minimumWidth: Math.round(250 * sp)
                Layout.preferredHeight: Math.round(220 * sp)
                icon: "\ue1db"  // hard_disk
                title: "Storage - /"
                percentage: Services.SystemStats.diskPercent / 100.0
                subtitle: Services.SystemStats.diskUsedGB + " / " + Services.SystemStats.diskTotalGB + " GiB"
                accentColor: Core.Theme.widgetDisk
            }
        }
    }

    // === HeroCard (Caelestia pattern: usage fill bg, icon+title header, temp bar bottom-left, usage% right) ===
    component HeroCard: Rectangle {
        id: heroCard

        property string icon
        property string title
        property string mainValue
        property string mainLabel
        property string secondaryValue
        property string secondaryLabel
        property real usage: 0
        property real temperature: 0
        property color accentColor: Core.Theme.accent
        readonly property real maxTemp: 100
        readonly property real tempProgress: Math.min(1, Math.max(0, temperature / maxTemp))

        property real animatedUsage: 0
        property real animatedTemp: 0

        color: Core.Theme.surfaceContainer
        radius: roundLg
        clip: true

        Component.onCompleted: {
            animatedUsage = usage
            animatedTemp = tempProgress
        }
        onUsageChanged: animatedUsage = usage
        onTempProgressChanged: animatedTemp = tempProgress

        // Usage fill background (Caelestia pattern — left-only rounded corners)
        Item {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: parent.width * heroCard.animatedUsage
            clip: true

            Behavior on width {
                NumberAnimation {
                    duration: Core.Anims.duration.large
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: Core.Anims.curves.standard
                }
            }

            Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: parent.width + roundLg
                radius: roundLg
                color: Qt.rgba(heroCard.accentColor.r, heroCard.accentColor.g, heroCard.accentColor.b, 0.15)
            }
        }

        // Header: icon + title (top-left)
        RowLayout {
            id: header
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.leftMargin: Math.round(padLg * 1.2)
            anchors.topMargin: Math.round(padLg * 1.2)
            width: parent.width - anchors.leftMargin - usageColumn.anchors.rightMargin - usageLabel.width - spacNorm
            spacing: Math.round(8 * sp)

            Text {
                text: heroCard.icon
                font.family: Core.Theme.fontIcon
                font.pixelSize: Math.round(18 * sp)
                color: heroCard.accentColor
            }

            Text {
                Layout.fillWidth: true
                text: heroCard.title
                font.family: Core.Theme.fontUI
                font.pixelSize: Math.round(12 * sp)
                color: Core.Theme.fgMain
                elide: Text.ElideRight
            }
        }

        // Bottom-left: temp value + label + progress bar
        Column {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: Math.round(padLg * 1.2)
            anchors.bottomMargin: Math.round(padLg * 1.3)
            spacing: Math.round(8 * sp)

            Row {
                spacing: Math.round(8 * sp)

                Text {
                    text: heroCard.secondaryValue
                    font.family: Core.Theme.fontMono
                    font.pixelSize: Math.round(12 * sp)
                    font.weight: Font.Medium
                    color: Core.Theme.fgMain
                }
                Text {
                    text: heroCard.secondaryLabel
                    font.family: Core.Theme.fontUI
                    font.pixelSize: Math.round(11 * sp)
                    color: Core.Theme.fgDim
                    anchors.baseline: parent.children[0].baseline
                }
            }

            // Temp progress bar (Caelestia ProgressBar)
            Rectangle {
                width: parent.width * 0.5
                height: Math.round(6 * sp)
                radius: 1000
                color: Qt.rgba(heroCard.accentColor.r, heroCard.accentColor.g, heroCard.accentColor.b, 0.2)

                Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: parent.width * heroCard.animatedTemp
                    color: heroCard.accentColor
                    radius: 1000

                    Behavior on width {
                        NumberAnimation {
                            duration: Core.Anims.duration.large
                            easing.type: Easing.BezierSpline
                            easing.bezierCurve: Core.Anims.curves.standard
                        }
                    }
                }
            }
        }

        // Right side: usage label + large percentage
        Column {
            id: usageColumn
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: padLg
            anchors.rightMargin: Math.round(32 * sp)
            spacing: 0

            Text {
                id: usageLabel
                anchors.right: parent.right
                text: heroCard.mainLabel
                font.family: Core.Theme.fontUI
                font.pixelSize: Math.round(12 * sp)
                color: Core.Theme.fgDim
            }

            Text {
                anchors.right: parent.right
                text: heroCard.mainValue
                font.family: Core.Theme.fontMono
                font.pixelSize: Math.round(28 * sp)
                font.weight: Font.Medium
                color: heroCard.accentColor
            }
        }

        Behavior on animatedUsage {
            NumberAnimation {
                duration: Core.Anims.duration.large
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Core.Anims.curves.standard
            }
        }
        Behavior on animatedTemp {
            NumberAnimation {
                duration: Core.Anims.duration.large
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Core.Anims.curves.standard
            }
        }
    }

    // === GaugeCard (Caelestia pattern: icon+title header, ArcGauge center, subtitle bottom) ===
    component GaugeCard: Rectangle {
        id: gaugeCard

        property string icon
        property string title
        property real percentage: 0
        property string subtitle
        property color accentColor: Core.Theme.accent

        property real animatedPercentage: 0

        color: Core.Theme.surfaceContainer
        radius: roundLg
        clip: true

        Component.onCompleted: animatedPercentage = percentage
        onPercentageChanged: animatedPercentage = percentage

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: padLg
            spacing: Math.round(6 * sp)

            // Header: icon + title
            RowLayout {
                Layout.fillWidth: true
                spacing: Math.round(8 * sp)

                Text {
                    text: gaugeCard.icon
                    font.family: Core.Theme.fontIcon
                    font.pixelSize: Math.round(18 * sp)
                    color: gaugeCard.accentColor
                }

                Text {
                    Layout.fillWidth: true
                    text: gaugeCard.title
                    font.family: Core.Theme.fontUI
                    font.pixelSize: Math.round(12 * sp)
                    color: Core.Theme.fgMain
                    elide: Text.ElideRight
                }
            }

            // ArcGauge center
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                Components.ArcGauge {
                    anchors.centerIn: parent
                    width: Math.min(parent.width, parent.height)
                    height: width
                    value: gaugeCard.animatedPercentage
                    progressColor: gaugeCard.accentColor
                    trackColor: Core.Theme.fade(gaugeCard.accentColor, 0.15)
                }

                Text {
                    anchors.centerIn: parent
                    text: Math.round(gaugeCard.percentage * 100) + "%"
                    font.family: Core.Theme.fontMono
                    font.pixelSize: Math.round(28 * sp)
                    font.weight: Font.Medium
                    color: gaugeCard.accentColor
                }
            }

            // Subtitle
            Text {
                Layout.alignment: Qt.AlignHCenter
                text: gaugeCard.subtitle
                font.family: Core.Theme.fontMono
                font.pixelSize: Math.round(11 * sp)
                color: Core.Theme.fgDim
            }
        }

        Behavior on animatedPercentage {
            NumberAnimation {
                duration: Core.Anims.duration.large
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Core.Anims.curves.standard
            }
        }
    }
}

import QtQuick
import QtQuick.Layouts
import "../../core" as Core
import "../../components" as Components

Item {
    id: root

    property date currentDate: new Date()
    property int displayMonth: currentDate.getMonth()
    property int displayYear: currentDate.getFullYear()

    // Refresh current date hourly (for midnight transition highlight)
    Timer {
        interval: 3600000
        running: true; repeat: true
        onTriggered: root.currentDate = new Date()
    }

    readonly property var monthNames: [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December"
    ]
    readonly property var dayNames: ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]

    function daysInMonth(month, year) {
        return new Date(year, month + 1, 0).getDate()
    }

    function firstDayOfWeek(month, year) {
        var day = new Date(year, month, 1).getDay()
        return day === 0 ? 6 : day - 1  // Monday = 0
    }

    function prevMonth() {
        if (displayMonth === 0) { displayMonth = 11; displayYear-- }
        else displayMonth--
    }

    function nextMonth() {
        if (displayMonth === 11) { displayMonth = 0; displayYear++ }
        else displayMonth++
    }

    function isToday(day) {
        var now = root.currentDate
        return day === now.getDate() &&
               root.displayMonth === now.getMonth() &&
               root.displayYear === now.getFullYear()
    }

    function isWeekend(index) {
        // index in the grid (0-based), columns 5 and 6 are Sa and Su
        return (index % 7) >= 5
    }

    implicitWidth: calLayout.implicitWidth
    implicitHeight: calLayout.implicitHeight

    ColumnLayout {
        id: calLayout
        width: parent.width > 0 ? parent.width : implicitWidth
        spacing: Core.Theme.spacing.sm

        // Month navigation
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Core.Theme.spacing.sm
            Layout.rightMargin: Core.Theme.spacing.sm

            // Previous month button
            Rectangle {
                id: prevBtn
                width: Math.round(28 * Core.Theme.dpiScale)
                height: width
                radius: width / 2
                color: prevMa.containsMouse ? Core.Theme.surfaceContainerHigh : "transparent"
                Text {
                    anchors.centerIn: parent
                    text: "\ue5cb"
                    font.family: Core.Theme.fontIcon
                    font.pixelSize: Core.Theme.fontSize.lg
                    color: prevMa.containsMouse ? Core.Theme.accent : Core.Theme.fgDim
                }
                MouseArea {
                    id: prevMa; anchors.fill: parent
                    hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: root.prevMonth()
                }
            }

            Text {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: root.monthNames[root.displayMonth] + " " + root.displayYear
                font.family: Core.Theme.fontUI
                font.pixelSize: Core.Theme.fontSize.sm
                font.weight: Font.DemiBold
                color: Core.Theme.accent
            }

            // Next month button
            Rectangle {
                width: Math.round(28 * Core.Theme.dpiScale)
                height: width
                radius: width / 2
                color: nextMa.containsMouse ? Core.Theme.surfaceContainerHigh : "transparent"
                Text {
                    anchors.centerIn: parent
                    text: "\ue5cc"
                    font.family: Core.Theme.fontIcon
                    font.pixelSize: Core.Theme.fontSize.lg
                    color: nextMa.containsMouse ? Core.Theme.accent : Core.Theme.fgDim
                }
                MouseArea {
                    id: nextMa; anchors.fill: parent
                    hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: root.nextMonth()
                }
            }
        }

        // Day headers
        RowLayout {
            Layout.fillWidth: true
            spacing: 0

            Repeater {
                model: root.dayNames
                Text {
                    Layout.fillWidth: true
                    text: modelData
                    font.family: Core.Theme.fontUI
                    font.pixelSize: Core.Theme.fontSize.xs
                    font.weight: Font.DemiBold
                    color: Core.Theme.accentDim
                    horizontalAlignment: Text.AlignHCenter
                }
            }
        }

        // Day grid
        Grid {
            Layout.fillWidth: true
            Layout.fillHeight: true
            columns: 7
            spacing: 2

            Repeater {
                model: {
                    var days = []
                    var firstDay = root.firstDayOfWeek(root.displayMonth, root.displayYear)
                    var totalDays = root.daysInMonth(root.displayMonth, root.displayYear)
                    // Empty cells before first day
                    for (var i = 0; i < firstDay; i++) days.push({ day: 0, idx: i })
                    // Day cells
                    for (var d = 1; d <= totalDays; d++) days.push({ day: d, idx: firstDay + d - 1 })
                    return days
                }

                Rectangle {
                    required property var modelData
                    width: (root.width - 12) / 7
                    height: Math.round(28 * Core.Theme.dpiScale)
                    radius: height / 2  // pill shape
                    color: {
                        if (modelData.day === 0) return "transparent"
                        if (root.isToday(modelData.day)) return Core.Theme.accent
                        return "transparent"
                    }

                    Text {
                        anchors.centerIn: parent
                        text: modelData.day > 0 ? modelData.day : ""
                        font.family: Core.Theme.fontUI
                        font.pixelSize: Core.Theme.fontSize.sm
                        font.weight: root.isToday(modelData.day) ? Font.Bold : Font.Normal
                        color: {
                            if (modelData.day === 0) return "transparent"
                            if (root.isToday(modelData.day)) return Core.Theme.bgBase
                            if (root.isWeekend(modelData.idx)) return Core.Theme.fgMuted
                            return Core.Theme.fgMain
                        }
                    }
                }
            }
        }
    }
}

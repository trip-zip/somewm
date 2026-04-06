import QtQuick
import "../core" as Core

Rectangle {
    property bool vertical: false

    width: vertical ? 1 : undefined
    height: vertical ? undefined : 1
    color: Core.Theme.glassBorder
}

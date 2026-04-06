import QtQuick
import "../core" as Core
import "." as Components

Rectangle {
    color: Core.Theme.bgSurface
    radius: Core.Theme.radius.md

    Behavior on color { Components.CAnim {} }
}

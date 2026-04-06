import QtQuick
import "../core" as Core

Text {
    property string icon: ""
    property int size: Core.Theme.fontSize.xl

    text: icon
    font.family: Core.Theme.fontIcon
    font.pixelSize: size
    color: Core.Theme.fgMain
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
}

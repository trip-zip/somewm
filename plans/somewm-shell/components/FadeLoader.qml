import QtQuick
import "../core" as Core

Loader {
    id: root

    property bool shown: false

    sourceComponent: shown ? content : null
    property Component content: null

    opacity: shown ? 1.0 : 0.0
    Behavior on opacity {
        NumberAnimation {
            duration: Core.Anims.duration.normal
            easing.type: Core.Anims.ease.decel
        }
    }
}

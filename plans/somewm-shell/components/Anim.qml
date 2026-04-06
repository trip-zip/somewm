import QtQuick
import "../core" as Core

NumberAnimation {
    duration: Core.Anims.reducedMotion ? 0 : Core.Anims.duration.normal
    easing.type: Core.Anims.ease.standard
}

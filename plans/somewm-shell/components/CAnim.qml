import QtQuick
import "../core" as Core

ColorAnimation {
    duration: Core.Anims.reducedMotion ? 0 : Core.Anims.duration.normal
    easing.type: Core.Anims.ease.standard
}

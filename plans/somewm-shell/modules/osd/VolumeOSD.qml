import QtQuick
import "../../core" as Core
import "../../services" as Services
import "../../components" as Components

Components.MaterialIcon {
    icon: Services.Audio.icon
    size: Core.Theme.fontSize.xxl
    color: Services.Audio.muted ? Core.Theme.fgMuted : Core.Theme.widgetVolume
}

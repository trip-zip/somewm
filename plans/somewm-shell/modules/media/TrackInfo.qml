import QtQuick
import QtQuick.Layouts
import "../../core" as Core
import "../../services" as Services

ColumnLayout {
    spacing: Core.Theme.spacing.xs

    // Track title
    Text {
        Layout.fillWidth: true
        text: Services.Media.trackTitle || "No media playing"
        font.family: Core.Theme.fontUI
        font.pixelSize: Core.Theme.fontSize.xl
        font.weight: Font.Bold
        color: Core.Theme.fgMain
        elide: Text.ElideRight
        maximumLineCount: 1
    }

    // Artist
    Text {
        Layout.fillWidth: true
        text: Services.Media.trackArtist
        font.family: Core.Theme.fontUI
        font.pixelSize: Core.Theme.fontSize.base
        color: Core.Theme.fgDim
        elide: Text.ElideRight
        maximumLineCount: 1
        visible: text !== ""
    }

    // Album
    Text {
        Layout.fillWidth: true
        text: Services.Media.trackAlbum
        font.family: Core.Theme.fontUI
        font.pixelSize: Core.Theme.fontSize.sm
        color: Core.Theme.fgMuted
        elide: Text.ElideRight
        maximumLineCount: 1
        visible: text !== ""
    }

    // Player identity
    Text {
        text: Services.Media.identity
        font.family: Core.Theme.fontUI
        font.pixelSize: Core.Theme.fontSize.xs
        color: Core.Theme.fgMuted
        visible: text !== ""
    }
}

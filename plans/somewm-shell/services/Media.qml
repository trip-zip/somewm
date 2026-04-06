pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Services.Mpris

Singleton {
    id: root

    // Active player (prefer currently playing, fall back to first available)
    property MprisPlayer player: null
    function _findActivePlayer() {
        var vals = Mpris.players.values
        if (!vals || vals.length === 0) return null
        // Prefer playing player
        for (var i = 0; i < vals.length; i++) {
            if (vals[i].playbackState === MprisPlaybackState.Playing) return vals[i]
        }
        return vals[0]
    }
    function _updatePlayer() { root.player = _findActivePlayer() }
    onPlayerChanged: root.position = root.player ? root.player.position : 0

    // Re-evaluate when player list changes
    Connections {
        target: Mpris.players
        function onObjectInsertedPost() { root._updatePlayer() }
        function onObjectRemovedPost()  { root._updatePlayer() }
    }
    // Re-evaluate periodically (catches playback state changes across players)
    Timer {
        interval: 2000; running: true; repeat: true
        onTriggered: root._updatePlayer()
    }
    Component.onCompleted: _updatePlayer()

    // Convenience properties
    readonly property bool hasPlayer: player !== null
    readonly property string trackTitle: player ? player.trackTitle : ""
    readonly property string trackArtist: player ? player.trackArtist : ""
    readonly property string trackAlbum: player ? player.trackAlbum : ""
    readonly property string artUrl: player ? player.trackArtUrl : ""
    readonly property string identity: player ? player.identity : ""

    // Playback state (Quickshell uses playbackState / MprisPlaybackState)
    readonly property bool isPlaying: player ? player.playbackState === MprisPlaybackState.Playing : false
    readonly property bool canPlay: player ? player.canPlay : false
    readonly property bool canPause: player ? player.canPause : false
    readonly property bool canGoNext: player ? player.canGoNext : false
    readonly property bool canGoPrevious: player ? player.canGoPrevious : false
    readonly property bool canSeek: player ? player.canSeek : false

    // Position tracking
    readonly property real length: player ? player.length : 0
    property real position: 0

    Timer {
        interval: 1000
        running: root.isPlaying
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            if (root.player) root.position = root.player.position
        }
    }

    readonly property real progressPercent: length > 0 ? (position / length) * 100 : 0

    // Format time as mm:ss
    function formatTime(seconds) {
        if (seconds <= 0) return "0:00"
        var m = Math.floor(seconds / 60)
        var s = Math.floor(seconds % 60)
        return m + ":" + (s < 10 ? "0" : "") + s
    }

    readonly property string positionText: formatTime(position)
    readonly property string lengthText: formatTime(length)

    // Controls (Quickshell uses togglePlaying(), next(), previous())
    function playPause() { if (player) player.togglePlaying() }
    function next()      { if (player) player.next() }
    function previous()  { if (player) player.previous() }
    function stop()      { if (player) player.stop() }
    function seek(pos)   { if (player && canSeek) player.position = pos }

    // Seek by percentage (0-100)
    function seekPercent(pct) {
        if (length > 0) seek((pct / 100.0) * length)
    }
}

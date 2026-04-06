pragma Singleton
import QtQuick
import Quickshell

Singleton {
    id: root

    // Current weather
    property string location: ""
    property string condition: ""
    property string conditionIcon: ""
    property int tempC: 0
    property int feelsLikeC: 0
    property int humidity: 0
    property int windKmh: 0
    property string windDir: ""

    // Forecast (array of { date, tempMinC, tempMaxC, condition, icon })
    property var forecast: []

    // Status
    property bool loading: false
    property bool hasData: false
    property string error: ""

    // Cache: refresh every 60 minutes
    property real _lastFetch: 0
    readonly property int _cacheMinutes: 60

    Timer {
        interval: root._cacheMinutes * 60 * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root._fetchWeather()  // Timer fires at interval — skip cache check to avoid drift
    }

    function refresh() {
        var now = Date.now()
        // Skip if cached and recent (manual/IPC refresh respects cache)
        if (_lastFetch > 0 && (now - _lastFetch) < (_cacheMinutes * 60 * 1000 - 5000) && hasData) return
        _fetchWeather()
    }

    function forceRefresh() {
        _lastFetch = 0
        _fetchWeather()
    }

    function _fetchWeather() {
        root.loading = true
        root.error = ""
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            root.loading = false
            if (xhr.status === 200) {
                _parseResponse(xhr.responseText)
            } else {
                root.error = "HTTP " + xhr.status
                root.hasData = false
                console.error("Weather fetch failed:", xhr.status)
            }
        }
        // wttr.in JSON format, metric units
        xhr.open("GET", "https://wttr.in/?format=j1")
        xhr.send()
    }

    function _parseResponse(text) {
        try {
            var data = JSON.parse(text)
            if (!data) return

            // Current conditions
            var cur = data.current_condition[0]
            root.tempC = parseInt(cur.temp_C) || 0
            root.feelsLikeC = parseInt(cur.FeelsLikeC) || 0
            root.humidity = parseInt(cur.humidity) || 0
            root.windKmh = parseInt(cur.windspeedKmph) || 0
            root.windDir = cur.winddir16Point || ""
            root.condition = cur.weatherDesc[0].value || ""

            // Weather code → Material icon
            root.conditionIcon = _weatherIcon(parseInt(cur.weatherCode) || 0)

            // Location
            var area = data.nearest_area[0]
            root.location = (area.areaName[0].value || "") +
                           (area.country[0].value ? ", " + area.country[0].value : "")

            // 3-day forecast
            var fc = []
            data.weather.forEach(function(day) {
                fc.push({
                    date: day.date,
                    tempMinC: parseInt(day.mintempC) || 0,
                    tempMaxC: parseInt(day.maxtempC) || 0,
                    condition: day.hourly[4].weatherDesc[0].value || "",
                    icon: _weatherIcon(parseInt(day.hourly[4].weatherCode) || 0)
                })
            })
            root.forecast = fc
            root.hasData = true
            root._lastFetch = Date.now()
        } catch (e) {
            root.error = "Parse error"
            root.hasData = false
            console.error("Weather parse error:", e)
        }
    }

    // Map wttr.in weather codes to Material Symbols icons
    function _weatherIcon(code) {
        // Sunny/Clear
        if (code === 113) return "\ue81a"  // sunny
        // Partly cloudy
        if (code === 116) return "\uf172"  // partly_cloudy_day
        // Cloudy
        if (code === 119 || code === 122) return "\ue42d"  // cloud
        // Fog/Mist
        if (code === 143 || code === 248 || code === 260) return "\ue818"  // foggy
        // Light rain/drizzle
        if ([176, 263, 266, 293, 296].indexOf(code) >= 0) return "\uf176"  // rainy_light
        // Rain
        if ([299, 302, 305, 308, 356, 359].indexOf(code) >= 0) return "\uf61f"  // rainy
        // Snow
        if ([179, 227, 230, 323, 326, 329, 332, 335, 338, 368, 371, 395].indexOf(code) >= 0)
            return "\ue80f"  // ac_unit (snowflake)
        // Thunderstorm
        if ([200, 386, 389, 392].indexOf(code) >= 0) return "\uf67e"  // thunderstorm
        // Sleet
        if ([182, 185, 281, 284, 311, 314, 317, 320, 350, 362, 365, 374, 377].indexOf(code) >= 0)
            return "\ue818"  // weather_mix
        return "\ue42d"  // cloud (default)
    }
}

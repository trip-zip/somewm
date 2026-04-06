-- No-op preload for somewm-one specs (stubs are in each spec file)
_G.awesome = {
	version = "v9999",
	api_level = 9999,
	connect_signal = function() end,
	emit_signal = function() end,
	restart = function() end,
	quit = function() end,
	lock = function() end,
}

_G.screen = { primary = { geometry = { x = 0, y = 0, width = 1920, height = 1080 } } }
_G.mouse = {}

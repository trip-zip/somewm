-- Check LGI availability and print version
-- Used by meson.build to verify LGI is installed for the detected Lua version

local ok, lgi = pcall(require, 'lgi')
if not ok then
    io.stderr:write("ERROR: lgi module not found\n")
    os.exit(1)
end

local version = require('lgi.version')
print(version)

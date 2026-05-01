---------------------------------------------------------------------------
-- Public preset surface for awful.layout.
--
-- For Clay-native presets, suit.* is a literal table identity to clay.*:
-- `awful.layout.suit.tile == awful.layout.clay.tile`. Existing rc.lua
-- using `tag.layout = awful.layout.suit.tile` continues to work unchanged.
--
-- carousel is still served by its legacy suit/*.lua body because its
-- viewport-relative model isn't flexbox-shaped (see DEVIATIONS).
--
-- @module awful.layout.suit
---------------------------------------------------------------------------

local clay = require("awful.layout.clay")

return {
    tile      = clay.tile,
    fair      = clay.fair,
    max       = clay.max,
    corner    = clay.corner,
    spiral    = clay.spiral,
    floating  = clay.floating,
    magnifier = clay.magnifier,
    carousel  = require("awful.layout.suit.carousel"),
}

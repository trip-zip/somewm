dofile(assert(os.getenv("SOMEWM_TEST_BASE_RC"),
    "SOMEWM_TEST_BASE_RC must point at the base config to load"))

local gears = require("gears")

require("ruled.client").append_rule {
    rule = {},
    properties = {
        shape = function(cr, w, h)
            gears.shape.rounded_rect(cr, w, h, 12)
        end,
    },
}

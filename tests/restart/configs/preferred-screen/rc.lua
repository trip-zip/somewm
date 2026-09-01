-- The default config's screen rule.

dofile(assert(os.getenv("SOMEWM_TEST_BASE_RC"),
    "SOMEWM_TEST_BASE_RC must point at the base config to load"))

require("ruled.client").append_rule {
    rule = {},
    properties = { screen = require("awful").screen.preferred },
}

---------------------------------------------------------------------------
-- This module used to be a "require only" module which, when explicitly
-- required, would allow handle focus when switching tags and other useful
-- corner cases. This code has been migrated to a more standard request::
-- API. The content itself is now in `awful.permissions`. This was required
-- to preserve backward compatibility since this module may or may not have
-- been loaded.
---------------------------------------------------------------------------
require("awful.permissions._common").grant_autofocus()

-- Blocks past the compositor's 10 second config alarm, to exercise the
-- SIGALRM + siglongjmp abort path. Kept free of X11-looking patterns so the
-- config prescan does not reject it before it ever runs.
while true do end

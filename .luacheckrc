-- KOReader runs plugins under LuaJIT with its own module loader, so the
-- only globals a plugin sees beyond the standard library are these.
std = "luajit"
read_globals = { "G_reader_settings", "G_defaults" }
max_line_length = false
-- `_` is gettext throughout, so unused loop variables are named `_` too and
-- shadowing it is deliberate (and called out where it matters). Widget
-- methods are defined with colon syntax (e.g. `function item:onTapSelect()`),
-- which gives each its own implicit `self` that shadows an enclosing method's
-- `self` on purpose.
ignore = {
    "212/self", "211/_.*", "212/_.*", "213/_",
    "421/_", "423/_", "431/_", "432/_",
    "421/self", "423/self", "431/self", "432/self",
}
exclude_files = { "dist/" }

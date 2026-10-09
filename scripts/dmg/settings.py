# dmgbuild settings for the Tsukumo download (scripts/release-mac.sh passes -D app=<path>).
# The window is 900x560 pt on Tsukumo's dark background (make_background.py); the app sits left of the
# pathway and Applications right of it (positions kept in step with make_background.py).
import os
app = defines["app"]  # noqa: F821 (dmgbuild provides `defines`)
here = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() else defines.get("here", ".")  # noqa: F821
format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}
background = os.path.join(defines.get("here", here), "background.tiff")  # noqa: F821
window_rect = ((180, 140), (900, 560))
default_view = "icon-view"
show_status_bar = show_tab_view = show_toolbar = show_pathbar = show_sidebar = False
icon_size = 120
text_size = 13
# The background file is hidden, but Finders that show hidden files would draw it; park it far off in
# the canvas's corner, out of the 900x560 window.
icon_locations = {os.path.basename(app): (260, 352), "Applications": (640, 352), ".background.tiff": (1850, 1140)}

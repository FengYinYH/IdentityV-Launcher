import os

# 离线整包的 Finder 布局：比公开发行版多一份使用说明。
# 图标坐标与背景图（660 × 360，箭头 y=145、底部提示文字 y≈74）对齐，
# 说明放在上方空白区，避免压住箭头和提示文字。
application = os.path.abspath(defines["app"])  # noqa: F821
guide = os.path.abspath(defines["guide"])  # noqa: F821
background_pdf = os.path.abspath(defines["background"])  # noqa: F821
app_name = os.path.basename(application)
guide_name = os.path.basename(guide)

format = "UDZO"
compression_level = 9
filesystem = "HFS+"

files = [application, guide]
symlinks = {"Applications": "/Applications"}

background = background_pdf
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
window_rect = ((160, 180), (660, 360))
default_view = "icon-view"
show_icon_preview = True
include_icon_view_settings = True
include_list_view_settings = False

arrange_by = None
grid_spacing = 80
scroll_position = (0, 0)
label_pos = "bottom"
text_size = 13
icon_size = 112
icon_locations = {
    app_name: (165, 145),
    "Applications": (495, 145),
    guide_name: (330, 285),
}

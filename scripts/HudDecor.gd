extends Control
class_name HudDecor
## 赛博朋克 HUD 装饰层：四角括号 + 屏幕外框 + CRT 扫描线。
##
## 全部用 _draw() 画，不需要任何美术资源 —— 改颜色/尺寸就能换风格。
## 挂成全屏 Control，鼠标过滤设成 IGNORE，否则会挡住底下的按钮。
##
## 用法：
##   var d := HudDecor.new()
##   d.set_anchors_preset(Control.PRESET_FULL_RECT)
##   d.show_scanlines = false      # 结算面板只要括号，不要扫描线
##   root.add_child(d)


@export_group("括号")
@export var bracket_color: Color = Color(0.00, 0.94, 1.00, 0.85)
@export var bracket_len: float = 28.0
@export var bracket_thick: float = 3.0
## 括号距屏幕边缘的距离
@export var inset: float = 16.0
## 四角之间连一条细线，把整个屏幕框起来（关掉就是纯四个角标）
@export var frame_line: bool = true
@export var frame_alpha: float = 0.22

@export_group("扫描线")
@export var show_scanlines: bool = true
## 扫描线的暗度。0.13 比较克制 —— 太大画面会明显发灰。
@export var scan_alpha: float = 0.13
## 每隔几像素一条暗线
@export var scan_step: float = 3.0

@export_group("开关")
@export var show_brackets: bool = true


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	if show_scanlines:
		_draw_scanlines()
	if show_brackets:
		_draw_brackets()


func _draw_scanlines() -> void:
	if scan_step < 1.0:
		return
	var y := 0.0
	var col := Color(0.0, 0.0, 0.0, scan_alpha)
	while y < size.y:
		# 1px 高的暗线，间隔 scan_step —— 模拟 CRT 的隔行扫描
		draw_rect(Rect2(0.0, y, size.x, 1.0), col)
		y += scan_step


func _draw_brackets() -> void:
	var s := size
	var fc := Color(bracket_color.r, bracket_color.g, bracket_color.b, frame_alpha)

	# 细外框：贴着括号内侧画一圈，把 HUD 区域「框」出来
	if frame_line:
		draw_rect(Rect2(inset, inset, s.x - inset * 2.0, 1.0), fc)
		draw_rect(Rect2(inset, s.y - inset - 1.0, s.x - inset * 2.0, 1.0), fc)
		draw_rect(Rect2(inset, inset, 1.0, s.y - inset * 2.0), fc)
		draw_rect(Rect2(s.x - inset - 1.0, inset, 1.0, s.y - inset * 2.0), fc)

	# 四角的 L 形括号。比整圈实线更像「HUD 取景框」，
	# 而且不会把画面整个围死。
	# 符号对写成两个局部变量而不是数组常量 ——
	# 无类型数组迭代出来是 Variant，会让下面的算术退化成 Variant 运算。
	var signs := [-1.0, 1.0]
	for sx_v in signs:
		for sy_v in signs:
			var sx: float = float(sx_v)
			var sy: float = float(sy_v)
			var ox := inset if sx < 0.0 else s.x - inset
			var oy := inset if sy < 0.0 else s.y - inset
			# 横腿
			draw_rect(Rect2(minf(ox, ox + bracket_len * sx), oy - bracket_thick * 0.5,
					bracket_len, bracket_thick), bracket_color)
			# 竖腿
			draw_rect(Rect2(ox - bracket_thick * 0.5, minf(oy, oy + bracket_len * sy),
					bracket_thick, bracket_len), bracket_color)

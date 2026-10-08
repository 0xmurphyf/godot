extends Control
class_name VirtualButton
## 虚拟按键里的单个按钮。
##
## 单独一个文件而不是放在 VirtualPad.gd 里做内部类 ——
## 内部类在部分 Godot 版本上会触发解析问题，拆开最稳。
##
## 外观全部 _draw() 出来，零美术资源。
## 半透明是必须的：这游戏的躲招全靠看地面上的动作，
## 不透明的按钮会把画面糊死。

## 平时半透明，按下去变亮。
## 只用描边变化的话，手指按住按钮时自己就看不见反馈了，
## 所以按下时内部还压一层亮色。
const ALPHA_IDLE := 0.30
const ALPHA_HELD := 0.62
const ALPHA_INNER := 0.24

var action: String = ""
var glyph: String = ""
var accent: Color = Color(0.00, 0.92, 1.00)
var held: bool = false

var _label: Label


func setup(a: String, g: String, col: Color, font_size: int) -> void:
	action = a
	glyph = g
	accent = col
	# IGNORE：命中测试统一由 VirtualPad._input() 算，
	# 按钮自己不参与 GUI 命中，这样也不会挡住底下的 HUD 按钮。
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE

	_label = Label.new()
	_label.text = g
	_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_font_size_override("font_size", font_size)
	_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.92))
	add_child(_label)


func set_held(on: bool) -> void:
	if held == on:
		return
	held = on
	queue_redraw()


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	var a: float = ALPHA_HELD if held else ALPHA_IDLE
	# 方角。CanvasItem.draw_rect() 没有圆角参数
	# （Godot 4 的 width 只在 filled=false 时是线宽），
	# 想要圆角得上 StyleBox —— 虚拟按键不值得为此多套一层。
	draw_rect(r, Color(accent.r, accent.g, accent.b, a))
	var edge_a: float = 0.95 if held else 0.50
	draw_rect(r, Color(accent.r, accent.g, accent.b, edge_a), false, 2.0)
	if held:
		draw_rect(r.grow(-6.0), Color(accent.r, accent.g, accent.b, ALPHA_INNER))

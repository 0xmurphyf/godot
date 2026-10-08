extends Node2D
class_name Arena
## 背景：赛博朋克城市（art/bg_city.png）+ 暗角 + 环境浮尘。
##
## 贴图是用户提供的城市夜景，原样使用 —— 不降饱和、不压暗、不量化、
## 不画地面线。只做了尺寸适配（缩到 1152x648，见 tools/gen_bg.py）。

## 地面在世界坐标里的 y。Boss 画地面预警时要换算到自己的局部坐标，所以对外暴露。
const GROUND_Y := 560.0
const WIDTH := 1152.0
const HEIGHT := 648.0

## 暗角：四角压暗，把注意力收到中间。
## 只画四条边的渐变带（不是整屏叠一层），开销很小。
##
## **默认关闭**：贴图是用户提供的原图，逐像素未做任何改动。
## 叠暗角和浮尘之后画面会「发闷」，看着不像原图 —— 要的就是原图本身。
## 想加氛围就在检查器里打开这两个开关，不需要改代码。
@export var vignette := false
@export var vignette_color: Color = Color(0.02, 0.02, 0.06, 0.55)
@export var vignette_size := 130.0
## 环境浮尘开关（同上，默认关闭）
@export var ambient_motes := false


func _ready() -> void:
	z_index = -10
	var sp := Sprite2D.new()
	sp.texture = preload("res://art/bg_city.png")
	sp.centered = false            # 左上角对齐 (0,0)，跟视口原点一致
	sp.position = Vector2.ZERO
	# 用线性过滤：原图是连续色调的绘制稿，不是整数倍关系的小像素画，
	# NEAREST 会出现不规则锯齿和丢行。角色美术才是 NEAREST 的场合。
	sp.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	sp.z_index = -1
	add_child(sp)

	if ambient_motes:
		AmbientFx.attach(self, WIDTH, HEIGHT)


func _draw() -> void:
	if not vignette:
		return
	# 上下左右四条渐变带。每带画 8 层矩形，从边缘的 alpha 渐变到 0。
	# 用分层矩形而不是 shader —— 没有 shader 依赖，改颜色/宽度立刻生效。
	var layers := 8
	var s := vignette_size
	var a0 := vignette_color.a
	for i in layers:
		var k := float(i) / float(layers)
		var t := s * (1.0 - k) / float(layers)      # 每层的厚度
		var a := a0 * k * k                          # 越往内衰减越快
		var c := Color(vignette_color.r, vignette_color.g, vignette_color.b, a)
		var off := s * k
		# 上
		draw_rect(Rect2(0.0, off, WIDTH, t + 1.0), c)
		# 下
		draw_rect(Rect2(0.0, HEIGHT - off - t, WIDTH, t + 1.0), c)
		# 左
		draw_rect(Rect2(off, 0.0, t + 1.0, HEIGHT), c)
		# 右
		draw_rect(Rect2(WIDTH - off - t, 0.0, t + 1.0, HEIGHT), c)

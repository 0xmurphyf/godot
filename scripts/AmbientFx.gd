extends Node2D
class_name AmbientFx
## 环境浮尘：缓慢上飘的光点。
##
## 为什么需要：静态背景 + 两个角色 = 画面很「死」。
## 几十个缓慢移动的微光点就能让场景活起来，而且几乎不占性能
## （纯 draw_circle，没有粒子节点）。
##
## 刻意做得很淡（alpha 0.10~0.30）—— 它是氛围，不能抢角色的视觉焦点。

const N := 46
var mote_color := Color(0.62, 0.78, 1.0)
var _x: Array[float] = []
var _y: Array[float] = []
var _sp: Array[float] = []
var _r: Array[float] = []
var _t := 0.0

var w := 1152.0
var h := 648.0


static func attach(parent: Node, vw: float, vh: float) -> AmbientFx:
	var a := AmbientFx.new()
	a.w = vw
	a.h = vh
	a.z_index = -5              # 在角色之下、背景之上
	parent.add_child(a)
	return a


func _ready() -> void:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for i in N:
		_x.append(rng.randf_range(0.0, w))
		_y.append(rng.randf_range(0.0, h))
		_sp.append(rng.randf_range(4.0, 17.0))
		_r.append(rng.randf_range(0.8, 2.2))
	set_process(true)


func _process(delta: float) -> void:
	_t += delta
	for i in N:
		_y[i] -= _sp[i] * delta
		_x[i] += sin(_t * 0.35 + float(i)) * 5.0 * delta
		if _y[i] < -4.0:
			_y[i] = h + 4.0
			# fmod 不是 fmodf —— 本项目的 Godot 版本没有 fmodf（跟 sinf 一样）
			_x[i] = fmod(_x[i] + 137.0, w)
	queue_redraw()


func _draw() -> void:
	for i in N:
		# 越靠近顶部越淡，模拟景深
		var depth: float = 1.0 - _y[i] / h
		var a := 0.10 + depth * 0.20
		var fade: float = 0.55 + 0.45 * sin(_t * 1.1 + float(i) * 0.7)
		draw_circle(Vector2(_x[i], _y[i]), _r[i],
				Color(mote_color.r, mote_color.g, mote_color.b, a * fade))

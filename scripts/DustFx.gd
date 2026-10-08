extends Node2D
class_name DustFx
## 落地 / 起步扬尘：贴地往两侧散开的低矮尘团。
##
## 为什么需要：角色从空中砸下来，如果「碰到地面就停」，
## 缺少重量感。扬尘是最便宜的重量提示 —— 几行代码就有。
##
## 用法：DustFx.spawn(parent, 地面y, 强度)

const PUFF_N := 8
var dur := 0.42
var puff_color := Color(0.72, 0.66, 0.62, 0.55)
var strength := 1.0
var _t := 0.0
var _p: Array[Vector2] = []
var _v: Array[Vector2] = []
var _r: Array[float] = []


static func spawn(parent: Node, pos: Vector2, s: float = 1.0) -> DustFx:
	var d := DustFx.new()
	d.position = pos
	d.strength = s
	parent.add_child(d)
	return d


func _ready() -> void:
	for i in PUFF_N:
		var k := float(i) / float(maxi(PUFF_N - 1, 1))
		var side := -1.0 if i % 2 == 0 else 1.0
		_p.append(Vector2.ZERO)
		_v.append(Vector2(side * lerpf(30.0, 120.0, k) * strength,
				-lerpf(10.0, 46.0, k) * strength))
		_r.append(lerpf(3.5, 9.0, k) * strength)
	set_process(true)


func _process(delta: float) -> void:
	_t += delta
	for i in _p.size():
		var v: Vector2 = _v[i]
		v.x = move_toward(v.x, 0.0, 220.0 * delta)
		v.y += 120.0 * delta
		_v[i] = v
		_p[i] = _p[i] + v * delta
	if _t >= dur:
		queue_free()
		return
	queue_redraw()


func _draw() -> void:
	var t := clampf(_t / dur, 0.0, 1.0)
	for i in _p.size():
		var a := (1.0 - t) * puff_color.a
		if a <= 0.002:
			continue
		var rr := _r[i] * (1.0 + t * 0.8)
		draw_circle(_p[i], rr, Color(puff_color.r, puff_color.g, puff_color.b, a))

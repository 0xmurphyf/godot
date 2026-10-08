extends Node2D
class_name TrailFx
## 残影拖尾：每隔一小段时间复制一次角色的精灵，留下逐渐淡出的影子。
##
## 冲拳 / 翻滚 / 闪现这类「高速位移」用得上：
## 纯靠动画帧的话，60fps 下高速移动会显得一格一格跳，
## 残影把中间的空隙补上，速度感立刻出来。
##
## 用法：TrailFx.attach(sprite, 颜色, 时长)  或  TrailFx.burst(sprite, n)

const MAX_GHOSTS := 10

var interval := 0.045          # 每隔多久留一个影子（秒）
var life := 0.28               # 单个影子存活时长
var ghost_color := Color(0.55, 0.80, 1.0, 0.42)
var _timer := 0.0
var _src: AnimatedSprite2D = null
var _ghosts: Array[Dictionary] = []
var _active := false


static func attach(src: AnimatedSprite2D, col: Color,
		sec: float = 0.28, iv: float = 0.045, parent: Node = null) -> TrailFx:
	var t := TrailFx.new()
	t._src = src
	t.ghost_color = col
	t.life = sec
	t.interval = iv
	t._active = true
	# 挂在源精灵的父节点上，坐标系跟角色一致
	var host: Node = parent if parent != null else (src.get_parent() if src else null)
	if host != null:
		host.add_child(t)
	return t


func _process(delta: float) -> void:
	# 注意：stop() 之后**不能**直接 return。
	#
	# 之前这里写的是 `if not _active: return` —— 结果是招式结束调用 stop()
	# 后，_ghosts 里的影子再也不会被计时推进，同时再也没有 queue_redraw()，
	# 于是最后几帧的残影**永远定在屏幕上不消失**（画面上一直糊着几个影子）。
	# 正确做法：停止只代表「不再产生新影子」，已有的要继续淡出，
	# 全部淡完再把自己从场景树里摘掉。
	if _active and _src != null and is_instance_valid(_src):
		_timer -= delta
		if _timer <= 0.0:
			_timer = interval
			_emit()

	# 无论是否 active，已有的影子都要继续老化
	var keep: Array[Dictionary] = []
	for g in _ghosts:
		var nt := float(g["t"]) + delta
		if nt < life:
			g["t"] = nt
			keep.append(g)
	_ghosts = keep

	if not _active and _ghosts.is_empty():
		# 停止且影子全部淡出 —— 节点使命完成，自动回收，不留空节点
		queue_free()
		return
	queue_redraw()


## 停掉拖尾（招式结束时调）。已有影子继续淡出，不会突然消失。
func stop() -> void:
	_active = false


func _emit() -> void:
	_ghosts.append({
		"tex": _src.sprite_frames.get_frame_texture(
				_src.animation, _src.frame),
		"pos": _src.position,
		"scale": _src.scale,
		"flip": _src.flip_h,
		"rot": _src.rotation,
		"t": 0.0,
	})
	if _ghosts.size() > MAX_GHOSTS:
		_ghosts.remove_at(0)


func _draw() -> void:
	for g in _ghosts:
		var k := clampf(float(g["t"]) / life, 0.0, 1.0)
		var a := (1.0 - k) * ghost_color.a
		if a <= 0.002:
			continue
		var tex: Texture2D = g["tex"]
		if tex == null:
			continue
		var c := ghost_color
		c.a = a
		var s: Vector2 = g["scale"]
		s.x = absf(s.x) * (-1.0 if bool(g["flip"]) else 1.0)
		draw_set_transform(Vector2(g["pos"]), float(g["rot"]), s)
		draw_texture(tex, -tex.get_size() * 0.5, c)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

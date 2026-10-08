extends Node2D
class_name HitFx
## 命中特效：冲击环 + 火花 + 碎片 + 中心闪光。
##
## 全部用代码画，不依赖美术资源 —— 改配色/尺寸只动常量。
## 一次性：播完自己 queue_free()，不需要外部管理。
##
## 为什么需要它：命中反馈原本只有顿帧 + 音效，缺「视觉确认」。
## 打中了但画面没变化，玩家会怀疑到底有没有打中。

# ============================================================
# 调参
# ============================================================
const RING_FROM := 6.0
const RING_TO := 34.0
const SPARK_N := 7
const SPARK_LEN := 16.0
const SPARK_MIN := 8.0
const SPARK_MAX := 26.0
## 新增：碎片数量。带重力的实心小方块，比火花更有「实体被打到」的感觉。
const DEBRIS_N := 5
const DEBRIS_GRAV := 900.0
const DEBRIS_MIN := 12.0
const DEBRIS_MAX := 30.0

## 冲击环颜色（默认偏白，命中时会被染成对应颜色）
var ring_color := Color(1.0, 0.95, 0.80, 1.0)
## 整体时长（秒）
var dur := 0.26
## 冲击方向：火花会往这个方向的反面喷（1 = 攻击往右，火花往左散）
var dir := 1
## 尺寸倍率：击飞 / 大招可以传更大的值
var scale_fx := 1.0
## 碎片开关。小伤害关掉省得画面太碎。
var debris_enabled := true

var _t := 0.0
var _seeds: Array[float] = []
var _debris: Array[Dictionary] = []


func _ready() -> void:
	for i in SPARK_N:
		# 固定伪随机（不用 randf，保证同一特效每次形状一致，方便调试比对）
		_seeds.append(fmod(float(i) * 0.61803398875, 1.0))
	if debris_enabled:
		for i in DEBRIS_N:
			var s := fmod(float(i) * 0.41421356 + 0.13, 1.0)
			var base := PI if dir > 0 else 0.0
			var ang := base + (s - 0.5) * 2.0
			var sp := lerpf(DEBRIS_MIN, DEBRIS_MAX, s)
			_debris.append({
				"v": Vector2.from_angle(ang) * sp * scale_fx,
				"p": Vector2.ZERO,
				"sz": lerpf(2.0, 4.5, s) * scale_fx,
				"spin": (s - 0.5) * 12.0,
				"rot": 0.0,
			})
	set_process(true)


## 便捷构造：在 pos 处放一个特效。返回实例，方便再调参。
static func spawn(parent: Node, pos: Vector2, col: Color,
		fx_dir: int = 1, size: float = 1.0) -> HitFx:
	var fx := HitFx.new()
	fx.position = pos
	fx.ring_color = col
	fx.dir = fx_dir
	fx.scale_fx = size
	parent.add_child(fx)
	return fx


func _process(delta: float) -> void:
	_t += delta
	# 碎片用真实 delta 步进（不是 _t 的归一化），才有正常重力感
	for d in _debris:
		var v: Vector2 = d["v"]
		v.y += DEBRIS_GRAV * delta
		d["v"] = v
		var p: Vector2 = d["p"]
		d["p"] = p + v * delta
		d["rot"] = float(d["rot"]) + float(d["spin"]) * delta
	if _t >= dur:
		queue_free()
		return
	queue_redraw()


func _draw() -> void:
	var t := clampf(_t / dur, 0.0, 1.0)
	# 冲击环：先快后慢地扩张，同时淡出
	var e := 1.0 - pow(1.0 - t, 3.0)       # ease-out cubic
	var r := lerpf(RING_FROM, RING_TO * scale_fx, e)
	var a := 1.0 - t
	if r > 0.5:
		draw_arc(Vector2.ZERO, r, 0.0, TAU, 20,
				Color(ring_color.r, ring_color.g, ring_color.b, a), 3.0 * scale_fx, true)

	# 第二层环：更慢、更淡，做出「余波」
	if t > 0.12:
		var t2 := (t - 0.12) / 0.88
		var r2 := lerpf(RING_FROM, RING_TO * 0.62 * scale_fx, 1.0 - pow(1.0 - t2, 2.0))
		draw_arc(Vector2.ZERO, r2, 0.0, TAU, 16,
				Color(ring_color.r, ring_color.g, ring_color.b, (1.0 - t2) * 0.35),
				1.5 * scale_fx, true)

	# 中心闪光球：只在最开始两帧存在，负责「啪」的一下
	if t < 0.35:
		var fa := 1.0 - t / 0.35
		draw_circle(Vector2.ZERO, 9.0 * scale_fx * fa,
				Color(ring_color.r, ring_color.g, ring_color.b, fa * 0.85))

	# 火花：往攻击的反方向扇形喷出
	var sp := clampf(t / 0.7, 0.0, 1.0)
	if sp < 1.0:
		for i in SPARK_N:
			var s := _seeds[i]
			var base := PI if dir > 0 else 0.0
			var ang := base + (s - 0.5) * 2.44
			var r0 := lerpf(SPARK_MIN, SPARK_MAX, s) * scale_fx
			var r1 := r0 + SPARK_LEN * scale_fx * sp
			var c := Color(ring_color.r, ring_color.g, ring_color.b, (1.0 - sp) * 0.9)
			draw_line(Vector2.from_angle(ang) * r0,
					Vector2.from_angle(ang) * r1, c, 2.5 * scale_fx, true)

	# 碎片：带重力的实心小方块，落地前一直存在
	for d in _debris:
		var dp: Vector2 = d["p"]
		var sz: float = d["sz"]
		var fade := clampf(1.0 - t * 1.15, 0.0, 1.0)
		if fade <= 0.0:
			continue
		# 画旋转方块：直接算四个顶点，不用 Sprite（省节点、省资源）
		var ang: float = d["rot"]
		var pts := PackedVector2Array()
		for k in 4:
			var ca := ang + k * PI * 0.5 + PI * 0.25
			pts.append(dp + Vector2.from_angle(ca) * sz * 0.72)
		draw_colored_polygon(pts,
				Color(ring_color.r, ring_color.g, ring_color.b, fade * 0.85))

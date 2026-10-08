extends Node2D
class_name DamageNumber
## 伤害飘字：数字向上飘一小段然后淡出。
##
## 作用：血条只看得到「变短了」，看不出这一下打了多少。
## 尤其 Boss 999 血、玩家 53 伤害，血条只动一点点，反馈很弱。
##
## 一次性节点，播完自己 queue_free()。

const RISE := 34.0        # 上飘距离（像素）
const HOLD := 0.18        # 先原地停一小会儿（让数字看得清）
const RISE_T := 0.42      # 上飘 + 淡出的时长
const POP := 1.5          # 出现瞬间的放大倍率

var amount := 0
var base_color := Color(1.0, 0.92, 0.55, 1.0)
var _t := 0.0
var _y0 := 0.0
var _label: Label


static func spawn(parent: Node, pos: Vector2, amt: int, col: Color) -> DamageNumber:
	var dn := DamageNumber.new()
	dn.position = pos
	dn.amount = amt
	dn.base_color = col
	parent.add_child(dn)
	return dn


func _ready() -> void:
	# _ready 在 add_child 之后才跑，此时 position 已经被 spawn 设好了，
	# 必须在这里把初始 y 存下来 —— 否则 _process 第一帧就会把它写回 0。
	_y0 = position.y
	_label = Label.new()
	_label.text = str(amount)
	_label.add_theme_font_size_override("font_size", 26)
	_label.add_theme_color_override("font_color", base_color)
	# 描边：浅色数字压在浅色背景上会看不清
	_label.add_theme_color_override("font_outline_color", Color(0.05, 0.04, 0.08, 1.0))
	_label.add_theme_constant_override("outline_size", 6)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.position = Vector2(-40.0, -16.0)
	_label.size = Vector2(80.0, 32.0)
	add_child(_label)
	set_process(true)


func _process(delta: float) -> void:
	_t += delta
	var total := HOLD + RISE_T
	if _t >= total:
		queue_free()
		return

	# 出现瞬间弹一下（POP -> 1.0），数字更"跳"
	var pop := 1.0
	if _t < 0.08:
		pop = lerpf(POP, 1.0, _t / 0.08)

	var rise := 0.0
	var alpha := 1.0
	if _t > HOLD:
		var k := (_t - HOLD) / RISE_T
		rise = -RISE * (1.0 - pow(1.0 - k, 2.0))    # ease-out
		alpha = 1.0 - k

	position.y = _y0 + rise
	scale = Vector2(pop, pop)
	if _label != null:
		_label.modulate = Color(1, 1, 1, alpha)

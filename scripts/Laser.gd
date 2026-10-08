extends Area2D
class_name Laser
## 全图炮的激光实体。
##
## 跟 Bullet 一样由 FrameActor._apply_spawn() 生成，靠 hurt_mask 决定打谁
## （这里是 8 = player_hurtbox）。区别：
##   - Bullet 是「飞行物」，自己会跑
##   - Laser 是「固定的一道光」，长度固定、一次性伤害、播完动画就消失
##
## 视觉与判定严格对齐：判定框就是这条光的范围，画多大打多大。

@export var damage := 30
@export var knockback := 420.0
@export var reach := 1200.0          # 长度（要够覆盖全场，见 boss_cannon 注释）
@export var beam_h := 110.0          # 高度
@export var hurt_mask := 8
@export var life := 0.78             # 略长于动画（总 duration 8.75 @ speed 12 = 0.73s）
@export var hitstop := 7

# 源图 128x128，光束内容满宽；竖直方向的实际高度是 23px（bbox 53..76）
const TEX := 128.0
const TEX_BEAM_H := 23.0

var dir := 1
var _hit := false
var _t := 0.0

@onready var sprite: AnimatedSprite2D = $Sprite
@onready var shape_node: CollisionShape2D = $CollisionShape2D


## 由 _apply_spawn() 在 add_child 之前调用 —— 此时 @onready 还没生效，
## 所以只存参数，真正的布局放到 _ready() 里做。
func setup(d: int, dmg: int, kb: float) -> void:
	dir = d
	if dmg > 0:
		damage = dmg
	if kb > 0.0:
		knockback = kb


func _ready() -> void:
	collision_mask = hurt_mask
	area_entered.connect(_on_area_entered)
	add_to_group("bullet")            # 结算时跟子弹一起被清掉
	_layout()
	if sprite != null and sprite.sprite_frames != null:
		sprite.play("beam")


## 把判定框和精灵都摆成「从原点朝 dir 伸出 reach」的一条横带。
## 两者必须完全重合，否则会出现「看着躲开了却被打到」。
func _layout() -> void:
	var cx := reach * 0.5 * float(dir)
	if shape_node != null:
		var rs := shape_node.shape as RectangleShape2D
		if rs != null:
			rs.size = Vector2(reach, beam_h)
		shape_node.position = Vector2(cx, 0.0)
	if sprite != null:
		sprite.position = Vector2(cx, 0.0)
		# 非等比拉伸：横向拉到 reach，纵向拉到 beam_h。
		# 光束是纯色矩形条，拉伸不会有形变瑕疵。
		sprite.scale = Vector2(reach / TEX, beam_h / TEX_BEAM_H)
		# 让较亮的「炮口端」始终朝向 Boss：dir<0 时水平翻转
		sprite.flip_h = dir < 0


func _physics_process(delta: float) -> void:
	_t += delta
	if _t >= life:
		queue_free()


func _on_area_entered(area: Area2D) -> void:
	# 一道激光只结算一次，之后虽然还在淡出但不再造成伤害
	if _hit:
		return
	var other := area.get_parent()
	if other == null or not other.has_method("take_damage"):
		return
	var landed: bool = other.take_damage(damage, dir, knockback, hitstop)
	if landed:
		_hit = true

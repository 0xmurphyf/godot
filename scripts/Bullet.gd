extends Area2D
class_name Bullet
## 子弹。玩家 / Boss 共用同一份脚本，靠 hurt_mask 区分打谁。
##
##   玩家子弹  Bullet.tscn       hurt_mask = 16 (boss_hurtbox)   绿色
##   Boss 子弹 BulletEnemy.tscn  hurt_mask = 8  (player_hurtbox)  红色

@export var speed := 1000.0
@export var damage := 16
@export var knockback := 120.0
@export var life := 1.4
@export var min_x := -20.0
@export var max_x := 1172.0
## 打谁：16 = boss_hurtbox（玩家子弹），8 = player_hurtbox（Boss 子弹）
@export var hurt_mask := 16

@onready var sprite: Sprite2D = $Sprite

var dir := 1
var _t := 0.0
var _hit := false


## 由 FrameActor._apply_spawn() 调用
func setup(d: int, dmg: int, kb: float) -> void:
	dir = d
	if dmg > 0:
		damage = dmg
	if kb > 0.0:
		knockback = kb
	collision_mask = hurt_mask
	if sprite != null:
		sprite.flip_h = dir < 0


func _ready() -> void:
	collision_mask = hurt_mask
	area_entered.connect(_on_area_entered)
	add_to_group("bullet")


func _physics_process(delta: float) -> void:
	if _hit:
		return
	position.x += speed * float(dir) * delta
	_t += delta
	if _t >= life or position.x < min_x or position.x > max_x:
		# 飞到边界/超时消失时播一声闷响。
		# 之前子弹打在墙上完全无声 —— 明明看到子弹过去了，
		# 却不知道它是飞出界还是打中墙，反馈缺一块。
		if position.x >= min_x and position.x <= max_x:
			Sfx.play("wall_hit", 0.0, 1.0, true)
		queue_free()


func _on_area_entered(area: Area2D) -> void:
	if _hit:
		return
	_hit = true
	var other := area.get_parent()
	var landed := false
	if other != null and other.has_method("take_damage"):
		# take_damage 返回 false = 无敌 / 已死，子弹不该消失，继续飞过去
		landed = other.take_damage(damage, dir, knockback, 0)
	if landed:
		_hit = true
		queue_free()
	else:
		# 没打中就恢复，让它继续飞
		_hit = false

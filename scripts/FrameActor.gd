extends CharacterBody2D
class_name FrameActor
## ============================================================
## 帧数据解释器 —— 对应 LF2 的帧状态机
##
## 这个文件只认识「第几帧 / 持续多久 / 下一帧去哪」，
## 完全不认识「冲拳」「闪现砸」这些具体招式。
## 所有招式都在 AttackData 资源里，加招式 = 加数据，本文件不动。
## ============================================================

signal health_changed(current: int, maximum: int)
signal damage_taken(amount: int, remain: int)   # remain <= 0 -> dead, drives the result screen
signal died
signal frame_changed(index: int, frame: FrameData)
signal move_started(move: AttackData)
signal move_finished(move: AttackData)
## 由 Boss 在「击飞成功」时触发，用于招式结束后接管行动（如后撤）
signal launched_player(move: AttackData)
signal teleported(to: Vector2)

@export var max_health := 100
@export var gravity := 1900.0
@export var iframe_ticks := 54          # 无敌帧数（60fps 下 54 = 0.9 秒）

@export_group("死亡演出")
## 死亡时连续爆几次（冲击环 + 闪白）。0 = 关闭。
@export_range(0, 12, 1) var death_fx_bursts := 5
## 两次爆炸的间隔（秒，真实时间 —— 不受慢动作影响）
@export var death_fx_interval := 0.16
@export var death_fx_first_scale := 0.9
@export var death_fx_last_scale := 2.2
@export var death_fx_color: Color = Color(1.0, 0.86, 0.42, 1.0)
## 每次爆炸时闪白多久
@export var death_flash_sec := 0.12
var death_flash_t := 0.0

@export_group("命中特效")
## 命中时在受击者身上画冲击环 + 火花。
## 原本只有顿帧和音效，缺视觉确认 —— 打中了画面没变化，会怀疑有没有打中。
@export var hit_fx_enabled := true
## 特效画在身体中心的高度（像素）。取身体高的一半即可。
@export var hit_fx_body_h := 106.0
## 敌人受击的特效颜色（偏白黄）
## 玩家受击不画特效（见 _spawn_hit_fx），所以没有玩家用的颜色。
@export var hit_fx_color_enemy: Color = Color(1.0, 0.94, 0.72, 1.0)
## 击退达到这个值就放大特效（击飞用）。放在基类是因为特效也在这里生成。
const LAUNCH_FX_KB := 900.0
# 受击后是否进入无敌。关掉 = 每一发都吃满，连击不会被吞。
# 翻滚的无敌不受这个开关影响 —— 那是主动闪避，跟受伤无关。
@export var hurt_invincible := true
@export var moves: Array[AttackData] = []
@export var min_x := 40.0
@export var max_x := 1112.0
@export var ceil_y := 180.0             # 闪现最高能到多高（防止飞出屏幕）

@onready var sprite: AnimatedSprite2D = $Sprite
@onready var hitbox: Area2D = $Hitbox
@onready var hitbox_shape: CollisionShape2D = $Hitbox/CollisionShape2D

var health := 0
var facing := 1
var current: AttackData = null
var frame_index := 0
var frame_ticks := 0                    # 已在当前帧停留的 tick 数
var frame_timer := 0                    # 当前帧剩余 tick 数

# ---- 逻辑帧推进（倍速/慢放安全的根基）----
#
# 招式的 duration、hitstop、iframe 全部以「60fps 下的帧数」为单位。
# 原本是每物理帧固定 +1/-1，但物理帧的调用频率是恒定的 ——
# 一旦改 Engine.time_scale 做慢放：
#     移动   velocity * delta   -> 变慢 ✓
#     动画   AnimatedSprite2D   -> 按 delta 变慢 ✓
#     招式   frame_timer -= 1   -> 【不变慢】✗
# 于是前摇/判定/后摇按原速走，画面却是慢的，动作和判定整个对不上。
#
# 修法：不按「物理帧次数」推进，改成按「累积的逻辑时间」推进。
# 正常速度下每物理帧刚好产出 1 个 tick，行为与之前完全一致；
# time_scale = 0.5 时隔一帧才产出 1 个，招式跟着一起变慢。
const FIXED_DT := 1.0 / 60.0
var _tick_acc := 0.0
var ticks := 1                          # 本物理帧应推进的逻辑帧数（0 或 1）
var current_damage := 0
var current_knockback := 0.0
var hit_landed := false
## 本招【到目前为止】是否命中过。与 hit_landed 的区别：
## hit_landed 每次 _advance 都重置（用来防同一招多次命中），
## 这个只在 play() 重置 —— 用来在招式末尾判断「这招到底打到人没有」。
var move_hit := false
## 连发计数（配合 FrameData.chain_next / AttackData.chain_min|max）。
## _chain_done = 本次招式已经完成的「连击段数」（第一下完成后 = 1）；
## _chain_max  = 本次招式允许的最大段数，play() 时随机（招式级，实例上存）。
var _chain_done := 0
var _chain_max := 0
var iframe_t := 0
@export_group("受击反馈")
## 受击闪光持续多久（秒）
@export var hurt_flash_sec := 0.18
## 玩家受击闪红
@export var hurt_flash_red: Color = Color(1.0, 0.32, 0.32, 1.0)
## Boss 受击闪白。用 1.45 过曝是刻意的：一阶段 Boss 本身就是白的，
## Color(1,1,1) 叠上去完全看不出变化，稍微过曝才读得出「闪了一下」。
@export var hurt_flash_white: Color = Color(1.45, 1.45, 1.45, 1.0)

## 落地时的震屏强度倍率。0 = 完全不震。
##
## 玩家设成 0：镜头是跟着玩家的（见 Main._build_camera），
## 玩家自己落地还震屏，会让整个画面在跑动时一直抖，很难受。
## Boss 落地（闪现砸）保留 —— 那是需要"地面被砸了一下"的重量感。
@export_range(0.0, 2.0) var land_shake_scale := 1.0

var hurt_flash_t := 0.0
var dead := false
var frozen := false                     # 战斗结束：停止一切行动与物理
## 「站着喘气」：战斗结束了，但胜者还在播 idle 呼吸，不定格。
##
## 跟 frozen 的区别只有一个：不把 speed_scale 归零。
## frozen 会让动画停在当前帧 —— 败者演出结束后定住是对的，
## 但胜者定格看着像游戏卡了，所以胜者用这个。
var standby := false
var hitstop_t := 0                      # 命中顿帧：>0 时整个角色冻结
var pending_next := -1                  # 上帧命中了玩家 → 本帧改道
var landing_x := 0.0                    # 落点锁定（世界 x）：进入闪现帧那一刻记录玩家位置
var _trail: TrailFx = null               # 高速位移时的残影（见 _start_trail）
                                        # 之后不再更新 —— 玩家跑开就真的躲掉了
var _box := RectangleShape2D.new()
var attack_dir := 1                     # 开判定那一刻锁定的朝向 —— 击飞方向以它为准
                                        # 不用实时 facing：命中回调可能晚于朝向变化

# 实时显示 hitbox / hurtbox（调试）。static = 所有角色共用一个开关，
# 按 F1 或 B 切换（见 Main._unhandled_input）。
static var show_boxes := false


@onready var hurtbox: Area2D = $Hurtbox
@onready var hurtbox_shape: CollisionShape2D = $Hurtbox/CollisionShape2D

# 场景里的默认 hurtbox，供每帧覆盖后还原
var _hurt_def_area_pos := Vector2.ZERO
var _hurt_def_shape_pos := Vector2.ZERO
var _hurt_def_size := Vector2.ZERO
var _hurt_def_set := false


func _ready() -> void:
	hitbox_shape.shape = _box
	hitbox_shape.disabled = true
	hitbox.area_entered.connect(_on_hitbox_entered)
	health = max_health
	# 自动适配美术：缩放 + 摆位都从资源实测。
	# 换一套尺寸 / 比例 / 脚底位置都不同的美术，角色依然站在地上、大小合适，
	# 不用改代码也不用去 .tscn 里手改 position —— 这里会覆盖它。
	if sprite != null and sprite.sprite_frames != null:
		var fit := art_fit(sprite.sprite_frames)
		sprite.scale = Vector2(fit["scale"], fit["scale"])
		sprite.position = fit["offset"]
	_remember_default_hurtbox()


## 记下场景里配的 hurtbox，供「某些帧临时改受击框」之后还原。
func _remember_default_hurtbox() -> void:
	if hurtbox == null or hurtbox_shape == null:
		return
	var rs := hurtbox_shape.shape as RectangleShape2D
	if rs == null:
		return
	if _hurt_def_set:
		return
	_hurt_def_area_pos = hurtbox.position
	_hurt_def_shape_pos = hurtbox_shape.position
	_hurt_def_size = rs.size
	_hurt_def_set = true


## 当前该给精灵上的染色。受击时闪光（hurt_flash_t 由 take_damage 设置）。
## 默认闪白；Player 覆写成闪红，Boss 覆写成闪白 + 二阶段常驻泛红。
func body_modulate() -> Color:
	# 死亡闪白优先级最高 —— 它比受击闪更亮，要能盖住二阶段泛红
	if death_flash_t > 0.0:
		return Color(2.2, 2.0, 1.6, 1.0)
	if hurt_flash_t > 0.0:
		return hurt_flash_white
	return Color(1.0, 1.0, 1.0, 1.0)


## 美术自动适配。子类覆写以切换目标高度（玩家 / Boss 不一样）。
## 返回 {"scale": float, "offset": Vector2}
func art_fit(sf: SpriteFrames) -> Dictionary:
	return SpriteFactory.auto_fit(sf, SpriteFactory.PLAYER_TARGET_H,
			float(SpriteFactory.P_CELL), float(SpriteFactory.P_GROUND))


# ============================================================
# 主循环：模板方法，子类只需重写 _act()
# ============================================================

func _physics_process(delta: float) -> void:
	# 先算出本物理帧该推进几个逻辑帧。必须在最前面 ——
	# 下面所有 tick 计数（hitstop / iframe / 招式帧）都依赖它。
	_step_ticks(delta)

	# 战斗结束：双方停手，不再行动也不再判定
	if frozen:
		velocity = Vector2.ZERO
		_close_hitbox()
		if sprite != null:
			sprite.speed_scale = 0.0
		return

	# 胜者：不再行动、不再判定，但动画照常播（idle 呼吸）。
	# 走完整物理（重力 + 摩擦）而不是直接 return ——
	# 万一是在空中分出胜负的，胜者还能正常落地，不会僵在半空。
	if standby:
		if sprite != null:
			sprite.speed_scale = 1.0
		_close_hitbox()
		velocity.x = move_toward(velocity.x, 0.0, 900.0 * delta)
		if not is_on_floor():
			velocity.y += gravity * delta
		move_and_slide()
		if sprite != null:
			sprite.flip_h = facing < 0
		queue_redraw()
		return

	# 受击闪红。放在顿帧之前 —— 顿帧时画面是停住的，
	# 要是放在后面，冻结期间根本看不到红色。
	if sprite != null:
		sprite.modulate = body_modulate()

	# 命中顿帧：冻结本角色（画面停住，打击感的主要来源）
	if hitstop_t > 0:
		hitstop_t -= ticks
		if sprite != null:
			sprite.speed_scale = 0.0        # 顿帧时画面定住
		return

	if iframe_t > 0:
		iframe_t -= ticks
	if hurt_flash_t > 0.0:
		hurt_flash_t = maxf(hurt_flash_t - delta, 0.0)

	if dead:
		# 必须恢复 speed_scale：上一帧如果还在顿帧，这里会是 0，
		# 死亡动画（dead 4 帧）就永远播不出来，看起来像"死的时候卡住了"。
		if sprite != null:
			sprite.speed_scale = 1.0
		if death_flash_t > 0.0:
			death_flash_t = maxf(death_flash_t - delta, 0.0)
			sprite.modulate = body_modulate()
		velocity.y += gravity * delta
		velocity.x = move_toward(velocity.x, 0.0, 600.0 * delta)
		move_and_slide()
		queue_redraw()
		return

	if sprite != null:
		sprite.speed_scale = 1.0
	_act(delta)
	move_and_slide()
	_post_move()
	if sprite != null:
		sprite.flip_h = facing < 0          # 朝向靠翻转，不用做两套美术
	queue_redraw()


func _act(_delta: float) -> void:
	pass                                  # 子类实现


## 进入「站着喘气」状态：胜者停止一切行动，但继续播 idle。
##
## 必须清空 current —— 否则招式系统还挂着当前招，
## 虽然 _act() 被跳过了不会推进，但 current 非 null 会让别处
## （比如 hitbox、动画选择）以为还在出招。
## 播 idle 而不只是「让当前动画自己播完」：
## dash / punch 这些非循环动画播完会停在最后一帧，那还是定格。
func set_standby() -> void:
	standby = true
	current = null
	_close_hitbox()
	if sprite != null:
		sprite.speed_scale = 1.0
		if sprite.sprite_frames != null and \
				sprite.sprite_frames.has_animation("idle"):
			sprite.play("idle")


func _post_move() -> void:
	global_position.x = clampf(global_position.x, min_x, max_x)
	_check_landing()


# ============================================================
# 落地反馈
# ============================================================

## 从空中落到地面时：扬尘 + 落地音 + 轻微震屏。
##
## 为什么放在 _post_move（move_and_slide 之后）：
## is_on_floor() 只有在实际移动过之后才是准确的。
## 放在移动前判断会差一帧，尘土会提早一帧冒出来。
## 用 _was_airborne 记录上一帧状态，只在「刚落地那一帧」触发一次。
var _was_airborne := false
var _land_vy := 0.0


func _check_landing() -> void:
	var airborne := not is_on_floor()
	if airborne:
		_was_airborne = true
		_land_vy = velocity.y
		return
	if not _was_airborne:
		return
	_was_airborne = false
	var impact := clampf(_land_vy / 900.0, 0.0, 1.0)
	if impact < 0.12:
		return                                  # 走路级别的微小起伏不扬尘
	DustFx.spawn(get_parent(), Vector2(global_position.x, Arena.GROUND_Y),
			0.5 + impact * 0.9)
	Sfx.play("land", -4.0, 1.0, true)
	if land_shake_scale > 0.0:
		Fx.shake((0.10 + impact * 0.30) * land_shake_scale)


# ============================================================
# 解释器核心：推进一帧
# ============================================================

## 把真实时间换算成逻辑帧数。
## 正常速度（time_scale = 1）下每个物理帧 delta = 1/60，累加器正好满 1，
## 产出 1 个 tick —— 跟原来「每帧 +1」完全等价。
##
## time_scale = 0.5 时 delta = 1/120，要两帧才凑满 1 个 tick，
## 招式的推进就跟着慢下来，与移动、动画保持一致。
##
## 单帧最多推进 1 个 tick：加速（time_scale > 1）时不追帧。
## 追帧会让一帧内跳过多个招式帧，中间的判定框就丢了 ——
## 宁可加速时显得卡顿，也不能漏判定。累加器也做了上限，避免越积越多。
func _step_ticks(delta: float) -> void:
	_tick_acc += delta / FIXED_DT
	if _tick_acc >= 1.0:
		ticks = 1
		_tick_acc -= 1.0
		_tick_acc = minf(_tick_acc, 2.0)
	else:
		ticks = 0


func _frame_tick(delta: float) -> void:
	if current == null or dead:
		_close_hitbox()
		return

	# 上帧命中了玩家 → 本帧改道（打中 / 扑空走不同分支）
	if pending_next >= 0:
		var n := pending_next
		pending_next = -1
		_advance(n)
		if current == null:
			return

	if frame_index < 0 or frame_index >= current.frames.size():
		_finish_move()
		return

	var f: FrameData = current.frames[frame_index]
	if f == null:
		_finish_move()
		return

	# --- 位移：速度来自数据 ---
	velocity.x = f.dvx * float(facing)
	if f.use_gravity:
		velocity.y += gravity * delta
	else:
		velocity.y = f.dvy

	# --- 判定框：只有带 box 的帧才开判定 ---
	if f.hitbox_rect.size != Vector2.ZERO:
		_open_hitbox(f)
	else:
		_close_hitbox()

	# --- 受击框：帧数据或子类动态指定的覆盖，否则还原默认 ---
	var hr := _dynamic_hurt_rect()
	if hr.size == Vector2.ZERO:
		hr = f.hurt_rect
	if hr.size == Vector2.ZERO:
		_reset_hurt_rect()
	else:
		_set_hurt_rect(hr)

	# --- 撞墙打断：数据里指定跳到哪一帧 ---
	if f.wall_next >= 0 and is_on_wall():
		_advance(f.wall_next)
		return

	# --- 推进 ---
	# 注意：上面的位移/判定框必须每个物理帧都执行（它们是连续状态），
	# 只有这里的「计数推进」才按逻辑帧 —— 慢放时 ticks 为 0 就不推进。
	frame_ticks += ticks
	if f.wait_for_landing:
		# 等落地才结束（下落砸击用）
		if frame_ticks > 1 and is_on_floor():
			_advance(f.next)
	else:
		frame_timer -= ticks
		if frame_timer <= 0:
			# 播完时的改道：若本招到目前为止命中过，走 next_on_hit。
			# 注意这跟 hit_next 不同 —— hit_next 是命中瞬间立即跳，会打断贯穿位移；
			# 这个是等本帧播完再跳，冲拳的滑行段不受影响。
			var nx := f.next
			if move_hit:
				# 命中过 → 走 next_on_hit（若配了），并且不连发
				if f.next_on_hit >= 0:
					nx = f.next_on_hit
			elif f.chain_next >= 0 and _chain_max > 0:
				# 一次都没打中 → 连发：回到 chain_next 帧再来一次
				_chain_done += 1
				if _chain_done < _chain_max:
					nx = f.chain_next
			_advance(nx)


func play(move: AttackData) -> void:
	if move == null or move.frames.is_empty():
		return
	current = move
	frame_index = 0
	frame_ticks = 0
	frame_timer = move.frames[0].duration
	hit_landed = false
	move_hit = false
	_chain_done = 0
	if move.chain_min > 0 and move.chain_max >= move.chain_min:
		# 每次出招随机决定「最多连几下」—— 随机结果存在实例上，
		# 不能写回 AttackData（那是共享资源，会被所有实例看到）。
		_chain_max = randi_range(move.chain_min, move.chain_max)
	else:
		_chain_max = 0
	pending_next = -1
	attack_dir = facing
	move_started.emit(move)
	_play_cue(move.frames[0])
	_start_trail(move)
	_apply_teleport(move.frames[0])
	_apply_spawn(move.frames[0])
	_apply_anim(move.frames[0])
	frame_changed.emit(0, move.frames[0])


func _advance(next_index: int) -> void:
	if current != null and next_index >= 0 and next_index < current.frames.size():
		frame_index = next_index
		frame_ticks = 0
		frame_timer = current.frames[frame_index].duration
		hit_landed = false
		var f: FrameData = current.frames[frame_index]
		_play_cue(f)
		_apply_teleport(f)
		_apply_spawn(f)
		_apply_anim(f)
		frame_changed.emit(frame_index, f)
	else:
		_finish_move()


func _finish_move() -> void:
	# 战斗已结束（standby / frozen）：不要再走「选下一招」这套逻辑。
	# 虽然 _act() 被跳过时这里根本不会进来，但动画 finished 信号
	# 也可能触发它 —— 漏掉的话胜者会在结算画面里突然又出一招。
	if dead or frozen or standby:
		return
	var m := current
	current = null
	frame_index = 0
	frame_ticks = 0
	frame_timer = 0
	pending_next = -1
	_close_hitbox()
	_reset_hurt_rect()
	_stop_trail()
	move_finished.emit(m)


# ============================================================
# 残影拖尾
# ============================================================

## 高速位移的招式留残影。
##
## 60fps 下角色一帧能移动十几像素，纯靠动画帧会显得一格一格跳。
## 残影把中间的空隙补上，速度感立刻出来 —— 成本只是几个 draw_texture。
##
## 按招式名匹配，不额外给 AttackData 加字段：需要拖尾的就这几个招。
const TRAIL_MOVES := {
	"dash": Color(0.98, 0.55, 0.42, 0.40),
	"dodge": Color(0.55, 0.85, 1.0, 0.34),
}


func _start_trail(move: AttackData) -> void:
	if sprite == null or move == null:
		return
	if not TRAIL_MOVES.has(move.move_name):
		return
	_stop_trail()
	_trail = TrailFx.attach(sprite, TRAIL_MOVES[move.move_name], 0.26, 0.05, self)


func _stop_trail() -> void:
	if _trail != null and is_instance_valid(_trail):
		# stop() 只是「不再产生新影子」，已有影子会继续淡出，
		# 淡完后 TrailFx 自己 queue_free()（见 TrailFx._process）。
		# 这里把引用置空即可 —— 不要 queue_free()，否则影子会硬切消失。
		_trail.stop()
		_trail = null


# ============================================================
# 闪现：进入带 teleport 的帧时立即改位置
# ============================================================

func _apply_teleport(f: FrameData) -> void:
	if f == null or f.teleport == "":
		return
	var t := _resolve_target()
	if t == null:
		return
	# 锁定落点：招式一旦闪现，落点就此固定，不再跟着玩家跑
	landing_x = t.global_position.x
	var to := t.global_position + f.teleport_offset
	match f.teleport:
		"above_player":
			to.x = t.global_position.x + f.teleport_offset.x
			to.y = t.global_position.y + f.teleport_offset.y
		"front_player":
			to.x = t.global_position.x + signf(f.teleport_offset.x) * absf(f.teleport_offset.x)
			to.y = t.global_position.y
		"behind_player":
			to.x = t.global_position.x - signf(f.teleport_offset.x) * absf(f.teleport_offset.x)
			to.y = t.global_position.y
		_:
			return

	global_position.x = clampf(to.x, min_x, max_x)
	global_position.y = clampf(to.y, ceil_y, 20000.0)
	velocity = Vector2.ZERO
	teleported.emit(global_position)


func _resolve_target() -> Node2D:
	return get_tree().get_first_node_in_group("player")


# ============================================================
# 生成子实体：对应 LF2 的 opoint（放火球就是靠它）
# ============================================================

func _apply_spawn(f: FrameData) -> void:
	if f == null or f.spawn_scene == "":
		return
	var ps := load(f.spawn_scene) as PackedScene
	if ps == null:
		push_error("子实体场景加载失败: " + f.spawn_scene)
		return
	var obj := ps.instantiate() as Node2D
	if obj == null:
		return
	var off := f.spawn_offset
	obj.global_position = global_position + Vector2(off.x * float(facing), off.y)
	if obj.has_method("setup"):
		obj.setup(facing, f.spawn_damage, f.spawn_knockback)
	get_tree().current_scene.add_child(obj)
	# 开火音效按生成的实体类型区分 —— 集中在这一处，
	# 不用给每个招式的帧数据都加字段
	var sn := f.spawn_scene.get_file().to_lower()
	if sn.begins_with("laser"):
		Sfx.play("cannon")
		Sfx.play("beam_hum", -6.0, 1.0, false)
		# 全图炮是全场大招，震屏和闪光都给满 —— 它必须显得「挨不起」。
		Fx.shake(0.75)
		Fx.flash(Color(1.0, 0.55, 0.25), 0.42)
	elif sn.begins_with("bulletenemy"):
		Sfx.play("enemy_shoot")
	elif sn.begins_with("bullet"):
		Sfx.play("shoot")


# ============================================================
# 动画：帧表里写 anim 名字，这里只负责切
# ============================================================

func _apply_anim(f: FrameData) -> void:
	if sprite == null or f == null or f.anim == "":
		return                                  # 留空 = 沿用上一帧的动画
	if sprite.sprite_frames == null:
		return
	if not sprite.sprite_frames.has_animation(f.anim):
		push_warning("动画不存在: " + f.anim)
		return
	if sprite.animation != f.anim or not sprite.is_playing():
		sprite.play(f.anim)
		# 非循环动画自动铺满本帧时长（见 FrameData.anim_fit 的说明）。
		# 只在「刚 play」时算一次 —— 后续同名帧不重启，速度保持不变。
		sprite.speed_scale = 1.0
		if f.anim_fit and not f.wait_for_landing:
			var sf := sprite.sprite_frames
			if not sf.get_animation_loop(f.anim):
				var n := sf.get_frame_count(f.anim)
				var base := sf.get_animation_speed(f.anim)
				var sec := float(f.duration) / 60.0
				# 总时长 = n / (base * speed_scale) 要等于 sec
				if n > 0 and base > 0.0 and sec > 0.0:
					sprite.speed_scale = float(n) / (sec * base)


# ============================================================
# 判定框
# ============================================================

func _open_hitbox(f: FrameData) -> void:
	attack_dir = facing                  # 判定开启的这一帧锁定朝向
	var r := f.hitbox_rect
	# r 是标准 Rect2 语义：position = 左上角，size = 宽高
	# 先按朝向镜像出左右边界，再取中心 —— 碰撞形状是以自身原点为中心的
	var left := r.position.x
	if facing < 0:
		left = -(r.position.x + r.size.x)
	var cx := left + r.size.x * 0.5
	var cy := r.position.y + r.size.y * 0.5
	hitbox.position = Vector2(cx, cy)
	_box.size = r.size
	hitbox_shape.disabled = false
	current_damage = f.damage
	current_knockback = f.knockback


## 关闭攻击判定。
##
## 必须用 set_deferred 而不是直接赋值 —— 这个函数会从
## `_on_hitbox_entered()`（Area2D 信号）里被调用，而信号是在物理引擎
## 「冲刷查询」阶段派发的。此时改碰撞体的 monitoring / disabled 会触发：
##   Can't change this state while flushing queries.
## set_deferred 把修改推迟到当前物理帧结束之后再执行，就安全了。
func _close_hitbox() -> void:
	if hitbox_shape == null:
		return
	if hitbox_shape.is_inside_tree():
		hitbox_shape.set_deferred("disabled", true)
	else:
		hitbox_shape.disabled = true


## 子类覆写：按「当前状态」动态指定受击框（比如闪现砸拳下落时拉长到地面）。
## 优先级最高 —— 比帧数据里的 hurt_rect 更动态，因为它能用到 global_position。
## 返回 Rect2() 表示不覆盖。
func _dynamic_hurt_rect() -> Rect2:
	return Rect2()


## 临时把受击框换成 r（Rect2 语义：position = 左上角）
func _set_hurt_rect(r: Rect2) -> void:
	if hurtbox == null or hurtbox_shape == null or not _hurt_def_set:
		return
	var rs := hurtbox_shape.shape as RectangleShape2D
	if rs == null:
		return
	hurtbox.position = r.position + r.size * 0.5
	hurtbox_shape.position = Vector2.ZERO
	rs.size = r.size


## 还原成场景里配的默认受击框
func _reset_hurt_rect() -> void:
	if hurtbox == null or hurtbox_shape == null or not _hurt_def_set:
		return
	var rs := hurtbox_shape.shape as RectangleShape2D
	if rs == null:
		return
	hurtbox.position = _hurt_def_area_pos
	hurtbox_shape.position = _hurt_def_shape_pos
	rs.size = _hurt_def_size


# ============================================================
# 调试：实时显示判定框
# ============================================================

func _draw() -> void:
	if not show_boxes:
		return
	# hurtbox（青）：常驻受击框。
	# 免疫状态（闪现砸空中段 / iframe / god_mode）画成黄色 ——
	# 光看框的颜色就能知道「现在打不打得动」，不用来回开枪试。
	var inv := god_mode or iframe_t > 0 or _is_invincible()
	_draw_box(hurtbox, hurtbox_shape,
			  Color(1.0, 0.85, 0.20, 0.95) if inv else Color(0.30, 0.85, 1.0, 0.95),
			  2.0)
	# hitbox（红）：只在判定真的开启时画。
	# 关闭后 hitbox.position 还留着上一次的值，画出来会误导 ——
	# 看起来像「一直有攻击判定」。
	if hitbox_shape != null and not hitbox_shape.disabled:
		_draw_box(hitbox, hitbox_shape, Color(1.0, 0.22, 0.22, 0.95), 2.0)


## 画一个 Area2D 下的矩形碰撞形状。
## 碰撞形状以自身原点为中心，draw_rect 要的是左上角，所以要减半个尺寸。
func _draw_box(area: Area2D, cs: CollisionShape2D, col: Color, w: float) -> void:
	if area == null or cs == null:
		return
	var rs := cs.shape as RectangleShape2D
	if rs == null:
		return
	var origin := area.position + cs.position
	var r := Rect2(origin - rs.size * 0.5, rs.size)
	draw_rect(r, Color(col.r, col.g, col.b, 0.16), true)   # 淡填充：重叠时更好读
	draw_rect(r, col, false, w)                            # 描边


func _on_hitbox_entered(area: Area2D) -> void:
	if hit_landed or dead or current == null:
		return
	if frame_index < 0 or frame_index >= current.frames.size():
		return
	var f: FrameData = current.frames[frame_index]
	if f == null:
		return

	hit_landed = true
	var other := area.get_parent()
	if other == null or not other.has_method("take_damage"):
		return

	# 击飞方向 = 开判定时锁定的朝向，保证「往 Boss 面朝的方向」飞
	other.take_damage(current_damage, attack_dir, current_knockback, f.hitstop)

	# 命中顿帧：默认攻击者也一起冻住。
	# 贯穿型招式标 hs_self:false —— 自己不停，保持惯性冲过去
	if f.hitstop > 0 and f.hitstop_self:
		hitstop_t = maxi(hitstop_t, f.hitstop)

	# 命中改道：打中 / 扑空走不同后摇
	if f.hit_next >= 0:
		pending_next = f.hit_next

	# 本招命中标记（供 next_on_hit 在招式末尾判断）
	move_hit = true

	# 命中即触发后撤 —— 只看招式有没有标 retreat_on_launch
	# 不看击退数值：击飞多远由帧数据的 kb 决定，与「要不要后撤」是两件事。
	# 用 kb 阈值当判据会在撞墙等边界情况下误判（位移被吃掉，但 kb 还在）
	if f.retreat_on_launch:
		launched_player.emit(current)


# ============================================================
# 伤害
# ============================================================

## 返回 true = 真的吃到伤害。无敌 / 已死返回 false —— 攻击方据此决定
## 是否要消失。翻滚无敌时子弹应该穿过去，而不是凭空消失。
## 无敌开关（调试/演示用，由 HUD 上的 INVINCIBLE 按钮控制）。
## 放在基类上，Boss 也能用同一套逻辑。
## 注意返回 false 会让攻击方走「没打中」分支 ——
## 子弹会穿过去继续飞，而不是凭空消失（见 Bullet 的 landed 判断）。
var god_mode := false


## 子类覆写：某些状态应当完全免疫伤害（比如闪现砸的空中段）。
## 跟 iframe_t 的区别：iframe 是「被击中之后的短暂无敌」，这个是
## 「状态性无敌」—— 不依赖有没有被打中过，进这个状态就免疫。
## 与 god_mode 的区别：god_mode 是常驻调试开关，这个是按招式/帧判定的。
func _is_invincible() -> bool:
	return false


func take_damage(amount: int, from_dir: int, knockback: float, hitstop: int = 0) -> bool:
	if dead or god_mode or iframe_t > 0 or _is_invincible():
		return false
	health = maxi(health - amount, 0)
	if not hurt_invincible:
		iframe_t = iframe_ticks
	hurt_flash_t = hurt_flash_sec
	if hitstop > 0:
		hitstop_t = maxi(hitstop_t, hitstop)
	health_changed.emit(health, max_health)
	damage_taken.emit(amount, health)
	_spawn_hit_fx(amount, from_dir, knockback)
	_hurt_sfx(knockback)
	on_hurt(from_dir, knockback)
	if health <= 0:
		_die()
	return true


## 命中特效：冲击环 + 火花。
## 位置用「受击者身体中心」而不是碰撞点 —— 子弹的碰撞点在边缘，
## 特效会画在角色轮廓外面，看着像打歪了。
func _spawn_hit_fx(_amount: int, from_dir: int, knockback: float) -> void:
	if not hit_fx_enabled:
		return
	# 玩家受击不画圈 —— 特效出现在自己身上会挡视线，
	# 而且被打中还「好看」是反直觉的。玩家这边靠闪红 + 顿帧反馈就够了。
	# 打 Boss 的特效才是真正需要的（确认「我打中了」）。
	if is_in_group("player"):
		return
	var col := hit_fx_color_enemy
	var big := knockback >= LAUNCH_FX_KB
	var sz := 1.6 if big else 1.0
	var pos := Vector2(0.0, -hit_fx_body_h * 0.5)
	HitFx.spawn(self, pos, col, from_dir, sz)
	# 打中敌人时轻微震屏 —— 打击感的一半来自画面动。
	# 幅度刻意小（0.10）：这是每秒可能发生 3 次的事，大了会晕。
	Fx.shake(0.16 if big else 0.10)


## 招式提示音：进帧时播 f.cue。
##
## 用真正的招式起手帧来播，而不是「每次 Boss 出手播一个通用音」——
## 每招音色不同（冲拳是风声蓄力、闪现砸是高频闪烁、炮是上升嗡鸣），
## 玩家听一遍就能对应上，之后靠耳朵读招，不用死盯动作。
##
## 只在 Boss 侧有意义（玩家动作本来就由自己输入触发）。
func _play_cue(f: FrameData) -> void:
	if f == null or f.cue == "":
		return
	Sfx.play(f.cue, 0.0, 1.0, false)   # 不抖动音高：提示音要每次一模一样才认得出


## 受击音效。默认按敌我区分；Player 会覆写，把「击飞」换成更重的 launch
## （击飞门槛 LAUNCH_KB 是 Player 的常量，不该搬到基类里重复一份）。
func _hurt_sfx(_knockback: float) -> void:
	if is_in_group("player"):
		Sfx.play("hurt")
	else:
		Sfx.play("hit")


func on_hurt(_from_dir: int, _knockback: float) -> void:
	pass                                  # 子类实现击退 / 闪白


func _die() -> void:
	dead = true
	_close_hitbox()
	if (
		sprite != null and sprite.sprite_frames != null
		and sprite.sprite_frames.has_animation("dead")
	):
		sprite.play("dead")
	# 死亡演出：连续爆闪 + 冲击环，播完才弹结算。
	# 没有这一步的话，死亡只是「动作停下 + 一声音效」，
	# 通关/失败都没有仪式感，玩家甚至不确定是不是已经结束了。
	if death_fx_bursts > 0:
		_play_death_fx()
	# 死亡震屏 + 全屏闪白：宣告「战斗结束了」。
	# 没有这个的话，最后一击跟普通命中在画面上没区别。
	Fx.shake(1.0)
	Fx.flash(Color(1.0, 0.92, 0.70), 0.70)
	died.emit()


## 死亡演出：连续几次爆炸闪，最后一次最大。
## 用 SceneTreeTimer 而不是 _process 计时 —— 死亡后 _physics_process
## 会走 dead 分支直接 return，自己维护计时器反而更绕。
func _play_death_fx() -> void:
	var n := death_fx_bursts
	for i in n:
		var delay := float(i) * death_fx_interval
		var last := i == n - 1
		var t := get_tree().create_timer(delay, true, false, true)   # ignore_time_scale
		t.timeout.connect(func() -> void:
			if not is_instance_valid(self) or not is_inside_tree():
				return
			# 最后一次最大，前面几次小 —— 收尾有「终于爆开」的感觉
			var sz := death_fx_last_scale if last else death_fx_first_scale
			var col := death_fx_color
			HitFx.spawn(self, Vector2(0.0, -hit_fx_body_h * 0.5), col, 1, sz)
			death_flash_t = death_flash_sec
			Sfx.play("phase" if last else "hit", 0.0, 1.0, false)
		)


# ============================================================
# 工具
# ============================================================

func find_move(nm: String) -> AttackData:
	for m in moves:
		if m != null and m.move_name == nm:
			return m
	return null


func current_label() -> String:
	if current == null or frame_index >= current.frames.size():
		return ""
	return current.frames[frame_index].label


func is_telegraphing() -> bool:
	if current == null or frame_index >= current.frames.size():
		return false
	return current.frames[frame_index].telegraph


## 按距离加权随机选招。权重为 0 或距离不符的招式不进池子。
func _pick_move(dist: float) -> AttackData:
	var pool: Array[AttackData] = []
	var total := 0.0
	for m in moves:
		if m == null:
			continue
		# weight <= 0 = 只能被显式 play() 调用（比如连发的后续发），不参与随机
		if m.weight <= 0.0:
			continue
		if dist >= m.min_dist and dist <= m.max_dist:
			pool.append(m)
			total += m.weight
	if pool.is_empty():
		return null
	var r := randf() * total
	for m in pool:
		r -= m.weight
		if r <= 0.0:
			return m
	return pool[-1]

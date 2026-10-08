extends FrameActor
class_name Player
## ============================================================
## 玩家控制器：走 / 跳 / 砍 / 翻滚
##
## 跟 Boss 共用同一个帧解释器，招式同样是 MoveLibrary 里的数据。
## 这里只有「读输入」和「切动画」，没有任何招式逻辑。
## ============================================================

# ============================================================
# 调参区：全部 @export，选中 Player.tscn 里的 Player 就能在检查器里改
# ============================================================

@export_group("移动")
@export var speed := 330.0
@export var jump_velocity := -650.0

@export_group("手感三件套")
## 走下平台后还有这么多帧可以起跳
@export_range(0, 30, 1) var coyote_ticks := 8
## 落地前这么多帧按跳会被记住，落地立刻执行
@export_range(0, 30, 1) var jump_buffer_ticks := 8
## 翻滚期间每帧刷新到这个数 -> 全程无敌
@export_range(0, 30, 1) var dodge_iframe := 3

@export_group("击飞")
## 只有 kb >= 这个值才触发「击飞」（上抛 + 失控）。
## 目前只有 Boss 普通拳（1200）达标，其余招式击退都在 340~420，
## 所以「只有普通拳会击飞」是数值上的事实，不是靠标记硬塞的。
@export var launch_kb := 900.0
## 击飞上抛：轻微离地一下（约 1/7 个跳跃高度），不是抛物线大弧。
## 参考：玩家自己跳 = -650 -> 41 帧 / 111px
## 档位：  -150 =  9帧/6px    -220 = 14帧/13px
##        -250 = 16帧/16px <- 当前    -300 = 19帧/24px
##         0   = 贴地滑行（不离地）
@export var launch_lift := -250.0
## 击飞失控的时长上限（帧）。保险丝 —— 正常靠「落地」或「停下」提前解锁。
@export_range(1, 120, 1) var launch_ticks := 24
## 水平滑行速度低于这个值就认为「滑完了」，解锁操作。
## 没有它的话 launch_lift=0（不离地）时永远等不到「落地」，会永久锁死。
@export var launch_stop_vx := 40.0

@export_group("受击")
## 普通受击的顿帧（帧）。闪光 + 卡一下，不上抛。
@export_range(0, 30, 1) var hurtstop_ticks := 4
## 受击 hurt 动画时长（帧）。3 帧 @ speed 15 = 0.2s。
## 这段时间内状态机不抢动画，否则下一帧就被 run/idle 覆盖，等于没播。
@export_range(1, 60, 1) var hurt_anim_ticks := 12

## ---------------------------------------------------------------------------
## 空中开枪的子弹生成高度
##
## 地面和空中**共用同一个 fire 招式**（只有动画分 shoot / shoot_air），
## 所以 spawn_off 只有一个值，改了会同时影响地面和空中。
##
## 空中单独取「hurtbox 竖直中心」：
##   hurtbox 在 Player.tscn 里是 position(0,-55) + 30x110，
##   即覆盖 -110..0，中心 = -55。
## 这里**运行时从 hurtbox 读**，不写死 -55 —— 以后改 hurtbox 高度会自动跟上。
##
## 关掉就退回帧数据里那个值（地面/空中一致）。
@export var air_fire_from_hurtbox_center := true
## hurtbox 读不到时的兜底值（等于当前 hurtbox 中心）
@export var air_fire_y_fallback := -55.0

var stand_move: AttackData = null
var fire_move: AttackData = null
var dodge_move: AttackData = null

var coyote_t := 0
var jump_buffer_t := 0
var was_on_floor := false
var _jump_anim_played := false   # 本次滞空是否已经播过 jump（防止空中开枪后重播）
var launch_t := 0              # 被强击飞后的失控时间（帧），期间不能操作
var launch_left_ground := false  # 击飞后是否已离地（用来判断"真正落地"）
var hurt_anim_t := 0           # 受击 hurt 动画的独占时间（帧），期间状态机不抢动画

# ---- 美术尺寸：从检查器写回 ----
# SpriteFactory 里是 static func，读不到实例变量，所以 _ready() 里把这几个值
# 抄进 static 常量。必须自己声明一份 ——
# Boss.gd 里也有同名变量，但 Player 不是 Boss 的子类，继承不到。
@export var art_display_height := 108.0     # 角色内容在屏幕上的目标高度（px）
@export_range(0, 768, 1) var art_cell := 768        # 源图画布边长
@export_range(0, 768, 1) var art_ground_row := 672  # 脚底所在行


func _ready() -> void:
	super._ready()
	add_to_group("player")
	# 玩家受击后【不】进入无敌：每一发子弹都要吃满，连击才有意义。
	# 这里在代码里强制设，不依赖 .tscn 的属性赋值 ——
	# 万一场景是旧版本 / 编辑器里被改回去，这里也能兜住。
	#
	# 翻滚无敌不受影响：它是 on_dodge 里每帧 iframe_t = maxi(iframe_t, dodge_iframe)，
	# 走的是另一条路径，跟 iframe_ticks 和这个开关都无关。
	hurt_invincible = false
	iframe_ticks = 0
	# 美术尺寸从检查器写回（SpriteFactory 是 static func，读不到实例变量）
	SpriteFactory.PLAYER_TARGET_H = art_display_height
	SpriteFactory.P_CELL = art_cell
	SpriteFactory.P_GROUND = art_ground_row
	if moves.is_empty():
		moves = MoveLibrary.player_moves()
	stand_move = find_move("stand")
	fire_move = find_move("fire")
	dodge_move = find_move("dodge")
	move_finished.connect(_on_move_finished)
	if sprite != null:
		if sprite.sprite_frames == null:          # 场景里已直接挂了 .tres，这里只是兜底
			sprite.sprite_frames = SpriteFactory.build_player()
			var fit := art_fit(sprite.sprite_frames)
			sprite.scale = Vector2(fit["scale"], fit["scale"])
			sprite.position = fit["offset"]
		sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	play(stand_move)


func _act(delta: float) -> void:
	# 受击动画独占计时（放在最前面，击飞失控期间也要递减）
	if hurt_anim_t > 0:
		hurt_anim_t -= ticks

	# 强击飞失控中：不能移动、不能攻击、不能翻滚，只能等结束。
	# 这里是唯一的输入入口，return 掉就什么都按不了 —— 不要在这之后再加攻击判定。
	if launch_t > 0:
		launch_t -= ticks
		# 击飞期间的跳跃计时器必须清零。
		# 这两个变量在 return 之后才更新，失控期间等于被「冻结」——
		# 挨打前按过跳的话 buffer 会一直挂着，落地那一帧
		# jump_buffer_t>0 且 coyote_t>0 会触发一次自动起跳（-650），
		# 比击飞本身高得多，看着就是"飞到边突然窜上去"。
		jump_buffer_t = 0
		coyote_t = 0
		# was_on_floor 也要跟着更新：它停在击飞前的值的话，
		# 落地那帧会走 `elif was_on_floor` 分支把 coyote_t 重新填满。
		was_on_floor = is_on_floor()

		# 结束条件（三个，任一满足）：
		#   1. 真的飞起来过 -> 落地即解锁
		#   2. 水平速度基本停下（滑行结束 / 撞墙卡住）
		#   3. 时长耗尽（保险）
		# 第 2 条是必需的：launch_lift = 0 时人根本不离地，
		# 只判「落地」的话 launch_left_ground 永远是 false，会永久锁死操作。
		if not is_on_floor():
			launch_left_ground = true
		if (
			(launch_left_ground and is_on_floor())
			or absf(velocity.x) < launch_stop_vx
			or launch_t <= 0
		):
			launch_t = 0                       # 恢复操作
		# 这里原本写死 0.016（假设 60fps），慢放时会失准 —— 必须用真实 delta。
		velocity.x = move_toward(velocity.x, 0.0, 900.0 * delta)
		return

	var dir := Input.get_axis("move_left", "move_right")

	# —— 计时器 ——
	var on_floor := is_on_floor()
	if on_floor:
		coyote_t = coyote_ticks
	elif was_on_floor:
		coyote_t = coyote_ticks          # 刚走下平台，给宽限
	else:
		coyote_t = maxi(coyote_t - ticks, 0)
	was_on_floor = on_floor

	jump_buffer_t = maxi(jump_buffer_t - ticks, 0)
	if Input.is_action_just_pressed("jump"):
		jump_buffer_t = jump_buffer_ticks

	# —— 按帧数据推进（翻滚的位移来自这里）——
	# 空中开枪要保留水平惯性：fire 帧没有 dvx，_frame_tick 会把 velocity.x 归零，
	# 结果人在半空突然悬停。这里把开枪前的水平速度还回去。
	var vx_before := velocity.x
	_frame_tick(delta)
	if current == fire_move and not is_on_floor():
		velocity.x = vx_before

	# 翻滚全程无敌：每帧刷新，翻完自动失效
	if current == dodge_move:
		iframe_t = maxi(iframe_t, dodge_iframe)

	# —— 翻滚：优先级最高，能打断攻击后摇 ——
	if Input.is_action_just_pressed("dodge") and current != dodge_move:
		if _can_act() and not dead:
			facing = 1 if dir > 0.0 else (-1 if dir < 0.0 else facing)
			play(dodge_move)
			Sfx.play("dodge")
			return

	if current == dodge_move:
		return                             # 翻滚中锁方向

	if current == fire_move:
		return                             # 开枪时锁住移动

	# —— 移动 ——
	if dir != 0.0:
		velocity.x = dir * speed
		facing = 1 if dir > 0.0 else -1
	else:
		velocity.x = move_toward(velocity.x, 0.0, speed * 8.0 * delta)

	# —— 跳跃（含 coyote + buffer）——
	if jump_buffer_t > 0 and coyote_t > 0:
		velocity.y = jump_velocity
		jump_buffer_t = 0
		coyote_t = 0
		Sfx.play("jump")

	# —— 开枪 ——
	if Input.is_action_just_pressed("attack") and _can_cancel():
		play(fire_move)

	# —— 站立时按状态切 jump / run / idle ——
	# 优先级：空中 > 移动 > 站立。
	# 原来的写法把 run 放在最前面（"run" if dir != 0 else ...），
	# 于是「跑动中起跳」时 dir 仍然非 0，会一直播 run —— 跳起来脚还在跑。
	# 离地必须优先判定，否则空中永远轮不到 jump。
	# 受击 hurt 动画独占中：不切 idle/run/jump，否则下一帧就被覆盖掉。
	# 仍然允许移动和开枪 —— 只是动画先让给 hurt。
	if hurt_anim_t > 0:
		return

	if current == stand_move:
		if on_floor:
			_jump_anim_played = false
			_set_anim("run" if dir != 0.0 else "idle")
		elif not _jump_anim_played:
			# 起跳瞬间才播一次 jump（loop=false，8 帧）
			_set_anim("jump")
			_jump_anim_played = true
		# 空中且 jump 已播过：保持当前动画，不重播。
		# 否则「空中开枪」结束后 shoot_air -> jump 会从头再放一遍，
		# 看起来像第二次起跳。停在 shoot_air 的举枪收尾帧反而更自然。


## 站立状态下动画由「状态」决定（idle / run / jump），不由帧数据决定。
## 不加这道闸的话，stand 帧数据里的 anim:"idle" 会把 run / jump 抢回 idle，
## 于是走路和跳跃看起来就是卡在第 1 帧。
func _apply_anim(f: FrameData) -> void:
	# 受击动画优先：开枪 / 翻滚时被打中也要先看到 hurt
	if hurt_anim_t > 0:
		return
	if current == stand_move:
		return
	# 开枪分地面 / 空中两套动画
	if current == fire_move:
		_set_anim("shoot_air" if not is_on_floor() else "shoot")
		return
	super._apply_anim(f)


## 空中开枪时，把子弹的生成高度换成 hurtbox 中心。
##
## 只改 y，x 沿用帧数据（枪口在身前，跟朝向镜像）。
## 做法是临时改 f.spawn_offset、调完立刻还原 ——
## 帧数据是**共享资源**（MoveLibrary 里静态构造，所有实例共用），
## 不还原的话地面开枪也会被改掉。
func _apply_spawn(f: FrameData) -> void:
	if f == null or f.spawn_scene == "" or is_on_floor():
		super._apply_spawn(f)
		return
	if not air_fire_from_hurtbox_center:
		super._apply_spawn(f)
		return
	var old := f.spawn_offset
	f.spawn_offset = Vector2(old.x, _air_fire_y())
	super._apply_spawn(f)
	f.spawn_offset = old


## hurtbox 的竖直中心（相对角色原点）。
func _air_fire_y() -> float:
	if hurtbox != null:
		return hurtbox.position.y
	return air_fire_y_fallback


func _can_act() -> bool:
	if current == null or current == stand_move:
		return true
	if frame_index >= current.frames.size():
		return true
	return current.frames[frame_index].cancellable


func _can_cancel() -> bool:
	if current == fire_move:
		return false                       # 射击中不能连点刷屏（想加射速就改这里）
	return _can_act()


func _on_move_finished(_m: AttackData) -> void:
	if not dead:
		play(stand_move)


## 玩家受击闪红（Boss 是闪白）
func body_modulate() -> Color:
	if death_flash_t > 0.0:
		return Color(2.2, 2.0, 1.6, 1.0)
	if hurt_flash_t > 0.0:
		return hurt_flash_red
	return Color(1.0, 1.0, 1.0, 1.0)


## 受击音效：击飞用更重的 launch，普通受击用 hurt。
## 门槛复用 launch_kb —— 音效和实际击飞行为必须一致，不能各判各的。
func _hurt_sfx(knockback: float) -> void:
	Sfx.play("launch" if knockback >= launch_kb else "hurt")


func on_hurt(from_dir: int, knockback: float) -> void:
	# 受击瞬间是否在空中 —— 必须在设 velocity.y 之前取，
	# 因为击飞的上抛会改变后续状态，但"当时在不在空中"才是判断依据。
	var airborne := not is_on_floor()
	velocity.x = float(from_dir) * knockback
	# 受击顿帧：卡一下。这里单独加是因为子弹命中时 hitstop 传的是 0，
	# 不额外给的话被子弹打中完全没手感。
	# 只加在玩家身上 —— Boss 有霸体，要是每挨一枪都卡 4 帧会被射到出不了招。
	hitstop_t = maxi(hitstop_t, hurtstop_ticks)

	# 受击震屏：轻击微震、击飞明显震，配合全屏闪红。
	# 之前只有顿帧 + 闪红，画面本身不动 —— 少了「被撞到」的冲击。
	Fx.shake(0.42 if knockback >= launch_kb else 0.14)
	Fx.flash(Color(1.0, 0.25, 0.30),
			0.30 if knockback >= launch_kb else 0.12)

	if knockback >= launch_kb:
		# 击飞：上抛 + 落地前禁操作
		velocity.y = launch_lift
		launch_t = launch_ticks
		launch_left_ground = false
	# 普通受击：不上抛。反馈交给 hurt 动画 + 闪红 + 顿帧。

	# 播 hurt 动画（强制重播，连击时每下都要有反馈）。
	# hurt_anim_t 期间状态机不抢动画，见 _act / _apply_anim。
	# 空中受击不播 —— 人在半空被打，切回踉跄动作会把 jump 掐断，
	# 看起来像突然"站"了一下再掉下去。空中保持跳跃姿态更连贯。
	if not airborne:
		_play_hurt()


## 强制播一次 hurt（_set_anim 在同名且正在播时会跳过，连击就看不出第二下）
func _play_hurt() -> void:
	if sprite == null or sprite.sprite_frames == null:
		return
	if not sprite.sprite_frames.has_animation("hurt"):
		return
	hurt_anim_t = hurt_anim_ticks
	sprite.play("hurt")


# ============================================================
# 动画：由 AnimatedSprite2D 播放，这里只负责切
# ============================================================

func _set_anim(nm: String) -> void:
	if (
		sprite == null or sprite.sprite_frames == null
		or not sprite.sprite_frames.has_animation(nm)
	):
		return
	# 只在「动画变了」时重播。
	# 不能加 `or not is_playing()`：jump 是 loop=false，播完就停；
	# 滞空 0.68 秒 > jump 动画 0.5 秒，最后 0.18 秒 is_playing() 为 false，
	# 那样会每帧重新 play("jump")，跳跃动作从头再放一遍，看起来像反复起跳。
	# 循环动画（idle / run）永不停，本来就不需要这个判断。
	if sprite.animation != nm:
		sprite.play(nm)

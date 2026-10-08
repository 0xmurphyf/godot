extends FrameActor
class_name Boss
## ============================================================
## Boss AI：走近 -> 冲拳 / 闪现砸拳
##
## 这里没有任何「冲拳」「闪现」的逻辑字样。
## 招式全是 MoveLibrary 里的数据，本文件只负责：
##   1. 按距离选招（含防复读）
##   2. 走路时判断是否该打断
##   3. 前摇预警的绘制
## ============================================================

# ============================================================
# 调参区：全部 @export，选中 Boss.tscn 里的 Boss 就能在检查器里改
# ============================================================

@export_group("接近与选招")
## 走进此距离就停步出招。必须 < walk 的 min_dist(240)，
## 否则会卡进「选中走路 → 立刻打断 → 又选走路」的死循环。
@export var attack_range := 220.0
## 走路最多走这么久就重选（秒）。
## 原本只有「走进 attack_range 就出招」，但玩家跑开的话 Boss 会一路追到底
## —— 变成枯燥的长途跋涉。加个时间上限后节奏更活
## （可能继续走，也可能改冲拳 / 开枪）。
## 1 秒 = 170px（走路速度 170）。
@export var walk_max_time := 1.0
## 连续选中同一招时，有多大概率强制换一招
@export var repeat_avoid := 0.7

@export_group("贴墙冲拳（撞到场地边界）")
## 启用：Boss 贴到左右边界时，下一个动作改为朝场地内侧冲拳。
## 没有这条规则时，Boss 会背对着墙站着出招（甚至往墙里出招），
## 观感很蠢，而且玩家躲在墙角能白嫖。
@export var wall_dash_enabled := true
## 距边界多少像素算「贴到墙」。
## 不能只判 == min_x：物理上一帧只推进约 25px，很容易跨过去又回不来，
## 用一点余量才稳定触发。
@export var wall_dash_margin := 40.0
## 触发后强制出的招式名（MoveLibrary 里的 move_name）
@export var wall_dash_move := "dash"
## 触发一次后要离开墙这么远才会重新武装（像素）。
## 否则冲拳结束后人还在墙边，会立刻再触发 —— 变成无限连冲。
@export var wall_dash_rearm := 120.0

@export_group("后撤（击飞玩家之后）")
## 后撤速度必须明显低于玩家走路速度（330），否则玩家永远追不上，
## 后撤那几秒就变成纯「看它走」，没有任何交互 —— 这是手感别扭的主因。
## 260 -> 净追 70px/s（翻滚净追 380px/s）。
@export var retreat_speed := 260.0
## 后撤至少走这么久才响应「被玩家打中」（秒）
@export var retreat_min_time := 0.6
## 后撤至少走这么远才允许「走到头」结束（像素）
@export var retreat_min_dist := 200.0
## 硬上限：撤满这么久一定停（秒）
@export var retreat_max_time := 3.0
## 击退值低于这个就不算「真的被打退」，不触发后撤
@export var retreat_min_kb := 1.0
## 撤退方向的前视距离：射线撞到墙就停
@export var retreat_ray_len := 56.0
## 后撤结束后的反击招式名（MoveLibrary 里的 move_name）
@export var retreat_end_move := "cannon"

@export_group("普通枪连发")
## 首发结束后有这个概率再来一发，上限 burst_max 发
@export_range(0.0, 1.0) var gun_burst_chance := 0.6
@export_range(1, 10, 1) var gun_burst_max := 5

@export_group("连发快慢刀")
## 连发不再固定节奏：每一发的前摇从下面四档里挑。
## 感知间隔 = 上一发后摇 10 + 这一发 aim：14 / 18 / 24 / 34 帧。
## 从 14 到 34 差 2.4 倍 —— 固定节奏听一次响就能数拍子躲，打乱后必须看动作。
@export_range(1, 60, 1) var burst_aim_fast := 4      ## 快刀
@export_range(1, 60, 1) var burst_aim_norm := 8      ## 标准
@export_range(1, 60, 1) var burst_aim_slow := 14     ## 慢刀
@export_range(1, 60, 1) var burst_aim_delay := 24    ## 延迟斩
## 延迟斩概率 = burst_delay_base × (第几发 - 1)，越到后面越可能憋一下。
##   第2发 12% / 第3发 24% / 第4发 36% / 第5发 48%
## 0.12 是调出来的：整体约 23% 的发是延迟斩 ——
## 高到能形成「这轮是不是打完了？」的犹豫，又不至于每次都拖成慢动作。
## 不写死「只有最后一发」—— 连发长度随机，打到第 5 发只有 13% 概率，
## 那样延迟斩几乎见不到，快慢刀等于没有。
@export_range(0.0, 1.0) var burst_delay_base := 0.12

@export_group("闪现砸拳")
## 帧号需与 MoveLibrary.boss_blink_slam() 保持一致
@export_range(0, 8, 1) var blink_appear_frame := 2
@export_range(0, 8, 1) var blink_drop_frame := 3
## 空中段（现身 + 下落）完全免疫伤害。
## 开启后受击框不再拉长到地面 —— 免疫时画一个长条受击框是自相矛盾的。
## 关掉就恢复成「整段可被击中」（受击框从 Boss 头顶拉到地面）。
##
## 为什么默认开：下落 260px @ 1500px/s 只有 10.4 帧，
## 而 Boss 受击后有 11 帧无敌（iframe_ticks）——
## 也就是说只要你打中过一下，剩下的下落过程本来就打不到，
## 那个「输出窗口」是假的。与其给个时有时无的窗口，不如明确免疫。
@export var blink_drop_invincible := true
## Boss 身体高（下落时受击框从这条线一直拉到地面）
@export var blink_hurt_top := 106.0
## 默认 hurtbox 半宽
@export var blink_hurt_half_w := 30.0

@export_group("二阶段")
## 血量降到这个比例进入二阶段（0.5 = 50%）
@export_range(0.05, 0.95) var phase2_hp := 0.5
## 二阶段招式时长缩放（越小越快）
@export var phase2_dur_scale := 0.8
## 二阶段伤害缩放
@export var phase2_dmg_scale := 1.25
## 二阶段常驻泛红
@export var phase2_tint: Color = Color(1.4, 0.70, 0.70, 1.0)
## 普通拳射程的放宽量（像素）。0 = 严格等于两个 hurtbox 重叠（45）；
## 75 = 120px 内都算近身。不放宽的话 46~189 之间只剩闪现砸，形成死区。
@export var punch_reach_extra := 75.0

@export_group("美术适配")
## 换美术后角色在屏幕上有多大（像素高）。
## 只看「内容高度」，跟源图是 128 还是 768 无关 —— auto_fit 会自动算缩放倍率。
## Boss 与 Player 设成一样的数值就是一样大。
@export var art_display_height := 108.0
## 源图脚底所在行（像素）。换美术后如果角色浮空/陷地，跑 tools/check_art.py
## 会打印应该填多少。768×768 的图一般是 672。
@export_range(0, 768, 1) var art_ground_row := 672
@export_range(0, 768, 1) var art_cell := 768

var target: Node2D = null
var last_move_name := ""
var retreat_active := false      # 是否处于「击飞后后撤」状态
var retreat_dir := 1             # 后撤方向 = 击飞的反方向
var retreat_hit := false         # 后撤途中被玩家打中 -> 转向反击
var phase2 := false              # 是否进入二阶段
var phase_flash_t := 0.0         # 转阶段时的闪白计时（秒）
var retreat_t := 0.0             # 本次后撤已持续的时间（秒）
var retreat_blocked := false     # 撤退方向被挡（调试显示用）
var gun_burst := 0               # 本次连发已经打出去几发（0 = 不在连发中）
var walk_t := 0.0                # 当前这段走路已经走了多久（秒）
var retreat_start_x := 0.0       # 本次后撤的起点，用来判断实际走了多远
var dash_forced_dir := 0         # 贴墙冲拳锁定的朝向（0 = 没锁定）
var wall_dash_armed := true      # 贴墙冲拳是否已武装（离开墙足够远才会重新武装）
@onready var retreat_ray: RayCast2D = $RetreatRay


func _ready() -> void:
	super._ready()
	add_to_group("boss")
	iframe_ticks = 11              # 0.18 秒，防止玩家一击被重复判定
	# 普通拳射程在检查器里改，写进 MoveLibrary 的静态变量。
	# 必须在建招式表之前 —— 招式是在 boss_moves() 里读这个值的。
	MoveLibrary.PUNCH_REACH_EXTRA = punch_reach_extra
	# 美术尺寸同样从检查器写回（SpriteFactory 是 static func，读不到实例变量）
	SpriteFactory.BOSS_TARGET_H = art_display_height
	SpriteFactory.B_CELL = art_cell
	SpriteFactory.B_GROUND = art_ground_row
	MoveLibrary.PUNCH_REACH = (MoveLibrary.HURT_HALF_BOSS
			+ MoveLibrary.HURT_HALF_PLAYER + punch_reach_extra)
	if moves.is_empty():
		moves = MoveLibrary.boss_moves()
	if sprite != null:
		if sprite.sprite_frames == null:          # 场景里已直接挂了 .tres，这里只是兜底
			sprite.sprite_frames = SpriteFactory.build_boss()
			var fit := art_fit(sprite.sprite_frames)
			sprite.scale = Vector2(fit["scale"], fit["scale"])
			sprite.position = fit["offset"]
		sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	launched_player.connect(_on_launch_success)
	play(find_move("walk"))


## 闪现砸拳的「下落 + 悬停」段：受击框从 Boss 头顶一直拉到地面。
## 原本只有本体那一小块，而下落只要几帧 —— 玩家水平射出的子弹
## 根本来不及在正确的高度命中，等于下落全程无敌。
## 拉长之后，下落到地面之间的任意高度都能被打到，成为真正的惩罚窗口。
## 打出非枪类招式时清掉连发计数（换招就要从头算）
func play(move: AttackData) -> void:
	if not _is_gun_move(move):
		gun_burst = 0
	# 每次开新招式都重置走路计时。
	# 必须无条件重置（包括又选到 walk 的情况）——
	# 否则「走 2 秒 -> 重选 -> 又选到 walk」会因为 walk_t 已经累积而立刻超时，
	# Boss 就再也走不动了。
	walk_t = 0.0
	super.play(move)


## 一发打完：按概率决定是否再来一发（连发上限 5）
func _finish_move() -> void:
	var was := current
	super._finish_move()
	if dead or frozen or standby:
		return
	if was == null:
		return
	if was.move_name == "gun_shot":
		gun_burst = 1                        # 首发
	elif not _is_gun_move(was):
		gun_burst = 0
		return
	if gun_burst >= gun_burst_max:
		gun_burst = 0                        # 打满 5 发，收
		return
	if randf() >= gun_burst_chance:
		gun_burst = 0                        # 没连上，收
		return
	var bm := _pick_burst_move()
	if bm != null:
		play(bm)
		gun_burst += 1


## 是不是「枪」类招式（首发 gun_shot 或任意连发变体 gun_burst_N）
func _is_gun_move(m: AttackData) -> bool:
	if m == null:
		return false
	if m.move_name == "gun_shot":
		return true
	return m.move_name.begins_with("gun_burst")


## 连发的下一发用哪个变体（快慢刀）。
## 最后一发大概率延迟斩，中间几发在快/标准/慢之间随机 ——
## 节奏不可预测，玩家不能靠「听响数拍子」躲，必须看动作。
func _pick_burst_move() -> AttackData:
	var nxt := gun_burst + 1                  # 即将打出的是第几发
	var aim := burst_aim_norm
	if randf() < burst_delay_base * float(nxt - 1):
		aim = burst_aim_delay
	else:
		var r := randf()
		if r < 0.35:
			aim = burst_aim_fast
		elif r < 0.75:
			aim = burst_aim_norm
		else:
			aim = burst_aim_slow
	var m := find_move("gun_burst_%d" % aim)
	if m == null:                            # 找不到就退回标准，不至于卡住
		m = find_move("gun_burst_%d" % burst_aim_norm)
	return m


## 是否处于闪现砸的空中段（现身 + 下落）
func _in_blink_air() -> bool:
	if current == null or current.move_name != "blink_slam":
		return false
	return frame_index == blink_drop_frame or frame_index == blink_appear_frame


## 空中段免疫（见 blink_drop_invincible 的说明）
func _is_invincible() -> bool:
	return blink_drop_invincible and _in_blink_air()


func _dynamic_hurt_rect() -> Rect2:
	# 免疫时不拉长受击框 —— 画一个长条框却打不动是误导
	if blink_drop_invincible:
		return Rect2()
	if not _in_blink_air():
		return Rect2()
	var gy := Arena.GROUND_Y - global_position.y     # 地面在局部坐标的高度
	if gy <= 0.0:
		return Rect2()
	var top := -blink_hurt_top                        # Boss 头顶
	return Rect2(-blink_hurt_half_w, top, blink_hurt_half_w * 2.0, gy - top)


## 二阶段常驻泛红；受击时闪白优先（覆盖泛红）
func body_modulate() -> Color:
	# 死亡闪白必须盖住二阶段泛红，否则二阶段死亡时闪不出来
	if death_flash_t > 0.0:
		return Color(2.2, 2.0, 1.6, 1.0)
	if hurt_flash_t > 0.0:
		return hurt_flash_white
	return phase2_tint if phase2 else Color(1.0, 1.0, 1.0, 1.0)


## Boss 用 boss 的目标高度
func art_fit(sf: SpriteFrames) -> Dictionary:
	return SpriteFactory.auto_fit(sf, SpriteFactory.BOSS_TARGET_H,
			float(SpriteFactory.B_CELL), float(SpriteFactory.B_GROUND))


# ============================================================
# AI：选招
# ============================================================

func _act(delta: float) -> void:
	if phase_flash_t > 0.0:
		phase_flash_t -= delta
		queue_redraw()

	if target == null or not is_instance_valid(target):
		target = _resolve_target()

	var dist := 9999.0
	if target != null:
		dist = absf(target.global_position.x - global_position.x)

	# --- 击飞后撤：一直往击飞的反方向走，直到受击或走到头 ---
	# 关键：后撤期间 current 恒为 null，完全不走招式系统。
	# 这样任何「选招 / 打断 / 换招」逻辑都碰不到它 —— 走的时候绝不会出别的招。
	if retreat_active:
		# 结束条件：走到场地边界，或者【走过最短时间之后】被玩家打中
		# 最短时间是必须的：玩家射速约 18 帧/发，若受击立刻停，
		# Boss 每次只能退 0.3 秒（约 100px）就被打断，等于原地转炮
		retreat_t += delta
		var moved := absf(global_position.x - retreat_start_x)
		var at_edge := global_position.x <= min_x + 1.0 or global_position.x >= max_x - 1.0
		# 三条结束条件：
		#   1. 撤满 3 秒（硬上限，兜底）
		#   2. 走过最短时间后被玩家打中
		#   3. 撤退方向的前视射线撞到碰撞体（墙 / 边界）
		# 「走到头」必须真的走过一段才算 —— 否则上次的后撤已经把 Boss 留在边界上，
		# 这一次一开始 at_edge 就为真，会瞬间结束，看起来像「后撤没触发」
		var blocked := _retreat_blocked()
		retreat_blocked = blocked
		var should_stop := (
			retreat_t >= retreat_max_time
			or blocked
			or (at_edge and moved >= retreat_min_dist)
			or (retreat_hit and retreat_t >= retreat_min_time)
		)
		if should_stop:
			_end_retreat()
			return
		if retreat_hit:
			retreat_hit = false              # 最短时间内挨打：记下但不打断

		# 收掉可能残留的招式（普通拳后摇 / 上一次的 walk）
		if current != null:
			_finish_move()

		# 直接播 walk 动画，不经过帧数据 —— 没有招式在跑，也就不会被打断
		facing = retreat_dir
		if (
			sprite != null and sprite.sprite_frames != null
			and sprite.sprite_frames.has_animation("walk")
			and (sprite.animation != "walk" or not sprite.is_playing())
		):
			sprite.play("walk")

		velocity.x = float(retreat_dir) * retreat_speed
		if not is_on_floor():
			velocity.y += gravity * delta
		return

	# --- 走路中：一进入攻击范围就立刻打断，转而出招 ---
	#     另外走满 walk_max_time 也强制结束 —— 玩家一直跑开的话，
	#     不给上限 Boss 会无限追，观感很闷。
	if current != null and current.interruptible:
		walk_t += delta
		_face(dist)
		if dist <= attack_range or walk_t >= walk_max_time:
			_finish_move()
			return

	# --- 没有招式在跑：按距离选一个 ---
	if current == null:
		# 上一次招式已经结束，朝向锁定随之失效
		dash_forced_dir = 0
		var m := _pick_wall_dash()
		if m != null:
			last_move_name = m.move_name
			play(m)
		else:
			m = _choose(dist)
			if m == null:
				return
			_face(dist)
			play(m)

	# --- 前摇帧持续朝向玩家：这是玩家读招的依据 ---
	#     但贴墙冲拳期间方向已被锁定，不能再转向玩家 ——
	#     否则「贴左墙 → 向右冲」会立刻被翻回朝左，直接撞进墙里。
	if is_telegraphing() and dash_forced_dir == 0:
		_face(dist)

	_frame_tick(delta)


## 返回「指向玩家」的方向：1 = 玩家在右，-1 = 玩家在左
func face_toward_target() -> int:
	if target == null or not is_instance_valid(target):
		return facing
	return 1 if target.global_position.x > global_position.x else -1


func _face(dist: float) -> void:
	if target != null and dist > 4.0:
		facing = 1 if target.global_position.x > global_position.x else -1


## 贴到场地左右边界 -> 下一个动作改为朝场地内侧冲拳。
##
## 返回 null 表示「不触发」，交给正常的按距离选招。
##
## 三个要点：
##   1. 用「距离边界的余量」判定而不是 is_on_wall() ——
##      后者不区分左右，没法决定往哪边冲。
##   2. 武装/重新武装机制：触发一次后要离开墙 wall_dash_rearm 才会再次触发。
##      不做这个的话，冲拳结束时人还在墙边，会无限连冲。
##   3. 触发后锁 facing，并且前摇期间不再 _face（见 _act）。
##      冲拳第一帧带 telegraph，本来会持续转向玩家 —— 玩家在墙那侧时
##      会立刻把「向右冲」翻成「向左撞墙」。
func _pick_wall_dash() -> AttackData:
	if not wall_dash_enabled:
		return null
	var near_left := global_position.x <= min_x + wall_dash_margin
	var near_right := global_position.x >= max_x - wall_dash_margin
	if not near_left and not near_right:
		# 离开墙足够远 -> 重新武装
		if absf(global_position.x - min_x) > wall_dash_rearm \
				and absf(global_position.x - max_x) > wall_dash_rearm:
			wall_dash_armed = true
		return null
	if not wall_dash_armed:
		return null
	var m := find_move(wall_dash_move)
	if m == null:
		return null
	wall_dash_armed = false
	# 贴左墙 -> 朝右冲（+1）；贴右墙 -> 朝左冲（-1）
	dash_forced_dir = 1 if near_left else -1
	facing = dash_forced_dir
	return m


## 带防复读的选招：连续出同一招会有较高概率被强制换掉
func _choose(dist: float) -> AttackData:
	var m := _pick_move(dist)
	if m == null:
		return null
	if m.move_name == last_move_name and m.move_name != "walk":
		if randf() < repeat_avoid:
			var alt := _pick_move(dist)
			if alt != null and alt.move_name != m.move_name:
				m = alt
	last_move_name = m.move_name
	return m


## 霸体（常驻）：Boss 受击不击退、不进硬直、招式不会被打断。
## 这正是 Boss 该有的行为 —— 否则玩家一枪就能打断它的大招。
## 真正的霸体实现就是「这里什么位移都不做」。
func on_hurt(_from_dir: int, _knockback: float) -> void:
	# 不击退、不打断；只闪白。但后撤途中被打中会立刻转向反击
	if retreat_active:
		retreat_hit = true
	_check_phase()


## 血量跌破阈值 -> 进入二阶段：换招式池（整体更快更痛）+ 一次转换演出
func _check_phase() -> void:
	if phase2 or dead:
		return
	if health > max_health * phase2_hp:
		return
	phase2 = true
	phase_flash_t = 0.6
	Sfx.play("phase", 0.0, 1.0, false)
	Sfx.play("phase_hit", -3.0, 1.0, false)
	# 二阶段转场：震一下 + 闪一下，让「它变强了」这件事被看见。
	# 叠一层 phase_hit（金属刮擦）是让转场有层次，不然只有一记闷响。
	Fx.shake(0.85)
	Fx.flash(Color(1.0, 0.35, 0.45), 0.55)
	# 常驻泛红交给 body_modulate() 每帧算，不在这里直接设 ——
	# 否则受击闪红结束后不会恢复成二阶段的红色。
	var swap := MoveLibrary.boss_moves_phase2()
	if not swap.is_empty():
		moves = swap
	last_move_name = ""              # 防复读记录作废
	# 立刻停掉当前招式，避免用着旧（慢）版本的帧数据打完
	if current != null:
		_finish_move()
	# 无敌帧（iframe）：转阶段时短暂无敌，让转换有个「仪式感」的停顿。
	# 注意这是无敌，不是霸体 —— 霸体是常驻的（见下方 on_hurt，Boss 永不击退）。
	# 不想要这个停顿就删掉本行。
	iframe_t = maxi(iframe_t, 24)


## 撤退方向的前视：撞到任何碰撞体（墙 / 边界）就返回 true。
## 用 RayCast2D 而不是 is_on_wall() —— 能提前预判，不会硬撞上去卡一帧。
func _retreat_blocked() -> bool:
	if retreat_ray == null:
		return false
	retreat_ray.target_position = Vector2(float(retreat_dir) * retreat_ray_len, 0.0)
	retreat_ray.force_raycast_update()
	if retreat_ray.is_colliding():
		return true
	# 射线没配好时的兜底：贴到场地边界也算撞到
	return global_position.x <= min_x + 1.0 or global_position.x >= max_x - 1.0


## 普通拳打中且击飞成功 -> 本招结束后往后撤离
## 后撤记账：由 _act() 在 move_and_slide 之后延迟调用，
## 用「实际发生的位移」扣减，撞墙（位移≈0）时直接结束，不会卡死。
## 结束后撤：转向玩家并发大炮
func _end_retreat() -> void:
	retreat_active = false
	retreat_hit = false
	if current != null:
		_finish_move()                  # 收掉 walk
	facing = face_toward_target()       # 转向玩家
	var m := find_move(retreat_end_move)
	if m != null:
		play(m)
	# 招式为空就什么都不做，下一帧 _act() 会正常按距离选招



## 招式命中并标记了 retreat_on_launch -> 进入后撤
## 参数由 launched_player 信号传入（触发的招式），目前不需要，用 _ 忽略
func _on_launch_success(_move: AttackData = null) -> void:
	# 击退值门槛：kb <= retreat_min_kb 说明没真的把玩家打退，不撤退。
	# 用 current_knockback（本帧实际生效的击退），不是帧数据的静态值。
	if current_knockback <= retreat_min_kb:
		return
	# 只设标记，真正的收招/切走路交给下一帧 _act() 处理，
	# 避免在命中回调里清空 current 导致帧推进读到半个状态
	retreat_active = true
	retreat_hit = false
	retreat_t = 0.0
	retreat_start_x = global_position.x
	retreat_dir = -attack_dir            # 击飞的反方向
	# 若这个方向正对着墙（比如上次后撤后还站在边界），改往另一侧退，
	# 否则一步都走不动，会立刻被 at_edge 判定结束
	if global_position.x <= min_x + 1.0 and retreat_dir < 0:
		retreat_dir = 1
	elif global_position.x >= max_x - 1.0 and retreat_dir > 0:
		retreat_dir = -1


# ============================================================
# 绘制。前摇预警已全部移除 —— 现在只留二阶段转场演出 + 调试判定框（F1）
# ============================================================

func _draw() -> void:
	# 先画父类的调试判定框（hitbox / hurtbox），Boss 覆写时别漏了
	super._draw()
	# 二阶段转换：以自身为中心的扩散冲击波 + 全身泛红
	if phase_flash_t > 0.0:
		var k := clampf(phase_flash_t / 0.6, 0.0, 1.0)     # 1 -> 0
		var r := (1.0 - k) * 260.0 + 40.0                   # 向外扩散
		draw_arc(Vector2(0, -80), r, 0, TAU, 48,
				Color(1.0, 0.35, 0.30, k * 0.9), 6.0, true)
		draw_arc(Vector2(0, -80), r * 0.6, 0, TAU, 36,
				Color(1.0, 0.75, 0.35, k * 0.7), 4.0, true)


extends Node2D
## HUD + result screen + restart.
##
## The only stat tracked is the fight timer.

@onready var player: Player = $Player
@onready var boss: Boss = $Boss

var player_bar: ProgressBar
var boss_bar: ProgressBar
## 「追尾条」：垫在实血条下面的那层浅色条。
## 实血条立刻掉，这层慢慢追上去 —— 中间露出的那一截就是刚掉的血，
## 玩家能直接看出「这一下掉了多少」，而不是只看到条变短了一点。
var player_lag: ProgressBar
var boss_lag: ProgressBar

var debug_root: Control             # 调参 UI 的容器，visible 由 F1 控制
var god_button: Button              # 无敌开关按钮（挂在 debug_root 下，F1 控制）
var touch_button: Button            # 虚拟按键开关（常驻可见，不跟 F1 走）
var virtual_pad: VirtualPad         # 触屏虚拟按键（见 VirtualPad.gd）

## 全局节奏倍率。0.75 = 当前节奏的 0.75 倍（整体放慢到 1/0.75 = 1.33 倍时长）。
##
## 这是「整体节奏」唯一的正确旋钮 —— 它缩放的是 Engine.time_scale，
## 也就是 delta。移动（velocity*delta）、动画（按 delta 播）、
## 招式帧（FrameActor._step_ticks 把 delta 换算成 tick）三者一起变，
## 所以画面里所有东西保持同步。
##
## **不要改 FrameActor.FIXED_DT 来做这件事**（见 README「tick 时长」一节）：
## FIXED_DT 只影响「计数推进」，移动和动画仍走真实 delta，
## 结果就是动画播完定住、位移跟帧表脱节。
##
## 注意 fight_time（计时/评级）是「游戏内秒数」，不随这个倍率变化 ——
## 放慢只是让同样的内容花更长的真实时间，游戏内时长不变，
## 所以 S/A/B/C 的门槛不需要跟着调。
@export var game_speed := 0.75

## 慢放倍率（按 P 切换）。0.25 = 四分之一速，足够逐帧看动作。
## 是**叠在 game_speed 之上**的：总倍率 = game_speed * slowmo_scale。
@export var slowmo_scale := 0.25

@export_group("结算演出")
## 死亡瞬间的慢动作倍率。让爆闪和死亡动画能看清。
## 1.0 = 不慢放。
@export var end_slowmo_scale := 0.25
## 死亡动画播完后，再停顿多久（真实秒数）才弹结算面板。
## 给一个呼吸的间隙，别让动画一停面板就糊上来。
@export var end_beat_time := 0.35
## 保险丝：最多等这么久（真实秒数）就必须弹结算。
## 正常情况下由「死亡动画播完」触发，这个只是防止信号没来导致永远卡住。
@export var end_death_timeout := 4.0
## 结算前是否先播一段全屏过场（16:9，约 10 秒，目前是 DUMMY 占位）。
## 关掉就直接弹结算，跟以前一样。
@export var play_end_cutscene := true
## 过场时长（秒）。真实时间，不受死亡慢动作影响。
@export_range(1.0, 60.0, 0.5) var end_cutscene_duration := 10.0
## 伤害飘字开关。默认关 —— 想在检查器里打开也行。
@export var damage_numbers := false
## 虚拟按键开关。默认关，但**收到触摸事件会自动打开**
## （见 VirtualPad.auto_show_on_touch）—— 手机上没有键盘，
## 不自动开的话根本没法玩。改成事件驱动而不是查设备类型，
## 是因为 OS.has_touchscreen_ui_hint() 在不同版本上行为不一致。
## 在电脑上想调试虚拟按键，就在这里勾上，或者点屏幕上的 TOUCH 按钮。
@export var virtual_pad_enabled := false
## 血条追尾速度（血量/秒）。越大越快追上（残留的黄条消失得越快）。
@export var lag_speed := 260.0
var time_label: Label
var debug_label: Label
var anim_label: Label

var result_layer: CanvasLayer
var result_wrap: Control             # 结算内容的容器（动画作用在它身上）
var result_dim: ColorRect            # 结算的暗背景，单独淡入
var result_title: Label
var result_time: Label
var result_rank: Label

var fight_time := 0.0
var fight_over := false
## 结算只弹一次。
##
## 之前只靠 _wait_death_then_result 里的局部 done 标志，
## 但那是「一次战斗一个闭包」级别的：只要 _show_result 有任何第二条
## 调用路径（保险丝超时 / 动画结束 / 重开时的残留 timer），就会弹两次。
## 这里加一层节点级的幂等，任何路径进来都只生效一次。
var result_shown := false
var end_cutscene: EndCutscene = null      # 结算前的过场（DUMMY）
var _last_win := false
var _result_tween: Tween
var _dim_tween: Tween


func _ready() -> void:
	# 全局节奏在这里生效一次。之后 P 键慢放 / 死亡慢动作都基于它叠加。
	Engine.time_scale = game_speed
	_build_camera()
	_build_ui()
	player.health_changed.connect(func(cur: int, _mx: int) -> void:
		if player_bar != null:
			player_bar.value = cur
	)
	boss.health_changed.connect(func(cur: int, _mx: int) -> void:
		if boss_bar != null:
			boss_bar.value = cur
	)

	boss.damage_taken.connect(func(amt: int, remain: int) -> void:
		_pop_number(boss, amt, Color(1.0, 0.92, 0.55, 1.0))
		_tick_combo()
		if remain <= 0:
			_end_fight(true)
	)
	player.damage_taken.connect(func(amt: int, remain: int) -> void:
		_pop_number(player, amt, Color(1.0, 0.45, 0.45, 1.0))
		if remain <= 0:
			_end_fight(false)
	)

	player_bar.max_value = player.max_health
	player_bar.value = player.max_health

	boss_bar.max_value = boss.max_health
	boss_bar.value = boss.max_health
	player_lag.max_value = player.max_health
	player_lag.value = player.max_health
	boss_lag.max_value = boss.max_health
	boss_lag.value = boss.max_health
	_update_time()


## 在目标头顶冒一个伤害数字。
## 挂在 Main（世界坐标）而不是 HUD 上 —— 要跟着角色走，
## 挂在 HUD 上的话角色移动时数字会留在原地。
func _pop_number(who: Node2D, amt: int, col: Color) -> void:
	if who == null or amt <= 0 or not damage_numbers:
		return
	DamageNumber.spawn(self, who.position + Vector2(0.0, -130.0), amt, col)


## 追尾条慢慢追上实血条。
## 用「每秒固定速度」而不是 lerp —— lerp 永远追不上（渐近），
## 掉一点血时会留一条永远消不掉的细缝。
func _update_lag(delta: float) -> void:
	var step := lag_speed * delta
	if boss_lag != null and boss_bar != null:
		boss_lag.value = move_toward(boss_lag.value, boss_bar.value, step)
	if player_lag != null and player_bar != null:
		player_lag.value = move_toward(player_lag.value, player_bar.value, step)


func _process(delta: float) -> void:
	if not fight_over:
		fight_time += delta
		_tick_low_hp(delta)
		if _combo_t > 0.0:
			_combo_t -= delta
			if _combo_t <= 0.0:
				_combo = 0
		_update_time()
	_update_lag(delta)

	# Live debug: which move the boss is running. Handy while tuning frame data.
	if player != null and player.sprite != null:
		var sf := player.sprite.sprite_frames
		var n := sf.get_frame_count(player.sprite.animation) if sf != null else 0
		var sc := player.sprite.scale.x
		anim_label.text = "PLAYER: %s  %d/%d  scale %.2f  spd %.1f%s%s" % [
			player.sprite.animation, player.sprite.frame + 1, n, sc,
			player.sprite.speed_scale,
			"  !! scale 0" if sc <= 0.01 else "",
			# iframe > 0 = 现在打不动（翻滚中）。受击后不应该出现这个。
			("  iframe %d" % player.iframe_t) if player.iframe_t > 0 else "  iframe 0",
		]
	if boss.retreat_active:
		debug_label.text = "MOVE: RETREAT  walked %.0fpx  %.1fs / max %.0fs%s%s" % [
			absf(boss.global_position.x - boss.retreat_start_x), boss.retreat_t,
			boss.retreat_max_time,
			"  (hit)" if boss.retreat_hit else "",
			"  (wall)" if boss.retreat_blocked else "",
		]
	elif boss.current == null or boss.frame_index >= boss.current.frames.size():
		debug_label.text = "MOVE: -"
	else:
		var f: FrameData = boss.current.frames[boss.frame_index]
		var dur := f.duration if f != null else 0
		debug_label.text = "MOVE: %s  frame #%d [%s]  tick %d/%d%s" % [
			boss.current.move_name,
			boss.frame_index,
			boss.current_label(),
			boss.frame_ticks,
			dur,
			"  [PHASE 2]" if boss.phase2 else "",
		]


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("restart"):
		_restart()
	if event.is_action_pressed("slowmo"):
		# 结算演出期间不响应 —— 否则按一下 P 就会把死亡慢动作解开，
		# 或者把演出卡在慢速里出不来。
		if fight_over:
			return
		# 慢放切换。Engine.time_scale 只缩放 delta ——
		# 移动/动画靠 delta 自动变慢，招式帧靠 FrameActor._step_ticks()
		# 把 delta 换算成逻辑帧，也跟着变慢。三者保持一致。
		var slow := Engine.time_scale < game_speed * 0.99
		Engine.time_scale = game_speed if slow else game_speed * slowmo_scale

	if event.is_action_pressed("debug_boxes"):
		# static 变量：玩家和 Boss 一起切判定框
		FrameActor.show_boxes = not FrameActor.show_boxes
		# 调参 UI 一起开关 —— 招式名/动画帧这些平时不该占屏幕
		if debug_root != null:
			debug_root.visible = FrameActor.show_boxes


## 无敌开关。切换的是 Player.god_mode ——
## take_damage() 里直接 return false，所以子弹会穿过去继续飞
## 而不是消失，视觉上能明确看出「我躲掉了 / 我没在掉血」。
func _on_god_pressed() -> void:
	if player == null or god_button == null:
		return
	player.god_mode = not player.god_mode
	_style_god_button()


func _restart() -> void:
	# 必须手动复位：reload_current_scene 不会重置 Engine.time_scale，
	# 死亡慢动作会带进下一局，新一局开局就是慢的。
	# 复位到 game_speed 而不是 1.0 —— 否则重开一局节奏就变了。
	Engine.time_scale = game_speed
	get_tree().reload_current_scene()


# ---------------- Fight end ----------------

func _end_fight(won: bool) -> void:
	if fight_over or result_shown:
		return
	fight_over = true

	# 慢动作：让死亡演出能看清。
	# 立刻冻结双方的话，死亡动画会被 speed_scale=0 定住 —— 等于没有演出。
	# 所以先只冻住「活着的那个」（防止它继续攻击），
	# 让死掉的那个把 dead 动画和爆闪放完。
	# 不能用三元：boss 是 Boss、player 是 Player，
	# Godot 的三元要求两边类型「互相兼容」，两个不同子类即使有共同基类
	# 也会报 INCOMPATIBLE_TERNARY。显式写 `var x: FrameActor =` 只解决了
	# Variant 推断，消不掉这条。改用 if/else 最干净。
	var loser: FrameActor
	var winner: FrameActor
	if won:
		loser = boss
		winner = player
	else:
		loser = player
		winner = boss
	# 胜者**不要定格** —— 用 standby：停止行动与判定，但 idle 呼吸继续播。
	# 原来这里写 winner.frozen = true，speed_scale 被归零，
	# 胜者直接僵在原地一动不动，看着像游戏卡死了。
	winner.set_standby()
	# 转身面对败者：正常流程里 flip_h 是在 _act 之后设的，
	# standby 分支自己设 flip_h，所以要先把 facing 调好。
	if winner != null and loser != null:
		winner.facing = -1 if loser.global_position.x < winner.global_position.x else 1
	boss.target = null
	_hide_debug_on_end()

	# 清掉飞行中的子弹，避免死亡演出期间还在扣血
	for n in get_tree().get_nodes_in_group("bullet"):
		n.queue_free()

	Engine.time_scale = game_speed * end_slowmo_scale
	Sfx.play("win" if won else "lose", 0.0, 1.0, false)

	# 等「败者的 dead 动画真正播完」再弹结算 ——
	# 不能再用固定时长的定时器：慢动作把动画的真实耗时拉长了 4 倍
	# （Boss dead 4 帧 @ speed 8 = 0.5s，0.25 倍速下要 2.0 秒才播完），
	# 而原来只等 1.1 秒 —— 结算会在动画播到一半时就弹出来，
	# 死亡演出等于没有。改成等动画自己的 animation_finished 信号。
	_wait_death_then_result(loser, won)


## 等败者的 dead 动画播完 + 一小段停顿，然后弹结算。
##
## 两个触发条件取「先到的那个」：
##   1. sprite.animation_finished —— 正常路径，慢动作下的真实耗时算得准
##   2. end_death_timeout 保险丝 —— 万一没有 dead 动画 / 信号没来，不能永远卡住
##
## 定时器一律用 ignore_time_scale=true —— 否则慢动作会把等待也拉长，
## 结算永远出不来。
func _wait_death_then_result(loser: FrameActor, won: bool) -> void:
	var done := false
	var finish := func() -> void:
		if done or result_shown:
			return
		done = true
		Engine.time_scale = game_speed
		loser.frozen = true          # 演出结束，死者也定住
		if play_end_cutscene and end_cutscene != null:
			_last_win = won
			_play_end_cutscene(won)
		else:
			_show_result(won)

	var t := get_tree().create_timer(end_death_timeout, true, false, true)
	t.timeout.connect(finish)

	# 连接死亡动画要推迟到本帧末尾：
	# _end_fight 是从 damage_taken 信号里调进来的，而那个信号在 _die() 之前发出
	# （见 FrameActor.take_damage）—— 此刻 sprite 还没开始播 dead。
	# 不推迟的话，可能接到上一段动画（jab / dash / hurt）的 animation_finished，
	# 结算就会提前弹出。
	_connect_death_anim.call_deferred(loser, finish)


## 播结算前的过场，播完（或跳过）再弹结算。
##
## 触发结算前的过场，播完（或被跳过）再弹结算。
func _play_end_cutscene(won: bool) -> void:
	if end_cutscene == null:
		_show_result(won)
		return
	# finished 每次都重连会累积：一局只结算一次，但 reconnect 之前
	# 先断开同名回调更安全（重开后 Main 会重建，一般不会走到这里）。
	if end_cutscene.finished.is_connected(_on_cutscene_done):
		end_cutscene.finished.disconnect(_on_cutscene_done)
	end_cutscene.finished.connect(_on_cutscene_done, CONNECT_ONE_SHOT)
	end_cutscene.play(won)


func _on_cutscene_done() -> void:
	_show_result(_last_win)


## 造过场：一个常驻的 CanvasLayer(layer=150) + 里面的过场节点。
##
## 过场节点必须**一直在场景树里** —— 不进树的话 _process 不跑、
## _ready() 也不会执行（anchors / mouse_filter 都在 _ready 里设）。
## 平时靠 EndCutscene 自己的 visible=false 藏起来，
## CanvasLayer 本身没有 visible 属性，不用管它。
func _build_end_cutscene() -> void:
	var layer := CanvasLayer.new()
	layer.name = "EndCutLayer"
	layer.layer = 150          # 高于 HUD(0)，低于结算面板(200)
	add_child(layer)

	end_cutscene = EndCutscene.new()
	end_cutscene.name = "EndCutscene"
	end_cutscene.duration = end_cutscene_duration
	layer.add_child(end_cutscene)


## 在 dead 动画确实在播的前提下，等它播完再收尾。
func _connect_death_anim(loser: FrameActor, finish: Callable) -> void:
	var sp := loser.sprite
	if sp == null or not is_instance_valid(sp):
		return
	if sp.animation != "dead":
		return                              # 没有在播死亡动画，交给保险丝
	var on_end := func() -> void:
		# 停顿一小段再弹，让最后一帧被看见
		var b := get_tree().create_timer(end_beat_time, true, false, true)
		b.timeout.connect(finish)
	sp.animation_finished.connect(on_end, CONNECT_ONE_SHOT)


## 底部操作提示。
## 键位写死在 InputSetup.KEYMAP 里，没有自定义键位，所以写死的字符串
## 就是准确的。改键位时记得同步改这里 —— 两边在同一处改不容易，
## 但为 8 个动作做一套设置界面不值得。
const KEY_HINT := "A/D Move    W Jump    SPACE Roll    J Fire    R Restart"


func _key_hint() -> String:
	return KEY_HINT


func _show_result(won: bool) -> void:
	if result_shown:
		return
	result_shown = true
	result_title.text = "VICTORY" if won else "DEFEAT"
	# 霓虹 + 色差（chromatic aberration）：
	# 胜 = 青字配洋红影，负 = 洋红字配青影。
	# 影子靠 Label 的 font_shadow + offset 做，偏移 4px 就是「重影」，
	# 比单纯的发光更有故障感，也不用额外节点。
	result_title.add_theme_color_override("font_color",
			C_CYAN if won else C_MAGENTA)
	result_title.add_theme_color_override("font_shadow_color",
			Color(C_MAGENTA.r, C_MAGENTA.g, C_MAGENTA.b, 0.85) if won
			else Color(C_CYAN.r, C_CYAN.g, C_CYAN.b, 0.85))
	result_title.add_theme_constant_override("shadow_offset_x", 4)
	result_title.add_theme_constant_override("shadow_offset_y", 0)
	result_time.text = "%s  %s" % [
		"CLEAR TIME" if won else "SURVIVED", _fmt_time(fight_time)]
	if result_rank != null:
		result_rank.text = _rank_text(won)
		result_rank.add_theme_color_override("font_color",
				_rank_color(won))
	# 结算面板淡入 + 轻微放大。
	# 必须动 wrap（Control）而不是 result_layer（CanvasLayer）——
	# CanvasLayer 是 Node，没有 scale / pivot_offset，动了会报错。
	result_layer.visible = true
	if result_wrap != null:
		# 先 kill 掉可能还活着的旧 tween：两个 tween 同时动画同一个属性
		# 会互相打架，视觉上就是面板「弹出来两次」。
		if _result_tween != null and _result_tween.is_valid():
			_result_tween.kill()
		result_wrap.modulate = Color(1, 1, 1, 0)
		result_wrap.scale = Vector2(1.12, 1.12)
		result_wrap.pivot_offset = Vector2(576, 324)
		_result_tween = create_tween()
		_result_tween.set_parallel(true)
		_result_tween.tween_property(result_wrap, "modulate", Color(1, 1, 1, 1), 0.35)
		_result_tween.tween_property(result_wrap, "scale", Vector2(1.0, 1.0), 0.35)\
				.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	if result_dim != null:
		if _dim_tween != null and _dim_tween.is_valid():
			_dim_tween.kill()
		result_dim.color = Color(0.02, 0.02, 0.05, 0.0)
		_dim_tween = create_tween()
		_dim_tween.tween_property(result_dim, "color", Color(0.02, 0.02, 0.05, 0.72), 0.30)
	_update_time()


## 结束时把 F1 调试信息藏掉 —— 结算画面上不该有招式名/帧号
func _hide_debug_on_end() -> void:
	if debug_root != null:
		debug_root.visible = false
	FrameActor.show_boxes = false
	if boss != null:
		boss.queue_redraw()
	if player != null:
		player.queue_redraw()


func _fmt_time(t: float) -> String:
	var total := int(t)
	var m := total / 60
	var s := total % 60
	var d := int((t - float(total)) * 10.0)
	return "%02d:%02d.%d" % [m, s, d]


func _update_time() -> void:
	if time_label == null:
		return
	time_label.text = "TIME  %s" % _fmt_time(fight_time)


# ---------------- UI ----------------

## 摄像机：给 Fx 的屏幕震动用。
##
## 场景里只要有一个 enabled 的 Camera2D，它就接管视口渲染。
## 震动改的是这个摄像机的 offset —— 比挪整个场景树安全，
## 挪树会连带移动 UI 和碰撞体，等于把游戏世界搞乱。
# ============================================================
# 连击音
# ============================================================

## 连击音：连续命中 Boss 时，音高一段段往上爬。
##
## 为什么需要：射速 3.3 发/秒，连续打中时每发的 hit 音一模一样，
## 听久了像机器在响。音高递增能把「我在持续输出」这件事听出来。
##
## 超过 combo_window 秒没打中就断 —— 连击必须是「连续的」才有意义。
var _combo := 0
var _combo_t := 0.0
@export var combo_window := 1.2
@export var combo_max := 8


func _tick_combo() -> void:
	_combo = mini(_combo + 1, combo_max)
	_combo_t = combo_window
	if _combo >= 2:
		# 第 2 连起每级 +9% 音高
		var pit := 1.0 + float(_combo - 2) * 0.09
		Sfx.play("combo", 0.0, pit, false)


# ============================================================
# 低血警告
# ============================================================

## 玩家血量跌破 low_hp_ratio 后，每隔一段时间播一次心跳音。
##
## 之前只有闪红 + 顿帧作为被打中的反馈，但「快死了」这件事
## 没有任何提示 —— 玩家得一直盯着血条。有个声音就不用看了。
##
## 只在跌破后播、且回血到阈值以上会重置，不会一直响。
var _low_hp_t := 0.0
var _low_hp_active := false
@export var low_hp_ratio := 0.25
@export var low_hp_interval := 1.6


func _tick_low_hp(delta: float) -> void:
	if player == null or fight_over:
		return
	if player.health > player.max_health * low_hp_ratio:
		_low_hp_active = false
		_low_hp_t = 0.0
		return
	if not _low_hp_active:
		_low_hp_active = true
		_low_hp_t = 0.0            # 刚跌破，立刻响一次
	_low_hp_t -= delta
	if _low_hp_t <= 0.0:
		_low_hp_t = low_hp_interval
		Sfx.play("low_hp", -5.0, 1.0, false)


# ============================================================
# 结算评级
# ============================================================

## 评级：胜利用时越短越高，失败统一显示「—」。
## 阈值是拍的，改 RANK_* 常量即可。
const RANK_S := 30.0
const RANK_A := 60.0
const RANK_B := 100.0


func _rank_text(won: bool) -> String:
	if not won:
		return "RANK  —"
	var t := fight_time
	if t <= RANK_S:
		return "RANK  S"
	if t <= RANK_A:
		return "RANK  A"
	if t <= RANK_B:
		return "RANK  B"
	return "RANK  C"


func _rank_color(won: bool) -> Color:
	if not won:
		return Color(0.62, 0.66, 0.74)
	var t := fight_time
	if t <= RANK_S:
		return Color(1.0, 0.85, 0.42)
	if t <= RANK_A:
		return Color(0.72, 1.0, 0.86)
	if t <= RANK_B:
		return Color(0.66, 0.84, 1.0)
	return Color(0.78, 0.78, 0.84)


# ============================================================
# UI 配色（赛博朋克）
# ============================================================
## 青 = 玩家 / 主界面，洋红 = Boss，琥珀 = 追尾伤害。
## 底色压到接近纯黑（带一点蓝）是刻意的 ——
## 霓虹色靠的是「极暗底 + 极亮线」的对比，
## 底色一亮霓虹就糊掉，反而更像普通的圆角 UI。
const C_CYAN := Color(0.00, 0.92, 1.00)
const C_MAGENTA := Color(1.00, 0.16, 0.45)
const C_AMBER := Color(1.00, 0.72, 0.10)
const C_DIM := Color(0.52, 0.74, 0.82)


func _build_camera() -> void:
	var cam := Camera2D.new()
	cam.position = Vector2(576.0, 324.0)     # 视口中心
	cam.enabled = true
	add_child(cam)
	Fx.bind_camera(cam)


func _build_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)

	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	canvas.add_child(root)

	# ---------------- Boss 血条：下方置中（不显示名字） ----------------
	# 视口是 1152x648 而不是 720。地面在 y=560，地面以下只有 88px 可用 ——
	# 血条放 672 会直接掉出屏幕（之前踩过这个坑，以为它只是被挡住了）。
	# 名字去掉之后，原来那 130px 的名字列直接并入血条：
	# 560 -> 640，居中。Boss 条是全场焦点，宽一点压迫感更足。
	var bar_w := 640.0
	var bar_h := 20.0
	var row_x := (1152.0 - bar_w) / 2.0                # 居中
	var row_y := 574.0

	boss_lag = _make_bar(C_AMBER, false)
	boss_lag.size = Vector2(bar_w, bar_h)
	boss_lag.position = Vector2(row_x, row_y)
	root.add_child(boss_lag)

	boss_bar = _make_bar(C_MAGENTA)
	boss_bar.size = Vector2(bar_w, bar_h)
	boss_bar.position = Vector2(row_x, row_y)
	root.add_child(boss_bar)


	# ---------------- Player 血条：左上角 ----------------
	player_lag = _make_bar(C_AMBER, false)
	player_lag.size = Vector2(320, 18)
	player_lag.position = Vector2(40, 40)
	root.add_child(player_lag)

	player_bar = _make_bar(C_CYAN)
	player_bar.size = Vector2(320, 18)
	player_bar.position = Vector2(40, 40)
	root.add_child(player_bar)

	var player_name := Label.new()
	player_name.text = "PLAYER"
	player_name.position = Vector2(40, 14)
	player_name.add_theme_font_size_override("font_size", 16)
	player_name.add_theme_color_override("font_color", C_CYAN)
	root.add_child(player_name)

	# ---------------- 无敌按钮：归到 F1 调试组 ----------------
	# 它是调参用的，不该在游戏画面上常驻 —— 玩家看到「无敌」两个字
	# 会以为是正式功能。
	# 挂进 debug_root（下面才创建，等那边 add_child 一次即可），
	# 于是跟招式名/帧号一起由 F1 开关。
	god_button = Button.new()
	god_button.text = "INVINCIBLE: OFF"
	god_button.focus_mode = Control.FOCUS_NONE
	god_button.size = Vector2(220, 44)
	# 放右上角、计时器正下方。
	# 一开始放在右下角，但 Boss 血条宽 560、右端到 x=927，
	# 而按钮从 x=892 起 —— 直接压在血条上。
	# 屏幕下方只有 88px（地面 y=560 以下）且已被血条和提示占满，
	# 上方计时器下面这块是空的，放这里最干净。
	god_button.position = Vector2(1152 - 40 - 220, 58)
	god_button.add_theme_font_size_override("font_size", 16)
	god_button.pressed.connect(func() -> void:
		Sfx.play("ui_click")
		_on_god_pressed()
	)
	_style_god_button()

	# ---------------- 虚拟按键开关：右上角 ----------------
	# 常驻可见（**不**跟 F1 走）：手机上没键盘也按不出 F1，
	# 玩家第一个要找的就是这个开关，藏起来等于触屏完全没法用。
	# y=108 保持不动 —— 不因无敌按钮隐藏而上移，否则按 F1 时
	# 按钮会跳一下，比留个空位更难受。
	touch_button = Button.new()
	touch_button.text = "TOUCH: OFF"
	touch_button.focus_mode = Control.FOCUS_NONE
	touch_button.size = Vector2(220, 44)
	touch_button.position = Vector2(1152 - 40 - 220, 108)
	touch_button.add_theme_font_size_override("font_size", 16)
	touch_button.pressed.connect(func() -> void:
		Sfx.play("ui_click")
		_on_touch_pressed()
	)
	root.add_child(touch_button)
	_style_touch_button()

	# 按键提示：放在 Boss 血条下方并居中（不写 F1 —— 那是调试键，不该占画面）
	var hint := Label.new()
	# 从 InputSetup 现取 —— 玩家在开局界面改过键位的话，
	# 这里写死 "A/D / SPACE..." 就会跟实际不符，等于骗人。
	hint.text = _key_hint()
	hint.size = Vector2(560, 22)
	hint.position = Vector2((1152 - 560) / 2, 606)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 16)
	hint.add_theme_color_override("font_color", C_DIM)
	root.add_child(hint)

	# ---------------- 调试 UI：只在按 F1 时可见 ----------------
	# 这些是调参用的（招式名 / 动画帧 / scale / iframe），
	# 平时不该占屏幕。debug_root 的 visible 由 F1 控制，见 _input()。
	debug_root = Control.new()
	debug_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	debug_root.visible = false
	root.add_child(debug_root)

	# 无敌按钮收进调试组：add_child 会自动改父节点，不用先 remove。
	# debug_root 是全屏 Control 且位置在原点，
	# 所以 god_button 的 position 不用改，屏幕坐标不变。
	if god_button != null:
		debug_root.add_child(god_button)

	anim_label = Label.new()
	anim_label.position = Vector2(40, 160)
	anim_label.add_theme_font_size_override("font_size", 15)
	anim_label.add_theme_color_override("font_color", Color(0.70, 0.86, 0.72))
	debug_root.add_child(anim_label)

	debug_label = Label.new()
	debug_label.position = Vector2(40, 190)
	debug_label.add_theme_font_size_override("font_size", 15)
	debug_label.add_theme_color_override("font_color", Color(0.75, 0.80, 0.95))
	debug_root.add_child(debug_label)

	# Timer only - top right.
	time_label = Label.new()
	time_label.size = Vector2(240, 40)
	time_label.position = Vector2(1152 - 40 - 240, 10)
	time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	time_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	time_label.add_theme_font_size_override("font_size", 24)
	time_label.add_theme_color_override("font_color", C_CYAN)
	root.add_child(time_label)

	# ---------------- 装饰层：四角括号 + CRT 扫描线 ----------------
	# 必须放在最后 add_child —— 它要盖在所有 HUD 元素之上。
	# 扫描线是「屏幕」的效果，不是某个控件的背景，压在最上层才对。
	# 鼠标过滤 IGNORE，不会挡住底下的按钮。
	var decor := HudDecor.new()
	decor.set_anchors_preset(Control.PRESET_FULL_RECT)
	decor.bracket_color = Color(C_CYAN.r, C_CYAN.g, C_CYAN.b, 0.80)
	root.add_child(decor)

	_build_result_panel()
	_build_end_cutscene()
	_build_virtual_pad()


## 建虚拟按键。
##
## **不用 OS.has_touchscreen_ui_hint()** 判断是不是触屏设备 ——
## 它在不同 Godot 版本上存在性/返回类型不一致（本项目报过 Parse error），
## 而且「设备有触摸屏」跟「玩家此刻想用触屏」是两回事：
## 带触摸屏的笔记本上开着虚拟按键反而碍事。
##
## 改成**收到真正的触摸事件才自动开**：见 VirtualPad._input()。
## 这样零 API 依赖，且桌面接触摸屏、手机上都能正确工作。
##
## 注意 CanvasLayer **没有 visible 属性**（Node 不是 CanvasItem），
## 所以开关走的是 VirtualPad.set_enabled()，由它去藏内部的 Control。
func _build_virtual_pad() -> void:
	virtual_pad = VirtualPad.new()
	virtual_pad.name = "VirtualPad"
	add_child(virtual_pad)
	virtual_pad.set_enabled(virtual_pad_enabled)
	# 自动开启时同步按钮文字 —— 否则按钮还写着 OFF，实际已经是开的。
	virtual_pad.pad_enabled_changed.connect(func(_on: bool) -> void:
		_style_touch_button()
	)
	_style_touch_button()


func _on_touch_pressed() -> void:
	if virtual_pad == null:
		return
	virtual_pad.set_enabled(not virtual_pad.is_enabled())
	_style_touch_button()


## TOUCH 按钮换肤。跟无敌按钮同一套路子：
## 换 StyleBox 而不只是改文字色 —— 余光里也能看出当前是开是关。
## OFF：暗底 + 青边；ON：琥珀底 + 亮金字。
func _style_touch_button() -> void:
	if touch_button == null:
		return
	var on := virtual_pad != null and virtual_pad.is_enabled()
	var edge := C_AMBER if on else C_CYAN
	var face := Color(C_AMBER.r, C_AMBER.g, C_AMBER.b, 0.20) if on \
			else Color(0.02, 0.04, 0.08, 0.88)
	touch_button.text = "TOUCH: ON" if on else "TOUCH: OFF"
	touch_button.add_theme_color_override("font_color",
			Color(1.0, 0.90, 0.62) if on else Color(0.62, 0.84, 0.90))
	touch_button.add_theme_stylebox_override("normal", _neon_sb(face, edge))
	touch_button.add_theme_stylebox_override("hover",
			_neon_sb(Color(face.r + 0.10, face.g + 0.10, face.b + 0.10, face.a), edge))
	touch_button.add_theme_stylebox_override("pressed",
			_neon_sb(Color(C_AMBER.r, C_AMBER.g, C_AMBER.b, 0.38) if on \
					else Color(0.00, 0.30, 0.36, 0.30), edge))
	touch_button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


func _build_result_panel() -> void:
	result_layer = CanvasLayer.new()
	result_layer.layer = 200            # above the HUD canvas
	result_layer.visible = false
	add_child(result_layer)

	# Dim backdrop. Must be STOP so taps do not reach the buttons underneath.
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.01, 0.01, 0.04, 0.80)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	result_layer.add_child(dim)
	result_dim = dim

	var wrap := Control.new()
	wrap.set_anchors_preset(Control.PRESET_FULL_RECT)
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	result_layer.add_child(wrap)
	result_wrap = wrap

	var vbox := VBoxContainer.new()
	vbox.size = Vector2(560, 300)
	vbox.position = Vector2((1152 - 560) / 2, (648 - 300) / 2)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 18)
	wrap.add_child(vbox)

	# 装饰分隔线：标题上下各一条，让面板不像「三个控件叠在一起」。
	# 用 ColorRect 画细线，不需要美术资源。
	var rule_top := ColorRect.new()
	rule_top.custom_minimum_size = Vector2(360, 2)
	rule_top.color = Color(C_CYAN.r, C_CYAN.g, C_CYAN.b, 0.65)
	vbox.add_child(rule_top)

	result_title = Label.new()
	result_title.text = "VICTORY"
	result_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	result_title.add_theme_font_size_override("font_size", 64)
	vbox.add_child(result_title)

	var rule_bot := ColorRect.new()
	rule_bot.custom_minimum_size = Vector2(360, 2)
	rule_bot.color = Color(C_CYAN.r, C_CYAN.g, C_CYAN.b, 0.65)
	vbox.add_child(rule_bot)

	result_time = Label.new()
	result_time.text = "CLEAR TIME  00:00.0"
	result_time.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	result_time.add_theme_font_size_override("font_size", 30)
	result_time.add_theme_color_override("font_color", Color(0.72, 0.90, 0.96))
	vbox.add_child(result_time)

	# 评级：按通关用时给 S/A/B/C。
	# 纯文字，不占额外资源 —— 但给玩家一个「再来一次刷分」的理由。
	result_rank = Label.new()
	result_rank.text = "RANK  S"
	result_rank.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	result_rank.add_theme_font_size_override("font_size", 22)
	result_rank.add_theme_color_override("font_color", C_AMBER)
	vbox.add_child(result_rank)

	var restart_btn := Button.new()
	restart_btn.text = "RESTART"
	restart_btn.custom_minimum_size = Vector2(260, 64)
	restart_btn.focus_mode = Control.FOCUS_NONE
	restart_btn.add_theme_font_size_override("font_size", 28)
	restart_btn.add_theme_color_override("font_color", Color(0.80, 0.98, 1.0))
	restart_btn.add_theme_stylebox_override("normal",
			_neon_sb(Color(0.00, 0.18, 0.24, 0.90), C_CYAN))
	restart_btn.add_theme_stylebox_override("hover",
			_neon_sb(Color(0.00, 0.30, 0.38, 0.95), C_CYAN))
	restart_btn.add_theme_stylebox_override("pressed",
			_neon_sb(Color(0.00, 0.42, 0.52, 1.0), C_CYAN))
	restart_btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	restart_btn.pressed.connect(func() -> void:
		Sfx.play("ui_click")
		_restart()
	)
	vbox.add_child(restart_btn)

	var sub := Label.new()
	sub.text = "or press R"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 16)
	sub.add_theme_color_override("font_color", C_DIM)
	vbox.add_child(sub)

	# 面板四角括号。只要括号不要扫描线 ——
	# 扫描线已经铺在 HUD 那层了，这里再叠一层会明显发灰。
	var deco := HudDecor.new()
	deco.set_anchors_preset(Control.PRESET_FULL_RECT)
	deco.show_scanlines = false
	deco.bracket_color = Color(C_CYAN.r, C_CYAN.g, C_CYAN.b, 0.55)
	wrap.add_child(deco)


## 霓虹描边按钮：暗底 + 亮色细边 + 同色外发光。
##
## 外发光用 StyleBoxFlat 的 shadow 模拟 ——
## shadow 本身就是绕盒子一圈的模糊色，拿霓虹色当 shadow_color
## 就是发光效果，不需要任何美术资源。
func _neon_sb(face: Color, edge: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = face
	s.set_corner_radius_all(2)
	s.border_width_left = 2
	s.border_width_right = 2
	s.border_width_top = 2
	s.border_width_bottom = 2
	s.border_color = edge
	s.shadow_size = 8
	s.shadow_color = Color(edge.r, edge.g, edge.b, 0.42)
	s.shadow_offset = Vector2(0, 0)
	s.content_margin_left = 14
	s.content_margin_right = 14
	s.content_margin_top = 10
	s.content_margin_bottom = 10
	return s


## 无敌按钮的整体换肤。
##
## 状态变化时**换 StyleBox 而不只是改文字颜色** ——
## 只改文字的话，从余光里看不出当前是开还是关，必须正对着读字。
## OFF：暗底 + 青边；ON：洋红底 + 亮粉字，一眼能分辨。
func _style_god_button() -> void:
	if god_button == null:
		return
	var on := player != null and player.god_mode
	var edge := C_MAGENTA if on else C_CYAN
	var face := Color(C_MAGENTA.r, C_MAGENTA.g, C_MAGENTA.b, 0.20) if on \
			else Color(0.02, 0.04, 0.08, 0.88)
	god_button.text = "INVINCIBLE: ON" if on else "INVINCIBLE: OFF"
	god_button.add_theme_color_override("font_color",
			Color(1.0, 0.74, 0.88) if on else Color(0.62, 0.84, 0.90))
	god_button.add_theme_stylebox_override("normal", _neon_sb(face, edge))
	god_button.add_theme_stylebox_override("hover",
			_neon_sb(Color(face.r + 0.10, face.g + 0.10, face.b + 0.10, face.a), edge))
	god_button.add_theme_stylebox_override("pressed",
			_neon_sb(Color(C_MAGENTA.r, C_MAGENTA.g, C_MAGENTA.b, 0.38) if on \
					else Color(0.00, 0.30, 0.36, 0.30), edge))
	# 焦点框清掉：选中态那圈默认黄框跟霓虹配色打架
	god_button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


## 造一根血条。
## opaque=false 时背景全透明 —— 用于垫在下面的「追尾条」：
## 它要能透出底下那根实血条的槽底，不然两层背景叠起来边上会有色差。
## 血条样式。
##
## 比原来多了三样东西，都是纯 StyleBox 参数、不需要美术资源：
##   1. 渐变填充 —— 纯色条太平，加点明暗有体积感
##   2. 高光描边 —— 把条从背景里「抠」出来
##   3. 内阴影 —— 底部压暗，像嵌在面板里
##
## 追尾条（opaque=false）不做描边：它是垫在下面的虚影，
## 描边会让它看起来像第二条实心条，反而分不清哪条是真的。
func _make_bar(color: Color, opaque: bool = true,
		edge: Color = Color(0, 0, 0, 0)) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.show_percentage = false

	# 边框色默认取填充色本身（压暗一点）——
	# 青条配青边、洋红条配洋红边，霓虹感来自「同色描边」；
	# 统一用灰边的话就变回普通 UI 了。
	var ec := edge if edge.a > 0.001 else Color(color.r, color.g, color.b, 0.70)

	# 圆角 2 而不是 5：赛博朋克的面板是硬的，
	# 大圆角会立刻变成手机 App 的味道。
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.02, 0.03, 0.07, 0.94) if opaque else Color(0, 0, 0, 0)
	bg.set_corner_radius_all(2)
	if opaque:
		bg.border_width_left = 2
		bg.border_width_right = 2
		bg.border_width_top = 2
		bg.border_width_bottom = 2
		bg.border_color = ec
		# 外发光：拿霓虹色当 shadow，就是一圈模糊的同色光晕。
		# 比贴图便宜得多，StyleBoxFlat 原生支持。
		bg.shadow_size = 6
		bg.shadow_color = Color(ec.r, ec.g, ec.b, 0.40)
		bg.shadow_offset = Vector2(0, 0)

	# fill 声明成基类 StyleBox —— 渐变版是 StyleBoxTexture，
	# 不透明版是 StyleBoxFlat，两者不是同一个类。
	# 声明成 StyleBoxFlat 再赋 StyleBoxTexture 会类型不匹配。
	var fill: StyleBox
	if opaque:
		# 渐变填充：StyleBoxFlat **没有** fill_begin / fill_end 属性
		# （那是别的 UI 框架里的写法，Godot 里赋值会直接报
		#  "Invalid assignment of property or key 'fill_begin'"）。
		# 渐变得靠 StyleBoxTexture + 一张运行时生成的竖直渐变纹理。
		fill = _gradient_fill(color)
	else:
		var flat := StyleBoxFlat.new()
		flat.bg_color = color
		flat.set_corner_radius_all(2)
		fill = flat

	bar.add_theme_stylebox_override("background", bg)
	bar.add_theme_stylebox_override("fill", fill)
	return bar


## 渐变填充条：运行时生成一张竖直渐变的小纹理，塞进 StyleBoxTexture。
##
## 为什么用纹理而不是纯色：
## 纯色条太平，加一点上亮下暗就有体积感。而 StyleBoxFlat 只支持单色，
## 做不了渐变 —— 只能换成 StyleBoxTexture。
##
## 纹理做成 4x32（很窄）：横向会被拉伸、纵向会被压缩，
## 但渐变只跟「纵向的比例位置」有关，缩放不影响观感。
## 按颜色缓存 —— 血条颜色只有两三种，没必要每次重建。
var _grad_cache: Dictionary = {}


func _gradient_fill(color: Color) -> StyleBoxTexture:
	var key := color.to_html(false)
	if not _grad_cache.has(key):
		var h := 32
		# 提亮上限按「最大通道」算：直接乘 1.30 会让亮通道溢出并被钳到 1.0，
		# 顶部几行就只剩黄白，色相明显偏掉（红条顶部会发橙白）。
		# 所以 f_top 取 min(1.30, 1/max_channel)，保证任何通道都不截断。
		var mx := maxf(color.r, maxf(color.g, color.b))
		var f_top := minf(1.30, 1.0 / maxf(mx, 0.05))
		var f_bot := 0.68
		var img := Image.create(4, h, false, Image.FORMAT_RGBA8)
		for y in h:
			var k := float(y) / float(h - 1)     # 0 顶部（亮） -> 1 底部（暗）
			var f := lerpf(f_top, f_bot, k)
			var c := Color(color.r * f, color.g * f, color.b * f, 1.0)
			for x in 4:
				img.set_pixel(x, y, c)
		_grad_cache[key] = ImageTexture.create_from_image(img)

	var sb := StyleBoxTexture.new()
	sb.texture = _grad_cache[key]
	# 纹理只有 4px 宽，必须允许拉伸，否则会被当成九宫格切碎
	sb.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
	sb.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
	return sb

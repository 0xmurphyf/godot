extends RefCounted
class_name MoveLibrary
## ============================================================
## 招式表 —— 这里就是「数据」。
##
## Boss 三招：走近 / 冲拳 / 闪现砸拳。
## 想改招式只动这个文件，脚本一行都不用碰。
##
## 时长单位：逻辑帧，60fps 下 30 = 0.5 秒
## 坐标系：节点原点在脚底，y 向上为负。Rect2(x, y, w, h)
## ============================================================


static func _f(label: String, duration: int, next: int, o: Dictionary = {}) -> FrameData:
	var f := FrameData.new()
	f.label = label
	f.duration = duration
	f.next = next
	f.dvx = o.get("dvx", 0.0)
	f.dvy = o.get("dvy", 0.0)
	f.use_gravity = o.get("gravity", true)
	f.wait_for_landing = o.get("land", false)
	f.wall_next = o.get("wall_next", -1)
	f.telegraph = o.get("tele", false)
	f.cancellable = o.get("cancel", false)
	f.invisible = o.get("invis", false)
	f.teleport = o.get("tp", "")
	f.teleport_offset = o.get("tp_off", Vector2(0, -260))
	f.damage = o.get("dmg", 0)
	f.knockback = o.get("kb", 0.0)
	f.hitstop = o.get("hs", 0)
	f.hitstop_self = o.get("hs_self", true)
	f.hit_next = o.get("hit_next", -1)
	f.next_on_hit = o.get("next_on_hit", -1)
	f.chain_next = o.get("chain_next", -1)
	f.anim = o.get("anim", "")
	f.anim_fit = o.get("fit", true)
	f.spawn_scene = o.get("spawn", "")
	f.spawn_offset = o.get("spawn_off", Vector2(38, -34))
	f.spawn_damage = o.get("spawn_dmg", 0)
	f.spawn_knockback = o.get("spawn_kb", 0.0)
	f.retreat_on_launch = o.get("retreat", false)
	f.cue = o.get("cue", "")
	if o.has("box"):
		f.hitbox_rect = o["box"]
	if o.has("hurt"):
		f.hurt_rect = o["hurt"]
	return f


# ============================================================
# 近身判定：Boss 普通拳的射程
# ============================================================
## 两个 hurtbox 刚好重叠的距离。
## Boss hurtbox 60 宽（半宽 30） + Player hurtbox 30 宽（半宽 15）
## -> 中心距 < 45 时才真的碰上，拳才不该挥空。
# 用 static var 而不是 const：Boss 检查器里的 punch_reach_extra
# 会在 Boss._ready() 时写进来。static func 读不到实例变量，只能这样中转。
static var HURT_HALF_BOSS := 30.0
static var HURT_HALF_PLAYER := 15.0
# 放宽量。0 = 严格重叠(45)，75 = 120px 内也算近身。
# 不放宽的话 46~189 之间只剩闪现砸一个选项，会变成「必闪现砸」的死区。
static var PUNCH_REACH_EXTRA := 75.0
static var PUNCH_REACH := HURT_HALF_BOSS + HURT_HALF_PLAYER + PUNCH_REACH_EXTRA


# ============================================================
# 玩家：站立 + 普攻
# ============================================================

static func player_moves() -> Array[AttackData]:
	var stand := AttackData.new()
	stand.move_name = "stand"
	# duration 必须够大：这是「待机状态」，不是真的一招。
	# 用 1 的话每 tick 都会 _advance(0) -> _apply_anim() 把动画强行拉回 idle，
	# 而 Player._set_anim() 紧接着又切回 run —— 两者互相打架，
	# 结果 run / jump 每帧都被 restart，永远停在第 1 帧。
	# 9999 = 永不自己结束，动画交给状态逻辑（idle / run / jump）驱动。
	stand.frames = [_f("stand", 9999, 0, {"anim": "idle"})]

	# 开枪：抬枪 -> 击发（这一帧生成子弹）-> 收枪
	# 近战判定框已完全移除，玩家只能远程输出
	var fire := AttackData.new()
	fire.move_name = "fire"
	fire.frames = [
		_f("raise", 4, 1, {"anim": "shoot"}),
		_f("fire", 2, 2, {"anim": "shoot",
			"spawn": "res://scenes/Bullet.tscn",
			"spawn_off": Vector2(56, -96),
			# 玩家伤害 53 = ceil(999/19)：正好 19 发打死 999 血的 Boss。
			# 18 发只有 954（差 45），第 19 发必杀 —— 数字是卡着算的。
			"spawn_dmg": 53, "spawn_kb": 120.0}),
		_f("recover", 12, -1, {"anim": "shoot", "cancel": true}),
	]

	# 翻滚：0.33 秒位移 156 像素，全程无敌
	var dodge := AttackData.new()
	dodge.move_name = "dodge"
	dodge.frames = [
		_f("roll_in", 2, 1, {"anim": "dodge", "dvx": 300.0}),
		_f("rolling", 12, 2, {"anim": "dodge", "dvx": 640.0, "cancel": true}),
		_f("roll_out", 6, -1, {"anim": "dodge", "dvx": 180.0}),
	]

	return [stand, fire, dodge]


# ---------------------------------------------------------------------------
# 伤害表（双方 999 血）
#
# 判断数值是否合理的标准不是绝对值，而是「单招占玩家血量的百分比」——
# 这样换血量时不用重算所有招式。
#
#   招式          伤害   占比    二阶段    占比
#   枪             90    9%      112     11%
#   普通拳         120   12%     150     15%
#   闪现砸 land   120   12%     150     15%
#   冲拳 carry    135   13.5%   169     17%
#   冲拳 launch   150   15%     188     19%
#   闪现砸 drop   165   16.5%   206     21%
#   全图炮        300   30%     375     37.5%  <- 大招
#
# （上面是原表 x1.5 之后的值，1.5 倍是整体难度倍率）
#
# 层次：枪 9% < 拳/砸 12~16% < 全图炮 30%。
# 炮是次高招的 1.8 倍 —— 「炮最疼、最该躲」不用教，玩家自己会感觉到。
# 全图炮 30% -> 3 下就倒，二阶段 2.6 下，是真正的「挨不起」。
#
# 玩家伤害 53 = ceil(999/19)，正好 19 发击杀（18 发只有 954，差 45）。
# ---------------------------------------------------------------------------

# ============================================================
# Boss 招式 1：走近
# 只负责位移，进入攻击范围后由 AI 立刻打断转出招
# ============================================================

static func boss_walk() -> AttackData:
	var m := AttackData.new()
	m.move_name = "walk"
	m.interruptible = true
	m.min_dist = 240.0          # 必须 > Boss 的 attack_range(220)，否则会死循环
	m.weight = 3.0
	m.frames = [
		_f("step", 9999, 0, {"anim": "walk", "dvx": 170.0}),   # 循环走，靠 AI 打断
	]
	return m


# ============================================================
# Boss 招式 2：冲拳
# 沉肩后缩 -> 爆发突进 -> 滑行余势 -> 后摇
# 打中走短后摇（帧4），扑空 / 撞墙走长硬直（帧3）
# ============================================================

static func boss_dash_punch() -> AttackData:
	var m := AttackData.new()
	m.move_name = "dash"
	# 贯穿型冲拳：命中也不停，直接冲过玩家。
	# 「整段只命中一次」靠 FrameActor.hit_landed —— 它在 play() 时重置，
	# 命中后一直是 true，所以第 2 帧的判定不会再打第二下。
	#
	# 有效射程：总位移 700px，判定框前缘在身前 14px
	#   min_dist 190 → 贴脸时根本不选这招（近距离靠普通拳 / 闪现砸拳）
	#   max_dist 650 → 超出就够不着，避免远距离无意义扑空
	# min_dist 从 190 降到 60：近身也能用冲拳脱离，
	# 配合上面放宽的普通拳射程，把「46~189 必定闪现砸」的死区消掉。
	m.min_dist = 60.0
	m.max_dist = 650.0
	m.weight = 3.0
	m.frames = [
		# 0 沉肩：略微后缩 0.28 秒，红光 —— 这是玩家唯一的读招窗口
		#   原本 20 帧，提速后缩到 17 帧，否则整体太慢
		_f("crouch", 24, 1, {"anim": "crouch", "dvx": -90.0, "tele": true,
			"cue": "mv_dash"}),

		# 1 爆发：速度 1300（30px/帧，看得清轨迹；1800 太接近瞬移）
		#    【不设 hit_next】—— 命中瞬间立刻跳走会打断贯穿位移。
		#    冲拳是贯穿型，打中了也要继续冲完，所以照 next 进 carry。
		_f("launch", 7, 2, {
			"dvx": 1300.0,
			"box": Rect2(9, -49, 52, 31),
			"anim": "dash", "dmg": 150, "kb": 340.0, "hs": 8,
			"cue": "dash_whoosh",   # 冲出去那一下的风声（跟前摇蓄力区分）
			"hs_self": false,   # 贯穿：自己不停，只有玩家定住
			"wall_next": 3,     # 撞墙 → 直接进 whiff
		}),

		# 2 滑行：保持 1500 的高速，只缩短时长 —— 1500 x 23 帧 ≈ 575px
		#    总位移 = -25.5 + 151.7 + 575 ≈ 700px
		#    1500px/s = 25px/帧，远小于判定框宽 70px，不会穿透
		#    next=3(whiff)：冲到底进失衡
		_f("carry", 23, 3, {
			"dvx": 1500.0,
			"box": Rect2(7, -49, 47, 31),
			"anim": "dash", "dmg": 135, "kb": 280.0, "hs": 6,
			"hs_self": false,
			"wall_next": 3,     # 撞墙 → 进 whiff
		}),

		# 3 失衡 whiff 0.3 秒：冲过头、重心没收住、踉跄找回平衡。
		#    【碰没碰到都放】—— 冲拳是「整个人撞出去」的招，冲到底必然失衡，
		#    打中打不中都是这个动作。它也是给玩家的输出窗口。
		#    next=4：到此为止还没打中过 → 再接一段 recover（额外 0.57s 惩罚）
		#    next_on_hit=5：命中过 → 直接 recover 站定，不再加倍惩罚
		#    （用 next_on_hit 而不是 hit_next：后者会在命中瞬间跳走，
		#     把贯穿位移打断，冲拳就不「贯」了）
		_f("whiff", 18, 4, {"anim": "whiff", "next_on_hit": 5}),

		# 4 未命中的额外惩罚：0.57 秒 recover。
		#    只有 whiff 结束时 move_hit 仍是 false 才会走到这里 ——
		#    命中过的话 whiff 的 next_on_hit=5 直接跳到 recover 站定，不吃这层。
		_f("recover_long", 34, -1, {"anim": "recover"}),

		# 5 站定收招 0.45 秒：命中后的收尾（比未命中短 0.12s）
		_f("recover", 27, -1, {"anim": "recover"}),
	]
	return m


# ============================================================
# Boss 招式 3：闪现砸拳
# 前摇锁位 -> 消失 -> 闪现到玩家头顶 -> 下落砸击 -> 落地冲击波 -> 后摇
# ============================================================

static func boss_blink_slam() -> AttackData:
	var m := AttackData.new()
	m.move_name = "blink_slam"
	m.min_dist = 0.0            # 全距离可用
	m.weight = 1.6
	# 连发：没砸中就再闪现砸一次，随机最多 2~4 连。
	# 第一下必砸；之后每下没中就继续，砸满随机上限、或砸中过就收招。
	m.chain_min = 2
	m.chain_max = 4
	m.frames = [
		# 0 前摇第一段（地上）：40 帧 = 0.67 秒。用专属的 warp
		#    （整体收缩 = 蓄力准备消失），
		#    不再共用 crouch —— 那样跟冲拳/普通拳的起手一模一样，
		#    玩家看不出「这次要闪走」，读招信息丢了。
		#    前摇分两段：这里是地上的 40 帧，第二段是闪现到头顶后的
		#    悬停 5 帧（帧 2）。总 0.88 秒 ——
		#    原来是一整段 84 帧(1.40s)，太长，拆开后压迫感反而更清楚。
		_f("telegraph", 40, 1, {"anim": "warp", "cue": "mv_blink"}),

		# 1 消失：0.13 秒，不渲染
		# 不隐藏，改播淡烟雾残影 —— 视觉上等于消失，但玩家能看到去向
		_f("vanish", 8, 2, {"anim": "vanish", "cue": "teleport_out"}),

		# 2 现身：闪现到玩家头顶 260 像素，悬停 5 帧
		#   只有这一帧标 telegraph —— 预警圈在 Boss 真正出现时才画，
		#   前摇阶段不剧透落点，玩家得先看到它出现在哪
		# anim 只在首帧指定：slam 是 appear+drop+land 合并成的连续动画，
		# 后面两帧留空 = 沿用上一帧，不重启，动画按 .tres 里每帧的
		# duration 一路播到底（appear 5 / drop 10 / land 14 tick）。
		# fit=false：这三段共用一个动画，不能按单帧时长拉伸。
		_f("appear", 5, 3, {
			"anim": "slam", "fit": false, "tp": "above_player", "tp_off": Vector2(0, -999),
			"gravity": false, "dvy": 0.0, "tele": true,
			"cue": "teleport_in",
		}),

		# 3 下落砸击：不受重力、恒定速度砸下，落地才结束。
		#    1000 -> 1500：260px 从 15.6 帧缩到 10.4 帧。
		#    注意「能被击中」不靠下落慢 —— 靠 _dynamic_hurt_rect()
		#    把受击框从 Boss 头顶一直拉到地面，只要在空中就打得到。
		#    所以加快下落不牺牲可命中性，只是窗口从 15 帧缩到 10 帧
		#    （玩家射速 18 帧/发，两者都只能插进 0~1 发，实际差别不大）。
		_f("drop", 300, 4, {
			"gravity": false, "dvy": 1800.0, "land": true,
			"box": Rect2(-28, -48, 56, 56),
			"dmg": 165, "kb": 300.0, "hs": 6,
		}),

		# 4 落地冲击波：横向 280 像素
		#    chain_next=1：这一下没砸中（本招至今一次都没命中过）→ 回到 vanish 帧
		#    （不是直接跳 appear）。从 vanish 走一遍，落地后会先播烟雾消失、
		#    再闪现到头顶 —— 有过渡，不是"落地瞬间凭空出现在空中"。
		#    vanish 有自己的 next=2，所以自然接到 appear，不需要额外处理。
		#    每次回到 appear 都会重新闪现到玩家**当前**位置头顶 —— 追着砸。
		#    最多连几下由 m.chain_min/max（2~4，每次出招随机）决定；
		#    只要砸中过一次就照 next=5 收招，不再连。
		_f("land", 14, 5, {
			"box": Rect2(-93, -31, 187, 37),
			"dmg": 120, "kb": 340.0, "hs": 5,
			"chain_next": 1,
		}),

		# 5 后摇：0.5 秒
		_f("recover", 30, -1, {"anim": "recover"}),
	]
	return m


# ============================================================
# Boss 招式 4：手枪射击
# 举枪瞄准 -> 击发生成子弹 -> 收枪
# 子弹是 Boss 专用场景（BulletEnemy.tscn，红色，打 player_hurtbox）
# ============================================================

static func boss_gun_shot() -> AttackData:
	var m := AttackData.new()
	m.move_name = "gun_shot"
	m.min_dist = 450.0           # 距离 <450 不用枪（近战交给冲拳/砸拳）
	m.max_dist = 9999.0          # 远距离随便打，不再走近
	m.weight = 4.5               # 主攻手段之一
	m.frames = [
		# 0 举枪瞄准 0.3 秒 —— 前摇，枪口会亮
		_f("aim", 24, 1, {"anim": "aim", "tele": true}),

		# 1 击发：生成一颗子弹
		_f("fire", 2, 2, {"anim": "fire",
			"spawn": "res://scenes/BulletEnemy.tscn",
			"spawn_off": Vector2(56, -96),
			"spawn_dmg": 90, "spawn_kb": 160.0}),

		# 2 收枪 0.4 秒
		_f("recover", 24, -1, {"anim": "aim"}),
	]
	return m


## 连发的「后续发」：前摇和后摇都比首发短，读起来才像连射。
## weight = 0 -> 不参与随机选招，只能由 Boss 在首发结束后显式 play()。
##
## 快慢刀：aim（前摇）时长是唯一变量，四个变体共用同一份结构。
## 玩家真正能感知到的「间隔」= 上一发 recover(10) + 这一发 aim：
##   快 14 帧 / 标准 18 帧 / 慢 24 帧 / 延迟斩 34 帧
## 从 14 到 34 差 2.4 倍 —— 固定节奏时听一次就能掌握，
## 打乱之后必须真的看动作才能闪。
static func boss_gun_burst(aim_ticks: int = 8) -> AttackData:
	var m := AttackData.new()
	m.move_name = "gun_burst_%d" % aim_ticks
	m.min_dist = 0.0            # 由代码显式调用，不受射程限制
	m.max_dist = 9999.0
	m.weight = 0.0              # 不随机出现
	m.frames = [
		_f("aim", aim_ticks, 1, {"anim": "aim", "tele": true}),
		_f("fire", 2, 2, {"anim": "fire",
			"spawn": "res://scenes/BulletEnemy.tscn",
			"spawn_off": Vector2(56, -96),
			"spawn_dmg": 90, "spawn_kb": 160.0}),
		_f("recover", 12, -1, {"anim": "aim"}),
	]
	return m


# ============================================================
# Boss 招式 5：全图炮
# 长蓄力 -> 一道贴地冲击波扫过整个场地 -> 长后摇
#
# 判定框 Rect2(-576,-70,1152,70) 覆盖全场宽度，但只有 70px 高：
# 玩家跳跃最高约 111px（650^2 / 2*1900），跳起来就能躲过。
# ============================================================

static func boss_cannon() -> AttackData:
	var m := AttackData.new()
	m.move_name = "cannon"
	m.min_dist = 450.0           # 近距离不放炮
	m.weight = 3.0               # 常见大招
	m.frames = [
		# 0 蓄力 0.75 秒（原 1.2 秒）：全图炮是「远程大招」，
		#    蓄能太久会让 Boss 站着不动的时间过长，节奏拖沓。
		#    缩短后更突然，但二阶段前摇会再乘 0.8（见 scaled）——
		#    那里才真正考验反应，一阶段这样够了。
		_f("charge", 45, 1, {"anim": "charge", "tele": true, "cue": "mv_charge"}),

		# 1 开炮：发射一道激光（Laser.tscn），朝面向那一侧横扫全场。
		#    判定由激光自己的 Area2D 负责 —— 不再用 box，
		#    否则「判定框瞬间命中」和「激光碰到」会各算一次，变成双倍伤害。
		#    激光的范围与原来的 box 完全一致：从自身出发、长 1200、高 70、贴地。
		#    spawn_off y=-96 = 光束竖直中心（覆盖自身 -151..-41）
		_f("blast", 8, 2, {"anim": "charge",
			"spawn": "res://scenes/Laser.tscn",
			"spawn_off": Vector2(0, -96),
			"spawn_dmg": 300, "spawn_kb": 420.0}),

		# 2 后摇 0.67 秒 —— 最大输出窗口。
		#    用专属的 vent（开完炮的散热/复位），不再共用 recover：
		#    那是「打完一拳从容收回」的小动作，撑不起全屏大招的分量。
		#    vent 起点是手臂前伸 + 后仰（后坐力），慢慢放下站定。
		_f("vent", 40, -1, {"anim": "vent"}),
	]
	return m


# ============================================================
# ============================================================
# Boss 招式 6：普通拳（近身专用）
# 距离 <190 才用。判定小、前摇短，但击飞极强（1200）
# 被打中会被轰飞约 1200 像素并短暂失控
# ============================================================

static func boss_normal_punch() -> AttackData:
	var m := AttackData.new()
	m.move_name = "normal_punch"
	# 射程 = 两个 hurtbox 刚好重叠的距离（Boss 30 + Player 15 = 45）。
	# 原本写 190，但那跟「贴脸」毫无关系 —— 190px 外两个受击框还差得远，
	# 挥出去会打空。现在严格按几何来：只有真的重叠才可能选到。
	# 45 = 严格重叠；+75 放宽到 120，用来消掉中近距离的招式死区。
	m.min_dist = 0.0
	m.max_dist = PUNCH_REACH
	m.weight = 3.6               # 近身主攻（仍然是概率，不是必定）
	m.frames = [
		# 0 抬手 0.25 秒 —— 短前摇，判定覆盖全身，只能靠翻滚躲
		#    用 jab_wind：蹲得比 crouch 浅，一眼能跟冲拳的深蹲蓄力区分开
		_f("windup", 15, 1, {"anim": "jab_wind", "tele": true, "cue": "mv_jab"}),

		# 1 出拳：判定覆盖 Boss 全身（x -51..50，y -107..0）
		#    用 jab：短促收得住，跟冲拳「整个人撞出去」的 dash 区分
		#    对称框，镜像后不变 —— 前后都打，想躲只能翻滚出去
		_f("strike", 4, 2, {"anim": "jab",
			"box": Rect2(-51, -107, 101, 107),
			"dmg": 120, "kb": 1200.0, "hs": 11,
			"retreat": true}),      # ← 只有这一招会触发后撤

		# 2 收拳 0.45 秒
		_f("recover", 27, -1, {"anim": "recover"}),
	]
	return m



# ============================================================
# 二阶段招式池：整体提速 + 加伤
#
# 不改原招式，而是复制一份再缩放 —— AttackData / FrameData 是 Resource，
# 直接改原对象会污染一阶段（它们是同一个实例）。
# ============================================================

## 把一招按比例缩放：时长 *dur_scale（越短越快），伤害 *dmg_scale
static func scaled(src: AttackData, dur_scale: float, dmg_scale: float) -> AttackData:
	var m := AttackData.new()
	m.move_name = src.move_name
	m.interruptible = src.interruptible
	m.min_dist = src.min_dist
	m.max_dist = src.max_dist
	m.weight = src.weight
	m.mp_cost = src.mp_cost
	# 连发上限也要复制 —— 漏了的话二阶段的闪现砸就不连发了
	m.chain_min = src.chain_min
	m.chain_max = src.chain_max
	for f in src.frames:
		if f == null:
			m.frames.append(null)
			continue
		var nf := f.duplicate() as FrameData
		# 至少 1 帧，且前摇不缩太多（否则玩家读不出招）
		nf.duration = maxi(1, int(round(float(f.duration) * dur_scale)))
		if f.damage > 0:
			nf.damage = int(round(float(f.damage) * dmg_scale))
		# 子实体伤害也要缩放 —— 全图炮改用激光后，伤害写在 spawn_dmg 上，
		# 不缩的话二阶段的炮会比其它招弱一截。
		if f.spawn_damage > 0:
			nf.spawn_damage = int(round(float(f.spawn_damage) * dmg_scale))
		m.frames.append(nf)
	return m


## 二阶段：所有招式时长 x0.8、伤害 x1.25
static func boss_moves_phase2() -> Array[AttackData]:
	var out: Array[AttackData] = []
	for m in boss_moves():
		out.append(scaled(m, 0.8, 1.25))
	return out


# 汇总
# ============================================================

static func boss_moves() -> Array[AttackData]:
	return [
		boss_walk(),
		boss_dash_punch(),
		boss_blink_slam(),
		boss_gun_shot(),
		# 连发变体（weight 0：只由连发逻辑显式调用）
		boss_gun_burst(6),      # 快刀（原 4）
		boss_gun_burst(11),     # 标准（原 8）
		boss_gun_burst(18),     # 慢刀（原 14）
		boss_gun_burst(30),     # 延迟斩（原 24）
		boss_cannon(),
		boss_normal_punch(),
	]

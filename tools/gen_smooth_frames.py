#!/usr/bin/env python3
"""把现有的关键帧扩展成「更顺滑」的动画。

原来很多动画只有 1~2 帧 —— 画面是静止的，这是「不流畅」的主因。
本脚本用两种方式生成中间帧：

  1. 混合（cross-dissolve）—— 用于本来就有多个真实姿势的动画（walk / punch）
  2. 形变（squash / stretch / bob）—— 用于只有单帧的动画，靠压扁拉长做运动感
     （以「贴地行」为锚点缩放，脚底不会离地）

输出：art/boss/*.png、art/player/*.png、两个 .tres、两张预览图
"""
from PIL import Image
import os, shutil
from math import sin, cos, pi as PI
import numpy as np

# 工作分辨率（内部形变都在这上面做，保持像素锐利）
#
# Boss 原本是 192 / x4 放大：屏幕上每个「美术像素」只有 4/6 = 0.67 个屏幕像素，
# 边缘发虚、看着像缩略图。Player 是 128 / x6 —— 每个美术像素正好 1 个屏幕像素，
# 干净利落。所以 Boss 改成 128 / x6，与 Player 的像素密度完全一致。
BOSS_CELL, BOSS_GROUND = 128, 112
PLAYER_CELL, PLAYER_GROUND = 128, 112

# 输出画布：两者统一 768x768。整数倍放大，脚底行都落在 672。
OUT_CELL = 768
BOSS_UP = OUT_CELL // BOSS_CELL           # 6
PLAYER_UP = OUT_CELL // PLAYER_CELL       # 6
# 112*6 = 672 —— 两者脚底行一致

# Boss 扁平调色板的色数。Player 实际用到的核心色约 15 个，
# 这里取 14 与之相当 —— 色数相近是「同风格」最直观的一条。
BOSS_PAL_N = 14
# Player 的扁平帧（idle/shoot）实际用到约 15 色，取相同数量保持一致
PLAYER_PAL_N = 15


# ---------------------------------------------------------------- 工具

def load(path):
	return Image.open(path).convert("RGBA").copy()


def clear_below(im, ground, cell):
	"""清掉贴地行以下的像素（形变后可能溢出）"""
	px = im.load()
	for y in range(ground, cell):
		for x in range(cell):
			if px[x, y][3]:
				px[x, y] = (0, 0, 0, 0)
	return im


def extract_palette(images, n, seed=7):
	"""k-means 提取扁平调色板 —— 把绘制稿压成有限色的像素画。

	Boss 原图有 15 万种颜色（渐变 + 抗锯齿），Player 只有约 15 种核心色。
	这是两者「不像一个游戏里的东西」的根本原因。
	这里用 k-means 从 Boss 自身取色，保留它的暗紫红身份，
	但把渲染方式压成与 Player 一致的扁平像素画。
	"""
	rng = np.random.default_rng(seed)
	pts = []
	for im in images:
		a = np.array(im)
		pts.append(a[..., :3][a[..., 3] > 128])
	X = np.concatenate(pts).astype(np.float32)
	C = X[rng.choice(len(X), n, replace=False)].copy()
	for _ in range(40):
		lab = ((X[:, None, :] - C[None, :, :]) ** 2).sum(-1).argmin(1)
		for k in range(n):
			if (lab == k).any():
				C[k] = X[lab == k].mean(0)
	return [tuple(int(round(v)) for v in c) for c in C]


def quantize(im, palette):
	"""把每个像素映射到调色板里最近的颜色（alpha 不动）。

	必须在形变/混合【之后】做：
	squash 用 LANCZOS，会在边缘产生插值色；不量化的话
	每一帧都会多出几十上百种过渡色，又变回「绘制稿」。
	量化后无论怎么形变，颜色数永远等于调色板大小。
	"""
	a = np.array(im).astype(np.int16)
	pal = np.array(palette, dtype=np.int16)
	d = ((a[..., None, :3] - pal[None, None, :, :]) ** 2).sum(-1)
	out = pal[d.argmin(-1)]
	res = np.dstack([out, a[..., 3]]).astype(np.uint8)
	return Image.fromarray(res, "RGBA")


def squash(im, sx, sy, ground, cell):
	"""以贴地行为锚点缩放：脚底固定不动"""
	bb = im.getbbox()
	if bb is None:
		return im
	c = im.crop(bb)
	nw = max(1, int(round(c.width * sx)))
	nh = max(1, int(round(c.height * sy)))
	c2 = c.resize((nw, nh), Image.LANCZOS)
	out = Image.new("RGBA", (cell, cell), (0, 0, 0, 0))
	out.paste(c2, ((cell - nw) // 2, ground - nh), c2)
	return clear_below(out, ground, cell)


def rotate(im, deg, ground, cell):
	"""绕内容中心旋转，之后重新贴地"""
	bb = im.getbbox()
	if bb is None:
		return im
	c = im.crop(bb)
	c2 = c.rotate(deg, expand=True, resample=Image.BICUBIC)
	out = Image.new("RGBA", (cell, cell), (0, 0, 0, 0))
	out.paste(c2, ((cell - c2.width) // 2, ground - c2.height), c2)
	return clear_below(out, ground, cell)


def fade(im, a):
	px = im.load()
	for y in range(im.height):
		for x in range(im.width):
			r, g, b, al = px[x, y]
			if al:
				px[x, y] = (r, g, b, int(al * a))
	return im


def blend(a, b, t):
	"""两帧混合，产生中间姿势（在高速播放下读作运动）"""
	if t <= 0.0:
		return a.copy()
	if t >= 1.0:
		return b.copy()
	return Image.blend(a, b, t)


def seq_blend(keys, n, loop=True):
	"""把 n 个关键姿势插值成 count 帧"""
	out = []
	seg = (len(keys) - 1) if loop else len(keys)
	total = n if loop else n
	for i in range(n):
		t = (i / n) * seg if loop else (i / max(n - 1, 1)) * (len(keys) - 1)
		i0 = int(t)
		frac = t - i0
		if loop:
			a = keys[i0 % len(keys)]
			b = keys[(i0 + 1) % len(keys)]
		else:
			if i0 >= len(keys) - 1:
				a = b = keys[-1]
			else:
				a, b = keys[i0], keys[i0 + 1]
		out.append(blend(a, b, frac))
	return out


# ---------------------------------------------------------------- Boss

## Boss 关键帧来自用户素材，源图（art/src）和 _keys_boss 都在精简时删了。
## 好消息：成品帧 = 关键帧 -> 一次已知形变 -> 最近邻 x4，
## 所以挑出「形变恒等」的那一帧再缩回来就精确等于原关键帧。
## 这里在 _keys_boss 缺失时自动反推，保证脚本随时能重跑。
BOSS_KEY_PLAN = [
	("idle_0", "idle_0", 1.0), ("idle_1", "idle_3", 1.0),
	("walk_0", "walk_0", 1.0), ("walk_1", "walk_2", 1.0),
	("walk_2", "walk_4", 1.0), ("walk_3", "walk_6", 1.0),
	("crouch_0", "crouch_0", 1.0),
	# 关键帧文件名仍叫 punch_*（jab / whiff 也基于这个姿势），
	# 但成品目录里它已经改名 dash_*，所以源写成候选列表。
	("punch_0", ["dash_0", "punch_0"], 1.0), ("punch_1", ["dash_2", "punch_2"], 1.0),
	("recover_0", "recover_0", 1.0),
	("vanish_0", "vanish_0", 0.85),      # alpha 被乘了 0.85，除回去
	("appear_0", ["slam_2", "appear_2"], 1.0),
	("drop_0", ["slam_4", "drop_0"], 1.0),
	("land_0", ["slam_12", "land_4"], 1.0),
	("dead_0", "dead_0", 1.0),           # 已旋转 -90°，无法还原
	("aim_0", "aim_1", 1.0),
	("fire_0", "fire_0", 1.0),
	("charge_0", "charge_3", 1.0),
]


def ensure_boss_keys():
	d = "art/_keys_boss"
	if os.path.isdir(d):
		return
	print("  art/_keys_boss 缺失 -> 从 art/boss 反推关键帧")
	os.makedirs(d)
	for dst, src, inv_a in BOSS_KEY_PLAN:
		# src 可以是单个名字或候选列表：
		# appear/drop/land 合并成 slam 后 PNG 改名了，
		# 但重建时要能同时吃「合并前 / 合并后」两种目录状态 ——
		# 否则第一次跑（还没有 slam_*）就反推不出来，鸡生蛋。
		cands = [src] if isinstance(src, str) else list(src)
		path = None
		for c in cands:
			if os.path.exists("art/boss/%s.png" % c):
				path = "art/boss/%s.png" % c
				break
		if path is None:
			raise SystemExit("关键帧源都不存在: %s (试过 %s)" % (dst, cands))
		# 768 -> 128 是大幅缩小，NEAREST 只会每隔 6 个像素取样一次，
		# 等于丢掉 98% 的信息并且产生锯齿。用 LANCZOS 做面积意义上的降采样，
		# 之后再量化成扁平色 —— 这才是「绘制稿转像素画」的正确顺序。
		im = load(path).resize((BOSS_CELL, BOSS_CELL), Image.LANCZOS)
		if inv_a != 1.0:
			px = im.load()
			for y in range(im.height):
				for x in range(im.width):
					r, g, b, al = px[x, y]
					if al:
						px[x, y] = (r, g, b, min(255, int(round(al / inv_a))))
		im.save("%s/%s.png" % (d, dst))
	print("  反推 %d 个关键帧" % len(BOSS_KEY_PLAN))


def build_boss():
	ensure_boss_keys()
	d = "art/_keys_boss"
	K = lambda n: load("%s/%s.png" % (d, n))
	G, C = BOSS_GROUND, BOSS_CELL

	# idle 8 帧：呼吸起伏 + 重心微移。曲线刻意非对称，
	# 否则相邻帧几乎一样，看起来是静止的。
	idle = seq_blend([K("idle_0"), K("idle_1")], 8)
	idle = [squash(f, 1.0, sy, G, C) for f, sy in zip(
		idle, [1.000, 1.006, 1.014, 1.020, 1.016, 1.008, 0.996, 0.990])]

	# walk 10 帧：4 个迈步姿势插值到 10 帧，起伏跟着步频走（正弦）
	walk = seq_blend([K("walk_%d" % i) for i in range(4)], 10)
	walk = [squash(f, 1.0, 1.0 + 0.035 * sin(2 * PI * i / 10.0), G, C)
			for i, f in enumerate(walk)]

	# crouch 5 帧：预备动作 —— 快速下沉再稳住（下蹲越深，冲出去越有劲）
	crouch = [squash(K("crouch_0"), 1.0 + 0.030 * i, 1.0 - 0.038 * i, G, C)
			  for i in range(5)]

	# punch 5 帧：向前伸展并定格（冲拳全程都保持这个"手臂伸出"的姿态）
	punch = seq_blend([K("punch_0"), K("punch_1")], 5)
	punch = [squash(f, 1.0 + 0.035 * i, 1.0, G, C) for i, f in enumerate(punch)]

	# ---- 普通拳专用（与冲拳区分开）----
	# 原来普通拳和冲拳共用 crouch + punch，两招起手/击打一模一样，
	# 玩家看不出「这次是近身短拳还是远程冲撞」—— 读招信息丢了。
	#
	# jab_wind 4 帧：蹲得比 crouch 浅（短拳不需要蓄力），幅度约 crouch 的 2/3
	jab_wind = [squash(K("crouch_0"), 1.0 + 0.020 * i, 1.0 - 0.025 * i, G, C)
				for i in range(4)]

	# jab 4 帧：击打幅度只有 punch 的一半（punch 是 0.035*i + 双手前伸）
	# —— 短促、收得住，跟冲拳「整个人撞出去」的姿态明显不同
	jab = [squash(K("punch_0"), 1.0 + 0.018 * i, 1.0, G, C) for i in range(4)]

	# whiff 6 帧：冲拳扑空的失衡 —— 冲过头、重心没收住、踉跄收回。
	# 这不是「复位」：recover 是从容收招，whiff 是失控后找回平衡。
	# 前 2 帧继续前倾（惯性还没吃完），之后才往回收，最后站定。
	whiff = []
	for i in range(6):
		whiff.append(squash(K("punch_0"),
							[1.10, 1.14, 1.08, 1.00, 0.96, 0.98][i],
							[0.98, 0.94, 0.96, 1.00, 1.03, 1.01][i], G, C))

	# recover 5 帧：收招复位 —— 从出拳后摇回到站定（d11 直立待机）
	recover = [squash(K("recover_0"), 1.0 - 0.030 * i, 1.0 + 0.024 * i, G, C)
			   for i in range(5)]

	# vent 6 帧：全图炮的专属后摇 —— 开完巨炮的「散热/复位」。
	# 不能共用 recover：那是「打完一拳从容收回」的小动作，
	# 而炮的后摇要体现「刚推出一道全屏光束」——
	#   手臂还在前方（炮口方向）、身体被后坐力顶得后仰，然后才慢慢放下站定。
	# 起点用 punch_0（手臂前伸），终点 recover_0（d11 直立待机），
	# 前两帧刻意不怎么动（后坐力还没卸掉），后面才收。
	vent = seq_blend([K("punch_0"), K("recover_0")], 6, loop=False)
	vent = [squash(f, 1.0 + 0.055 * (1.0 - i / 5.0), 1.0 - 0.038 * (1.0 - i / 5.0),
				   G, C) for i, f in enumerate(vent)]

	# warp 6 帧：闪现砸的专属前摇（原来共用 crouch，看不出要闪走）
	# 整体收缩 = 「蓄力、准备消失」，跟 crouch 的「变宽变扁」明显区分。
	# 只缩不淡出 —— 淡出是 vanish 的事，这里要让玩家看清它在蓄力。
	warp = []
	for i in range(6):
		k = i / 5.0
		warp.append(squash(K("crouch_0"), 1.0 - 0.10 * k, 1.0 - 0.12 * k, G, C))

	# vanish 5 帧：缩小 + 淡出。关键帧是未淡出的原图，这里统一做渐隐
	vanish = [fade(squash(K("vanish_0"), 1.0 - 0.10 * i, 1.0 - 0.12 * i, G, C),
				   [0.90, 0.62, 0.38, 0.18, 0.06][i]) for i in range(5)]

	# appear 4 帧：由小变大（= 从空中落下来的"凑近"感）
	appear = [squash(K("appear_0"), 0.72 + 0.10 * i, 0.72 + 0.10 * i, G, C)
			  for i in range(4)]

	# drop 4 帧：下落时纵向拉长（速度感）
	drop = [squash(K("drop_0"), 1.0 - 0.035 * i, 1.0 + 0.075 * i, G, C)
			for i in range(4)]

	# land 6 帧：砸地 —— 猛压扁，再弹回并轻微过冲（打击感全靠这组）
	land = []
	for i in range(6):
		k = i / 5.0
		# 0.70 压到最扁 -> 1.05 过冲 -> 1.00 稳定
		sy = 0.70 + 0.35 * k if k < 0.8 else 1.05 - 0.05 * ((k - 0.8) / 0.2)
		sx = 1.30 - 0.30 * k if k < 0.8 else 1.06 - 0.06 * ((k - 0.8) / 0.2)
		land.append(squash(K("land_0"), sx, sy, G, C))

	# dead 4 帧：向后倒下（关键帧本身已是 -90°，这里再补一段倒地过程）
	dead = [rotate(K("dead_0"), 26.0 - 9.0 * i, G, C) for i in range(4)]

	# aim 4 帧：抬枪瞄准，手逐渐举稳
	aim = [squash(K("aim_0"), 1.0, 0.96 + 0.018 * i, G, C) for i in range(4)]

	# fire 4 帧：击发 —— 后坐猛地一缩再回弹。
	# 注意 fire 帧在招式里只持续 2 tick，所以第 0 帧才是真正会被看到的，
	# 把最强的枪口/后坐放在第一帧。
	fire = []
	for i in range(4):
		k = [1.0, 0.60, 0.22, 0.0][i]
		fire.append(squash(K("fire_0"), 1.0 - 0.12 * k, 1.0 - 0.05 * k, G, C))

	# charge 8 帧：蓄力脉动（循环，配合全图炮 1.2 秒前摇）
	# 脉动：原本 k = abs(i/8*2-1) 是对称的，8 帧里只有 5 种 ——
	# 相邻帧会有重复，循环起来一卡一卡。改成 8 个各不相同的相位值。
	charge = []
	for i in range(8):
		k = [0.20, 0.55, 0.90, 1.00, 0.78, 0.48, 0.12, 0.00][i]
		charge.append(squash(K("charge_0"), 1.0 + 0.07 * k, 1.0 + 0.06 * k, G, C))

	_res = {
		"idle": (idle, 7.0, True),
		"walk": (walk, 14.0, True),
		"crouch": (crouch, 16.0, False),
		"warp": (warp, 14.0, False),
		"dash": (punch, 20.0, False),
		"jab_wind": (jab_wind, 12.0, False),
		"jab": (jab, 24.0, False),
		"whiff": (whiff, 16.0, False),
		"recover": (recover, 11.0, False),
		"vent": (vent, 9.0, False),
		"vanish": (vanish, 18.0, False),
		"appear": (appear, 24.0, False),
		"drop": (drop, 10.0, False),
		"land": (land, 22.0, False),
		"dead": (dead, 8.0, False),
		"aim": (aim, 14.0, False),
		"fire": (fire, 40.0, False),
		"charge": (charge, 12.0, True),
		# slam = appear + drop + land 合并成一个连续动画。
		# 三段在帧表里是三帧（7 / 落地为止 / 14 tick），分开播会在衔接处
		# 各播各的、节奏对不上。合并后靠每帧 duration 精确分配：
		#   appear 4 帧共 7 tick、drop 4 帧共 10 tick、land 6 帧共 14 tick
		# speed 设 60，duration 就直接等于 tick 数。
		#
		# drop 段必须跟帧表里的下落速度对齐：
		#   dvy 1500、落差 260px -> 260/1500*60 = 10.4 帧
		# 原来是 1000 -> 15.6 帧，写 16 tick。改成 1500 后必须同步改这里，
		# 否则动画还没播完就落地，drop 段的姿势被切掉。
		"slam": (appear + drop + land, 60.0, False,
				 [7.0 / 4] * 4 + [10.0 / 4] * 4 + [14.0 / 6] * 6),
	}

	# ---- 统一量化成扁平像素画 ----
	# 在形变/混合【之后】量化：squash 用 LANCZOS 会插值出过渡色，
	# 不压回去的话每一帧又变回「绘制稿」。量化后颜色数恒等于调色板大小，
	# 无论怎么缩放/混合都保持扁平。
	_pal = extract_palette([f for v in _res.values() for f in v[0]], BOSS_PAL_N)
	print("  Boss 扁平调色板 %d 色: %s" % (
		len(_pal), " ".join("#%02X%02X%02X" % c
							for c in sorted(_pal, key=lambda c: -sum(c)))))
	_out = {}
	for _k, _v in _res.items():
		# 注意外层的 [[...]]：帧列表必须作为一个整体元素。
		# 直接 [frames...] + rest 会把每一帧摊平成独立元素，
		# 于是 v[0] 变成单张 Image 而不是帧列表。
		_out[_k] = tuple([[quantize(f, _pal) for f in _v[0]]] + list(_v[1:]))
	return _out


# ---------------------------------------------------------------- Player

## 玩家关键帧同样从成品反推（art/src 已删）。
## 挑「形变恒等 / 最接近恒等」的那一帧，按 1/6 最近邻缩回 128：
##   idle_0 sy=1.000 恒等
##   run_0  sy=1.05 / run_1 mix / run_2 sy=1.05 ...  取 0/2/4 近似
##   jump_2 sy=1.14  -> 取 jump_6 (sy=0.80) 反而最差，用 jump_3 (1.16)? 都不恒等
##   -> 统一策略：取每个动画里「形变最小」的帧，残差 <=16% 可忽略（仅用于重建管线）
PLAYER_KEY_PLAN = [
	("idle_0", "idle_0"), ("idle_1", "idle_1"),
	("run_0", "run_0"), ("run_1", "run_1"), ("run_2", "run_2"), ("run_3", "run_3"),
	# jump 改成 5 帧后索引只有 0..4。取形变最小的一帧（curve[1] = 0.98/1.04，
	# 最接近恒等）—— 原来写的 jump_5 已经越界。
	("jump_0", ["jump_1", "jump_5"]),
	("shoot_0", "shoot_0"), ("shoot_1", "shoot_2"),
	("dodge_1", "dodge_0"),
	("shoot_air_0", "shoot_air_0"), ("shoot_air_1", "shoot_air_2"),
	("hurt_0", "hurt_0"),
]


def ensure_player_keys():
	d = "art/_keys_player"
	if os.path.isdir(d):
		return
	print("  art/_keys_player 缺失 -> 从 art/player 反推关键帧")
	os.makedirs(d)
	for dst, src in PLAYER_KEY_PLAN:
		# src 支持候选列表：jump 改帧数后旧索引会失效，
		# 写成 ["jump_1", "jump_5"] 就能同时吃新旧两种目录状态。
		cands = [src] if isinstance(src, str) else list(src)
		path = None
		for c in cands:
			if os.path.exists("art/player/%s.png" % c):
				path = "art/player/%s.png" % c
				break
		if path is None:
			raise SystemExit("关键帧源都不存在: %s (试过 %s)" % (dst, cands))
		# Player 用 NEAREST：它的 768 图本来就是 128 图整数倍放大出来的，
		# NEAREST 降采样是【无损还原】，颜色数一点不变。
		# 这里千万别用 LANCZOS —— 会把清晰的像素边缘插值成渐变，
		# 颜色数从 15 暴涨到 1600+，像素画直接变糊。
		# （Boss 相反：它是绘制稿，必须 LANCZOS 降采样再量化。）
		im = load(path).resize((PLAYER_CELL, PLAYER_CELL), Image.NEAREST)
		im.save("%s/%s.png" % (d, dst))
	print("  反推 %d 个关键帧" % len(PLAYER_KEY_PLAN))


def build_player():
	ensure_player_keys()
	d = "art/_keys_player"
	K = lambda n: load("%s/%s.png" % (d, n))
	G, C = PLAYER_GROUND, PLAYER_CELL

	# idle 3 帧：极轻的呼吸起伏，非对称值避免相邻帧雷同
	idle = [squash(K("idle_0"), 1.0, sy, G, C) for sy in (1.000, 1.018, 0.992)]

	# run 6 帧：4 个关键姿势插值到 6 帧，配合迈步起伏
	run = seq_blend([K("run_%d" % i) for i in range(4)], 6)
	run = [squash(f, 1.0, 1.05 if i % 2 == 0 else 0.96, G, C)
		   for i, f in enumerate(run)]

	# jump 8 帧：蹲 -> 蹬直 -> 升空 -> 顶点 -> 下落 -> 落地压扁 -> 回弹 -> 站定
	jump = []
	#  (纵向, 横向)：越高越修长，落地越扁
	# 5 帧：蹲 -> 蹬直升空 -> 顶点修长 -> 落地压扁 -> 回弹站定
	# 保留了最关键的三个节点（起跳蹲 / 落地压扁 / 回弹），中间的过渡帧去掉。
	curve = [(0.84, 1.14), (0.98, 1.04), (1.16, 0.90), (0.80, 1.22), (0.94, 1.06)]
	for sy, sx in curve:
		jump.append(squash(K("jump_0"), sx, sy, G, C))

	# shoot 5 帧：抬枪 -> 举稳 -> 击发（枪口焰）-> 后坐 -> 回位
	s0, s1 = K("shoot_0"), K("shoot_1")
	# 末帧不能直接用 s0 —— 那样首末帧完全相同，check_art 会报重复，
	# 播起来也像「没回到位就跳回去了」。用 0.85 让枪口还留一点余焰。
	shoot = [s0.copy(), blend(s0, s1, 0.45), s1.copy(),
			 blend(s1, s0, 0.5), blend(s1, s0, 0.85)]

	# dodge 6 帧：整体旋转一圈（-72° 起步更有翻滚感）
	dodge = []
	for i in range(6):
		deg = -72.0 * (i / 6.0)
		dodge.append(rotate(K("dodge_1"), deg, G, C))

	# shoot_air 5 帧：空中射击 —— 收腿姿势 + 举枪/击发/后坐，与 shoot 同节奏
	sa0, sa1 = K("shoot_air_0"), K("shoot_air_1")
	shoot_air = [sa0.copy(), blend(sa0, sa1, 0.45), sa1.copy(),
				 blend(sa1, sa0, 0.5), blend(sa1, sa0, 0.85)]

	# hurt 3 帧（清单里没指定，沿用）
	hurt = [squash(K("hurt_0"), 1.0 + 0.05 * i, 1.0 - 0.04 * i, G, C)
			for i in range(3)]

	# dead 5 帧：踉跄 -> 倾倒 -> 躺倒。
	# 之前 Player 根本没有 dead 动画 —— 玩家死掉时 sprite.play("dead") 找不到
	# 动画就什么都不做，人直接定格在原姿势，跟"死了"完全对不上。
	# 用 rotate 而不是 squash：往前倒是「绕脚底转」，缩放做不出倾倒感。
	# 后两帧再叠一点纵向压缩 = 倒地后彻底瘫下去，不是硬邦邦地竖着倒。
	dead = []
	_degs = (6.0, 24.0, 50.0, 74.0, 90.0)
	_settle = (1.00, 1.00, 0.98, 0.94, 0.90)
	for i in range(5):
		f = rotate(K("idle_0"), _degs[i], G, C)
		if _settle[i] != 1.0:
			f = squash(f, 1.0, _settle[i], G, C)
		dead.append(f)

	_res = {
		"idle": (idle, 5.0, True),
		"run": (run, 14.0, True),
		"jump": (jump, 16.0, False),
		"shoot": (shoot, 20.0, False),
		"shoot_air": (shoot_air, 20.0, False),
		"dodge": (dodge, 20.0, False),
		"hurt": (hurt, 15.0, False),
		"dead": (dead, 8.0, False),
	}

	# ---- 统一量化成扁平像素画 ----
	# Player 的 idle / shoot 本身就是 15 色的扁平像素画，但 jump / dodge /
	# hurt 走过 squash(rotate) 的 LANCZOS 重采样，插值出了上千种过渡色 ——
	# 同一个角色内部风格都不统一。量化后全部回到同一套调色板。
	_pal = extract_palette([f for v in _res.values() for f in v[0]], PLAYER_PAL_N)
	print("  Player 扁平调色板 %d 色: %s" % (
		len(_pal), " ".join("#%02X%02X%02X" % c
							for c in sorted(_pal, key=lambda c: -sum(c)))))
	_out = {}
	for _k, _v in _res.items():
		_out[_k] = tuple([[quantize(f, _pal) for f in _v[0]]] + list(_v[1:]))
	return _out


# ---------------------------------------------------------------- 输出

def upscale(im, k):
	"""整数倍最近邻放大 —— 像素不会被插值糊掉"""
	if k == 1:
		return im
	return im.resize((im.width * k, im.height * k), Image.NEAREST)


def write(outdir, data, cell, sheet_name, order, up=1, ground=None):
	if os.path.isdir(outdir):
		shutil.rmtree(outdir)
	os.makedirs(outdir)

	out_cell = cell * up
	rows = []
	maxf = max(len(v[0]) for v in data.values())
	sheet = (Image.new("RGBA", (out_cell * maxf, out_cell * len(order)), (0, 0, 0, 0))
			 if sheet_name else None)
	ext = []
	for r, nm in enumerate(order):
		frames, fps, loop = data[nm][0], data[nm][1], data[nm][2]
		for c, im in enumerate(frames):
			# 统一裁掉贴地行以下：LANCZOS 降采样会在边缘留下半透明像素，
			# 放大后越过地面行（穿地）。squash 自带 clear_below，
			# 但 shoot / shoot_air 这类只做混合、没走 squash 的帧不会。
			if ground is not None:
				im = clear_below(im, ground, cell)
			big = upscale(im, up)
			fn = "%s/%s_%d.png" % (outdir, nm, c)
			big.save(fn)
			if sheet:
				sheet.paste(big, (c * out_cell, r * out_cell), big)
			ext.append(("t_%s_%d" % (nm, c), "res://%s/%s_%d.png" % (outdir, nm, c)))
		durs = data[nm][3] if len(data[nm]) > 3 else None
		rows.append((nm, len(frames), fps, loop, durs))
	if sheet:
		sheet.save(sheet_name)
	print("  输出画布 %dx%d (x%d 最近邻)" % (out_cell, out_cell, up))

	L = ['[gd_resource type="SpriteFrames" load_steps=%d format=3]' % (len(ext) + 1), ""]
	for eid, p in ext:
		L.append('[ext_resource type="Texture2D" path="%s" id="%s"]' % (p, eid))
	L += ["", "[resource]", "animations = ["]
	for i, (nm, cnt, fps, loop, durs) in enumerate(rows):
		L.append("{")
		L.append('"frames": [')
		for c in range(cnt):
			d = 1.0 if durs is None else durs[c]
			L.append("{")
			L.append('"duration": %s,' % round(float(d), 4))
			L.append('"texture": ExtResource("t_%s_%d")' % (nm, c))
			L.append("}" + ("," if c < cnt - 1 else ""))
		L.append("],")
		L.append('"loop": %s,' % ("true" if loop else "false"))
		L.append('"name": &"%s",' % nm)
		# 有每帧 duration 时 speed 必须是 60：
		# 实际每帧时长 = duration / speed，speed=60 时 duration 就是 tick 数。
		L.append('"speed": %s' % (60.0 if durs is not None else fps))
		L.append("}" + ("," if i < len(rows) - 1 else ""))
	L.append("]")
	tres = outdir + "_frames.tres"
	open(tres, "w").write("\n".join(L) + "\n")

	print("%s: %d 动画 / %d 帧" % (tres, len(rows), len(ext)))
	return rows


def verify(outdir, data, cell, ground, up=1, order=None):
	cell = cell * up
	ground = ground * up
	bad = 0
	# 只验实际输出到磁盘的动画。
	# slam 是由 appear/drop/land 拼出来的，那三个本身不再单独出 PNG ——
	# 遍历 data 全部键会去找已经不存在的 appear_3.png。
	for nm in (order if order else list(data.keys())):
		frames = data[nm][0]
		im = Image.open("%s/%s_%d.png" % (outdir, nm, len(frames) - 1))
		bb = im.getbbox()
		if bb is None:
			print("  !! %s 空帧" % nm)
			bad += 1
			continue
		x0, _y0, x1, y1 = bb
		if y1 > ground or x0 < 0 or x1 > cell:
			print("  !! %s bbox x %d..%d 底 %d" % (nm, x0, x1, y1))
			bad += 1
	print("  校验问题:", bad)


def main():
	# Boss 关键帧缺失时会自动从 art/boss 反推（见 ensure_boss_keys），
	# 所以这里可以安全地同时重建双方 —— 不会把用户美术覆盖成占位图。
	b = build_boss()
	order_b = ["idle", "walk", "crouch", "warp", "dash", "jab_wind", "jab",
			   "whiff", "recover", "vent", "vanish", "slam", "dead", "aim",
			   "fire", "charge"]
	write("art/boss", b, BOSS_CELL, None, order_b, BOSS_UP, BOSS_GROUND)
	verify("art/boss", b, BOSS_CELL, BOSS_GROUND, BOSS_UP, order_b)

	p = build_player()
	order_p = ["idle", "run", "jump", "shoot", "shoot_air", "dodge", "hurt",
			   "dead"]
	write("art/player", p, PLAYER_CELL, None, order_p, PLAYER_UP, PLAYER_GROUND)
	verify("art/player", p, PLAYER_CELL, PLAYER_GROUND, PLAYER_UP, order_p)

	print("\n帧数对比（原 -> 现）")
	for nm in order_b:
		print("  boss   %-10s %2d -> %2d" % (nm, OLD_BOSS.get(nm, 1), len(b[nm][0])))
	for nm in order_p:
		print("  player %-10s %2d -> %2d" % (nm, OLD_PLAYER.get(nm, 1), len(p[nm][0])))
	return
	order_b = ["idle", "walk", "crouch", "warp", "dash", "jab_wind", "jab",
			   "whiff", "recover", "vent", "vanish", "slam", "dead", "aim",
			   "fire", "charge"]
	write("art/boss", b, BOSS_CELL, "art/boss_sheet.png", order_b, BOSS_UP)
	verify("art/boss", b, BOSS_CELL, BOSS_GROUND, BOSS_UP, order_b)

	p = build_player()
	order_p = ["idle", "run", "jump", "shoot", "shoot_air", "dodge", "hurt",
			   "dead"]
	write("art/player", p, PLAYER_CELL, "art/player_sheet.png", order_p, PLAYER_UP)
	verify("art/player", p, PLAYER_CELL, PLAYER_GROUND, PLAYER_UP, order_p)

	print("\n帧数对比（原 -> 现）")
	for nm in order_b:
		print("  boss %-9s %d -> %d" % (nm, OLD_BOSS.get(nm, 1), len(b[nm][0])))
	for nm in order_p:
		print("  player %-7s %d -> %d" % (nm, OLD_PLAYER.get(nm, 1), len(p[nm][0])))


OLD_BOSS = {"idle": 2, "walk": 4, "crouch": 1, "dash": 2, "recover": 1,
			"vanish": 1, "dead": 1, "aim": 1, "fire": 1, "charge": 2,
			"vent": 0,
			"warp": 0, "slam": 1}
OLD_PLAYER = {"idle": 3, "run": 6, "jump": 5, "shoot": 5, "shoot_air": 0,
			  "dodge": 6, "hurt": 3, "dead": 0}

if __name__ == "__main__":
	main()

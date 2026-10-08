#!/usr/bin/env python3
"""合成芯片音（8-bit 风格）音效，输出 16-bit PCM WAV。

为什么用合成而不是找素材：
  - 体积可控（每个 0.1~0.6 秒），跟像素美术风格统一
  - 无版权问题
  - 参数随时可调，改一个数字就能改音色

用法：python3 tools/gen_sfx.py
"""

import os
import wave
import numpy as np

SR = 44100
OUT = "sfx"


def env(n, attack=0.005, decay=None, curve=3.0):
	"""指数衰减包络。curve 越大衰减越快。"""
	a = max(1, int(SR * attack))
	e = np.ones(n)
	if a > 1:
		e[:a] = np.linspace(0.0, 1.0, a)
	if decay is None:
		decay = n / float(SR)
	d = min(max(1, int(SR * decay)), n)
	e[n - d:] *= np.exp(-curve * np.linspace(0.0, 1.0, d))
	return e


def osc(freq, n, kind="square", phase=0.0):
	"""freq 可以是常数，也可以是和 n 等长的数组（做扫频）。"""
	t = np.arange(n) / float(SR)
	f = np.full(n, float(freq)) if np.isscalar(freq) or isinstance(freq, (int, float)) else freq
	ph = 2.0 * np.pi * np.cumsum(f) / float(SR) + phase
	if kind == "square":
		return np.sign(np.sin(ph))
	if kind == "saw":
		return 2.0 * ((ph / (2.0 * np.pi)) % 1.0) - 1.0
	if kind == "tri":
		return 2.0 * np.abs(2.0 * ((ph / (2.0 * np.pi)) % 1.0) - 1.0) - 1.0
	return np.sin(ph)


def noise(n, seed=0):
	rng = np.random.default_rng(seed)
	return rng.uniform(-1.0, 1.0, n)


def sweep(n, f0, f1, curve=1.0):
	"""从 f0 指数扫到 f1。curve>1 前慢后快。"""
	t = np.linspace(0.0, 1.0, n) ** curve
	return f0 * (f1 / float(f0)) ** t


def norm(x, peak=0.85):
	m = np.max(np.abs(x))
	if m < 1e-6:
		return x
	return x * (peak / m)


def save(name, x):
	x = np.clip(norm(x), -1.0, 1.0)
	pcm = (x * 32767.0).astype(np.int16)
	os.makedirs(OUT, exist_ok=True)
	p = "%s/%s.wav" % (OUT, name)
	with wave.open(p, "w") as w:
		w.setnchannels(1)
		w.setsampwidth(2)
		w.setframerate(SR)
		w.writeframes(pcm.tobytes())
	print("  %-12s %5.3fs  %5.1f KB" % (name, len(x) / float(SR),
										len(pcm) * 2 / 1024.0))


# ---------------------------------------------------------------- 外部素材

## 冲拳音效改用外部素材（用户提供的 mp3 的第 2.5~5.0 秒）。
## 素材本身存在 sfx/src/ 下 —— 这样重跑本脚本不会把改动冲掉。
DASH_SRC_WAV = "sfx/src/dash_clip_2.5-5.0s.wav"
DASH_SRC_T0 = 2.5
DASH_SRC_T1 = 5.0

## 裁掉素材开头的静音（秒）。
##
## 这段素材开头约 0.29 秒几乎无声 —— 触发时要等 0.29 秒才听到响动，
## 冲拳前摇总共才 0.40 秒，听感上像「没触发」。
## 默认 0.0 = 严格按用户指定的 2.5~5.0 秒，一个采样都不裁。
## 想要「按下立刻出声」，把它改成 0.2875（第一个超过 -34dBFS 的位置）。
DASH_CLIP_TRIM_LEAD = 0.0


def load_clip(path, t0=None, t1=None):
	"""读 16-bit PCM WAV，返回 float32 [-1,1]。可指定起止秒数。"""
	with wave.open(path, "r") as w:
		if w.getsampwidth() != 2:
			raise ValueError("需要 16-bit PCM: %s" % path)
		sr = w.getframerate()
		nch = w.getnchannels()
		raw = w.readframes(w.getnframes())
	x = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
	if nch > 1:
		x = x.reshape(-1, nch).mean(axis=1)
	if sr != SR:
		# 线性重采样（音效长度都很短，够用）
		idx = np.arange(int(len(x) * SR / float(sr))) * (sr / float(SR))
		i0 = idx.astype(np.int64)
		frac = idx - i0
		i0 = np.clip(i0, 0, len(x) - 2)
		x = x[i0] * (1.0 - frac) + x[i0 + 1] * frac
	if t0 is not None:
		x = x[int(t0 * SR):]
	if t1 is not None:
		x = x[:int((t1 - (t0 or 0.0)) * SR)]
	return x


# ---------------------------------------------------------------- 音效

def s_shoot():
	"""玩家开枪：短促的 pew，高频起手快速下滑"""
	n = int(SR * 0.11)
	f = sweep(n, 1500.0, 420.0, 0.6)
	x = osc(f, n, "square") * env(n, 0.002, None, 5.0)
	x += noise(n, 1) * env(n, 0.001, 0.03, 8.0) * 0.30
	return x


def s_enemy_shoot():
	"""Boss 开枪：比玩家低沉，稍长"""
	n = int(SR * 0.14)
	f = sweep(n, 900.0, 260.0, 0.6)
	x = osc(f, n, "saw") * env(n, 0.003, None, 4.0)
	x += noise(n, 2) * env(n, 0.001, 0.04, 7.0) * 0.22
	return x


def s_hit():
	"""打中 Boss：干脆的金属打击 + 低频厚度"""
	n = int(SR * 0.13)
	x = osc(sweep(n, 620.0, 190.0, 0.5), n, "square") * env(n, 0.001, None, 6.0)
	x += noise(n, 3) * env(n, 0.001, 0.05, 6.0) * 0.45
	x += osc(90.0, n, "tri") * env(n, 0.001, 0.07, 4.0) * 0.55
	return x


def s_hurt():
	"""玩家受击：更闷、带一点下坠感（跟 hit 明确区分）"""
	n = int(SR * 0.17)
	x = osc(sweep(n, 300.0, 110.0, 0.7), n, "tri") * env(n, 0.002, None, 4.0)
	x += noise(n, 4) * env(n, 0.001, 0.06, 5.0) * 0.50
	return x


def s_jump():
	"""跳跃：上滑的短音"""
	n = int(SR * 0.12)
	f = sweep(n, 300.0, 760.0, 0.8)
	x = osc(f, n, "square") * env(n, 0.004, None, 4.0) * 0.7
	return x


def s_dodge():
	"""翻滚：噪声扫频，像布料/风声 whoosh"""
	n = int(SR * 0.20)
	nn = noise(n, 5)
	# 用一个随时间移动的带通近似：把噪声乘上扫频正弦
	x = nn * osc(sweep(n, 2600.0, 500.0, 0.6), n, "sin")
	x *= env(n, 0.02, None, 3.0) * 0.75
	return x


def s_launch():
	"""被击飞：低频冲击 + 上滑尾音，比 hurt 更重"""
	n = int(SR * 0.28)
	x = osc(sweep(n, 160.0, 60.0, 0.5), n, "square") * env(n, 0.002, 0.12, 3.0)
	x += osc(sweep(n, 220.0, 700.0, 0.9), n, "tri") * env(n, 0.01, None, 3.0) * 0.5
	x += noise(n, 6) * env(n, 0.001, 0.08, 5.0) * 0.40
	return x


def s_cannon():
	"""全图炮激光：蓄能嗡鸣 -> 发射爆鸣 -> 余韵"""
	n0 = int(SR * 0.30)
	n1 = int(SR * 0.35)
	n = n0 + n1
	# 蓄能：上升的嗡鸣
	ch = osc(sweep(n0, 120.0, 900.0, 1.6), n0, "saw") * env(n0, 0.05, None, 0.6) * 0.35
	# 发射：宽频爆鸣
	bl = noise(n1, 7) * env(n1, 0.002, None, 2.2) * 0.75
	bl += osc(sweep(n1, 1400.0, 180.0, 0.5), n1, "square") * env(n1, 0.001, None, 3.0) * 0.55
	x = np.concatenate([ch, bl])
	return x


def s_mv_jab():
	"""普通拳提示音：极短的高音「嗒」。
	普通拳前摇只有 15 帧(0.25s)，提示音必须短 ——
	长了会盖住下一招的提示，玩家反而分不清。"""
	n = int(SR * 0.07)
	x = osc(sweep(n, 1750.0, 1250.0, 0.5), n, "square") * env(n, 0.001, None, 8.0) * 0.55
	return x


def s_mv_dash():
	"""冲拳音效：外部素材 mp3 的第 2.5~5.0 秒（用户指定）。

	原来这里是 0.30 秒的合成风声蓄力 —— 换成真实素材后长度 2.5 秒，
	比冲拳前摇(0.40s)长很多，会一直响到招式结束之后。
	这是素材本身的长度造成的，不是 bug；想缩短就改 DASH_SRC_T1，
	或者调 SfxTuning.mv_dash 的音量把它压低当背景层。

	save() 会统一归一化到 peak 0.85，跟其它音效响度一致，
	所以这里不需要自己做音量。
	"""
	if not os.path.exists(DASH_SRC_WAV):
		raise FileNotFoundError("素材缺失: %s" % DASH_SRC_WAV)
	return load_clip(DASH_SRC_WAV, DASH_CLIP_TRIM_LEAD, None)


def s_mv_blink():
	"""闪现砸提示音：高频闪烁 shimmer（要消失了）。
	用交替的断续高音，跟冲拳的连续风声拉开距离 ——
	一个是「冲过来」，一个是「要消失」，听觉上必须一眼分得开。"""
	n = int(SR * 0.32)
	x = np.zeros(n)
	# 6 段短促高音，越来越密 —— 像能量在聚集
	for i in range(6):
		seg = int(SR * 0.045)
		st = int(i * SR * 0.042)
		if st + seg > n:
			break
		f = 1400.0 + i * 260.0
		x[st:st + seg] += osc(f, seg, "tri") * env(seg, 0.002, None, 7.0) * 0.45
	x += osc(sweep(n, 600.0, 1500.0, 1.3), n, "sin") * env(n, 0.06, None, 1.6) * 0.25
	return x


def s_mv_charge():
	"""全图炮提示音：上升的蓄能嗡鸣。
	蓄能 45 帧(0.75s)，音做 0.62s —— 在开炮前收尾。
	这是最该躲的一招(300伤害)，提示音要最「贵」、最有存在感。"""
	n = int(SR * 0.62)
	x = osc(sweep(n, 90.0, 760.0, 1.7), n, "saw") * env(n, 0.10, None, 0.9) * 0.40
	x += osc(sweep(n, 180.0, 1520.0, 1.7), n, "tri") * env(n, 0.10, None, 1.1) * 0.22
	x += noise(n, 12) * env(n, 0.15, None, 1.4) * 0.18
	return x



def s_wall_hit():
	"""子弹打在墙上：短促的闷响 + 金属余韵。
	比 hit 更干、更短 —— 打墙不该跟打中人一样有分量。"""
	n = int(SR * 0.09)
	x = osc(sweep(n, 780.0, 300.0, 0.5), n, "square") * env(n, 0.001, None, 9.0) * 0.38
	x += noise(n, 21) * env(n, 0.001, 0.04, 8.0) * 0.28
	return x


def s_land():
	"""落地：低频闷响 + 一点碎石感。跳跃落地和闪现砸落地都用。"""
	n = int(SR * 0.16)
	x = osc(sweep(n, 140.0, 48.0, 0.6), n, "tri") * env(n, 0.002, None, 5.0) * 0.70
	x += noise(n, 22) * env(n, 0.001, 0.06, 5.5) * 0.35
	return x


def s_dash_whoosh():
	"""冲拳冲出去那一下的风声。跟 mv_dash（前摇蓄力）区分开：
	这个是「已经动了」，短、急、有速度感。"""
	n = int(SR * 0.22)
	nn = noise(n, 23)
	x = nn * osc(sweep(n, 1800.0, 320.0, 0.45), n, "sin")
	x *= env(n, 0.012, None, 3.2) * 0.55
	return x


def s_teleport_out():
	"""闪现消失：上滑的「咻」，音高往上跑 = 人往上/往外去了。"""
	n = int(SR * 0.18)
	x = osc(sweep(n, 420.0, 1900.0, 0.7), n, "tri") * env(n, 0.005, None, 4.5) * 0.40
	x += noise(n, 24) * env(n, 0.004, None, 5.5) * 0.20
	return x


def s_teleport_in():
	"""闪现现身：下滑的「咚」，跟 teleport_out 首尾呼应。"""
	n = int(SR * 0.20)
	x = osc(sweep(n, 1700.0, 380.0, 0.7), n, "tri") * env(n, 0.004, None, 4.0) * 0.45
	x += osc(sweep(n, 200.0, 70.0, 0.6), n, "square") * env(n, 0.002, 0.08, 5.0) * 0.35
	return x


def s_ui_click():
	"""UI 点击：极短的清脆「嘀」。音量刻意很小，不抢战斗音。"""
	n = int(SR * 0.045)
	x = osc(sweep(n, 1600.0, 1200.0, 0.5), n, "square") * env(n, 0.001, None, 10.0) * 0.30
	return x


def s_low_hp():
	"""低血警告：两声急促的心跳式闷音。
	玩家血量低于阈值时循环播 —— 不用看血条也知道快死了。"""
	out = []
	for i in range(2):
		n = int(SR * 0.13)
		seg = osc(sweep(n, 110.0, 55.0, 0.7), n, "tri") * env(n, 0.006, None, 4.5) * 0.55
		if i == 1:
			seg *= 0.75                      # 第二声轻一点，像心跳的「咚-哒」
		out.append(seg)
		out.append(np.zeros(int(SR * 0.09)))
	return np.concatenate(out)


def s_phase_hit():
	"""二阶段转场的第二层：金属刮擦，叠在 phase 之上让转场更有层次。"""
	n = int(SR * 0.50)
	x = noise(n, 25) * osc(sweep(n, 3200.0, 700.0, 0.5), n, "sin")
	x *= env(n, 0.03, None, 2.0) * 0.30
	x += osc(sweep(n, 160.0, 420.0, 1.2), n, "saw") * env(n, 0.05, None, 2.2) * 0.22
	return x


def s_combo():
	"""连续命中的累进音：音高随连击数上行。
	由代码按 combo 数选 pitch，这里只做基础音。"""
	n = int(SR * 0.10)
	x = osc(880.0, n, "square") * env(n, 0.002, None, 6.0) * 0.40
	x += osc(1760.0, n, "tri") * env(n, 0.002, None, 7.0) * 0.18
	return x


def s_beam_hum():
	"""激光持续期的嗡鸣。发射后循环铺在 cannon 爆鸣之后，
	让「一道光横在那里」有持续存在的感觉。"""
	n = int(SR * 0.45)
	x = osc(sweep(n, 620.0, 480.0, 0.8), n, "saw") * env(n, 0.02, None, 1.0) * 0.26
	x += osc(960.0, n, "sin") * env(n, 0.02, None, 1.2) * 0.10
	return x


def s_phase():
	"""二阶段转场：低沉的轰鸣 + 上升长音"""
	n = int(SR * 0.75)
	x = osc(sweep(n, 70.0, 300.0, 1.4), n, "tri") * env(n, 0.08, None, 1.6) * 0.7
	x += noise(n, 8) * env(n, 0.02, None, 2.0) * 0.30
	return x


def s_win():
	"""胜利：上行三音"""
	out = []
	for f in (523.25, 659.25, 783.99):
		n = int(SR * 0.17)
		out.append(osc(f, n, "square") * env(n, 0.006, None, 3.0) * 0.6)
	# 最后一个音延长收尾
	n = int(SR * 0.40)
	out.append(osc(1046.5, n, "square") * env(n, 0.006, None, 2.2) * 0.6)
	return np.concatenate(out)


def s_lose():
	"""失败：下行两音"""
	out = []
	for f in (392.0, 261.63):
		n = int(SR * 0.30)
		out.append(osc(f, n, "tri") * env(n, 0.01, None, 2.0) * 0.65)
	n = int(SR * 0.55)
	out.append(osc(196.0, n, "tri") * env(n, 0.01, None, 1.5) * 0.65)
	return np.concatenate(out)


PLAN = [
	("shoot", s_shoot),
	("enemy_shoot", s_enemy_shoot),
	("hit", s_hit),
	("hurt", s_hurt),
	("jump", s_jump),
	("dodge", s_dodge),
	("launch", s_launch),
	("cannon", s_cannon),
	("beam_hum", s_beam_hum),
	# ---- 动作反馈 ----
	("wall_hit", s_wall_hit),
	("land", s_land),
	("dash_whoosh", s_dash_whoosh),
	("teleport_out", s_teleport_out),
	("teleport_in", s_teleport_in),
	("combo", s_combo),
	# ---- 状态 / UI ----
	("low_hp", s_low_hp),
	("phase_hit", s_phase_hit),
	("ui_click", s_ui_click),
	# ---- 每招专属起手音（audio telegraph）----
	("mv_jab", s_mv_jab),
	("mv_dash", s_mv_dash),
	("mv_blink", s_mv_blink),
	("mv_charge", s_mv_charge),
	("phase", s_phase),
	("win", s_win),
	("lose", s_lose),
]


def main():
	print("生成音效 -> %s/ (SR %d, 16-bit PCM)" % (OUT, SR))
	for name, fn in PLAN:
		save(name, fn())
	print("共 %d 个" % len(PLAN))


if __name__ == "__main__":
	main()

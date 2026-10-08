#!/usr/bin/env python3
"""从现有 art/boss/*.png 反推「干净关键帧」，重建 art/_keys_boss。

为什么需要这个
--------------
art/src（用户原始素材）和 art/_keys_boss 都在精简时删掉了，
而 gen_boss_from_source.py 没有源图就跑不了。
好在成品帧是「关键帧 -> 一次形变 -> 最近邻放大 x4」的结果，
形变参数在 gen_smooth_frames.py 里是已知的，
所以只要挑出**形变为恒等（sx=sy=1.0）**的那一帧，
再按 1/4 最近邻还原，就精确等于原来的关键帧。

选帧依据（对照 gen_smooth_frames.py 里 build_boss 的形变表）
--------------------------------------------------------
  idle_0     sy=1.000                        恒等
  walk_0/2/4/6  sy 在 1.03 / 0.98 之间       残差 3%，忽略
  punch_0    sx=1.00                         恒等
  punch_2    两姿势各半                      当作第二个姿势
  crouch_0   sx=1.00 sy=1.00                 恒等
  recover_0  sx=1.00 sy=1.00                 恒等
  vanish_0   形状恒等，只有 alpha*0.85       alpha 除回去
  appear_2   0.82+0.09*2 = 1.00              恒等
  drop_0     sx=1.00 sy=1.00                 恒等
  land_4     sx=1.00 sy=1.04                 残差 4%，忽略
  dead_0     已旋转 -90°                    无法还原，原样保留
  aim_1      sy=0.99                         残差 1%，忽略
  fire_0     k=0 -> 恒等                     恒等
  charge_3   k=abs(0.5*2-1)=0 -> 恒等        恒等

用法：python3 tools/extract_boss_keys.py
"""

import os
import shutil
from PIL import Image

CELL_OUT = 768      # 成品画布
CELL = 192          # 关键帧画布（= 成品 / UP）
UP = CELL_OUT // CELL
OUT = "art/boss"
DST = "art/_keys_boss"


def down(im):
	"""最近邻 1/4 还原。成品是 NEAREST x4 放大的，
	块内任意像素值都相同，所以 NEAREST 缩回来是精确的。"""
	return im.resize((CELL, CELL), Image.NEAREST)


def unfade(im, a):
	"""把 fade(a) 乘掉的 alpha 除回去（vanish_0 用）"""
	px = im.load()
	for y in range(im.height):
		for x in range(im.width):
			r, g, b, al = px[x, y]
			if al:
				px[x, y] = (r, g, b, min(255, int(round(al / a))))
	return im


def get(name):
	p = "%s/%s.png" % (OUT, name)
	if not os.path.exists(p):
		raise SystemExit("缺少 %s —— 请先确认 art/boss 完整" % p)
	return down(Image.open(p).convert("RGBA"))


# 关键帧名 -> (来源帧, 后处理)
PLAN = [
	("idle_0", "idle_0", None),
	("idle_1", "idle_3", None),      # 两姿势各半，当作第二姿势
	("walk_0", "walk_0", None),
	("walk_1", "walk_2", None),
	("walk_2", "walk_4", None),
	("walk_3", "walk_6", None),
	("crouch_0", "crouch_0", None),
	("punch_0", "punch_0", None),
	("punch_1", "punch_2", None),
	("recover_0", "recover_0", None),
	("vanish_0", "vanish_0", lambda im: unfade(im, 0.85)),
	("appear_0", "appear_2", None),
	("drop_0", "drop_0", None),
	("land_0", "land_4", None),
	("dead_0", "dead_0", None),      # 已是 -90°，无法还原
	("aim_0", "aim_1", None),
	("fire_0", "fire_0", None),
	("charge_0", "charge_3", None),
]


def main():
	if os.path.isdir(DST):
		shutil.rmtree(DST)
	os.makedirs(DST)
	print("从 %s 反推关键帧 -> %s（画布 %dx%d）" % (OUT, DST, CELL, CELL))
	for dst, src, post in PLAN:
		im = get(src)
		if post is not None:
			im = post(im)
		im.save("%s/%s.png" % (DST, dst))
		bb = im.getbbox()
		print("  %-10s <- %-10s  bbox %s" % (dst, src, bb))
	print("共 %d 个关键帧" % len(PLAN))


if __name__ == "__main__":
	main()

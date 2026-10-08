#!/usr/bin/env python3
"""从用户提供的 Boss 立绘生成 Godot 精灵帧。

源图：art/src/*.jpg  1408x1408，洋红背景，每张 2x2 共 4 个姿势
      （art/src 已从发布包删除 —— 要重跑本脚本需自行把源图放回该目录）
输出：art/boss/*.png（每个动画独立帧）+ art/boss_frames.tres + art/boss_sheet.png

流程：
  1. 色度键抠掉洋红背景（边缘做半透明过渡）
  2. 每格裁到内容包围盒
  3. 统一缩放（以最高姿势为基准 -> TARGET_H），保持姿势间相对大小
  4. 水平按包围盒居中，垂直底部贴地
  5. 外扩 1px 补淡紫轮廓光（深色装甲在暗背景上才看得清）
  6. 裁掉地面以下的溢出像素
"""
from PIL import Image, ImageFilter, ImageChops
import os, shutil

BG        = (240, 8, 147)   # 源图背景色
TOL       = 62              # 色度键容差（曼哈顿距离）
CELL      = 192             # 输出网格
GROUND    = 168             # 贴地行（cell 内 y）
TARGET_H  = 158.0           # 最高姿势的目标高度
RIM       = (168, 138, 205) # 轮廓光颜色
RIM_ALPHA = 0.42

# 姿势 -> 动画 的分配表
ASSIGN = {
	"idle":    ["a00", "a01"],
	"walk":    ["c00", "c01", "c10", "c11"],
	"crouch":  ["b11"],
	"punch":   ["d10", "d00"],
	"recover": ["d11"],
	"vanish":  ["a10"],              # 会自动降透明度
	"appear":  ["b01"],
	"drop":    ["b10"],
	"land":    ["b00"],
	"dead":    ["d11"],              # 会自动旋转 -90°
	"aim":     ["d01"],
	"fire":    ["d10"],
	"charge":  ["d01", "d01"],
}
ORDER = ["idle", "walk", "crouch", "punch", "recover", "vanish",
		"appear", "drop", "land", "dead", "aim", "fire", "charge"]

# 动画名 -> (帧数, fps, 循环)
ROWS = [("idle", 2, 2.0, True), ("walk", 4, 8.0, True), ("crouch", 1, 1.0, False),
	("punch", 2, 14.0, True), ("recover", 1, 1.0, False),
	("vanish", 1, 1.0, False), ("appear", 1, 1.0, False), ("drop", 1, 1.0, False),
	("land", 1, 1.0, False), ("dead", 1, 1.0, False), ("aim", 1, 1.0, False),
	("fire", 1, 1.0, False), ("charge", 2, 6.0, True)]

SOURCES = [("a", "boss_a"), ("b", "boss_b"), ("c", "boss_c"), ("d", "boss_d")]


def chroma(im):
	im = im.convert("RGBA")
	px = im.load()
	for y in range(im.height):
		for x in range(im.width):
			r, g, b, _a = px[x, y]
			d = abs(r - BG[0]) + abs(g - BG[1]) + abs(b - BG[2])
			if d < TOL:
				px[x, y] = (0, 0, 0, 0)
			elif d < TOL * 2.4:
				px[x, y] = (r, g, b, int(255 * (d - TOL) / (TOL * 1.4)))
	px = im.load()
	for y in range(im.height):
		for x in range(im.width):
			if px[x, y][3] < 60:
				px[x, y] = (0, 0, 0, 0)
	return im


def add_rim(im):
	a = im.split()[3]
	edge = ImageChops.subtract(a.filter(ImageFilter.MaxFilter(3)), a)
	layer = Image.new("RGBA", im.size, (RIM[0], RIM[1], RIM[2], 0))
	lp = layer.load()
	ep = edge.load()
	for y in range(im.height):
		for x in range(im.width):
			v = ep[x, y]
			if v:
				lp[x, y] = (RIM[0], RIM[1], RIM[2], int(v * RIM_ALPHA))
	return Image.alpha_composite(layer, im)


def load_cells():
	src = {}
	for tag, nm in SOURCES:
		im = chroma(Image.open("art/src/%s.jpg" % nm))
		cw, ch = im.width // 2, im.height // 2
		for r in range(2):
			for c in range(2):
				src["%s%d%d" % (tag, r, c)] = im.crop((c * cw, r * ch, (c + 1) * cw, (r + 1) * ch))
	return {k: v.crop(v.getbbox()) for k, v in src.items() if v.getbbox()}


def place(im, scale, alpha=1.0, rotate=0):
	if rotate:
		im = im.rotate(rotate, expand=True, resample=Image.BICUBIC)
	nw = max(1, int(round(im.width * scale)))
	nh = max(1, int(round(im.height * scale)))
	im = im.resize((nw, nh), Image.LANCZOS)
	out = Image.new("RGBA", (CELL, CELL), (0, 0, 0, 0))
	out.paste(im, (int(round(CELL / 2.0 - nw / 2.0)), GROUND - nh), im)
	out = add_rim(out)
	# 轮廓光会外扩到地面下方，裁掉
	px = out.load()
	for y in range(GROUND, CELL):
		for x in range(CELL):
			if px[x, y][3]:
				px[x, y] = (0, 0, 0, 0)
	if alpha < 1.0:
		px = out.load()
		for y in range(CELL):
			for x in range(CELL):
				r, g, b, a = px[x, y]
				if a:
					px[x, y] = (r, g, b, int(a * alpha))
	return out


def main():
	crops = load_cells()
	scale = TARGET_H / max(c.height for c in crops.values())
	print("源最高 %d px -> 缩放 %.4f" % (max(c.height for c in crops.values()), scale))

	outdir = "art/boss"
	if os.path.isdir(outdir):
		shutil.rmtree(outdir)
	os.makedirs(outdir)

	sheet = Image.new("RGBA", (CELL * 4, CELL * len(ORDER)), (0, 0, 0, 0))
	for r, nm in enumerate(ORDER):
		for c, key in enumerate(ASSIGN[nm]):
			base = crops[key]
			if nm == "vanish":
				im = place(base, scale, alpha=0.30)
				# 同时存一份「未淡出」的干净关键帧，供 gen_smooth_frames 做渐隐
				os.makedirs("art/_keys_boss", exist_ok=True)
				place(base, scale).save("art/_keys_boss/vanish_0.png")
			elif nm == "dead":
				im = place(base, scale, rotate=-90)
			else:
				im = place(base, scale)
			im.save("%s/%s_%d.png" % (outdir, nm, c))
			sheet.paste(im, (c * CELL, r * CELL), im)
	sheet.save("art/boss_sheet.png")
	print("art/boss_sheet.png %s" % (sheet.size,))

	# .tres
	ext = []
	for nm, cnt, _fps, _loop in ROWS:
		for c in range(cnt):
			ext.append(("t_%s_%d" % (nm, c), "res://art/boss/%s_%d.png" % (nm, c)))
	L = ['[gd_resource type="SpriteFrames" load_steps=%d format=3]' % (len(ext) + 1), ""]
	for eid, p in ext:
		L.append('[ext_resource type="Texture2D" path="%s" id="%s"]' % (p, eid))
	L += ["", "[resource]", "animations = ["]
	for i, (nm, fps, loop, cnt) in enumerate(ROWS):
		L.append("{")
		L.append('"frames": [')
		for c in range(cnt):
			L.append("{")
			L.append('"duration": 1.0,')
			L.append('"texture": ExtResource("t_%s_%d")' % (nm, c))
			L.append("}" + ("," if c < cnt - 1 else ""))
		L.append("],")
		L.append('"loop": %s,' % ("true" if loop else "false"))
		L.append('"name": &"%s",' % nm)
		L.append('"speed": %s' % fps)
		L.append("}" + ("," if i < len(ROWS) - 1 else ""))
	L.append("]")
	open("art/boss_frames.tres", "w").write("\n".join(L) + "\n")
	print("art/boss_frames.tres: %d 动画 / %d 帧" % (len(ROWS), len(ext)))

	# 校验
	bad = 0
	for nm in ORDER:
		im = Image.open("%s/%s_0.png" % (outdir, nm))
		x0, _y0, x1, y1 = im.getbbox()
		if y1 > GROUND or x0 < 0 or x1 > CELL:
			bad += 1
			print("  !! %s bbox x %d..%d 底 %d" % (nm, x0, x1, y1))
	print("校验问题:", bad)


if __name__ == "__main__":
	main()

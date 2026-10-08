#!/usr/bin/env python3
"""换美术之后跑一下这个 —— 检查尺寸、脚底行、动画名是否与代码一致。

用法: python3 tools/check_art.py
"""
from PIL import Image
import glob, os, re, sys

WANT_BOSS = ["idle", "walk", "crouch", "warp", "dash", "jab_wind", "jab",
             "whiff", "recover", "vent", "vanish", "slam", "dead", "aim",
             "fire", "charge"]
WANT_PLAYER = ["idle", "run", "jump", "shoot", "shoot_air", "dodge", "hurt",
               "dead"]
# 目标帧数（None = 不校验）
WANT_PLAYER_N = {"idle": 3, "run": 6, "jump": 5, "shoot": 5, "shoot_air": 5,
                  "dodge": 6, "hurt": 3}

EXPECT = {"art/boss": (768, 672, "boss"), "art/player": (768, 672, "player")}
# 目标屏幕高度（与 SpriteFactory 的 PLAYER_TARGET_H / BOSS_TARGET_H 一致）
TARGET_H = {"boss": 108.0, "player": 108.0}   # Boss 现在与玩家同高
TSCN = {"boss": "scenes/Boss.tscn", "player": "scenes/Player.tscn"}


def scan(d):
    sizes, bottom = set(), 0
    anims = {}
    for f in sorted(glob.glob(d + "/*.png")):
        im = Image.open(f)
        sizes.add(im.size)
        bb = im.getbbox()
        if bb:
            bottom = max(bottom, bb[3])
        m = re.match(r"(.+)_(\d+)\.png", os.path.basename(f))
        if m:
            anims[m.group(1)] = anims.get(m.group(1), 0) + 1
    return sizes, bottom, anims


def main():
    bad = 0
    for d, (cell, ground, who) in EXPECT.items():
        sizes, bottom, anims = scan(d)
        want = WANT_BOSS if who == "boss" else WANT_PLAYER
        print("=== %s (%s) ===" % (d, who))
        print("  画布尺寸 %s  实际脚底行 %d" % (sorted(sizes), bottom))
        if len(sizes) != 1 or list(sizes)[0] != (cell, cell):
            print("  !! 尺寸不一致或不是 %dx%d" % (cell, cell)); bad += 1
        if bottom != ground:
            print("  !! 脚底行 %d != 期望 %d" % (bottom, ground)); bad += 1
        # 每动画的「不同帧数」—— 若有重复帧，动画看起来就是静止的
        dup = {}
        for a in anims:
            hs = set()
            for i in range(anims[a]):
                im = Image.open("%s/%s_%d.png" % (d, a, i)).convert("RGBA")
                hs.add(im.tobytes())
            dup[a] = (anims[a], len(hs))
        for a, (n, u) in sorted(dup.items()):
            mark = "  <-- 有重复帧!" if u < n else ""
            print("     %-8s %d 帧 / %d 种%s" % (a, n, u, mark))
        miss = [a for a in want if a not in anims]
        extra = [a for a in anims if a not in want]
        print("  动画 %d 个 / %d 帧" % (len(anims), sum(anims.values())))
        if miss:
            print("  !! 缺动画:", miss); bad += 1
        if extra:
            print("  !! 多出（帧表不会用）:", extra)
        if who == "player":
            for a, n in WANT_PLAYER_N.items():
                if anims.get(a) != n:
                    print("  !! %s 帧数 %d != 目标 %d" % (a, anims.get(a, 0), n)); bad += 1
        # 期望的 scale 与 sprite.position（整数倍缩放）
        # 与 SpriteFactory.content_rect(prefer_anim="idle") 一致：只量 idle
        i0, i1 = 10**9, -1
        for f in glob.glob(d + "/idle_*.png"):
            bb2 = Image.open(f).getbbox()
            if bb2:
                i0 = min(i0, bb2[1]); i1 = max(i1, bb2[3])
        ch = (i1 - i0) if i1 > 0 else 0
        raw = TARGET_H[who] / ch
        if raw >= 1.0:
            sc = float(max(1, min(8, round(raw))))
        else:
            sc = 1.0 / float(max(1, min(8, round(1.0 / raw))))
        off = -sc * (ground - cell / 2.0)
        print("  内容高 %d  目标屏幕高 %g  -> scale %.4f (1/%d)" % (
            ch, TARGET_H[who], sc, round(1 / sc) if sc < 1 else 1))
        print("  屏幕高 %.0f px" % (ch * sc))
        print("  -> sprite.position 应为 Vector2(0, %g)" % off)
        cur = None
        for line in open(TSCN[who]):
            if line.strip().startswith("position = Vector2(0,"):
                cur = line.strip(); break
        print("     .tscn 里是 %s  %s" % (cur, "(运行时会被自动覆盖)" ))
        print()
    print("问题数:", bad)
    return bad


if __name__ == "__main__":
    sys.exit(0 if main() == 0 else 1)

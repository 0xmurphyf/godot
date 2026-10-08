#!/usr/bin/env python3
"""生成像素风机甲士兵精灵表（玩家 / Boss 两套配色）+ 子弹。

同一套骨架：
  棕蓝相间发型 + 蓝色面罩护目镜 + 黑色重型装甲 + 露腹
  肩/臂/背 发光能量灯 + 破损黑披风 + 背部推进器 + 机械护腿 + 厚底靴

玩家 = 原配色（绿能量灯），持枪
Boss = 暗紫装甲 + 红能量灯（暗背景上更醒目），徒手

规范网格 32x32，脚底在第 28 行。
玩家放大 4x -> 128 cell（脚底 112）
Boss  放大 6x -> 192 cell（脚底 168）
"""
from PIL import Image

CANON = 32
GROUND = 28

PLAYER_PAL = {
    "hair_a": (96, 62, 44, 255),
    "hair_b": (52, 92, 158, 255),
    "visor": (54, 118, 196, 255),
    "visor_hi": (140, 214, 255, 255),
    "armor": (26, 28, 36, 255),
    "armor_mid": (46, 50, 62, 255),
    "armor_hi": (78, 86, 104, 255),
    "skin": (208, 162, 126, 255),
    "energy": (86, 238, 138, 255),
    "energy_hi": (190, 255, 216, 255),
    "cape": (16, 16, 21, 255),
    "cape_edge": (44, 44, 54, 255),
    "boot": (32, 34, 44, 255),
    "thrust": (120, 196, 255, 255),
    "thrust_hi": (206, 238, 255, 255),
    "gun": (58, 62, 76, 255),
    "gun_hi": (104, 112, 132, 255),
    "muzzle": (255, 236, 160, 255),
}

BOSS_PAL = dict(PLAYER_PAL)
BOSS_PAL.update({
    "hair_a": (72, 44, 40, 255),
    "hair_b": (78, 44, 96, 255),
    "visor": (176, 46, 52, 255),
    "visor_hi": (255, 140, 120, 255),
    "armor": (32, 20, 42, 255),
    "armor_mid": (56, 34, 70, 255),
    "armor_hi": (96, 62, 116, 255),
    "skin": (150, 118, 132, 255),
    "energy": (255, 74, 62, 255),
    "energy_hi": (255, 176, 150, 255),
    "cape": (18, 10, 22, 255),
    "cape_edge": (58, 34, 66, 255),
    "boot": (38, 24, 46, 255),
    "thrust": (255, 128, 90, 255),
    "thrust_hi": (255, 210, 170, 255),
})

T = (0, 0, 0, 0)


def R(im, x, y, w, h, c):
    px = im.load()
    for yy in range(y, y + h):
        for xx in range(x, x + w):
            if 0 <= xx < im.width and 0 <= yy < im.height and c[3] > 0:
                px[xx, yy] = c


def _clear(im, x, y, w, h):
    px = im.load()
    for yy in range(y, y + h):
        for xx in range(x, x + w):
            if 0 <= xx < im.width and 0 <= yy < im.height:
                px[xx, yy] = (0, 0, 0, 0)


def _line(im, x0, y0, x1, y1, c, t=1):
    steps = max(abs(x1 - x0), abs(y1 - y0))
    for i in range(steps + 1):
        k = i / max(steps, 1)
        x = round(x0 + (x1 - x0) * k)
        y = round(y0 + (y1 - y0) * k)
        R(im, x, y, t, t, c)


def draw_char(pal, crouch=0, lean=0, arm="down", leg="stand",
              stretch=0, squash=0, alpha=1.0, glow=False, hide_cape=False,
              recoil=0):
    """recoil: 开枪后坐 —— 身体后仰、枪上抬"""
    im = Image.new("RGBA", (CANON, CANON), T)
    cx = 16 + lean - recoil
    # 持枪时整体左移，给枪身/枪口留位置，否则会超出 32 网格被裁掉
    if arm in ("gun", "gun_fire"):
        cx -= 5
    hip = 20 + crouch + squash
    head_top = 3 + crouch + squash - stretch
    head_bot = 11 + crouch + squash - stretch
    torso_top = 11 + crouch + squash - stretch
    torso_bot = hip
    feet = GROUND

    def A(c):
        if alpha >= 1.0:
            return c
        return (c[0], c[1], c[2], int(c[3] * alpha))

    # ---- 披风 ----
    if not hide_cape:
        cape_top = torso_top
        cape_bot = min(feet - 1, hip + 6)
        cape_w = 15
        cxx = cx - 1
        R(im, cxx - cape_w // 2, cape_top, cape_w, cape_bot - cape_top, A(pal["cape"]))
        R(im, cxx - cape_w // 2, cape_top, 2, cape_bot - cape_top, A(pal["cape_edge"]))
        for i in range(cape_w):
            depth = (i * 5) % 4
            for d in range(depth):
                if cape_bot - 1 - d >= cape_top:
                    R(im, cxx - cape_w // 2 + i, cape_bot - 1 - d, 1, 1, T)

    # ---- 背部推进器 ----
    tr_x = cx - 9
    tr_y = torso_top + 1
    R(im, tr_x - 1, tr_y, 4, 7, A(pal["armor_mid"]))
    R(im, tr_x, tr_y + 1, 2, 2, A(pal["armor_hi"]))
    noz = tr_y + 7
    nh = max(0, min(2, feet - noz))
    if nh:
        R(im, tr_x, noz, 3, nh, A(pal["boot"]))
    if glow:
        fy = noz + 2
        fh = max(0, min(3, feet - fy))
        if fh:
            R(im, tr_x, fy, 3, fh, A(pal["thrust"]))
            R(im, tr_x + 1, fy, 1, fh, A(pal["thrust_hi"]))

    # ---- 腿 ----
    leg_len = feet - hip
    if leg == "stand":
        legs = [(cx - 4, 0), (cx + 1, 0)]
    elif leg == "step_a":
        legs = [(cx - 5, 0), (cx + 2, -1)]
    elif leg == "step_b":
        legs = [(cx - 3, -1), (cx + 4, 0)]
    elif leg == "tuck":
        legs = [(cx - 4, 0), (cx + 1, 0)]
        leg_len = max(4, leg_len - 3)
    else:
        legs = [(cx - 6, 0), (cx + 3, 0)]

    for lx, off in legs:
        ly = hip + off
        R(im, lx, ly, 3, leg_len, A(pal["armor_mid"]))
        R(im, lx, ly + leg_len - 4, 3, 4, A(pal["armor_hi"]))
        R(im, lx - 1, ly + leg_len - 2, 5, 2, A(pal["boot"]))

    # ---- 躯干（露腹）----
    tw = 11
    R(im, cx - tw // 2, torso_top, tw, torso_bot - torso_top, A(pal["armor"]))
    R(im, cx - tw // 2, torso_top, tw, 2, A(pal["armor_hi"]))
    abd_y = torso_bot - 3
    R(im, cx - 3, abd_y, 7, 2, A(pal["skin"]))
    R(im, cx - 3, abd_y, 7, 1, A((140, 104, 82, 255)))

    # ---- 肩甲 + 能量灯 ----
    sh_y = torso_top
    R(im, cx - 8, sh_y, 5, 4, A(pal["armor_hi"]))
    R(im, cx + 4, sh_y, 5, 4, A(pal["armor_hi"]))
    R(im, cx - 7, sh_y + 1, 2, 2, A(pal["energy"]))
    R(im, cx + 6, sh_y + 1, 2, 2, A(pal["energy"]))
    if glow:
        R(im, cx - 7, sh_y + 1, 1, 1, A(pal["energy_hi"]))
        R(im, cx + 6, sh_y + 1, 1, 1, A(pal["energy_hi"]))

    # ---- 手臂 / 枪 ----
    shx = cx + 6
    shy = sh_y + 3
    gun_up = 1 if recoil else 0          # 后坐时枪口上抬

    if arm == "gun" or arm == "gun_fire":
        _line(im, shx, shy, shx + 4, shy + 1, A(pal["armor_mid"]), 3)   # 上臂前伸
        gx = shx + 4
        gy = shy - gun_up
        R(im, gx, gy, 9, 4, A(pal["gun"]))            # 枪身
        R(im, gx, gy, 9, 1, A(pal["gun_hi"]))          # 高光
        R(im, gx + 8, gy - 1, 3, 3, A(pal["gun_hi"]))  # 枪口
        R(im, gx + 2, gy + 4, 3, 2, A(pal["gun"]))     # 弹匣
        if arm == "gun_fire":
            R(im, gx + 8, gy - 3, 5, 8, A(pal["muzzle"]))      # 枪口焰
            R(im, gx + 9, gy - 2, 3, 6, A((255, 255, 255, 255)))
            R(im, gx + 11, gy, 3, 4, A(pal["muzzle"]))
    elif arm == "fwd":
        _line(im, shx, shy, shx + 8, shy + 2, A(pal["armor_mid"]), 3)
        R(im, shx + 7, shy, 4, 4, A(pal["armor_hi"]))
        R(im, shx + 8, shy + 1, 2, 2, A(pal["energy"]))
    elif arm == "back":
        _line(im, shx, shy, shx - 5, shy - 2, A(pal["armor_mid"]), 3)
        R(im, shx - 6, shy - 3, 3, 3, A(pal["armor"]))
    elif arm == "up":
        _line(im, shx, shy, shx + 3, shy - 7, A(pal["armor_mid"]), 3)
        R(im, shx + 2, shy - 9, 3, 3, A(pal["armor_hi"]))
    elif arm == "raise":
        # 双臂上举蓄力：拳举过头顶，配 glow 像在充能
        _line(im, shx, shy, shx + 1, shy - 9, A(pal["armor_mid"]), 3)
        R(im, shx - 1, shy - 11, 4, 4, A(pal["armor_hi"]))
        _line(im, cx - 6, shy, cx - 7, shy - 9, A(pal["armor_mid"]), 3)
        R(im, cx - 9, shy - 11, 4, 4, A(pal["armor_hi"]))
        R(im, shx - 1, shy - 11, 2, 2, A(pal["energy_hi"]))
        R(im, cx - 8, shy - 11, 2, 2, A(pal["energy_hi"]))
    elif arm == "tuck":
        _line(im, shx, shy, shx + 2, shy + 5, A(pal["armor_mid"]), 3)
        R(im, shx, shy + 5, 4, 3, A(pal["armor"]))
    else:
        _line(im, shx, shy, shx + 1, shy + 8, A(pal["armor_mid"]), 3)
        R(im, shx - 1, shy + 8, 4, 3, A(pal["armor"]))
        R(im, shx, shy + 4, 2, 2, A(pal["energy"]))

    # ---- 头 ----
    hw, hh = 9, head_bot - head_top
    R(im, cx - hw // 2, head_top, hw, hh, A(pal["skin"]))
    R(im, cx - hw // 2 - 1, head_top - 1, hw + 2, 3, A(pal["hair_a"]))
    R(im, cx - hw // 2 - 1, head_top - 1, 4, 3, A(pal["hair_b"]))
    R(im, cx + 2, head_top - 2, 3, 2, A(pal["hair_b"]))
    R(im, cx - hw // 2 - 1, head_top + 2, 2, 3, A(pal["hair_a"]))
    R(im, cx - 4, head_top + 3, 8, 3, A(pal["visor"]))
    R(im, cx - 4, head_top + 3, 8, 1, A(pal["visor_hi"]))
    R(im, cx - 3, head_top + 4, 2, 1, A(pal["visor_hi"]))
    R(im, cx + 3, head_top + 1, 2, 2, A(pal["energy"]))
    if glow:
        R(im, cx + 3, head_top + 1, 1, 1, A(pal["energy_hi"]))

    _clear(im, 0, feet, CANON, CANON - feet)
    return im


def scale(im, k):
    return im.resize((CANON * k, CANON * k), Image.NEAREST)


def sheet(rows, k, path):
    cols = 4
    W, H = CANON * k * cols, CANON * k * len(rows)
    out = Image.new("RGBA", (W, H), T)
    for r, (name, frames) in enumerate(rows):
        for c, im in enumerate(frames):
            s = scale(im, k)
            out.paste(s, (c * CANON * k, r * CANON * k), s)
    out.save(path)
    print("%s  %dx%d  %d行  脚底行=%d" % (path, W, H, len(rows), GROUND * k))
    return [(n, len(f)) for n, f in rows]


# ---------------- 玩家：持枪，6 行动画 ----------------
P = PLAYER_PAL
player_rows = [
    ("idle",  [draw_char(P, arm="gun"), draw_char(P, crouch=1, arm="gun")]),
    ("run",   [draw_char(P, leg="step_a", arm="gun"),
               draw_char(P, crouch=1, arm="gun"),
               draw_char(P, leg="step_b", arm="gun"),
               draw_char(P, crouch=1, arm="gun")]),
    ("jump",  [draw_char(P, leg="tuck", arm="gun", glow=True)]),
    ("shoot", [draw_char(P, arm="gun", lean=1),
               draw_char(P, arm="gun_fire", lean=-2, recoil=1)]),
    # 空中射击：收腿姿势 + 持枪（与 jump 同一腿型，视觉上"人在空中开枪"）
    ("shoot_air", [draw_char(P, leg="tuck", arm="gun", lean=1),
                   draw_char(P, leg="tuck", arm="gun_fire", lean=-2, recoil=1)]),
    ("dodge", [draw_char(P, crouch=4, leg="tuck", arm="tuck", lean=1),
               draw_char(P, crouch=5, leg="tuck", arm="tuck", lean=2),
               draw_char(P, crouch=4, leg="tuck", arm="tuck", lean=1)]),
    ("hurt",  [draw_char(P, crouch=2, arm="gun", lean=-2)]),
]

# ---------------- Boss：徒手，11 行动画 ----------------
B = BOSS_PAL
boss_rows = [
    ("idle",    [draw_char(B, glow=True), draw_char(B, crouch=1, glow=True)]),
    ("walk",    [draw_char(B, leg="step_a", arm="back", glow=True),
                 draw_char(B, crouch=1, arm="down", glow=True),
                 draw_char(B, leg="step_b", arm="down", glow=True),
                 draw_char(B, crouch=1, arm="back", glow=True)]),
    ("crouch",  [draw_char(B, crouch=4, arm="back", lean=-2, glow=True)]),
    ("punch",   [draw_char(B, arm="fwd", lean=3, glow=True),
                 draw_char(B, arm="fwd", lean=2, glow=True)]),
    ("recover", [draw_char(B, crouch=2, arm="down", glow=True)]),
    ("vanish",  [draw_char(B, crouch=1, arm="tuck", alpha=0.28)]),
    ("appear",  [draw_char(B, crouch=3, leg="tuck", arm="tuck", glow=True)]),
    ("drop",    [draw_char(B, crouch=2, leg="tuck", arm="down", stretch=3, glow=True)]),
    ("land",    [draw_char(B, crouch=5, leg="wide", arm="down", squash=1, glow=True)]),
    ("dead",    [draw_char(B, crouch=6, leg="wide", arm="tuck", squash=2, alpha=0.9)]),
    # 手枪：举枪瞄准 / 击发（带枪口焰 + 后坐）
    ("aim",     [draw_char(B, arm="gun", lean=1, glow=True)]),
    ("fire",    [draw_char(B, arm="gun_fire", lean=-2, recoil=1, glow=True)]),
    # 全图炮：蓄力（双臂上举、全身发光）
    ("charge",  [draw_char(B, crouch=2, arm="raise", glow=True),
                 draw_char(B, crouch=3, arm="raise", glow=True)]),
]

# 关键帧导出：gen_smooth_frames.py 读这些「干净姿势」来生成补间。
# 放在独立目录 —— 从输出目录读会把形变逐次叠加。
import os as _os


def dump_keys(rows, outdir, k):
    if _os.path.isdir(outdir):
        import shutil as _sh
        _sh.rmtree(outdir)
    _os.makedirs(outdir)
    for nm, frames in rows:
        for i, im in enumerate(frames):
            scale(im, k).save("%s/%s_%d.png" % (outdir, nm, i))
    print("%s  %d 关键帧" % (outdir, sum(len(f) for _, f in rows)))


# 只导出玩家：Boss 关键帧来自用户素材（gen_boss_from_source.py + art/src），
# 用本脚本的程序化图导出会覆盖掉用户美术。
dump_keys(player_rows, "art/_keys_player", 4)

sheet(player_rows, 4, "art/player_sheet.png")
sheet(boss_rows, 6, "art/boss_sheet.png")


# ---------------- 子弹 ----------------
def draw_bullet(pal, k=4):
    im = Image.new("RGBA", (CANON, CANON), T)
    cy = CANON // 2
    # 弹头（亮）
    R(im, 13, cy - 2, 8, 4, pal["energy_hi"])
    R(im, 14, cy - 3, 6, 6, pal["energy_hi"])
    R(im, 15, cy - 2, 4, 4, (255, 255, 255, 255))
    # 拖尾（渐隐）
    R(im, 9, cy - 1, 4, 2, pal["energy"])
    R(im, 6, cy - 1, 3, 2, (pal["energy"][0], pal["energy"][1], pal["energy"][2], 140))
    R(im, 3, cy, 3, 1, (pal["energy"][0], pal["energy"][1], pal["energy"][2], 70))
    return scale(im, k)


b = draw_bullet(P)
b.save("art/bullet.png")
print("art/bullet.png  %dx%d" % b.size)
be = draw_bullet(B)
be.save("art/bullet_enemy.png")
print("art/bullet_enemy.png  %dx%d" % be.size)

print("玩家脚底:", GROUND * 4, " Boss脚底:", GROUND * 6)

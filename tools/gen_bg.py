#!/usr/bin/env python3
"""把用户给的城市夜景做成背景贴图。

用法：
    python3 tools/gen_bg.py                 # 用默认的 art/bg_city_src.jpg
    python3 tools/gen_bg.py <输入图>        # 换图

输出 art/bg_city.png（1152x648，正好是视口大小）。

## 不做任何色彩处理

之前试过降饱和、压暗、k-means 量化成 40 色扁平像素画 —— 都不要。
原图该怎么看就怎么看。

唯一做的是**尺寸适配**：把原图缩到 1152x648（视口大小）。
原图 1280x720 和视口 1152x648 都是 16:9，缩放不变形。

## 为什么用 LANCZOS 而不是 NEAREST

原图是 1280x720 的照片/绘制稿，不是整数倍关系的小像素画，
用 NEAREST 会出现不规则的锯齿和丢行。LANCZOS 缩放最平滑。

（角色美术相反：它们是 128 -> 768 的整数倍放大，必须用 NEAREST
才能保住像素块，见 gen_smooth_frames.py 的 upscale。）
"""

import os
import sys

from PIL import Image

# 视口大小
VIEW_W, VIEW_H = 1152, 648

DEFAULT_SRC = "art/bg_city_src.jpg"
OUT = "art/bg_city.png"


def main():
    src_path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SRC
    if not os.path.isfile(src_path):
        print("找不到输入图: %s" % src_path)
        return 1

    src = Image.open(src_path).convert("RGB")
    print("输入: %s  %dx%d" % (src_path, src.width, src.height))

    # 只做尺寸适配，不做任何色彩处理
    out = src.resize((VIEW_W, VIEW_H), Image.LANCZOS)
    out.save(OUT)
    print("输出: %s  %dx%d" % (OUT, out.width, out.height))

    import numpy as np
    a = np.asarray(out).astype(np.float32)
    L = a[:, :, 0] * 0.299 + a[:, :, 1] * 0.587 + a[:, :, 2] * 0.114
    print()
    print("平均亮度 %.1f（角色带 %.1f，地面区 %.1f）" % (
        L.mean(), L[452:560].mean(), L[560:].mean()))
    return 0


if __name__ == "__main__":
    sys.exit(main())

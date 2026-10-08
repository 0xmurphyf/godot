# Web 部署

把游戏导出成网页，别人打开链接就能玩。

## 一、装导出模板

Godot 编辑器：`Editor > Manage Export Templates` → 下载（或 `Install from File` 装本地模板）。

只要 **Web** 那一个。装完能看到 `Web` 平台说明模板就位了。

## 二、导出

`Project > Export...` → 选 `Web` 预设 → `Export Project`。

导出到 `build/index.html`。产物：

```
build/
├── index.html
├── Boss Script Demo.pck      # 所有游戏资源
├── Boss Script Demo.wasm     # 引擎 + 脚本
└── Boss Script Demo.js       # 加载器
```

`export_presets.cfg` 已经配好了（含 exclude 过滤，见第四节）。

> 预设是照着 Godot 4.x 通用格式写的。要是编辑器报预设有问题，
> 直接删掉 `export_presets.cfg`，在导出窗口 `Add > Web` 重建一个 ——
> 唯一会丢的是 exclude 过滤，把第四节的过滤串手动粘回去即可。

## 三、本地验证

```bash
python3 tools/serve_web.py
# http://localhost:8000/
```

**不要直接双击 `index.html`** —— `file://` 协议下浏览器拒绝加载 `.wasm`，一定是白屏。

如果非要用 `python3 -m http.server`，至少确认 `.wasm` 的 MIME 是
`application/wasm`（Python 3.9+ 才认）。用 `serve_web.py` 没这问题。

## 四、体积

当前实测：

| | 大小 |
|---|---|
| 真实游戏资源 | **3.4 MB** |
| 开发预览图（不该打包） | **2.8 MB** |

`export_presets.cfg` 里的 exclude 已排除开发产物：

```
art/*_preview.png, art/*_compare.png, art/sfx_mv_dash_wave.png,
tools/*, README.md, cutscene/README.md, sfx/src/*
```

不加这个过滤，包会白白大 80%。

### 想再小一点（可选）

音效是大头之一。1.2 MB 的 WAV 转 OGG 能压到 ~150 KB：

```bash
cd sfx && for f in *.wav; do ffmpeg -y -i "$f" -c:a libvorbis -q:a 4 "${f%.wav}.ogg"; done
```

⚠ 转完还要改代码：`autoload/Sfx.gd` 里拼的是 `.wav` 后缀
（`const DIR := "res://sfx/"` + 名字 + `.wav`）。
改成先试 `.ogg` 再退回 `.wav` 就能两种格式通吃。
**这一步我没动，避免又给你弄出编译错误** —— 需要的话说一声我来改。

背景图 `art/bg_city.png` 966 KB，换成 JPG 或缩到 960×540 也能省一半。

## 五、上线

### 最省事：itch.io

1. New project → Kind of project = **HTML**
2. 上传 `build/` 里所有文件（zip 打包时**不要多套一层目录**）
3. 勾 `This file will be played in the browser`，填 1152×648
4. 发布

它自动处理 MIME 和压缩，最省心。

### GitHub Pages

单线程构建可以直接用（不需要改响应头，Pages 也不让你改）。

```bash
# 导出到 docs/index.html，仓库 Settings > Pages > /docs
```

注意 Pages 有 1 GB 软限制和 100 MB 单文件限制，我们远低于此。

### Netlify / Cloudflare Pages / Vercel

拖 `build/` 目录上去即可。想加缓存头就放个 `_headers`：

```
/*.wasm
  Content-Type: application/wasm
  Cache-Control: public, max-age=31536000, immutable
/*.pck
  Cache-Control: public, max-age=31536000, immutable
/index.html
  Cache-Control: no-cache
```

（Netlify 用 `_headers`，Cloudflare 用 `_headers`，Vercel 用 `vercel.json`。）

## 六、这个项目的几个 Web 注意事项

**音频要用户交互后才能响**
浏览器策略：页面没被点击过就不许出声。玩家按第一个键之后音频才解锁 ——
Godot 4 会自动恢复 AudioContext，所以只要不是「进来就播 BGM」都没问题。
我们的音效全在按键之后触发，安全。

**过场视频在 Web 上不可用**
Native Video / Godot 核心视频在 Web 强制的 Compatibility 后端下均失效，
自动回退 DUMMY 画面，不影响上线。桌面端（Forward+）可正常播放 `cutscene/win.mp4` / `lose.mp4`。

**渲染器已经是 `gl_compatibility`**
Web 只能跑 Compatibility（Forward+/Mobile 在 Web 上不可用或很慢）。
`project.godot` 里已经是这个，不用改。

**键位**

| 动作 | 键 |
|---|---|
| 移动 | A / D 或 ← / → |
| 跳跃 | W 或 ↑ |
| 开枪 | J / K |
| 翻滚 | SPACE / Shift |
| 重开 | R |

触屏另有虚拟按键（见上）。

**手机可以玩** —— 有虚拟按键，且**收到触摸事件时自动开启**。
桌面上默认关，点屏幕右上角的 `TOUCH: OFF/ON` 按钮可随时开关（电脑调试用）。

用的是事件驱动而不是查设备类型（`OS.has_touchscreen_ui_hint()`）：
后者在不同 Godot 版本上行为不一致，而且「设备有触摸屏」不等于
「玩家想用触屏」—— 带触摸屏的笔记本上开着虚拟按键反而碍事。

布局（视口 1152x648）：

| 位置 | 按键 |
|---|---|
| 左下 | `<` 左移 / `>` 右移（110px） |
| 右下（左→右） | `ROLL` 翻滚 / `JUMP` 跳跃 / `FIRE` 开枪（78px） |

放在**底部两个角**而不是压中间：底部中间（x 256..896）被
Boss 血条（y 574..594）和按键提示（y 606..628）占着，
按钮压上去会挡住血条 —— 血条是全场焦点，不能挡。

实现要点见 `scripts/VirtualPad.gd` 文件头；按钮本身是
`scripts/VirtualButton.gd`（独立文件，不是内部类）。两个关键决策：

- **不用 `Button`**：触摸被模拟成鼠标，多指合并成一个指针，
  没法「一边移动一边开枪」
- **不用 `Input.action_press()`**：它只改内部状态，
  `_input` / `_unhandled_input` 收不到，跳过/重开这类回调会失效。
  改用 `Input.parse_input_event()` 发 `InputEventAction`，走完整管线

⚠ **需要在真机/浏览器上验证的一点**：跳跃和翻滚用的是
`Input.is_action_just_pressed()`，靠 `parse_input_event`
能否正确触发「本帧刚按下」我没法在这台机器上跑 Godot 确认。
如果手机上跳跃/翻滚没反应，把 `VirtualPad._send()` 换成
`Input.action_press()` / `Input.action_release()` 试试。

## 七、排错

| 现象 | 原因 |
|---|---|
| 双击 html 白屏 | `file://` 不能加载 wasm，必须起 HTTP 服务 |
| 卡在加载进度条 | `.wasm` MIME 不对，用 `serve_web.py` |
| 打开是黑屏但没报错 | 看浏览器 Console，多半是资源路径（大小写敏感，Linux 服务器严格） |
| 本地好使、线上 404 | 上传时多套了一层目录，index.html 要在根 |
| 声音不出来 | 先点一下画面 / 按个键 |

extends Control
class_name EndCutscene
## 结算前的全屏过场（16:9，默认约 10 秒）—— 目前是 DUMMY 占位。
##
## 真片：把视频放到 res://cutscene/win.mp4 与 lose.mp4 即可，
## 找不到就自动回退到 DUMMY 画面。转换脚本见 tools/。
##
## 故意不写 VideoStreamPlayer 这个标识符：
##   某些构建（精简 / 无视频后端）里这个类可能没注册，
##   直接写会让脚本加载失败。改用 ClassDB + 字符串调用，
##   缺了也只会安静地回退到 DUMMY，不会拖垮整个项目。

signal finished
signal skipped

# 尝试的扩展名。写成三个常量而不是数组 ——
# GDScript 里带类型的数组常量（Array[String]）在部分版本上会
# 触发分析/解析错误，展开成常量最稳。
const EXT_MP4 := ".mp4"
const EXT_OGV := ".ogv"
const EXT_WEBM := ".webm"

@export_group("时长")
## 过场总时长（秒，真实时间，不受 time_scale 影响）。有视频时以视频时长为准。
@export var duration: float = 10.0
## 结尾淡出时长
@export var fade_out: float = 0.6
## 开头淡入时长
@export var fade_in: float = 0.5

@export_group("外观")
@export var bg_color: Color = Color(0.01, 0.01, 0.03, 1.0)
@export var neon: Color = Color(0.00, 0.92, 1.00)
@export var accent: Color = Color(1.00, 0.16, 0.45)

@export_group("视频（可选）")
## 视频目录。放 win.mp4 / lose.mp4。
@export_dir var video_dir: String = "res://cutscene"
@export var win_video: String = "win"
@export var lose_video: String = "lose"
## 视频音量（dB）。只要画面就拉到 -80。
@export var video_volume_db: float = 0.0

@export_group("跳过")
@export var skippable: bool = true
@export var skip_hint: String = "SKIP  J / SPACE"
## 多少秒后才允许跳过 —— 0 秒能跳的话，死亡瞬间手指多半还按在开火键上，会误触。
@export var skip_after: float = 1.0

# 全部显式类型，不用 := 推断 —— 本项目开了 warning-as-error，
# 任何一处推不出类型都会直接编译失败。
var _t: float = 0.0
var _playing: bool = false
var _won: bool = false
var _ended: bool = false
var _video: Control = null
var _overlay: Control = null
var _warn: Label = null
var _has_video: bool = false
var _len: float = 0.0
# 运行时真实渲染驱动（来自 RenderingServer.get_current_rendering_driver_name()），
# 以及它是否支持视频呈现（Compatibility/OpenGL 不支持）。
var _render_driver: String = "unknown"
var _render_ok: bool = false


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP   # 挡住底下的按钮
	visible = false
	modulate = Color(1, 1, 1, 0)
	_build_video()


## 建视频播放器 + 覆盖层。
##
## 两者都必须**一直在场景树里**：不在树里 _process 不跑、视频也不解码。
## 平时靠本节点自己的 visible=false 一起藏起来。
##
## 覆盖层必须**在 video 之后** add_child ——
## CanvasItem 是「父先于子、兄弟按加入顺序」绘制的，
## 视频会盖住本节点 _draw() 出来的东西，框架/进度条得画在更上层。
func _build_video() -> void:
	if not ClassDB.class_exists("VideoStreamPlayer"):
		# Renderer 不支持（例如仍在 gl_compatibility）时这个类不会注册，
		# 只能走 DUMMY。重启编辑器切到 Forward+/Mobile 后即可出现。
		print("[EndCutscene] VideoStreamPlayer 未注册 —— 当前渲染后端不支持视频，将只用 DUMMY。请重启 Godot 并确认 renderer 为 forward_plus/mobile。")
		return
	# 运行时诊断：拿到**真实**渲染驱动名（不是配置文件里写的值）。
	# 因为 Vulkan/D3D12 初始化失败时 Godot 会**自动回退**到 opengl3，
	# 此时 VideoStreamPlayer 与 Native Video 都不会输出画面（黑屏）。
	# 正确 API（Godot 4.x，commit 4a70ac2，2024-10-02 加入）：
	#   RenderingServer.get_current_rendering_driver_name()
	#   返回 vulkan / d3d12 / metal / opengl3 / opengl3_es / opengl3_angle
	var rmethod: String = ProjectSettings.get_setting("rendering/renderer/rendering_method", "forward_plus")
	var drv: String = "unknown"
	if RenderingServer.has_method("get_current_rendering_driver_name"):
		drv = str(RenderingServer.call("get_current_rendering_driver_name"))
	elif RenderingServer.has_method("get_current_rendering_method"):
		# 老版本兜底：返回 forward_plus / mobile / gl_compatibility
		drv = str(RenderingServer.call("get_current_rendering_method"))
	# 关键：直接确认 Native Video 扩展是否真的加载了（加载了才有 .mp4 导入器）
	var nv_loaded: bool = ClassDB.class_exists("NativeVideoStream")
	print("[EndCutscene] 渲染驱动=", drv, "  配置渲染方法=", rmethod,
		"  NativeVideoStream=", nv_loaded,
		"  VideoStreamPlayer=", ClassDB.class_exists("VideoStreamPlayer"))
	var unsupported: bool = drv.begins_with("opengl") or rmethod == "gl_compatibility"
	if unsupported:
		print("[EndCutscene] ⚠ 运行时后端是 Compatibility/OpenGL（视频不渲染 → 黑屏）。请用「Godot.exe --rendering-driver d3d12」（或 vulkan）启动，或在导出预设里把渲染方法锁成 Forward+。")
	else:
		print("[EndCutscene] ✓ 后端为 ", drv, "，视频应当能渲染；若仍黑屏，请在 Output 面板找 native_video 的报错。")
	_render_driver = drv
	_render_ok = not unsupported
	# ClassDB.instantiate() 返回 Object，必须 as Control 才能赋给 Control 变量
	_video = ClassDB.instantiate("VideoStreamPlayer") as Control
	_video.name = "Video"
	_video.call("set_anchors_preset", Control.PRESET_FULL_RECT)
	_video.set("expand", true)          # 否则保持视频原始像素尺寸贴在左上角
	_video.set("autoplay", false)       # 由 play() 决定什么时候播
	_video.set("volume_db", video_volume_db)
	add_child(_video)
	# 字符串形式连接信号 —— 不引用 VideoStreamPlayer 类型也能拿到 finished
	_video.connect("finished", Callable(self, "_on_video_finished"))

	_overlay = Control.new()
	_overlay.name = "Overlay"
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_overlay)
	_overlay.draw.connect(Callable(self, "_draw_overlay"))

	# 视频已加载但渲染后端不支持时，屏幕上弹个明确提示（否则用户只看得到日志，
	# 画面却什么都没有）。Label 用的是 Godot 内置兜底字体，不依赖外部美术资源。
	_warn = Label.new()
	_warn.name = "Warn"
	_warn.set_anchors_preset(Control.PRESET_CENTER)
	_warn.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_warn.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_warn.visible = false
	_warn.add_theme_color_override("font_color", accent)
	_warn.text = "VIDEO DISABLED\n渲染后端为 Compatibility/OpenGL\nNative Video 需要 d3d12 / vulkan\n请用 Godot --rendering-driver d3d12 启动"
	add_child(_warn)


## 按胜负找视频文件，依次试 .mp4 / .ogv / .webm，返回第一个存在的。
## 都没有就返回 ""（走 DUMMY）。
func _find_video(win: bool) -> String:
	var base: String = win_video if win else lose_video
	var dir: String = video_dir
	if not dir.ends_with("/"):
		dir += "/"
	# 本项目用 Native Video 扩展做硬件解码，直接播 .mp4（H.264）。
	# 核心 Godot 4 在本机无 Ogg Theora 导入器（.ogv 不可用），故 .mp4 优先。
	var p: String = dir + base + EXT_MP4
	if ResourceLoader.exists(p):
		return p
	p = dir + base + EXT_OGV
	if ResourceLoader.exists(p):
		return p
	p = dir + base + EXT_WEBM
	if ResourceLoader.exists(p):
		return p
	return ""


func _process(delta: float) -> void:
	if not _playing:
		return
	# 真实时间：_process 的 delta 已经被 time_scale 缩放过（死亡时压到 0.25），
	# 直接累加的话「10 秒」会变成 40 秒。除回去拿到未缩放的秒数。
	_t += delta / maxf(Engine.time_scale, 0.0001)
	queue_redraw()
	if _overlay != null:
		_overlay.queue_redraw()
	if _t >= _len:
		_finish(false)


func _unhandled_input(event: InputEvent) -> void:
	if not _playing or not skippable or _ended:
		return
	if _t < skip_after:
		return
	# 注意是 "attack" 不是 "fire" —— InputMap 里注册的是 attack
	# （见 InputSetup.KEYMAP）。写 "fire" 会报
	# "Request for nonexistent InputMap action"，而且跳过功能直接失效。
	if event.is_action_pressed("attack") or event.is_action_pressed("dodge") or event.is_action_pressed("ui_accept"):
		get_viewport().set_input_as_handled()
		_finish(true)


## 开始播。win 只影响配色（胜=青，负=洋红）。
func play(win: bool) -> void:
	_won = win
	_playing = true
	_ended = false
	_t = 0.0
	visible = true
	modulate = Color(1, 1, 1, 0)

	_has_video = false
	_len = duration
	var path: String = _find_video(win)
	if path != "" and _video != null:
		var res = load(path)
		if res != null:
			_video.set("stream", res)
			if res.has_method("get_length"):
				var l: float = res.get_length()
				# 只采信合理时长（>1s）。Native Video 在开局尚未探测完时可能返回
				# 极小值，直接采信会让过场在闪一下后就结束。
				if l > 1.0:
					_len = l          # 用视频真实时长，进度条才准
			_has_video = true
			print("[EndCutscene] 视频已加载：", path, "  时长=", _len, "  time_scale=", Engine.time_scale)
		else:
			# 文件被找到但 load 失败 —— 几乎总是 .ogv 还没被 Godot 导入（缺 .import）。
			print("[EndCutscene] 找到视频文件但 load() 返回 null（多半是 .ogv 尚未导入，请在 Godot 里重新打开项目触发导入）：", path)
	else:
		print("[EndCutscene] 未找到视频文件，播放 DUMMY。path=", path, "  _video=", _video)

	if _has_video:
		_video.call("set_anchors_preset", Control.PRESET_FULL_RECT)
		_video.set("expand", true)
		_video.set("volume_db", video_volume_db)
		_video.call("play")
		# 视频加载成功但后端不支持呈现 → 屏幕上直接弹提示，免得只看得到日志。
		if _warn != null:
			_warn.visible = not _render_ok
	else:
		queue_redraw()

	var tw: Tween = create_tween()
	tw.tween_property(self, "modulate", Color(1, 1, 1, 1), fade_in)


## 视频自己播完也算结束。
## 注意：跳过时视频的 finished **不会**触发，
## 所以 _finish() 里必须手动 stop() —— 否则视频还在后台放着声音。
## 另外：Native Video 偶尔会在开局瞬间误发一次 finished（还没真正开播就报「结束」），
## 直接采信会让过场「闪一下就消失」。因此忽略过早的结束信号，
## 真正的结束交给 _process 计时器（_t >= _len）；仅当已播放过半才接受 finished。
func _on_video_finished() -> void:
	print("[EndCutscene] 收到 finished：_t=", snappedf(_t, 0.01), "  _len=", _len, "  playing=", _playing, "  ended=", _ended)
	if _playing and not _ended and _t >= _len * 0.5:
		_finish(false)


func _finish(by_skip: bool) -> void:
	if _ended:
		return
	_ended = true
	_playing = false
	print("[EndCutscene] _finish 触发：by_skip=", by_skip, "  _t=", snappedf(_t, 0.01), "  _len=", _len)
	if _video != null and bool(_video.call("is_playing")):
		_video.call("stop")
	var tw: Tween = create_tween()
	tw.tween_property(self, "modulate", Color(1, 1, 1, 0), fade_out)
	tw.tween_callback(Callable(self, "_on_fade_out_done").bind(by_skip))


func _on_fade_out_done(by_skip: bool) -> void:
	visible = false
	if by_skip:
		skipped.emit()
	finished.emit()


# ============================================================
# DUMMY 画面
# ============================================================

## 16:9 内框：按宽度反推高度居中放置。
## 视口换成 4:3 之类时会自动加黑边，不用改代码。
func _16x9_frame(s: Vector2) -> Rect2:
	var h: float = s.x * 9.0 / 16.0
	if h > s.y:
		h = s.y
	var w: float = h * 16.0 / 9.0
	var ox: float = (s.x - w) * 0.5
	var oy: float = (s.y - h) * 0.5
	return Rect2(ox, oy, w, h)


## 这一层只画「视频画面之下的东西」：底色和 DUMMY。
## 框架 / 进度条 / SKIP 画在 _overlay 上（见 _draw_overlay）。
func _draw() -> void:
	# 永远先铺底色：视频渲染不出来时至少是个纯色背景，而不是透出底层游戏。
	draw_rect(Rect2(Vector2.ZERO, size), bg_color)
	if _has_video:
		return                    # 视频自己有画面，铺底色反而挡住它
	var s: Vector2 = size
	var frame: Rect2 = _16x9_frame(s)
	var col: Color = neon if _won else accent
	_draw_dummy(frame, col)


## 画在覆盖层上的东西：内框、进度条、SKIP 提示。
func _draw_overlay() -> void:
	if _overlay == null:
		return
	var frame: Rect2 = _16x9_frame(_overlay.size)
	var col: Color = neon if _won else accent
	_draw_frame(_overlay, frame, col)

	# 进度条：沿内框底边推进，让人知道「还要多久」
	var p: float = clampf(_t / maxf(_len, 0.001), 0.0, 1.0)
	var bw: float = frame.size.x - 80.0
	_overlay.draw_rect(
			Rect2(frame.position.x + 40.0, frame.end.y - 44.0, bw, 6.0),
			Color(0.10, 0.12, 0.18, 0.9))
	_overlay.draw_rect(
			Rect2(frame.position.x + 40.0, frame.end.y - 44.0, bw * p, 6.0), col)

	if skippable and _t >= skip_after:
		_draw_skip_hint(_overlay, frame, col)


## 内框四角括号 + 细边 —— 跟 HUD 用的是同一套语言。
## 四角直接展开成四次调用，不用数组遍历。
func _draw_frame(cv: CanvasItem, f: Rect2, col: Color) -> void:
	var c: Color = Color(col.r, col.g, col.b, 0.30)
	cv.draw_rect(Rect2(f.position, Vector2(f.size.x, 1.0)), c)
	cv.draw_rect(Rect2(f.position + Vector2(0.0, f.size.y - 1.0), Vector2(f.size.x, 1.0)), c)
	cv.draw_rect(Rect2(f.position, Vector2(1.0, f.size.y)), c)
	cv.draw_rect(Rect2(f.position + Vector2(f.size.x - 1.0, 0.0), Vector2(1.0, f.size.y)), c)

	var l: float = 34.0
	var t: float = 3.0
	_draw_corner(cv, f.position.x, f.position.y, -1.0, -1.0, l, t, col)
	_draw_corner(cv, f.end.x, f.position.y, 1.0, -1.0, l, t, col)
	_draw_corner(cv, f.position.x, f.end.y, -1.0, 1.0, l, t, col)
	_draw_corner(cv, f.end.x, f.end.y, 1.0, 1.0, l, t, col)


## 一个 L 形角标。(px, py) 是角点，sx/sy 决定两条腿往哪个方向伸。
func _draw_corner(cv: CanvasItem, px: float, py: float, sx: float, sy: float,
		l: float, t: float, col: Color) -> void:
	var hx: float = px if sx < 0.0 else px - l
	var hy: float = py if sy < 0.0 else py - l
	cv.draw_rect(Rect2(hx, py - t * 0.5, l, t), col)
	cv.draw_rect(Rect2(px - t * 0.5, hy, t, l), col)


## DUMMY 内容：扫描光带 + 中心十字 + 底部方块 + 占位色块。
## 全部程序绘制，零美术资源 —— 只为占位和验证时长 / 遮罩 / 跳过。
func _draw_dummy(f: Rect2, col: Color) -> void:
	var cx: float = f.position.x + f.size.x * 0.5
	var cy: float = f.position.y + f.size.y * 0.5

	# 横向扫描光带：来回移动
	var sweep: float = fmod(_t * 0.22, 2.0)      # 0..2 来回
	var sxp: float = absf(sweep - 1.0)           # 0..1..0
	var bx: float = f.position.x + f.size.x * sxp
	draw_rect(Rect2(bx, f.position.y, 3.0, f.size.y), Color(col.r, col.g, col.b, 0.35))

	# 中心十字
	draw_rect(Rect2(cx - 60.0, cy - 1.0, 120.0, 2.0), Color(col.r, col.g, col.b, 0.55))
	draw_rect(Rect2(cx - 1.0, cy - 60.0, 2.0, 120.0), Color(col.r, col.g, col.b, 0.55))

	# 底部一排方块，按时间逐个亮起（每 0.25 秒一个）
	var n: int = 12
	var cell: float = 26.0
	var gap: float = 8.0
	var total: float = float(n) * cell + float(n - 1) * gap
	var x0: float = cx - total * 0.5
	for i in n:
		var lit: bool = fmod(_t, 3.0) >= float(i) * 0.25
		var a: float = 0.85 if lit else 0.16
		draw_rect(Rect2(x0 + float(i) * (cell + gap), cy + 90.0, cell, 12.0),
				Color(col.r, col.g, col.b, a))

	# 占位"字"：8 个起伏色块。不引字体，避免不同环境缺字。
	for i in 8:
		var bx2: float = cx - 200.0 + float(i) * 50.0
		var bh: float = 26.0 + 16.0 * sin(_t * 1.6 + float(i) * 0.7)
		draw_rect(Rect2(bx2, cy - 40.0 - bh * 0.5, 34.0, bh),
				Color(col.r, col.g, col.b, 0.28))


## SKIP 提示：三角 + 虚线段。不引字体，避免缺字。
func _draw_skip_hint(cv: CanvasItem, f: Rect2, col: Color) -> void:
	var x: float = f.end.x - 40.0
	var y: float = f.end.y - 70.0
	var c: Color = Color(col.r, col.g, col.b, 0.75)
	cv.draw_colored_polygon(PackedVector2Array([
			Vector2(x - 14.0, y - 8.0), Vector2(x - 14.0, y + 8.0), Vector2(x - 2.0, y)]), c)
	var i: float = 0.0
	while i < 120.0:
		cv.draw_rect(Rect2(x - 134.0 + i, y + 12.0, 8.0, 2.0), Color(c.r, c.g, c.b, 0.35))
		i += 14.0

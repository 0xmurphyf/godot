extends RefCounted
class_name SpriteFactory
## ============================================================
## 加载 Godot 原生 SpriteFrames 资源（.tres）
##
## 美术是真正的 Godot 资源，不再是运行时从图集切：
##   res://art/player_frames.tres   6 个动画 / 31 帧
##   res://art/boss_frames.tres    14 个动画 / 58 帧
##
## Boss 美术源自用户提供的精灵图集（洋红背景），
## 经 tools/gen_boss_from_source.py 抠图 -> 等比缩放 -> 贴地对齐 -> 加轮廓光生成。
## 源图已不在包内（art/src 已删），成品帧仍在，游戏不受影响。
##
## 在编辑器里双击 .tres 就能：
##   加删动画、拖入新帧、改 fps、勾循环、调每帧时长
##
## 每个动画独立成一行 PNG，放在 art/player/ 与 art/boss/。
## 所有帧画布尺寸一致（玩家 128x128 / Boss 192x192），脚底对齐同一像素行。
##
## 换美术不用改代码：detect_ground_row() 会扫描所有帧找出真正的脚底行，
## detect_cell() 取实际画布尺寸，auto_offset() 算出精灵该放哪。
## 所以改画布大小、改脚底位置、加减帧，角色都还是稳稳站在地面上。
##
## 换完之后跑 python3 tools/check_art.py 校验。
## ============================================================

const PLAYER_FRAMES := "res://art/player_frames.tres"
const BOSS_FRAMES := "res://art/boss_frames.tres"

# 下面这两个是「兜底值」，只在自动探测失败时才用。
# 实际偏移由 auto_offset() 从美术资源本身算出来 —— 换美术不用改代码。
# 目标「屏幕高度」：角色实际显示在屏幕上多高（像素）。
# 换美术会按这个高度归一化，角色不会忽大忽小。
# 这两个数 = 当前美术在 scale 1.0 时的内容高度，所以默认不缩放。
static var PLAYER_TARGET_H := 108.0
# Boss 与玩家同高：两者屏幕高度现在都是 ~108px
# （玩家 660/6=110，Boss 636/6=106，差 4px，肉眼分不出）
static var BOSS_TARGET_H := 108.0

# 兜底：只在探测失败时用。两者画布都是 768x768，脚底行 672。
static var P_CELL := 768
static var P_GROUND := 672
static var B_CELL := 768
static var B_GROUND := 672

# 顺序与 .tres 里的动画顺序一致，仅用于文档 / 校验
const P_ANIMS := ["idle", "run", "jump", "shoot", "dodge", "hurt", "dead"]
const B_ANIMS := ["idle", "walk", "crouch", "dash", "recover", "vent",
	"vanish", "appear", "drop", "land", "dead", "aim", "fire", "charge"]


static func build_player() -> SpriteFrames:
	return _load(PLAYER_FRAMES)


static func build_boss() -> SpriteFrames:
	return _load(BOSS_FRAMES)


static func _load(path: String) -> SpriteFrames:
	if not ResourceLoader.exists(path):
		push_error("SpriteFrames 资源不存在: " + path)
		return SpriteFrames.new()
	var sf := load(path) as SpriteFrames
	if sf == null:
		push_error("SpriteFrames 加载失败: " + path)
		return SpriteFrames.new()
	return sf


## 扫描若干帧，返回「内容包围盒」（不透明像素的并集）。
## 用 Image.get_used_rect()（C++ 实现），比逐像素扫描快得多。
##
## 关键点：用内容框而不是画布框来定位。换美术时画布尺寸、角色在画布里的
## 位置、脚底行都可能变，只看画布会把角色摆歪甚至顶出屏幕。
##
## prefer_anim：优先只用这一套动画来量。全表并集会被个别「大帧」带偏 ——
## 比如某帧带满屏特效，并集变得巨大，算出的 scale 就会小到接近 0。
## 用 idle（角色本体尺寸）量最稳。
static func content_rect(sf: SpriteFrames, prefer_anim := "idle") -> Rect2:
	if sf == null:
		return Rect2()
	var names := sf.get_animation_names()
	if names.is_empty():
		return Rect2()
	var scan: Array = []
	if prefer_anim != "" and names.has(prefer_anim):
		scan = [prefer_anim]
	else:
		scan = names
	var min_x := 1e9
	var min_y := 1e9
	var max_x := -1e9
	var max_y := -1e9
	var found := false
	for nm in scan:
		var n := sf.get_frame_count(nm)
		for i in range(n):
			var tex := sf.get_frame_texture(nm, i) as Texture2D
			if tex == null:
				continue
			var img := tex.get_image()
			if img == null:
				continue
			var r := _used_rect(img)
			if r.size.x <= 0 or r.size.y <= 0:
				continue
			found = true
			min_x = minf(min_x, float(r.position.x))
			min_y = minf(min_y, float(r.position.y))
			max_x = maxf(max_x, float(r.position.x + r.size.x))
			max_y = maxf(max_y, float(r.position.y + r.size.y))
	if not found:
		return Rect2()
	return Rect2(min_x, min_y, max_x - min_x, max_y - min_y)


## 内容框。优先用 Image.get_used_rect()（C++ 实现，很快）；
## 万一版本没有这个 API 就退回逐像素扫描（用 get_data() 的原始字节，比
## 逐个 get_pixel() 快一个量级）。
static func _used_rect(img: Image) -> Rect2i:
	if img.has_method("get_used_rect"):
		return img.get_used_rect()
	var w := img.get_width()
	var h := img.get_height()
	var d := img.get_data()
	var min_x := w
	var min_y := h
	var max_x := -1
	var max_y := -1
	for y in range(h):
		var row := y * w * 4
		for x in range(w):
			if d[row + x * 4 + 3] > 12:            # alpha
				if x < min_x: min_x = x
				if x > max_x: max_x = x
				if y < min_y: min_y = y
				if y > max_y: max_y = y
	if max_x < 0:
		return Rect2i()
	return Rect2i(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)


## 画布尺寸（取第一帧）
static func canvas_size(sf: SpriteFrames) -> Vector2:
	if sf == null:
		return Vector2.ZERO
	var names := sf.get_animation_names()
	if names.is_empty():
		return Vector2.ZERO
	var tex := sf.get_frame_texture(names[0], 0) as Texture2D
	if tex == null:
		return Vector2.ZERO
	return Vector2(tex.get_width(), tex.get_height())


## 自动适配：算出该给 AnimatedSprite2D 设多大的 scale 和什么 position。
##
## 两个动作：
##   1. 缩放 —— 让角色「内容高度」等于 target_h。换一套尺寸完全不同的美术
##      也不会变成巨人 / 蚂蚁，更不会头顶顶出屏幕。
##   2. 摆位 —— 脚底落在节点原点 y=0，且内容水平居中。
##
## AnimatedSprite2D centered=true 时，缩放是绕纹理中心做的，所以：
##   脚底局部 y  = s * (foot_row - canvas_h/2)
##   要让脚底落在节点原点 -> position.y = -s * (foot_row - canvas_h/2)
##   水平同理 -> position.x = -s * (content_cx - canvas_w/2)
static func auto_fit(sf: SpriteFrames, target_h: float,
		fb_cell := 0.0, fb_ground := 0.0) -> Dictionary:
	var out := {"scale": 1.0, "offset": Vector2.ZERO}
	if sf == null:
		return out
	var cr := content_rect(sf)
	var cs := canvas_size(sf)
	if cr.size.y <= 0 or cs.y <= 0:
		# 探测失败（比如美术全是空帧）：退回写死的兜底值
		if fb_cell > 0.0 and fb_ground > 0.0:
			out["offset"] = Vector2(0, -(fb_ground - fb_cell * 0.5))
		return out

	# 只做「整数倍」缩放：1/6、1/4、1/2、2、3 ...
	#
	# 为什么必须是整数倍：NEAREST 过滤下，非整数缩放会让某些源像素占 2 格、
	# 某些占 1 格，边缘看起来粗细不均并且移动时发抖。整数倍（尤其 1/n）能把
	# 每个 n×n 块精确映射成 1 个像素，放大缩小的画面都干净。
	#
	#   raw >= 1（要放大）-> n = round(raw)，scale = n
	#   raw <  1（要缩小）-> n = round(1/raw)，scale = 1/n
	#   n == 1            -> scale 1.0（差不多大，干脆不缩放）
	#
	# 这样也顺带避免了 scale 0：1/n 的 n 有上限，见下面 clamp。
	var raw := target_h / cr.size.y
	var s := 1.0
	if raw >= 1.0:
		s = float(clampi(int(round(raw)), 1, 8))
	else:
		s = 1.0 / float(clampi(int(round(1.0 / raw)), 1, 8))
	if s <= 0.01:                      # 双保险：绝不允许 0
		s = 1.0

	var foot := cr.position.y + cr.size.y          # 内容底边 = 脚底行
	var content_cx := cr.position.x + cr.size.x * 0.5

	out["scale"] = s
	out["offset"] = Vector2(
		-s * (content_cx - cs.x * 0.5),
		-s * (foot - cs.y * 0.5)
	)
	return out



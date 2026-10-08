extends Node
## 屏幕震动 + 全屏闪光（autoload 名：Fx）。
##
## 用 Camera2D 实现震动：场景里只要有一个 enabled 的 Camera2D，
## 它就接管视口渲染，动它的 offset 就是最干净的「镜头位移」。
## 比挪整个场景树安全 —— 挪树会连带移动 UI 和碰撞体位置。
##
## 用法：Fx.shake(0.6)      /   Fx.flash(Color(1,0.2,0.2), 0.5)

const TRAUMA_MAX := 1.0
var decay := 0.86              # 每帧衰减。越大震越久
var max_offset := 14.0         # trauma=1 时最大偏移（像素）
var max_roll := 0.012          # 旋转幅度（弧度）

var trauma := 0.0
var _t := 0.0
var _cam: Camera2D = null
var _seed := 0.0

var _flash_color := Color(1, 1, 1, 0)
var _flash_fade := 0.0
var _flash_rect: ColorRect = null
var _flash_layer: CanvasLayer = null


func _ready() -> void:
	set_process(true)
	_seed = randf() * 100.0
	_build_flash_layer()


func _process(delta: float) -> void:
	_shake(delta)
	_flash(delta)


## 绑定摄像机。Main 在 _ready 里调一次。
## 没有摄像机就只是不震（不会报错）—— 万一以后换了场景结构不至于炸。
func bind_camera(cam: Camera2D) -> void:
	_cam = cam
	if cam != null:
		cam.enabled = true


## 加震动。trauma 会累加，上限 1.0。
## 用平方衰减：小幅震动收得快，大招震得久 —— 层次感来源。
func shake(amount: float) -> void:
	trauma = minf(trauma + amount, TRAUMA_MAX)


## 全屏闪一下颜色。strength 0~1。
func flash(col: Color, strength: float) -> void:
	_flash_color = col
	_flash_fade = strength
	if _flash_rect != null:
		_flash_rect.color = Color(col.r, col.g, col.b, strength)


func _build_flash_layer() -> void:
	_flash_layer = CanvasLayer.new()
	_flash_layer.layer = 150            # 在 UI 之下、角色之上
	add_child(_flash_layer)
	_flash_rect = ColorRect.new()
	_flash_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_flash_rect.color = Color(1, 1, 1, 0)
	_flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash_layer.add_child(_flash_rect)


func _shake(delta: float) -> void:
	if _cam == null or not is_instance_valid(_cam):
		return
	if trauma <= 0.001:
		_cam.offset = Vector2.ZERO
		_cam.rotation = 0.0
		trauma = 0.0
		return
	# trauma 平方：小震动几乎看不见，大招才明显 —— 避免一直在抖
	var s := trauma * trauma
	_t += delta * 34.0
	# 两条不同频率的正弦叠加代替噪声表：不需要预生成随机数，
	# 也不依赖随机种子，形状稳定可复现。
	# 注意是 sin() 不是 sinf() —— 本项目的 Godot 版本没有 sinf。
	var ox: float = (sin(_t * 1.0 + _seed) + sin(_t * 2.7 + _seed * 1.7) * 0.5) / 1.5
	var oy: float = (sin(_t * 1.3 + _seed * 2.1) + sin(_t * 3.1 + _seed) * 0.5) / 1.5
	_cam.offset = Vector2(ox, oy) * max_offset * s
	_cam.rotation = ox * max_roll * s
	trauma = maxf(trauma - decay * delta, 0.0)


func _flash(delta: float) -> void:
	if _flash_fade <= 0.0:
		return
	_flash_fade = maxf(_flash_fade - delta * 3.2, 0.0)
	if _flash_rect != null:
		_flash_rect.color = Color(_flash_color.r, _flash_color.g,
				_flash_color.b, _flash_fade)

extends CanvasLayer
class_name VirtualPad
## 触屏虚拟按键。
##
## 为什么不用 Button / TouchScreenButton：
##   Button 走「触摸模拟鼠标」—— 多个手指会被合并成一个指针，
##   没法一边移动一边开枪，而这是本作的核心操作。
##   TouchScreenButton 支持多点，但它是 Node2D、要贴图，
##   想做成赛博朋克外观还得另外生成纹理。
## 自己写：Control + 手动命中测试，每个手指按 index 独立记录，
## 外观直接 _draw()，零美术资源。
##
## 命中测试为什么放在 _input() 里而不是每个按钮的 _gui_input()：
##   _gui_input 的事件坐标是「控件局部坐标」，滑出判定很容易算错
##   （算错的表现是按下后立刻自己松开）。
##   在 _input() 里拿到的是视口坐标，而按钮是 CanvasLayer 的直接子节点、
##   get_rect() 本来就是视口坐标 —— 直接比就行，不用换算。
##   顺带也支持了「手指从一个按钮滑到另一个」。
##
## 动作怎么发出去：
##   Input.parse_input_event() 发 InputEventAction，
##   而不是 Input.action_press()。
##   前者走完整输入管线（_input / _unhandled_input 都会收到），
##   Main 的 restart、EndCutscene 的跳过这些用
##   is_action_pressed() 判断的回调才能正常工作；
##   action_press() 只改内部状态，那些回调收不到。

const VIEW_W := 1152.0
const VIEW_H := 648.0

const C_CYAN := Color(0.00, 0.92, 1.00)
const C_MAGENTA := Color(1.00, 0.16, 0.45)

# 布局（视口坐标，1152x648）。
#
# 放**底部两个角**而不是压在中间：
# 底部中间（x 256..896）被 Boss 血条（y 574..594）和按键提示
# （y 606..628）占了 —— 按钮压上去会挡住血条，而血条是全场焦点。
# 左角 x<256、右角 x>896 是空的，正好各塞一组。
const BTN_L_X := 24.0
const BTN_L_Y := 514.0
const BTN_L_SIZE := 110.0
const BTN_R_Y := 546.0
const BTN_R_SIZE := 78.0
const BTN_R_GAP := 9.0
const BTN_R_MARGIN := 24.0

## 屏幕触摸用 index 区分手指；鼠标固定用这个假 index。
const MOUSE_INDEX := -1

## 收到真正的触摸事件时自动开启（即使当前是关的）。
## 默认开 —— 手机上没键盘，不自动出虚拟按键就完全没法玩。
@export var auto_show_on_touch := true

## 开启状态变化时发出（含自动开启）。Main 用它同步 TOUCH 按钮的文字。
##
## 不能叫 visibility_changed —— 那是 CanvasLayer 的**原生信号**
## （Godot 4 里 CanvasItem/Node 自带一个同名信号），重名会报
## "Member "visibility_changed" redefined (original in native class)"。
signal pad_enabled_changed(is_on: bool)

var _root: Control
var _btns: Array = []
var _enabled: bool = false
# 触摸 index -> 当前按住的按钮。一根手指只按一个按钮。
var _active: Dictionary = {}


func _ready() -> void:
	name = "VirtualPadRoot"
	layer = 100          # 高于 HUD(0)，低于过场(150) 和结算(200)

	_root = Control.new()
	_root.name = "Pad"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	# IGNORE：本层完全不参与 GUI 命中，所有输入走 _input() 自己算。
	# 这样虚拟按键不会挡住底下的无敌按钮 / 结算面板按钮。
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_add_button("move_left", "<", BTN_L_X, BTN_L_Y, BTN_L_SIZE, C_CYAN, 40)
	_add_button("move_right", ">", BTN_L_X + BTN_L_SIZE + 10.0, BTN_L_Y,
			BTN_L_SIZE, C_CYAN, 40)

	# 右边三个从左往右：ROLL / JUMP / FIRE。
	# FIRE 放最外（最右）—— 用得最多，拇指最容易够到。
	var rx: float = VIEW_W - BTN_R_MARGIN - BTN_R_SIZE * 3.0 - BTN_R_GAP * 2.0
	_add_button("dodge", "ROLL", rx, BTN_R_Y, BTN_R_SIZE, C_CYAN, 15)
	_add_button("jump", "JUMP", rx + BTN_R_SIZE + BTN_R_GAP, BTN_R_Y,
			BTN_R_SIZE, C_CYAN, 15)
	_add_button("attack", "FIRE", rx + (BTN_R_SIZE + BTN_R_GAP) * 2.0, BTN_R_Y,
			BTN_R_SIZE, C_MAGENTA, 15)

	set_enabled(_enabled)


func _add_button(action: String, glyph: String, x: float, y: float,
		size: float, col: Color, font_size: int) -> void:
	var b := VirtualButton.new()
	b.setup(action, glyph, col, font_size)
	b.size = Vector2(size, size)
	b.position = Vector2(x, y)
	_root.add_child(b)
	_btns.append(b)


## 开关。关闭时必须把按住的键全部松开 ——
## 否则「一边跑一边关掉虚拟按键」会让角色永远朝一个方向跑。
func set_enabled(on: bool) -> void:
	# 只跳过 emit，不跳过 visible 同步 ——
	# 首次调用（_ready 里）时 _enabled 已经是 false，
	# 直接 return 的话 _root.visible 会留在默认的 true，按钮白显示出来。
	var changed: bool = _enabled != on
	_enabled = on
	if _root != null:
		_root.visible = on
	if not on:
		_release_all()
	if changed:
		pad_enabled_changed.emit(on)


func is_enabled() -> bool:
	return _enabled


func _input(event: InputEvent) -> void:
	# 自动开启的判断必须放在 `if not _enabled: return` **之前** ——
	# 否则关着的时候收不到触摸事件，永远开不了。
	if auto_show_on_touch and not _enabled:
		if event is InputEventScreenTouch or event is InputEventScreenDrag:
			set_enabled(true)

	if not _enabled:
		return

	if event is InputEventScreenTouch:
		_on_touch(event as InputEventScreenTouch)
		return

	if event is InputEventScreenDrag:
		_on_drag(event as InputEventScreenDrag)
		return

	# 鼠标：桌面调试用。不加这段的话，在电脑上开虚拟按键点不动。
	if event is InputEventMouseButton:
		_on_mouse_button(event as InputEventMouseButton)
		return

	if event is InputEventMouseMotion:
		_on_mouse_motion(event as InputEventMouseMotion)


func _on_touch(t: InputEventScreenTouch) -> void:
	if t.pressed:
		var b := _hit(t.position)
		if b != null:
			_active[t.index] = b
			_press(b)
	else:
		_lift(t.index)


func _on_drag(d: InputEventScreenDrag) -> void:
	var cur := _held_of(d.index)
	if cur == null:
		return
	var b := _hit(d.position)
	if b == cur:
		return
	# 滑出原按钮（或滑到另一个按钮）：先把原来的松开
	_active.erase(d.index)
	_release(cur)
	if b != null:
		_active[d.index] = b
		_press(b)


func _on_mouse_button(mb: InputEventMouseButton) -> void:
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if mb.pressed:
		var bm := _hit(mb.position)
		if bm != null:
			_active[MOUSE_INDEX] = bm
			_press(bm)
	else:
		_lift(MOUSE_INDEX)


func _on_mouse_motion(mm: InputEventMouseMotion) -> void:
	var held := _held_of(MOUSE_INDEX)
	if held != null and not held.get_rect().has_point(mm.position):
		_lift(MOUSE_INDEX)


## 从 _active 里取按钮。
##
## 必须走 has() + as 转换，不能 `var x := _active.get(i)` ——
## Dictionary.get() 返回 Variant，`var x :=` 推不出类型，
## 本项目开了 warning-as-error，直接编译失败。
func _held_of(index: int) -> VirtualButton:
	if not _active.has(index):
		return null
	return _active[index] as VirtualButton


func _hit(pos: Vector2) -> VirtualButton:
	# 同理：_btns 是无类型 Array，取出来要 as 一下再调用。
	for i in _btns.size():
		var b: VirtualButton = _btns[i] as VirtualButton
		if b != null and b.get_rect().has_point(pos):
			return b
	return null


func _press(b: VirtualButton) -> void:
	b.set_held(true)
	_send(b.action, true)


func _release(b: VirtualButton) -> void:
	b.set_held(false)
	_send(b.action, false)


func _lift(index: int) -> void:
	var b := _held_of(index)
	if b == null:
		return
	_active.erase(index)
	_release(b)


## 发动作。用 parse_input_event 而不是 action_press —— 见文件头说明。
func _send(action: String, pressed: bool) -> void:
	if not InputMap.has_action(action):
		push_warning("VirtualPad: 输入映射里没有动作 '%s'" % action)
		return
	var e := InputEventAction.new()
	e.action = action
	e.pressed = pressed
	Input.parse_input_event(e)


## 全部松开。关开关、退出场景树时都要调 ——
## 不调的话切场景后角色会一直往一个方向跑。
func _release_all() -> void:
	for i in _btns.size():
		var b: VirtualButton = _btns[i] as VirtualButton
		if b != null and b.held:
			_release(b)
	_active.clear()


func _exit_tree() -> void:
	_release_all()

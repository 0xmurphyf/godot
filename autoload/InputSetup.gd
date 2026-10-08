extends Node
## 输入映射注册。键位写死在 KEYMAP 里，改键直接改这张表。
##
## 用代码注册输入映射，省去在 项目设置 -> 输入映射 里手动点。
##
## 曾经做过「开局按键设置界面 + user://keymap.cfg 存盘」，已回滚 ——
## 对只有 8 个动作的 demo 来说，那套东西（独立场景、冲突抢占、
## 存读盘、版本迁移）比它解决的问题还多。

## 动作名 -> 键位数组。第二个键可以留空（KEY_NONE）。
## KEY_* 常量是 int，physical_keycode 要 Key 枚举 —— 存的时候统一转成 Key。
const KEYMAP := {
	"move_left": [KEY_A, KEY_LEFT],
	"move_right": [KEY_D, KEY_RIGHT],
	# 翻滚用 SPACE（手感上 SPACE 更适合「闪避」这种需要快速反应的动作），
	# 跳跃让位到 W / 上方向键。
	"jump": [KEY_W, KEY_UP],
	"attack": [KEY_J, KEY_K],
	"dodge": [KEY_SPACE, KEY_SHIFT],
	"restart": [KEY_R, KEY_NONE],
	"debug_boxes": [KEY_F1, KEY_B],
	"slowmo": [KEY_P, KEY_NONE],
}


func _ready() -> void:
	apply()


func apply() -> void:
	for a in KEYMAP:
		if not InputMap.has_action(a):
			InputMap.add_action(a)
		else:
			InputMap.action_erase_events(a)
		for k in KEYMAP[a]:
			var key := int(k) as Key
			if key == KEY_NONE:
				continue
			var ev := InputEventKey.new()
			# 显式转成 Key 枚举，避免 INT_AS_ENUM_WITHOUT_CAST
			ev.physical_keycode = key
			InputMap.action_add_event(a, ev)

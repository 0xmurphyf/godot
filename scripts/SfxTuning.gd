extends Resource
class_name SfxTuning
## 音效调参资源。双击 sfx/sfx_tuning.tres 就能在检查器里改音量，
## 改完 Ctrl+S 保存即可生效 —— 不用碰代码。
##
## 为什么单独做成 Resource：Sfx 是 autoload，而 autoload 节点的 @export
## 只有在运行时才能在场景树里选中，编辑期没法直接在检查器里改。
## 做成 .tres 资源文件就没有这个问题。

@export_group("总音量")
## 所有音效的整体增益（dB）。0 = 原音量，负数更小。
@export_range(-60.0, 6.0) var master_db := 0.0
## 全局静音
@export var muted := false

@export_group("招式提示音（dB）")
## 每招的起手音。刻意比命中音轻一点 ——
## 提示音是「背景信息」，不该盖过真正打中时的打击音。
## 但 mv_charge 要给足：全图炮是最该躲的一招，听不见就完了。
@export_range(-60.0, 6.0) var mv_jab := -5.0
@export_range(-60.0, 6.0) var mv_dash := -4.0
@export_range(-60.0, 6.0) var mv_blink := -4.0
@export_range(-60.0, 6.0) var mv_charge := -1.0

@export_group("新增音效（dB）")
## 动作反馈类：都刻意压低 —— 它们每秒可能触发多次，
## 跟命中音抢音量会让画面显得很吵。
@export_range(-60.0, 6.0) var wall_hit := -8.0
@export_range(-60.0, 6.0) var land := -6.0
@export_range(-60.0, 6.0) var dash_whoosh := -6.0
@export_range(-60.0, 6.0) var teleport_out := -4.0
@export_range(-60.0, 6.0) var teleport_in := -4.0
@export_range(-60.0, 6.0) var combo := -7.0
@export_range(-60.0, 6.0) var beam_hum := -8.0
@export_range(-60.0, 6.0) var phase_hit := -4.0
@export_range(-60.0, 6.0) var low_hp := -3.0
@export_range(-60.0, 6.0) var ui_click := -10.0

@export_group("单个音量（dB）")
@export_range(-60.0, 6.0) var shoot := -3.0
@export_range(-60.0, 6.0) var enemy_shoot := -4.0
@export_range(-60.0, 6.0) var cannon := 0.0
@export_range(-60.0, 6.0) var hit := -1.0
@export_range(-60.0, 6.0) var hurt := -2.0
@export_range(-60.0, 6.0) var launch := -2.0
@export_range(-60.0, 6.0) var jump := -6.0
@export_range(-60.0, 6.0) var dodge := -8.0
@export_range(-60.0, 6.0) var phase := -2.0
@export_range(-60.0, 6.0) var win := -3.0
@export_range(-60.0, 6.0) var lose := -3.0

@export_group("播放细节")
## 同名音效的最小间隔（秒）。同一帧可能触发多次，不设间隔会叠成爆音。
@export_range(0.0, 0.5, 0.005) var min_interval := 0.035
## 音高微扰幅度。连发时每发略有不同，不至于机械重复。0 = 关闭。
@export_range(0.0, 0.3, 0.01) var pitch_jitter := 0.06


## 按名字取音量（dB）。名字不在列表里就返回 master_db 本身。
func db_for(nm: String) -> float:
	match nm:
		"wall_hit": return wall_hit
		"land": return land
		"dash_whoosh": return dash_whoosh
		"teleport_out": return teleport_out
		"teleport_in": return teleport_in
		"combo": return combo
		"beam_hum": return beam_hum
		"phase_hit": return phase_hit
		"low_hp": return low_hp
		"ui_click": return ui_click
		"mv_jab": return mv_jab
		"mv_dash": return mv_dash
		"mv_blink": return mv_blink
		"mv_charge": return mv_charge
		"shoot": return shoot
		"enemy_shoot": return enemy_shoot
		"cannon": return cannon
		"hit": return hit
		"hurt": return hurt
		"launch": return launch
		"jump": return jump
		"dodge": return dodge
		"phase": return phase
		"win": return win
		"lose": return lose
		_: return 0.0

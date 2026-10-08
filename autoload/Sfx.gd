extends Node
## 音效播放单例（autoload 名：Sfx）。
##
## 音效是合成的芯片音，见 tools/gen_sfx.py —— 改音色改那个脚本重跑即可。
##
## 用法：Sfx.play("hit")      /   Sfx.play("shoot", -6.0, 0.97)

const DIR := "res://sfx/"
const BUS := "Master"
# 调参资源：双击 sfx/sfx_tuning.tres 在检查器里改音量
const TUNING_PATH := "res://sfx/sfx_tuning.tres"

# 预热列表。刻意不写 Array[String] ——
# 带类型的数组常量在部分 Godot 版本上会触发解析/分析错误，
# 这里取 String(n) 显式转换，效果一样但更稳。
const PRELOAD_NAMES := [
	"shoot", "enemy_shoot", "hit", "hurt", "jump", "dodge",
	"launch", "cannon", "phase", "win", "lose",
	"mv_jab", "mv_dash", "mv_blink", "mv_charge",
	"wall_hit", "land", "dash_whoosh", "teleport_out",
	"teleport_in", "combo", "beam_hum", "phase_hit",
	"low_hp", "ui_click",
]

var _cache := {}
var _last := {}
var _rng := RandomNumberGenerator.new()
var _tuning: SfxTuning = null       # 加载失败就走下面 _db() / _jitter() 的默认值


func _ready() -> void:
	_rng.randomize()
	if ResourceLoader.exists(TUNING_PATH):
		_tuning = load(TUNING_PATH) as SfxTuning
	# 预热：把音效读进缓存，避免第一次播放时卡一下
	for n in PRELOAD_NAMES:
		_stream(String(n))


func _db() -> float:
	return _tuning.master_db if _tuning != null else 0.0


func _muted() -> bool:
	return _tuning.muted if _tuning != null else false


func _interval() -> float:
	return _tuning.min_interval if _tuning != null else 0.035


func _jitter() -> float:
	return _tuning.pitch_jitter if _tuning != null else 0.06


func _stream(nm: String) -> AudioStream:
	if _cache.has(nm):
		return _cache[nm]
	var path := DIR + nm + ".wav"
	if not ResourceLoader.exists(path):
		push_warning("音效缺失: " + path)
		_cache[nm] = null
		return null
	var s := load(path) as AudioStream
	_cache[nm] = s
	return s


## 播放一次性音效。
## vol_db 是「额外」的分贝偏移（0 = 用 sfx_tuning.tres 里配的音量）。
## pitch 1.0 = 原速；默认加音高微扰，连发时每发略有不同。
func play(nm: String, vol_db := 0.0, pitch := 1.0, jitter := true) -> void:
	if _muted():
		return
	var s := _stream(nm)
	if s == null:
		return
	var t := float(Time.get_ticks_msec()) / 1000.0
	if _last.has(nm) and t - float(_last[nm]) < _interval():
		return                              # 太密集，丢弃
	_last[nm] = t

	var base := _tuning.db_for(nm) if _tuning != null else 0.0
	var p := AudioStreamPlayer.new()
	p.stream = s
	p.volume_db = _db() + base + vol_db
	p.bus = BUS
	if jitter:
		var j := _jitter()
		p.pitch_scale = pitch * (1.0 + _rng.randf_range(-j, j))
	else:
		p.pitch_scale = pitch
	add_child(p)
	# 播完自己释放 —— 一次性音效不需要长期持有节点
	p.finished.connect(func() -> void: p.queue_free())
	p.play()

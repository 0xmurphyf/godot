extends Resource
class_name AttackData
## 一招 —— 对应 LF2 的 file_t。
## 招式 = 一串帧。换个帧表就是新招，解释器一行不用改。

@export var move_name: String = ""
@export var frames: Array[FrameData] = []

@export var interruptible: bool = false   # 为真时 AI 可随时打断（走路这种持续动作用）

@export_group("选招条件（AI 用）")
@export var min_dist: float = 0.0         # 距离小于此值不选这招
@export var max_dist: float = 9999.0      # 距离大于此值不选这招
@export var weight: float = 1.0           # 权重，越大越容易被选中

@export_group("连发")
## 连发段数上限的随机范围（只有帧数据里配了 chain_next 的招式才生效）。
## 每次出招时随机取 [chain_min, chain_max] 之间的整数，
## 作为本次「最多连几下」。0 = 不连发。
## 随机发生在 play() 里 —— AttackData 是共享资源，不能把随机结果存进来。
@export var chain_min: int = 0
@export var chain_max: int = 0

@export_group("消耗")
@export var mp_cost: int = 0



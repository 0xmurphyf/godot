extends Resource
class_name FrameData
## 一帧 —— 对应 LF2 的 frame_t。
## 每一个字段都能在 Godot 检查器里直接改，改完立刻生效，不用碰代码。

@export var label: String = ""            # 备注名，方便你认（startup / active / recover ...）
@export var duration: int = 1             # wait：本帧持续多少个逻辑帧（60fps 下 30 = 0.5 秒）
@export var next: int = -1                # 结束后跳到第几帧；-1 = 本招式结束

@export_group("位移")
@export var dvx: float = 0.0              # 水平速度（会自动按 facing 镜像）
@export var dvy: float = 0.0              # 垂直速度（仅 use_gravity=false 时生效）
@export var use_gravity: bool = true      # 关掉 = 本帧不受重力（下落/悬停用）
@export var wait_for_landing: bool = false  # 本帧不靠计时结束，等落地才结束

@export_group("瞬间位移")
@export var teleport: String = ""         # "" / "above_player" / "front_player" / "behind_player"
@export var teleport_offset: Vector2 = Vector2(0, -260)  # 进入本帧时闪现到哪（相对玩家）
@export var invisible: bool = false       # 本帧不渲染（闪现的消失帧）

@export_group("动画")
@export var anim: String = ""            # 本帧播放哪个动画（AnimatedSprite2D 的动画名）
                                          # 留空则沿用上一帧的动画
## 是否让「非循环动画」自动铺满本帧的时长。
## 默认开：动画是独立系统（按自己的 speed 播），帧表的 duration 是另一套，
## 两者不匹配时动作会播一半就切换 —— 前摇越短越明显。
## 关掉的场景：一个动画被连续多帧共用（比如 slam 跨 appear/drop/land），
## 此时各段节奏由 .tres 里每帧的 duration 精确控制，不该被拉伸。
@export var anim_fit := true

@export_group("判定")
@export var hitbox_rect: Rect2            # 攻击判定框（留空 = 本帧无判定）
# 受击框覆盖（留空 = 用场景里的默认 hurtbox）。
# 不按朝向镜像 —— 受击框本来就是自身范围，跟朝哪边无关。
@export var hurt_rect: Rect2
@export var damage: int = 0
@export var knockback: float = 0.0
@export var hitstop: int = 0
## 命中顿帧是否也冻结「攻击者自己」。
## 默认 true（双方一起定住，打击感）。
## 贯穿型招式设 false —— 攻击者保持惯性冲过去，只有被打的人定住。
@export var hitstop_self := true              # 命中时双方冻结的帧数（打击感开关）
@export var hit_next: int = -1            # 命中玩家时改跳到第几帧（-1 = 照 next 走）
                                          # 用途：打中走短后摇，扑空走长硬直
## 本帧【播完时】的改道：若本招到此时为止命中过，跳到第几帧（-1 = 照 next 走）。
## 与 hit_next 的区别：hit_next 是「命中瞬间立即跳」，会把贯穿型招式打断；
## 这个是「等本帧播完再跳」，贯穿位移不受影响。
@export var next_on_hit: int = -1

## 本帧【播完时】的连发改道：若本招到此时为止**还没**命中过，
## 且本次连击段数还没到上限，就跳到第几帧「再来一次」（-1 = 不连发）。
## 用途：闪现砸没砸中 → 回到 appear 帧再闪现砸一次，追着玩家连砸。
## 命中过就照 next 走（不连了）—— 判据用 move_hit，与 next_on_hit 互补。
@export var chain_next: int = -1

@export_group("生成子实体（对应 LF2 的 opoint）")
@export var spawn_scene: String = ""      # 要生成的场景路径，如 "res://scenes/Bullet.tscn"
@export var spawn_offset: Vector2 = Vector2(38, -34)   # 相对自身的出生点（x 按朝向镜像）
@export var spawn_damage: int = 0         # <1 则用子弹自身的默认值
@export var spawn_knockback: float = 0.0
## 命中后本招结束时是否触发「后撤」（Boss 专用）
## 判据只有这一个布尔值，不看击退数值 ——
## 用 kb 阈值当条件会在撞墙等边界情况下误判（位移被吃掉但 kb 还在）
@export var retreat_on_launch: bool = false

@export_group("控制")
@export var telegraph: bool = false       # 本帧是前摇 → 前摇期间持续朝向玩家（读招依据）
@export var wall_next: int = -1           # 撞墙时跳到第几帧（-1 = 不处理）
@export var cancellable: bool = false     # 本帧能否被新输入打断（连招用）

@export_group("招式提示音")
## 进入本帧时播放的音效名（对应 sfx/ 下的 .wav）。
## 每招一个专属起手音 —— 玩家光靠听就能分辨 Boss 要出哪一招，
## 不用一直盯着动作看。这是格斗游戏的常规做法（audio telegraph）。
## 留空 = 这一帧不播音。
@export var cue: String = ""

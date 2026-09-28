# 真机 Release 性能测量方案（阶段 7 的前置）

**写于** 2026-09-19 · 独立验收 agent（a4）· 分支 `feature/ios-native-prototype`
**状态** 工具已就绪并在模拟器上跑通；**没有任何真机数字，也不会有模拟器数字冒充**。

配套工具：`ios-native/Tools/perf-measure.sh`、`Tools/perf-report.py`、
`Tools/count-posts.py`、`Tools/PerfSignposts.swift`（后者尚未接入任何 target）。

---

## 0. 为什么先写起止点，再写工具

上一轮的教训是"133 个测试全绿、手机上是一块黑"。性能这一项有它自己的版本：
**一个名字听起来对、起止点选错了的数字，比没有数字更糟**，因为它会被当成基线，
之后所有对比都以它为准。

所以下面每一项先回答两个问题：**从哪个事件开始计时，到哪个事件停**。
两个事件都必须是"外部可观测的、能指着说就是这一刻"的事件，
不能是"大概加载完了"。

不用的替代品，以及为什么不用：

| 看起来能用 | 为什么不用 |
| --- | --- |
| `applicationDidFinishLaunching` | 它在 SwiftUI 建第一个视图之前就返回了。本应用在这一刻会话还没解析、一条帖子都没有。用它当"启动完成"会得到一个漂亮且毫无意义的数字 |
| 安装包体积 | 验收矩阵 §11.5 明令禁止"用文件大小代替启动耗时" |
| 截图前后的墙钟时间 | 截图本身要 100–300ms，且不知道那一帧是什么时候上屏的 |
| 模拟器上的任何数字 | 桌面 CPU/GPU、没有热限制、文件系统不是 NAND。它不是"慢一点的真机"，是另一个量 |
| `resident_size` | 它把共享页和可回收页都算进去，读数远高于系统真正据以杀进程的 `phys_footprint` |

---

## 1. 四项指标的起点与终点

### 1.1 冷启动

| | |
| --- | --- |
| **起点** | 进程 `exec`，取自 `kinfo_proc.kp_proc.p_starttime`（`sysctl KERN_PROC_PID`）。**包含 dyld**，冷启动里 dyld 是真实开销 |
| **终点** | **第一帧"含真实 feed 内容且已提交给渲染服务"**。实现：`model.posts` 首次非空的那次渲染中，经 `DispatchQueue.main.async` + `CATransaction` 完成回调触发 —— 完成回调在该事务的图层树交给 render server 之后执行，这是进程内部能拿到的、最接近"上屏"的时刻 |
| **不是** | 不是 `didFinishLaunching`；不是 `.task` 触发；不是 `body` 被调用 |
| **样本数** | **20 次**。不是 10 —— 见 §2 |
| **统计量** | 中位数为主，同时给 min / max / stdev / 全部样本；样本 ≥20 才给 p95 |
| **前置** | 每次之间 `terminate` 后等 3 秒。相隔几百毫秒的重启是"页缓存还在"的热启动顶着冷启动的名字 |

### 1.2 Feed 滚动掉帧

| | |
| --- | --- |
| **起点** | 第一个滚动事件（Instruments 自己标） |
| **终点** | 列表滚到第 210 条 |
| **方法** | `xctrace record --template "Animation Hitches"`。验收矩阵：滚动与动画**必须**用逐帧或 Instruments，**不得用截图代替** |
| **样本数** | 整列表来回 **5 轮**（矩阵 7.3 的"≥5 轮"） |
| **统计量** | hitch time ratio（每秒卡顿毫秒），加**单帧最大耗时**。预算：掉帧率 <1%，单帧最大 <33ms |
| **手势** | **匀速滚，不要甩**。甩出去的列表会跳过整段行，得到的是"没合成过的行"的掉帧率。这个坑已经在视频测试里踩过一次：快速滚动时播放器一个都没创建，测试全绿而什么都没测 |

### 1.3 媒体加载耗时

| | |
| --- | --- |
| **起点** | 应用**决定需要这个资源**的那一刻（`ImageLoader` 发起取图 / `VideoPlaybackCoordinator.player(for:url:)` 建播放器）。不是行出现的时刻 —— 行可以先存在好几帧，URL 才确定 |
| **终点** | **解码后的图像交给视图**；视频是 `AVPlayerItem.status == .readyToPlay`。**不是网络传输结束** —— 解码是真实成本，把它藏起来会让数字好看且错误 |
| **样本数** | 前 30 条帖子各一次，冷缓存；再跑一轮暖缓存，两轮分开报 |
| **统计量** | 中位数 + max；冷/暖分别给 |
| **缓存状态** | 每轮开始前记录冷或暖。矩阵阶段 7 前置明确要求"记录缓存冷/暖状态" |

### 1.4 内存峰值

| | |
| --- | --- |
| **起点** | App 启动 |
| **终点** | **整列表来回滚 3 轮之后**（对应 5D.7 的"3 轮"） |
| **量** | `task_vm_info.phys_footprint`。这是 iOS 真正据以杀进程的数、也是 Xcode 内存表显示的数 |
| **样本数** | 每次运行取该次的峰值；跑 5 次，报 5 个峰值的中位数与 max |
| **预算** | 不超过 Capacitor 基线的 1.2 倍（7.4）。**基线目前不存在**，所以这一项在 Capacitor 侧也做完之前只能建基线、不能判合格 |

---

## 2. 样本数为什么是 20

矩阵 7.1/7.2 写"≥10 次"，报告纪律写"样本量不足时不得报 p95/p99"。这两句合起来
意味着：10 次可以给分布，但**不能给 p95**。而"启动慢"这件事的用户感受恰恰在尾部。

所以这里定 20：20 个样本的 p95 用最近秩法就是第 19 个样本，它至少是一个**测到的值**，
不是插值出来的。`perf-report.py` 硬性拒绝在少于 20 个样本时打印 p95，
并且打印拒绝的理由，而不是安静地跳过 —— 安静跳过会让人以为这项没测。

同样地，报告**必须**给出全部样本和离群值。删掉一个离群值需要写出理由
（来了通知、设备热限制），"它不方便"不是理由。

---

## 3. 数据集（每个数字都依赖它）

2026-09-19 实测自 emulator（`Tools/count-posts.py` + REST 读取，只读）：

| 项 | 实测 |
| --- | --- |
| 种子脚本 | `functions/scripts/seed-ios-native.mjs` |
| 帖子总数 | **210**（`ios-post-000` … `ios-post-209`） |
| 视频帖 | **7 条**：002 `dog.mp4`、026 `sea_turtle.mp4`、**041 故意 404**、063 `elephants.mp4`、117 `dog.mp4`、170 `sea_turtle.mp4`、203 `elephants.mp4` |
| 多图帖 | 41 条 |
| 无媒体帖 | 1 条 |
| 超长文案 | 1 条（>500 字符） |
| 60 条评论的帖 | `ios-post-001` |
| 账号 | `accept-a@example.com`（已验证）、`accept-b`（已验证）、`accept-new`（未验证）、`accept-admin`、`a3-expire` |

**数据集里有一处已知脏数据，会影响任何按计数判断的观察**：见 §6。

## 4. 构建版本（每个数字必须带）

`perf-measure.sh` 每次运行都把这三行写进输出文件，而不是事后凭记忆补：

```
commit=<git rev-parse --short HEAD>  dirty_files=<N>  configuration=Release  date=<UTC>
```

`dirty_files` 不为 0 的运行**不能**当基线：那份二进制在仓库里不存在，重现不了。

两个构建（Capacitor 与 Swift）都必须是 **Release**。Debug Swift 不是"慢一点的
Release"，是另一个二进制：没有泛型特化、没有内联、边界检查全开。
Debug 的数字换算不成 Release 的。

---

## 5. 预检结果（2026-09-19，模拟器 pn-a4）

```
Tools/perf-measure.sh preflight --simulator pn-a4
```

| 检查 | 结果 |
| --- | --- |
| `Animation Hitches` / `App Launch` / `Allocations` 模板 | **可用** |
| `xcrun` / `xctrace` | **可用** |
| emulator 数据集 210 帖 | **符合** |
| 冷启动埋点 `PERF cold_start_ms` | **不存在** |
| 媒体埋点 `PERF media_ms` | **不存在** |
| 内存埋点 `PERF footprint_kb` | **不存在** |
| 真机 | **不在线**（本轮全程 unavailable） |

**结论：`preflight FAILED with 3 blocking item(s)`。**

这三项都是同一件事：`grep -rn "signpost\|OSSignposter" App Core Features Support`
在这个工程里**一条都没有**，11 个 `Logger` 全部只记事件、没有一个记时长。
也就是说**今天没有任何一项指标是可测的**，四项全部 `[待验证]`。

`Tools/PerfSignposts.swift` 是补这个洞的提案，含每个埋点的确切调用位置。
它**没有加进任何 target** —— 加文件要改 `project.pbxproj`，那是主协调 agent 的文件。

预检过程本身抓到两个自己的 bug，记下来因为它们是同一类错误：

1. `xcrun xctrace list templates | grep -q` 在 `set -o pipefail` 下永远报失败 ——
   `grep -q` 命中即关闭管道，xctrace 收到 SIGPIPE 退出非零。
   **一个会误报的预检比没有预检更糟**，因为它会被人无视。
2. Firestore emulator 的 REST `list` 有自己的分页上限，`pageSize=1000` 只回 150 条。
   第一版预检据此报告"数据集只有 150 帖、与 210 不符"。
   **如果有人信了这个结论去重跑种子脚本，会清掉另外三个 agent 正在用的数据。**

---

## 6. 会让性能结论失真的一处脏数据

`ios-post-001` 的 `commentCount` 是 **120**，而它的 `comments` 子集合里只有 **60** 条。

原因可复现：种子脚本第 358 行直接把 `commentCount: 60` 写进帖子文档，
第 377–386 行又逐条 `add()` 了 60 条评论 —— functions emulator 正在跑，
`onCommentCreated` 对每一条又 `increment(1)`。60 + 60 = 120。

点赞没有这个问题：种子给自己写的 like 盖了 `counted: true`，`onLikeCreated`
认这个标记并跳过，所以 `likeCount` 是对的（逐条核对过前 12 帖）。评论没有对应的守卫。

对性能测量的影响：按"卡片上的计数"判断列表是否正确加载的任何观察都不可信。
对验收的影响见独立复核报告的缺陷清单。

---

## 7. 明确不会做的事

- **不用模拟器数字填任何一格。** `perf-measure.sh` 的三个测量子命令在没有
  `--device` 时直接退出。`preflight --simulator` 存在的唯一目的是验证
  *工具本身*跑得通、起止点埋在对的地方。
- **不报没测到的数。** 没有样本时 `perf-report.py` 打印 `NO SAMPLES` 并说明
  这是 `[待验证]`，不是 0、也不是"很快"。
- **不用截图证明滚动。**
- **样本不足不报 p95。**

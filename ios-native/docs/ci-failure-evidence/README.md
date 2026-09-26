# 四次 CI 失败：每一条「是测试缺陷」的证据

2026-09-23。四次失败都发生在 GitHub 的 runner 上（`Apple M1 (Virtual)`，3 核，7 GiB）。
结论「是测试的缺陷，不是 App 的」要**每一条单独有证据**，所以每一条都做了两件事：

1. **确定性重现**：把 CI 上偶然出现的先后顺序，在测试里固定下来，让旧测试每次都按 CI 的原话失败。
   **没有改任何产品代码**。
2. **反向验证**：临时把 App 里对应的保护去掉，看修过的测试会不会失败。
   会失败，才说明修测试没有削弱它原本要验证的产品行为。

这里的补丁都是**临时的证据，不是测试**，不要合进测试目录。用法：在仓库根目录
`git apply ios-native/docs/ci-failure-evidence/<名字>.patch`，跑完 `git apply -R` 撤掉。
重现补丁会在 `ios-native/PetNoteAppTests/` 下建 `TEMP_` 开头的文件；变异补丁改一行产品代码，行上写着 `TEMPORARY MUTATION - DO NOT COMMIT`。
补丁是在提交这份说明的那个版本上做的，以后代码改动了可能要重新对行号。

本机结果（iOS 27 模拟器，单元测试串行）：

| 运行 | 结果 |
| --- | --- |
| 四个重现补丁一起，831 条单元测试 | 只有 3 条重现测试失败，失败原话和 CI 一致（见下）；修过的测试、提议的测试全过 |
| 压力重现（第 1 条，另跑） | 两个不加锁的替身都让**测试进程崩溃**（SIGSEGV），栈和 CI 一致；加锁的对照通过 |
| 变异 2-3（去掉「超时后放弃请求」） | 恰好 2 条失败：`aLikeRequestThatIsNeverAnsweredIsGivenUpOn`、`aPostStillWorksAfterARequestIsAbandoned`，撤掉后恢复 |
| 变异 4（保存前的检查和置位之间插一次让出） | 已提交的 `twoTapsInTheSameTurnSaveOnce` **仍然通过**（盲区，见第 4 条）；新加的 `aSecondTapAtTheFirstSuspensionWritesNothing` 失败，写了 2 次；撤掉后恢复 |

---

## 1. 测试进程崩溃 · run 35905119437（`44f8d99`）

**CI 上看到的**：单元测试进程收到 SIGSEGV。崩溃报告的栈：`Array.append` → `_consumeAndCreateNew` →
`_swift_release_dealloc`，在测试替身 `FakeSearchRepository.posts(since:limit:)` 往记录数组追加的那一行，调用方是
`ExploreModel.load()` → `loadTrending()`。崩溃时正在跑 `SocialRenderTests`。

**原来的说法要更正**：`8915ac2` 的提交说明写的是「`ExploreModel.load()` 用 `async let` 同时发出的几个读取」。
但一次 `load()` 只往这个数组追加一次，一次 `load()` 自己撞不上自己。**真正同时在写的，是几次渲染各自启动的 `load()`**：
`SocialRenderTests` 用 `ImageRenderer` 画搜索页，渲染会启动页面的 `.task`（测试里原来的注释说「不跑 `.task`」，是错的），
三次渲染就是三次同时的读取，而且它们在测试结束后还在跑。

**重现**（`repro-1.patch`）：
- 确定性部分：数渲染启动了几次读取。结果：`REPRO-1 render: 3 trending reads started by 3 renders, at most 3 in flight at once`。
- 压力部分：用和 `44f8d99` 一样**不加锁**的替身反复渲染。两个不加锁的版本都让测试进程崩溃，
  栈是 `Array.append → _consumeAndCreateNew → _swift_release_dealloc`，在替身的 `posts(since:limit:)`，经 `ExploreModel.loadTrending`，和 CI 一致；
  **加锁**的对照版本通过。

**修法**：替身的记录加锁（`8915ac2`，这一轮又补了点赞、社交、用户资料几个替身）。正式的仓库本来就是线程安全的，产品代码没改。

**更早那次崩溃**（run 35836744989，`59c6225`）没有崩溃报告，**只能说很可能是同一类，没有证实**。

## 2. 点赞「放弃请求」测试 · run 35924362700（`3b4f497`）

**CI 原话**：`aPostStillWorksAfterARequestIsAbandoned` — `never reached: the first request was not given up on`。

**说法**：测试手动放行超时，但 `ManualDeadline.pass()` 只放行**那一刻已经在等**的计时器；
慢机器上模型的计时器在测试放行**之后**才进入等待，放行落空。

**重现**（`repro-2.patch`）：替身计时器和现有的一样，只是固定成「晚一步进入等待」。旧测试每次都失败，原话同上；
按现在的写法（`passOnceArmed()`，等计时器就位再放行）的两条通过。

**反向验证**（`mutation-2-3.patch`）：去掉 App 里「超时后放弃请求」的那一行，这条测试失败。所以修过的测试仍然在测放弃请求。

## 3. 点赞「从不回答的请求」测试 · run 35929225283（`be9ce4d`）

**CI 原话**：`aLikeRequestThatIsNeverAnsweredIsGivenUpOn` — `Expectation failed: (deadline.durations.count → 0) == 1`。

**说法**：测试一看到请求发出就去数计时器，同一轮里模型的计时器还没**开始**，数到 0。第 2 条修的是「放行」，这条是「数」，早了一步。

**重现**（`repro-3.patch`）：计时器固定成「晚一步开始」。旧测试失败：`deadline.durations.count == 1` 不成立；按现在的写法（先等计时器就位再数）的两条通过。
CI 的附言里显示 `[12.0 seconds]` 而本机是 `[]`：CI 上计时器线程恰好在「判断条件」和「拼附言」之间的几微秒里记下了时长；本机是把开始推迟到测试这一轮之后，所以附言是空的。两者说明的是同一个空档。

**反向验证**：同第 2 条，去掉「超时后放弃」后这条也失败。

**这一轮还修了同一类的一处**（`LikeConvergenceRegressionTests` 约 572 行）：之前我判断它「已经安全」，复核发现不对——它也是在同一轮里数计时器。现在改成有时限地等到计时器出现再数。

## 4. 编辑资料「连点两下只保存一次」 · run 35933245850（`5baad70`）

**CI 原话**：`twoTapsInTheSameTurnSaveOnce` — `Expectation failed: (users.updateCalls.count → 2) == 1`。

**说法**：两次保存没有重叠。假服务端瞬间返回，慢机器上第二次保存开始时第一次已经做完了，写两次是对的。
`EditProfileModel` 在主线程上，检查和置位之间没有让出，只有「不重叠」才可能写两次。

**重现**（`repro-4.patch`）：把「第二次在第一次做完之后才开始」固定下来。旧测试每次都失败：写了 2 次。

**我上一次的修法削弱了测试，这一轮补上**：`bc01248` 让第一次保存停在服务端、确认它在进行中再点第二下。
这保证了重叠，但第二下落在第一次**已经置位之后**——如果 App 的检查和置位之间有一次让出（变异 4），这条测试照样通过。
也就是说它不再能发现原本最该发现的那种缺陷。
**补法**：新加 `aSecondTapAtTheFirstSuspensionWritesNothing`，第二下落在第一次保存**第一次让出**的那一刻。变异 4 下它失败（写了 2 次），正常代码下通过。
原来那条保留（它测的是「保存进行中再点」）。

---

## 共同的根：用「让出次数」当超时

这几处测试原来用「最多让出 N 次」来等某个条件。等的东西在别的线程上跑时，让出次数和时间没有关系：
快机器上 N 次够，慢机器上不够。这一轮把单元测试里这类等待都换成**按时钟计的时限**
（`PetNoteAppTests/Eventually.swift`：`eventuallyTrue` 在主线程上等，`eventuallyTrueAnywhere` 给别的线程上的条件用），
用到的地方：点赞、社交、评论删除、编辑资料的测试，以及 `ManualDeadline.waitUntilArmed()`。

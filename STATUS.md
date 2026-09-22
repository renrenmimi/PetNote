# PetNote Swift 客户端 · 状态表

这是**唯一**的状态表。每批工作收口后更新这一份，不另写过程总结。
审查目录里的 `evidence/ios-native/acceptance-status.md` 是**第一阶段验收矩阵**（按
`SWIFT-CLIENT-ACCEPTANCE.md` 条目编号记证据），不是状态表；功能迁移进度只记在这里。

**更新** 2026-09-22（下午）· 分支 `feature/ios-native-prototype` · PR [#204](https://github.com/renrenmimi/PetNote/pull/204)（Draft，不合并）

---

## 功能迁移清单（旧版用户侧功能 → Swift）

范围来自旧版 `src/pages` 的 28 个页面与其组件，按旧代码核对，不按印象。
`AdminPanel` 是管理端，不在用户侧迁移范围内。**不换算成百分比。**

**等级**（只记已达到的最高一级，不跳级）
① 未实现 · ② 模型验证通过（单元测试，不经界面）· ③ UI 验证通过（隔离模拟器 + emulator，真实界面操作）·
④ 与真实测试后端联调通过（`petnote-devtest`）· ⑤ 真机验证通过（带版本）· ⑥ 外部阻塞或明确延期

「界面已接入」**不是一个等级**：它只说明入口存在、页面能被点到，不说明任何流程被验证过。
UI 测试里的上传一律走**本地替身**（`ios-native/scripts/upload-standin.py`，仅 Emulator 构建可切换），
不是真实 Cloudinary；emulator 里翻转验证位**不是**真实邮件往返。这两条在任何一级都不会被写成已通过。

### 账号

| 功能 | 等级 | 证据 / 环境 | 未验证、阻塞 |
| --- | --- | --- | --- |
| 邮箱密码登录 | ⑤ @`4ba1c57` | `AuthUITests`（emulator）；真机 TESTCLOUD | 当前候选版待真机回归 |
| 冷启动恢复会话 | ③ | `testColdStartRestoresTheSessionWithoutShowingSignIn` | — |
| 退出登录；换账号无残留 | ③ | `testSignOutReturnsToSignIn`、`testTheNextAccountInheritsNothingFromTheLastOne` | 新 Tab 壳下的残留未重跑 |
| 会话被吊销 | ③ | `testARevokedSessionEndsTheSessionAndGivesTheScreenBack` | — |
| 注册（显示名唯一） | ③ | `JourneyUITests`（emulator，真实界面操作）；`AuthSignUpTests`、`UserAccountTests` | 名字并发抢占只有服务端事务保证，客户端预检不算 |
| 邮箱验证状态 | ③ | `JourneyUITests`：未验证账号出现横幅，服务端置为已验证后点「I've verified」横幅消失 | **是在 emulator 上翻转状态，不是真实邮件往返**；真实邮件 ⑥ |
| 忘记密码（链接方式） | ② | `AuthPasswordResetTests` | UI 未验；真实邮件 ⑥。验证码重置**有意不接**（生产未配置） |
| Google 登录 | ① → ⑥ | 旧版 `contexts/AuthContext.tsx` 使用 | 需要测试项目的 iOS OAuth 客户端，**待授权** |

### 资料与设置

| 功能 | 等级 | 证据 / 环境 | 未验证、阻塞 |
| --- | --- | --- | --- |
| 首次引导 | ③ | `JourneyUITests`：新账号出现引导，改名后服务端 `displayName` 与 `onboardingComplete` 均已写入 | 「跳过」是否该写入名字仍是产品决定 |
| 个人主页 | ③ | `JourneyUITests`（经「我的」Tab） | 旧版的「已收藏」「签到」两个分栏 ① |
| 编辑资料 / 头像 | ③（简介）/ ②（头像） | `JourneyUITests`：改简介，页面与服务端一致 | 头像换图 UI 未验 |
| 我的宠物列表 | ③ | `JourneyUITests`（Add a pet 入口）。旅程测试发现容器标识符覆盖了按钮的标识符，已修 | 多只宠物、刷新失败的界面状态未验 |
| 设置页（通知偏好、深色、语言、位置、改密码） | ① | 旧版 `Settings.tsx` | 第 5 批 |
| 中文界面 | ① | 旧版支持 en / zh（默认 en）；**Swift 全部是英文硬编码** | 横跨所有页面，未排批次 |
| 注销账号 | ① | `Callables.deleteUserAccount` 已登记，无调用 | 第 5 批；共享宠物的处理照服务端规则 |
| 屏蔽用户 / 屏蔽列表 | ① | 旧版 `BlockedUsers.tsx` | 第 5 批 |
| 举报 | ① | 旧版 `ReportModal.tsx` | 第 5 批 |
| 联系我们、隐私政策、服务条款 | ① | 旧版 `ContactUs` / `PrivacyPolicy` / `TermsOfService` | 第 5 批 |
| 账号被封提示 | ① | 旧版 `SuspendedBanner.tsx` | 第 5 批 |

### 宠物

| 功能 | 等级 | 证据 / 环境 | 未验证、阻塞 |
| --- | --- | --- | --- |
| 创建 / 编辑宠物 | ③（创建）/ ②（编辑） | `JourneyUITests`：建宠物后服务端有这只宠物，创建者在它的 family 里 | 编辑宠物、宠物头像 UI 未验 |
| 宠物主页 | ③ | `JourneyUITests`：保存后打开新宠物的主页 | 帖子/签到分栏 UI 未验 |
| 删除宠物（最后一位主人） | ② | `PetOwnershipTests` | UI 未验；多主人时由服务端拒绝，客户端只按 `isPrimary` 决定显示 |
| 关注 / 取消关注、关注列表 | ② | `SocialFollowTests`、`SocialListsTests`、`SocialCallableErrorTests`；界面已接入宠物页和「我的」 | UI 未验 |
| 共同主人：邀请、兑换、撤销、移除、退出、转让 | ② | `FamilyInviteTests`、`FamilyManageTests`、`FamilyCallableErrorTests`；界面已接入：宠物页「Owners & invites」、「我的 → Join a pet's family」 | UI 未验；两个账号互相邀请的旅程还没写；授权规则没改 |
| 生日庆祝、宠物聚光 | ① | 旧版 `BirthdayCelebration` / `PetSpotlight` | 未排批次 |

### 内容

| 功能 | 等级 | 证据 / 环境 | 未验证、阻塞 |
| --- | --- | --- | --- |
| Feed、刷新、分页 | ⑤ @`4ba1c57` | `RefreshAndPagingUITests`、`NavigationUITests`；真机中文内容 | 当前候选版待回归 |
| 帖子详情、返回位置 | ⑤ @`4ba1c57` | `NavigationUITests` | 可中断返回的两个细节真机未确认 |
| 图片、全屏看图 | ③ | `ImageUITests` | 真机未专项验 |
| 视频播放、断流恢复 | ⑤ @`4ba1c57`（播放） | `VideoPlaybackUITests`；断流恢复只到 ③。`08c1105` 上 CI 的 3 条红：测试写死了字节范围，CI 渲染的测试视频长度随 runner 变化（测试代码相同，`0867749` 上又通过了）；已改成先问夹具要长度（`14ddb6d`），本地 52/52 | 断流恢复真机未验 |
| 点赞 | ⑤ @`4ba1c57` | 真机 `Like/0 → Unlike/1`，云端 `counted=True`；`LikeUITests` 在 Tab 栏下 7/7（`98bd1b7`） | 此前那条失败已查明：点击落在离屏幕底边 3.7pt 处，App 没收到，不是点赞逻辑的问题 |
| 评论（写） | ⑤ @`4ba1c57` | `CommentUITests`；真机中文输入 | — |
| 删除自己的评论 | ① | `Callables.deleteComment` 已登记，无界面 | 未排批次 |
| 收藏 | ② | `PostWriteManageTests` · 详情页菜单 | UI 未验；「已收藏」列表 ① |
| 发帖（图片 / 视频、选宠物、标签） | ③（图片，**上传替身**） | `JourneyUITests`：系统相册选图 → 带签名的 multipart 上传到本地替身 → `createPostCallable`（emulator 里 URL 校验真实执行）→ Feed 第一条就是它；服务端的 `authorId`、`petId` 和媒体 URL 都核对过 | **不是**真实 Cloudinary（替身不校验签名，返回的 URL 在 CDN 上不存在，所以图片不显示）；视频、标签的 UI 未验；**真实 Cloudinary 待授权** |
| 发帖草稿 | ② | `ComposeDraftTests` | UI 未验 |
| 发帖滤镜 | ① | 旧版 `ImageFilter.tsx` | 未排批次 |
| 编辑 / 删除 / 置顶自己的帖子 | ③（编辑、删除）/ ②（置顶） | `JourneyUITests`：编辑后详情页不重进就显示新文字，服务端已更新；删除后回到 Feed、帖子消失、服务端文档不存在 | 置顶 UI 未验；删除失败的提示 UI 未验 |
| 分享 | ① | 旧版 `ShareMenu` / `ShareCard` | 未排批次 |
| 搜索、话题、发现 | ② | `SearchModelTests`、`SearchExploreTests`；界面已接入首页顶栏搜索 | UI 未验 |
| 他人主页 | ② | `UserProfileModelTests`；从搜索、粉丝列表进入，链接 `/profile/<uid>` | UI 未验 |
| 通知列表、全部已读 | ① | 旧版 `Notifications.tsx` | 第 5 批；推送旧版没有 |

### 地点与聚会（第 4 批，均 ①）

地点列表、地点详情、添加地点、地点照片、签到、评分评价；聚会列表、详情、创建、编辑、取消、报名。
旧版底部导航是 首页 / 地点 / 发布 / 聚会 / 我的，**Swift 目前只有 首页 / 发布 / 我的**，另两个 Tab 等功能做完再加，不放空 Tab。

---

## 真机验收断点（主人已拔线离开）

真机自动化、截图、安装、启动、连接重试**全部已停止**。不再查询设备。

| 项 | 状态 |
| --- | --- |
| 手机上已安装 | `dev.local.petnote.native` **0.1**，来自 commit `4ba1c57` |
| 旧 App | `dev.local.petnote` **1.0**，**未被触碰**，数据完整 |
| 连接的后端 | `petnote-devtest`（云测试项目），徽标实测 `TESTCLOUD · petnote-devtest` |
| 描述文件 | **2026-09-25 到期** —— 届时需重新生成，**这不是项目损坏** |

### 真机上已经验过的（有证据）

| 项 | 证据 |
| --- | --- |
| 环境校验 | 徽标 `TESTCLOUD · petnote-devtest` |
| Feed | 中文内容正常显示 |
| 点赞 | UI `Like/0 → Unlike/1`；云端 `likeCount=1`、`counted=True` |
| 评论 | UI 出现；云端逐字找到该条文本 |
| 视频 | `state=picture playing=true size=854x480 advanced=true` |
| 评论计数同步（Feed） | `1 → 2`，刷新后仍 `2` |
| 评论计数同步（详情页） | `5 → 6`，半秒内到位 |
| 中文输入 | 主人手动确认：键盘无遮挡、发送成功、出现在详情页 |

### 真机上**未**验的

| 项 | 为什么 |
| --- | --- |
| 可中断返回手势（中途取消、草稿保留） | 主人只确认「手势可用」，**这两个细节未确认** |
| VoiceOver | 主人未给出结果 |
| 启动/帧率/内存/发热 | 需 Instruments + 真机 |
| 静音时别的 App 音乐是否真的不中断 | 模拟器给不出这个结论 |

---

## 本轮缺陷分类（按主人要求区分四类）

| 类别 | 条目 |
| --- | --- |
| **用户发现的真实缺陷** | ① 发完评论返回 Feed 仍显示旧计数 ② 详情页自身的评论计数也不动 |
| **实现修复** | 两处都是页面间状态未同步，复用点赞的收敛模型修复 |
| **测试读得太早 / 测试辅助自身失败** | ③ 我的真机用例在 `send` 点下后立刻读计数，读到写入前的值，**误报成「没修好」** ④ 存储密码弹窗辅助在「检查存在」与「点击」之间竞态，把别的测试判成失败 |
| **尚未验证** | 可中断返回的两个细节、VoiceOver、真机性能 |

**③ 不改变 ① 和 ② 的性质**：主人原先发现的缺陷是真的，后端查证过计数与文档一致（触发器早已运行），是客户端两块屏幕各自持有写入前的快照。

---

## 未提交改动（HEAD = `f947da0`）

> **已过期（2026-09-22）**：下面列的改动早已提交（`f947da0` 之后的提交），当前分支顶端和未提交内容以 `git log` / `git status` 为准。保留原文作为当时的记录。

上一批 8 个改动文件已全部提交，落成 `0e81c59`…`f947da0` 六个 commit。
当前工作区是**第二批，三个 agent 正在并行写**，所以这份清单随时在动：

```
M  Core/Media/VideoPlayerView.swift            断流状态机（agent 在改）
M  Core/Media/VideoPlaybackCoordinator.swift   同上
M  PetNoteAppTests/FeedViewModelTests.swift    刷新/分页失败（agent 在改）
M  PetNoteAppTests/PostDetailViewModelTests.swift  同上
M  PetNoteAppUITests/HitRegionBoundaryUITests.swift 触控区探针修复（agent 在改）
M  PetNoteAppUITests/TouchTargetUITests.swift  同上
M  scripts/a2-*                                可控媒体服务（agent 在改）
M  PetNoteAppUITests/VideoPlaybackUITests.swift  我：补两条导航断言
?? PetNoteAppTests/ClaimGuardTests.swift        我：名字≠断言的守卫
?? scripts/with-build-lock.sh                   我：构建锁
```

**待办**：三个 agent 收工后跑全量回归，确认无回退再提交。

---

## 收口结果（2026-09-21 晚）

**候选 commit `c955449`**，7 个提交已推送，未 force push，Draft PR 不合并。

### CI

`c955449` 上 `ci` 与 `ios-native` 两个工作流**均通过**。

### 本地全量回归

| | 结果 |
| --- | --- |
| 单元测试 | 280 条，**1 条间歇性失败** |
| 界面测试 | 90 条，7 条跳过，**2 条失败** |

界面从本批初次运行的 6 条失败降到 2 条。剩下两条：

1. `testTheInstrumentAgreesWithTheKnownGeometryOfTheFeedActionRow`
   —— 触控仪器校准未通过，**故意保留为红**。详见下文与验收矩阵「第五次」。
2. `testEachOutcomeIsReachable`
   —— `Failed to synthesize event: Timed out while synthesizing event`。
   **不是断言失败**，是自动化框架在高负载下合成触摸事件超时；同一条在当日
   早些时候的运行中通过（36.7 秒）。

### 那条间歇性单测，按观察记录而不是按结论记录

`ImageLoaderBehaviourTests.aRowScrollingAwayDoesNotCancelTheRowBesideIt`
断言「一行滚走时，旁边那行还需要的共享下载不能被取消」。

| 环境 | 结果 |
| --- | --- |
| CI（干净机器） | 通过 |
| 本机全量单测（当日早些时候） | 通过 |
| 本机最终全量回归 | **失败** |
| 本机 8 次连续重复 | 全部通过 |

**11 次观察失败 1 次，原因未查明。** 不写「偶发」：那是一个结论，
而「还没找到原因」是另一个。本轮已经因为混淆这两者错过一次
（把「一次都没采样到」当成「每次采到的都是空」）。建议单独排一轮。

**期间我自己踩了一次本轮一直在防的坑**：第一次测量的过滤器写的是**文件名**
`ImageLoaderTests`，而 Swift Testing 按**类型名**匹配（`ImageLoaderBehaviourTests`），
于是一条都没跑，xcodebuild 照样报 `** TEST SUCCEEDED **`。
按退出码读就会写成「8 次全过」。重跑时先核对「这条实际跑了几次」，
为 0 直接判结果无效。

### 真机候选包审计：`--release-check` 退出码 0

| | |
| --- | --- |
| 1 BUILD | **PASS** |
| 2 SIGN | **PASS**（`codesign --verify --strict` 通过，主人手机在描述文件里） |
| 3 INSTALL | TODO —— 设备 `unavailable`，脚本从不代为声称 |
| 4 LAUNCH | TODO —— 同上 |

诊断代码的闭环证据：

```
[PASS] control yields 19 distinct switch tokens - the scan reaches Swift code
[PASS] 0 of 11 fault-injection switches are in the device package
[PASS] Release device package: 0 test switches, with a control that finds 19
```

**第一行是第二行成立的前提**：先证明扫描器确实扫得到 Swift 里的开关（找到 19 个），
「0 个故障注入开关」才是真的零，而不是扫描器没工作。

真机包仍带 8 个只读探针 token，这是 `Debug-TestCloud` 应有的——
真机验收要靠它们取证。必须为零的是 Release 包，已实测为零。

两条 WARN 记下来不掩盖：包里还带着 `GoogleService-Info-Emulator.plist`
（`PROJECT_ID=petnote-test`，emulator 配置，非生产密钥）；
描述文件 **2026-09-25 到期，还剩 3 天**，届时重新生成即可，不是项目损坏。

---

## 第二批（四个缺口）的实际结果

三个并行 agent 在 15:3x 全部因会话额度中断，之后由我接手。以下是**我独立核对过代码与日志**得出的，不是转述它们的自述。

### 1. 视频断流 —— 已实现，并在复核中发现一个真缺陷

状态机九个，阈值集中在 `VideoStallPolicy`，每个默认值都有论证（0.6s 出反馈取
Nielsen 1s 界限之下、0.1–0.3s 噪音带之上；重试 1.5/4/9s 三次封顶）。
界面上**只有 `.stalled` 会画东西**，`.pausedByViewer` / `.suspended` /
`.waitingItsTurn` / `.ended` 都不画——「暂停、离屏、切后台不误报错误」成立。
恢复时不改静音（`entry.player.isMuted = isMuted`，沿用用户的选择）。

**复核时发现的缺陷：重试上限实际上不生效。**

`automaticRecoveryIsBoundedAndThenOffersAWayOut` 连续两次在 60 秒后超时，
最后状态 `phase=playing attempts=1`。病因是两个常量互相打架：

| 常量 | 值 | 作用 |
| --- | --- | --- |
| `rebuildItem` 的 `toleranceBefore` | **`.positiveInfinity`** | 恢复后 seek 回断点**之前**，落点无下界 |
| `healthyProgressToRefundBudget` | 3.0s | 播够这么久就退还一次重试预算 |

注释写的是「落在断点或之前，绝不之后」——理由正确（后面的字节正是缺失的那段），
但「之前」没有下界，包含**文件开头**。16 秒测试素材在 35% 处断流，
于是一次恢复重播了整个完好的 5.6 秒，远超 3 秒阈值，
**每一次失败的恢复都把预算还给了自己**，「三次之后问用户」变成了死循环。

改为 `recoverySeekToleranceBefore = 1.5`（不到退还阈值的一半），
并加了一条算术不变式测试 `recoverySeekLandsInsideTheRefundWindow` 钉住这层关系——
集成测试要一分钟才失败，且只会说「超时」，不会说是哪两个常量不再相容。

**另一处：VoiceOver 分不清「在播」和「卡住」。** 标签只有 `Video` /
`Video, not playing` 两种，断流落进第一种；说明卡顿的那个转圈是
`accessibilityHidden(true)`，而状态字符串只在探针模式下填。
也就是说在出现重试按钮之前的 10 秒里，VoiceOver 用户什么都得不到。
已加第三种标签 `Video, stopped loading`。**这一处目前没有测试覆盖**，
记为已实现·未验证。

### 2. 刷新与分页失败 —— 已实现

九条单测用 `FakeFeed` 测试替身，四条真机 UI 测试
（`RefreshAndPagingUITests`）用确定性启动参数驱动真实界面，两套证据分开记。
不靠固定延时等网络变慢——正面回应了「emulator 只有 90ms 复现不了」。

`PostDetailViewModel` 修了三个缺陷：

1. 刷新不再先清空列表。在 emulator 上那段空白只有 90ms 所以一直没人发现，
   真实网络下它的长度就是整个往返，且刷新失败时会停在空白并说「加载失败」，
   说的是它自己刚扔掉的那些评论。
2. 刷新改为**替换**而非合并——否则服务端已删除的评论会成为唯一永远删不掉的东西。
3. 失败时释放已用游标。**没有这一条，重试按钮按下去是静默的空操作**：
   它撞进自己的重入保护，返回时什么也没做，界面停在转圈。
   Feed 的分页路径从一开始就释放了，详情页这条从来没有。

### 3. 触控区 —— **不交付数字，工具未通过校准**

按要求先用已知尺寸的对照组验证工具。**两轮都没通过**：

| 轮次 | like 按钮实际 48.33 × 44 | 结论 |
| --- | --- | --- |
| 14:48 | 高 `[28.1, 28.8)`、宽 `[0, 0.54)` | 塌缩成一个点：左右边界都落在 40.167，正是水平中心 |
| 17:0x（修过探针后） | 高 `[61.9, 62.5)`、宽 UNRESOLVED | 反过来高估约 40% |

二分搜索算法本身是对的——合成探针（纯函数，真值 18/44/60/44.165）那条一直通过，
且 44.000 正确地报 UNCONFIRMED。坏的是**探针判定「这一下是不是命中了目标控件」**。

读代码可以排除「对照组期望值错了」这个可能：like 按钮的 `contentShape(.rect)`
套在 `.frame(minWidth: 44, minHeight: 44)` 上，命中区就应当等于无障碍 frame。

所以按你定的规矩——工具没通过校准就不去量核心控件——**本轮不产出任何触控区数字**，
上一轮 02:23 那批旧数据也不冒充成本轮结果。那条对照组测试留在树里红着，
它是这条线唯一真实的产出。

### 4. 验收记录 —— 已按版本重写

见 `evidence/ios-native/acceptance-status.md`。要点：中文输入恢复为
**真机通过 @`4ba1c57`**（主人亲自确认），`f947da0` 标**当前候选版待回归**并写明
待回归的具体范围；返回手势拆成「手势可用（通过）」与「中途取消/草稿保留（未验证）」
两行，不外推；VoiceOver 改为「主人未给出结果」。

---

## 诊断代码与真机包：`#if DEBUG` 挡不住

问构建系统核实的四个配置：

```
Debug-Emulator  → DEBUG PETNOTE_FAULT_INJECTION
Debug-Prod      → DEBUG PETNOTE_READ_ONLY
Debug-TestCloud → DEBUG PETNOTE_TEST_CLOUD      ← 装到手机上的就是这个
Release         → PETNOTE_READ_ONLY
```

`Debug-TestCloud` 是 Debug 配置，所以 `#if DEBUG` 里的东西**会进真机包**。
11 个故障注入开关（让刷新失败、让读卡住 8 秒、让某页丢失）本来都在那里面。

拆成两类门：只读探针留 `#if DEBUG`（真机验收要靠它们取证），
故障注入改用新的 `#if PETNOTE_FAULT_INJECTION`，只有 Debug-Emulator 定义。

**并且不靠读源码相信**：`scripts/fault-switches.sh` 从源码里自动读出落在该门后的
字面量清单（现为 11 个），包审计断言它们在真机包二进制里一个都不存在。
提取器用五种情形的对照组验过（无门不计、嵌套 `#if DEBUG` 内计、`&&` 组合式计、
`!` 取反不计）。清单为空时报 FACT 而非 PASS——**找不到东西的扫描不算证据**。

两条方向相反的守卫钉住配置：非 Emulator 配置不得定义该条件；
Emulator 必须定义（否则所有故障注入测试会**因为故障根本不会发生而通过**）。

### 顺带修的两个真缺陷

- 包审计脚本在开关扫描**因缺对照组而没得出结论**时仍 `exit 0`，
  正文写着「不报告为干净」而退出码说「干净」。现在无结论 `exit 2`。
- CI 只断言执行数 ≥1，挡得住「一个都没跑」，挡不住「265 个只跑了 3 个」。
  加了下限 `FLOOR=240`，并写明是下限不是精确值。

---

## 「测试名称不能代替业务证据」：全量审计结果

起因是主人点出的一条：`testThirtyVideosInARealListNeverExceedTheCeiling`
被我当作「滚动不误触导航」的证据，但它只断言了播放器数量上限，
**通篇没有任何关于导航的断言**。名字带着一个承诺，断言没有兑现，
而被读走的是名字。

### 已修

| 用例 | 补了什么 |
| --- | --- |
| `testThirtyVideosInARealListNeverExceedTheCeiling` | feed 导航栏仍在、无 `Post` 栏、无 `composer.field` |
| `testFlingingPastVideosStaysWithinTheCeiling` | 同上（快速滑动最容易误触，同一形状） |

### 全量扫描：340 个测试，0 条「只有名字没有断言」

扫描器剥掉注释与字符串字面量后解析 `@Test` 与 `func test…()` 两种方言，
判定「一条断言都没有」的用例。**只有三种情况可以没有断言，且必须显式声明**：
名字以 `record` 开头的记录器、断言在会 throw 的 helper 里、显式 skip。

工具本身做了对照验证，因为这一轮它骗了我两次：

1. 第一版用 XCTest 的 `func test…` 模式扫单元测试，解析到 **0 个**测试，
   于是报告「0 条可疑」。单元测试用的是 Swift Testing（`@Test` + `#expect`），
   258 个一个都没解析到。**一个什么都没解析到的解析器，永远报 0。**
2. 第二版修好解析后报「0 条红」。往真实文件里注入一条零断言测试，
   **它仍然报 0** —— 中间那版生成脚本时转义套多了一层，正则变成了字面量。

第三版通过注入对照：340 → 341 个测试，注入的
`theCeilingIsNeverExceededUnderLoad` 被抓到，还原后回到 0。

3. **然后注入对照自己也漏了一个。** 加了一条元检查（白名单里的 helper
   必须自己判失败）之后，它指控 `TestVideoFixture.waitUntil` 不判失败——
   而那个 helper 正是整条规则围绕着写的，它明明 `throw WaitedTooLong`。
   真正的原因是解析器：`waitUntil` 的参数里有个默认值闭包
   `describe: @escaping () -> String = { "" }`，取「函数名之后的第一个 `{`」
   咬住的是那个闭包，函数体被读成了两个字符 `""`。
   **凡是带默认闭包参数的函数，全都被读错了。**
   而第 2 步的注入对照没发现，因为我注入的那条签名很普通，
   走的是本来就好用的那条路径。

改成「跳过参数列表后的第一个 `{`」，并补了一条专门钉这个形状的对照。
重新注入两种形状（带默认闭包的零断言测试、同名但不判失败的 helper），
两条都被抓到，还原后回到 0。

**先证明工具抓得住，再相信它给的零。** 这一轮它骗了我三次，
每次都是「0」看起来像结论、实际是仪器没工作。

这套规则已经钉成 `PetNoteAppTests/ClaimGuardTests.swift`，
含 4 条正/负对照和 2 条解析器自身的对照，下一个新测试犯同样的错会直接红。

### 顺带查出的一个真隐患：同名 helper，失败语义相反

白名单按**名字**匹配，而名字不是函数。查下来项目里有三个 `waitUntil`：

| 定义 | 超时行为 |
| --- | --- |
| `TestVideoFixture.waitUntil` | `throw WaitedTooLong` → 测试红 |
| `ImageLoaderTests.waitUntil` | `Issue.record(...)` → 测试红 |
| `TouchTargetUITests.waitUntil` | **只 `return false`** → 测试不红 |

还有两个 `signIn`：`SessionFlow.signIn` 断言「到达 feed」，
`DeviceAcceptanceUITests.signIn` 什么都不检查。

调用第三个 `waitUntil` 而没检查返回值的测试，就是一条永远不会失败的测试，
而守卫会凭「另外两个同名的都判失败」把它放行。两处都已改名：
`becomesTrue(within:)`（touch agent 改）、`typeCredentialsAndSubmit`（我改，
5 处调用同步更新）。元检查现在会保证白名单上每个名字的**所有**定义都判失败。

### 顺带查清的两条「零断言」，都是合理的

- `theSessionIsAmbientBeforeTheFirstFrameIsShown` —— 断言在 `waitUntil` 里，
  它超时会 `throw WaitedTooLong`。已核实该 helper 确实 throw 而不是静默返回
  （本项目出现过 helper 把「查询被拒」吞成「零结果」，让四条断言保持绿色）。
- `recordTheDisabledSubmitButtonRatio` —— 自己的注释就写着「不是断言，是记录」。
  禁用态控件不在 WCAG 1.4.3 范围内，没有阈值可断言。

---

## 状态一致性：独立复核找到 6 个缺陷，全部在我建的收敛机制里

**「正常路径真机通过」不等于「并发正确」——这一条被证实了。**

十种确定性交错，用「在一次读取尚未返回的窗口内执行写入或第二次刷新」构造，
**零 sleep、零重复采样**。

| # | 缺陷 | 根因 | 改前实测 |
| --- | --- | --- | --- |
| A | 分批收敛**重复加一**（两屏都有） | `hasCaughtUp` 全有全无，而 `snapshotCount` 每次读取重新取基准；聚合分批到账时，已到账的那一半既在服务端数字里又留在偏移里 | 显示 8、9，真值 7 |
| B | 切号后**上一个人的 +1 留给下一个人** | `prepare(for:)` 清了 `likeStates`，漏了紧挨着的 `commentStates` | 显示 1，应 0 |
| C | 帖子被删后**偏移残留** | `.postNotFound` 移除行时没清偏移，同 id 再出现时带回来 | 显示 1，应 0 |
| D | 详情侧偏移**无上限** | 规则只有「数字变了就整个丢弃」，数字不变时永远丢不掉 | 整屏生命周期恒定多 1 |
| E | 结果未知但**查证已落地时不计数** | `settleUnknownOutcome` 只改措辞，没把查证到的写入升格为已确认 | 显示 2，应 3 |
| F | 评论缺少**写/读定序** | 旧的 `writeSequence` 只保护点赞；早于写入的读取会白白耗掉偏移额度 | 1 → 1 → **0** |

**B、C、D 是我亲手引入的。** A 同时适用于点赞，只是正常路径上看不出来。

修法：`absorbed(moved:owed:)` 按实际移动量**部分抵扣**，同向取 `min(|moved|,|owed|)`。
四行算术，两屏各一份，用参数化对照测试（同一串读取序列两屏必须同答）防止分叉——
**没有为消除四行重复去建通用框架**。

### 主人点出的两个疑点，实测结论

1. **方向/幅度证明不了是我们的** —— 属实，**后端契约下无解**。`commentCount` 是一个
   无出处、无版本的整数。他人评论先落地时我们的 +1 被误判为已收敛，该次读取少显示 1，
   下次自愈。**这是设计边界，不是缺陷**，已写进代码注释。
2. **三次读取可能都是旧值** —— **真的会错误丢弃偏移**，两种失效方式见上表 D 和 F。

### 后端契约下做不到的

聚合与文档写入**非原子**，聚合值无出处无版本，因此**只能最终一致**。
采用的边界：临时显示 = 权威读数 + 本机已确认写入的差额；重新核对 = 每次读取按实际
移动量部分抵扣；失败恢复 = 同向无移动累计 3 次后放弃偏移，以服务端为准。
**不声称严格实时准确。** 根治需要后端在聚合旁给出写入水位或让计数可溯源——未做。

### 仍未验证

- 全部结论来自模拟器单测 + 假仓库，**不等同于真机通过**
- emulator 端的 `CommentUITests`（真实触发器端到端）未跑
- 删除评论方向（delta −1）：代码支持，但**产品里没有删除评论入口**，无真实调用路径
- `refreshLikeState()` 在 app 内**无调用方**（只有一条单测覆盖）

---

## 媒体：三个用户能看见的缺陷

| # | 症状 | 根因 |
| --- | --- | --- |
| ① | **滚开的图回来永远挂着「Tap to retry」** | 取消时 URLSession 抛 `URLError(.cancelled)`(-999) 而非 `CancellationError`，只认后者 → 每次滚动取消都落进 `failed = true`；`failed` 是 `@State`，行回来还在，且 failed 分支没有 `.task`，好照片永远显示重试 |
| ② | **全图页显示的是中心裁切** | `FullImageView` 向 `RemoteImage` 要 `aspectRatio: 1` → 正方形框 + `scaledToFill` → 4:1 和 1:4 的照片各自只剩中间一块，捏合只是放大这块裁切 |
| ③ | **feed 里点喇叭会打开帖子，不会取消静音** | `MediaView` 外套 `.onTapGesture` 吞掉里面按钮的点击 |

③ 的定位方式值得记：测试看着像「切换没生效」，日志显示点击那一刻
`video: released all (navigated away)`——**人已经在另一屏了**，详情页画的是同一个
`video.mute`。而定位靠的是先修好 `a2-playback-log.sh`：它此前 UDID 用 `$2` 解析
（"iPhone 17" → "17"），且 info 级日志不落盘，**取不到它存在的理由那些行**。

### `PostCard` 的容器手势吞点击：第三次

1. 点赞按钮（`.buttonStyle(.borderless)` 解决）
2. VoiceOver 打不开帖子
3. 喇叭按钮 —— **而注释里就记着前一次**

同一个文件、同一个形状、三次。这不是「又一个 bug」，是这个布局的结构问题。

### 断流：零覆盖，且按代码读不会有任何反馈

播一半流断掉时 item 仍 `.readyToPlay`、播放器停在 `waitingToPlayAtSpecifiedRate`，
而 `markFailed` 只在 `status == .failed` 触发 —— 那一行会举着最后一帧、**无提示无重试**。
**正是上一轮被误判的形状。** 判它坏掉需要「卡住超过 N 秒」的规则，
**N 是产品决定**，未自行设定。

---

## 独立验收：我的触控区测量装置本身有缺陷

三个**在 App 里根本不存在**的标识符被测试引用：`full.close`（真名 `fullImage.close`）、
`image.full`、`detail.root`。后果不是笔误 —— 详见 `acceptance-status.md`，
**所有触控区区间已降级为未确认**。

其余无效证据：
- `CommentUITests` 的刷新用例**分不清「刷新正确」和「根本没刷新」**（四条断言在手势完全没触发时全部照样成立）
- 分页用例里「已在屏上的评论不许动」**基本不执行**（锚点滚出窗口就整条跳过）
- `detail.commentsError` / `detail.commentsRetry` 失败态**无人到达**（三个注入开关都作用在*发送*路径，没有「评论加载失败」的注入点）→ 记**尚未验证**，非缺陷
- **`EmulatorAdmin` 把「查询被拒绝」和「一条都没有」折叠成同一个答案** —— 把 `op` 改成 `"BOGUS"`，4 个 `equals: 0` 的用例仍然全绿。**已修**：`post()` 和 `get()` 现在检查状态码

新增守卫 `TestHygieneTests`（扫「两次遍历会动的树」，普查出 **24 处存量**，
4 条阳性对照 + **4 条阴性对照**）和 `IdentifierGuardTests`（标识符必须在 App 里存在）。

---

## 交互走查：三个用户能看见的缺陷，加三个已加固但未验证的

### 改前红、改后绿（有完整证据）

| # | 症状 | 备注 |
| --- | --- | --- |
| ① | **账户菜单里唯一能点的控件就是结束会话那一个** | 点背景不关，出口只有拖拽。加了 `account.close`（44pt） |
| ② | **详情页的评论数按钮是死控件**（`onOpenComments: {}`） | 见下 |
| ③ | **feed 里点喇叭会打开帖子** | 见下 |

**② 的前两次修法都被实测推翻**：内联写 `composerFocused = true`、以及延后一拍的
`Task { @MainActor }` —— 键盘 19/20 次读数全是 down，**SwiftUI 吞掉了那一轮更新里写的
`@FocusState`**。最终改成「滚到评论区」，效果可测：`minY 752.7 → 132.3`。

**③ 是两层的。** 我派任务时只说了「去掉 `MediaView` 外层的 `.onTapGesture`」——
实测不够，卡片 `content` 外面**还有一层** `.contentShape + .onTapGesture` 也盖着播放器。
所以「容器手势吞子按钮」这个形状在同一个文件里叠了两层，我的指示只覆盖了看见的那层。

### 读代码找到、已修、**模拟器复现不出**（记为已加固·未验证）

| # | 症状 | 为什么复现不出 |
| --- | --- | --- |
| ④ | Feed 刷新/刷新失败会**丢掉已加载内容** | 本地 emulator 往返比一次 XCUITest 查询还快，第一个采样点 0.09s 已稳态。**空白多长等于往返多长，手机上不是 90ms** |
| ⑤ | 详情页翻页失败会**抹掉已读的前几页** | 仓库的 fault 注入只覆盖 `create`，**没有手段造出这个场景**，未为此新增注入点 |
| ⑥ | 同卡两连点可能 push 两个详情页 | 加守卫前该用例就是绿的，属**硬化**不属修复 |

### 提出后被实测推翻、已撤回

怀疑 `.disabled(model.isSending)` 挂输入框上会导致每次发送收走键盘 ——
**不成立**，`keyboard after send: ["up" ×8]`。改动撤回，测量写进注释。
慢网络下的行为仍未验证。

### 一个必须由主人决定的取舍：点视频打不开帖子

修喇叭这条缺陷，到这里是**四次判断、三次被实测否定**：

1. 我说「去掉 `MediaView` 外层手势」 → **不够**，卡片 `content` 外面还有一层
2. 交互线去掉两层后喇叭绿了 → 但视频行**打不开帖子**了（回归）
3. 我给视频补上激活手势 → **连播放决策都不工作了**（两条用例卡在
   `scrollToAPlayingVideo`，连「找到一个正在播的视频」都做不到）
4. 停用我加的那一行 → 喇叭立刻通过（31.3s）

**实测结论**：任何盖在播放器之上的东西都会吃掉它自己的控件或破坏它的可见性上报，
而可见性上报正是播放决策的输入。

**所以「点视频进详情」和「喇叭能用」在当前结构下是冲突的。**
现状：视频行的入口走卡片其余部分（标题行、正文各有手势）+ VoiceOver 的 `post.open`；
**点画面本身不做任何事**。

这比成熟社交 App 差（那里点视频通常进详情），**记为需要产品决定的技术债**，
不悄悄留一个坏掉的入口。要同时满足两者，需要重做这一行的手势与播放器层级关系
—— 那超出本阶段范围。

### 一个我自己的方法错误，记下来

我为了判断「是不是我改坏的」用 `git stash push -- <两个文件>` 测基线。
但那会把文件恢复到 **HEAD**，而交互线的修复同样是未提交的 ——
于是我测的「基线」连它的修复一起撤掉了，报出原始缺陷，
我据此得出「交互线的修复没留在代码里」。**那个判断是错的。**
正确的隔离方式是只停用我自己加的那一行。

### 留给后续 / 未验证

- `session.signOut()` 抛错被 `try?` 吞掉：菜单已关、人还登着、**屏幕什么都不说**
- 离开详情页再回来**草稿丢失**（每次进都新建 `PostDetailViewModel`）
- 评论下拉刷新会**先清空已加载评论再转圈**
- 登录失败的朗读：原注释声称会朗读，实际只有 `.isStaticText`（不朗读任何东西）。已改为真正 post 通告，但 **XCUITest 读不到通告**，需真人 + VoiceOver
- 点赞无触感反馈；小屏（SE/mini）**无可用模拟器**，未验证

---

## 并行安排的一个真实缺陷

**这个目录不是隔离 worktree，是共享的。** 文件归属能防改冲突，**防不了编译期互相阻塞**——
一个 agent 的编译错误会让整个测试 target 无法构建，其他 agent 跟着卡住（实测约 2 分钟）。
下次要么用 `isolation: worktree`，要么让 agent 只改不跑、由主协调串行跑。

---

## 云测试环境（已就绪，不再扩大）

`petnote-devtest`：6 函数、`nam5` Firestore、规则已发布、25 索引、3 个测试账号、210 帖种子。
$1 预算告警（50/90/100%）+ 镜像清理策略。生产 `petnote-a9dac` 零写入零部署。

**仅用于已授权的定点验收。重复回归和压力场景在本地 emulator 跑。不做云端负载测试。**

---

## 资源

清理后：`build/dd`（2.6G）、`build/spm`（1.2G）、`build/dd-pkg`（785M）。
**一个**模拟器（iPhone 17）。已回收 12 GB。

# 独立测试 Firebase 环境 · 待批准清单

本文件是**申请**，不是记录。里面没有任何一步已经执行过。截至撰写时，生产项目
`petnote-a9dac` 没有被写入或部署，也没有创建任何云项目。

所有事实都是本地只读核查得来的，给出了文件和行号，可以自行复核。

---

## 1. 为什么要新建，以及新项目该叫什么

### 现有 8 个项目，没有一个能用

`firebase projects:list` 的实际输出：

| Project ID | 能不能用 | 原因 |
| --- | --- | --- |
| `petnote-a9dac` | **不能** | 生产 |
| `wayne-test-666` | 不推荐 | 见下 |
| `fir-flutter-codelab-6d0bf` | 不能 | 教程遗留 |
| `hypergaragesale-ad651` | 不能 | 无关项目 |
| `kova-flooring` | 不能 | 无关项目 |
| `remoteconfigdemo-f12ac` | 不能 | 教程遗留 |
| `tictactoe-63d2e` | 不能 | 无关项目 |
| `tictactoe2-9d04b` | 不能 | 无关项目 |

`wayne-test-666` 是唯一勉强算候选的。不推荐，三个理由：它里面已有什么数据不清楚，
清不干净就会污染验收结论；它的计费状态不清楚；最重要的是它的名字不说明用途，
三个月后没人能从名字看出它是 PetNote 的测试环境，而**测试环境最容易出的事就是
被人误以为可以随便删或随便改**。

### 新项目 ID：**不要叫 `petnote-test`**

这一条很重要，因为我上一版文档提过这个名字，是错的。

**本地 emulator 现在就跑在 `petnote-test` 这个 project id 下**
（`ios-native/Support/GoogleService-Info-Emulator.plist` 的 `PROJECT_ID`）。
如果云项目也叫这个，那么日志、崩溃报告、截图、控制台输出里，
「在本机跑的」和「在云上跑的」将**完全无法区分**。
而分得清这两者，正是建独立测试环境的全部意义。

推荐：**`petnote-devtest`**，显示名 `PetNote DevTest`。
备选（若被占用）：`petnote-devtest-1`、`petnote-ios-staging`。

**Firebase project id 是全球唯一的，可用性无法只读核查** —— 唯一的检验方式是尝试创建，
那是写操作。所以请带着两个备选去建，不要卡在第一个名字上。

### 但名字不是保护

名字只是给人看的。真正的防线在代码里，`ios-native/Support/EnvironmentGuard.swift`，
14 个单元测试覆盖。它检查**两件事**，而不是一件：

**身份**（Firebase 实际加载了哪个项目）：
- 编译进去的预期 id 与实际加载的 id 不符 → 停
- 任何非生产构建加载了 `petnote-a9dac` → 停
- 云构建加载了 emulator 的 id（或反过来）→ 停

**传输**（字节实际发去了哪里）—— 这一条是这次新加的，它堵的洞是身份检查完全看不见的：
- emulator 构建的 host 设置没生效，于是连上了真正的 `firestore.googleapis.com`，
  但 project id 是对的 → 停
- 云构建的 emulator host 还留着，于是**从没离开过这台 Mac**，却报告说
  「在云测试项目上验过了」→ 停

第二种更安静也更糟：它会生产出一份看起来完全正常、实际毫无意义的验收证据。

守卫在 `FirebaseBootstrap` 里的调用点也相应挪到了 emulator 设置**之后** ——
放在之前的话，传输检查永远只能读到默认的云 host，也就永远抓不到它要抓的东西。

---

## 2. 六个函数：导出名、依赖、命令、能力边界

### 准确的导出名与定义位置

| 导出名 | 位置 | 类型 | 触发路径 |
| --- | --- | --- | --- |
| `createCommentCallable` | `functions/src/posts.ts:768` | `onCall` | 客户端直接调用 |
| `deleteCommentCallable` | `functions/src/posts.ts:868` | `onCall` | 客户端直接调用 |
| `onLikeCreated` | `functions/src/notifications.ts:458` | `onDocumentCreated` | `posts/{postId}/likes/{likeId}` |
| `onLikeDeleted` | `functions/src/notifications.ts:538` | `onDocumentDeleted` | 同上 |
| `onCommentCreated` | `functions/src/notifications.ts:559` | `onDocumentCreated` | `posts/{postId}/comments/{commentId}` |
| `onCommentDeleted` | `functions/src/notifications.ts:679` | `onDocumentDeleted` | 同上 |

运行时 Node 22（`functions/package.json`），v2 函数 —— 也就是跑在 Cloud Run 上，
用 Eventarc 送 Firestore 事件，镜像存 Artifact Registry，由 Cloud Build 构建。
全局配置 `setGlobalOptions({ maxInstances: 20 })` 在 `functions/src/platform.ts:26`。

### 它们会读写哪些集合

| 集合 | 谁用 | 用途 |
| --- | --- | --- |
| `users/{uid}` | 全部 | 作者名、头像、`banned` 标记、账号状态 |
| `posts/{postId}` | 全部 | `likeCount` / `commentCount` 增减 |
| `posts/{postId}/likes/{likeId}` | 点赞触发器 | 读回，写 `counted: true` 戳 |
| `posts/{postId}/comments/{commentId}` | 评论触发器 | 反规范化作者名与头像 |
| `processedEvents/{id}` | 全部触发器 | `runEventOnce` 幂等台账（`shared.ts:362`），防事件重投重复计数 |
| 限流文档 | `createCommentCallable` | `assertRateLimit(uid, "createComment", RATE_LIMITS.write)` |
| 拉黑关系 | `createCommentCallable` | 评论者与作者之间的拉黑检查（`blocking.ts`） |
| `notifications` | 评论/点赞触发器 | **站内**通知文档 |

这些集合都要由种子脚本建起来，否则函数会在第一步就抛 `not-found`。

### 权限

不需要手工配 IAM。`firebase deploy` 会自动启用需要的 API
（Cloud Functions、Cloud Run、Eventarc、Cloud Build、Artifact Registry）
并用默认服务账号。管理员 SDK 绕过 Firestore 规则，所以台账和限流集合不需要规则条目。

### 部署命令

```bash
firebase deploy --project petnote-devtest \
  --only functions:createCommentCallable,functions:deleteCommentCallable,\
functions:onLikeCreated,functions:onLikeDeleted,\
functions:onCommentCreated,functions:onCommentDeleted
```

**一个已知风险**：`--only` 只决定部署哪些，但 firebase-tools 仍会构建并分析整个
`functions/` 代码库。若某个**未被部署**的模块在分析阶段就要求 secret，部署会中止。
处理方式：**中止就停下来报告，不要用 `--force`，更不要为了过关把生产密钥塞进测试项目**。

### 这 6 个支持什么、不支持什么

**支持**（也就是第一阶段核心链路能在真机上验的部分）：
- 登录、会话
- Feed 读取与分页
- 点赞 / 取消点赞，**并且 `likeCount` 由真实的异步触发器维护** ——
  这正是本阶段最难的一致性问题，emulator 上验过，真机上必须再验一遍
- 评论写入与删除，带**真实的服务端校验**：邮箱未验证拒绝、封禁拒绝、限流、拉黑
- `commentCount` 维护
- 站内通知文档的产生

**不支持**（本阶段也不需要）：
发帖、媒体上传（没有 Cloudinary）、宠物、地点、活动、搜索、
推送送达、验证码重置密码、以及全部定时任务。

---

## 3. 账号、种子、规则、索引、触发器：怎么验收，怎么清理

### 测试账号

由 Admin SDK 创建，**`emailVerified` 直接置位**，所以 Firebase **不会发出任何邮件**。
这是邮件副作用隔离的主要手段。

| 账号 | 邮箱已验证 | 用途 |
| --- | --- | --- |
| `accept-a@example.com` | 是 | 主验收账号 |
| `accept-b@example.com` | 是 | 第二个用户 —— 验「别人点赞导致总数变化」那条路径必须有它 |
| `accept-new@example.com` | **否** | 验评论的权限拒绝分支 |

密码在本机生成，写进 `ios-native/Config/Local.xcconfig`（已在 gitignore）。
**不需要在聊天里发送任何密钥或密码。**

**不要在 Auth 控制台点「发送验证邮件」** —— 那是唯一会真的发信的入口，
而收信地址是 `example.com`，只会产生退信。

### 种子数据

`functions/scripts/seed-ios-native.mjs`，210 条帖子（图片与视频混合）。
媒体 URL 指向 Cloudinary 的公共 `demo` cloud，**不是**生产的 `dgeunvmmn`。

脚本有三道守卫，每一道都是实跑验证过的，不是读代码推断的：
1. 按名字拒绝 `petnote-a9dac`
2. 拒绝任何没有通过 `PETNOTE_TEST_PROJECT` 显式指名的云项目
3. `FIRESTORE_EMULATOR_HOST` / `FIREBASE_AUTH_EMULATOR_HOST` 还设着时，拒绝连云项目
   —— 这一条防的是「以为自己在种本地、其实在种云上」

### 规则

原样部署 `firestore.rules`。测试环境与生产用同一套规则，否则测出来的授权行为不作数。

### 索引

核对过 iOS 端实际发出的每一个查询（`Core/Repository/Firestore*Repository.swift`），
**核心链路只需要一个复合索引**：

```
likes  [COLLECTION_GROUP]  userId ASC + postId ASC
```

用于批量查询「这一页帖子里我点赞过哪些」。其余查询
（`posts` 按 `createdAt` 降序、`comments` 子集合按 `createdAt` 降序）走自动单字段索引。

建议仍然部署完整的 `firestore.indexes.json`（26 个），保持与生产一致以免行为差异。
索引存储计入 1 GiB 免费额度，这个量级可以忽略。

### 触发器验收：怎么证明它真的跑了

**不是**看界面上数字变了 —— 界面上的数字有本地乐观增量，它变了不证明服务端变了。

| 动作 | 证据 |
| --- | --- |
| 点赞 | `posts/{id}/likes/{uid}` 存在 **且** `counted: true` **且** `posts/{id}.likeCount` 增加了 |
| 取消点赞 | like 文档消失 **且** `likeCount` 减少了 |
| 评论 | `posts/{id}/comments/{cid}` 存在且内容一致 **且** `posts/{id}.commentCount` 增加了 |
| 未验证账号评论 | 调用被拒，**且**没有任何评论文档产生 |

最后一行是最容易糊弄过去的：界面上显示了一条错误提示，不等于服务端没写进去。

### 清理

三层，从轻到重：
1. 种子脚本的清除模式：只删它自己种的（按 id 前缀），不碰别的
2. 删掉 Admin SDK 创建的那几个 Auth 账号
3. 验收结束后**直接删掉整个项目** —— 这是唯一能保证不留下持续计费的做法

---

## 4. 外部副作用：逐项核查

对 `functions/src/notifications.ts` 和 `functions/src/posts.ts` 全文 grep 过
`defineSecret` / `fetch(` / `axios` / `nodemailer` / `resend` / `sendgrid` / `https://`：

**这 6 个函数：零个 secret，零个外部 HTTP 调用。**

| 外部依赖 | 风险 | 隔离方式 |
| --- | --- | --- |
| **Cloudinary** | cloud name 在 `functions/src/platform.ts:50` **硬编码成生产的 `dgeunvmmn`**，而 `media.ts:219` 会调 `.../destroy`。把媒体函数部署到测试项目，**有删掉生产图片的风险** | **一个媒体函数都不部署**。测试项目里一个 Cloudinary 变量都不配，即使误调也没有凭据 |
| **邮件** | 这 6 个里没有任何邮件发送 | 账号用 Admin SDK 建并预置 `emailVerified`，Firebase 不发信。不碰控制台的发信入口 |
| **Geoapify** | 只在地点/活动函数里 | 不部署 |
| **FCM 推送** | 全库 grep `getMessaging` / `admin.messaging` / `sendEachForMulticast`：**零命中**。通知只是 Firestore 文档 | 无需处理 |
| **定时任务** | 有 3 个 `onSchedule` | **一个都不部署**，也不在 `--only` 列表里 |

---

## 5. Blaze 费用：诚实的版本

### 为什么必须升级

Firebase 自 2022 年起要求 Blaze 才能部署 Cloud Functions。不升级就没有评论功能，
真机验收的核心链路缺一块。

### 免费额度（2026-09-19 取自 firebase.google.com/pricing）

| 项目 | 免费额度 | 超出后 |
| --- | --- | --- |
| 函数调用 | 200 万次/月 | $0.40/百万 |
| GB-秒 | 40 万/月 | 按 Google Cloud 计价 |
| CPU-秒 | 20 万/月 | 按 Google Cloud 计价 |
| 出站流量 | 5 GB/月 | $0.12/GB |
| Firestore 读 | 5 万/天 | 按量 |
| Firestore 写 | 2 万/天 | 按量 |
| Firestore 存储 | 1 GiB | 按量 |
| Auth 月活 | 5 万 | 按量 |
| **Cloud Build 构建分钟** | **120 分钟/天** | **$0.003/分钟** |
| **容器镜像存储** | **500 MB** | 按 Google Cloud 计价 |

### 「预计低用量可能为零」不等于保证免费

这句话要说清楚。按上面的额度，人工点几十次的用量确实远低于免费线。
但**真正会产生账单的不是调用量，而是部署本身**，有两项：

**1. Artifact Registry 容器镜像存储 —— 这是最容易被忽略的一项。**
每次部署都会为函数构建并推送新镜像。免费额度只有 500 MB，
而 6 个 v2 函数的镜像反复累积很容易越过它。函数运行时并不需要这些镜像，
它们纯粹是历史堆积。
**控制措施**：firebase-tools ≥ 14.0.0 提供
`firebase functions:artifacts:setpolicy`，默认删除 1 天以上的镜像。
**这一步要做，不是可选项。**

**2. Cloud Build 构建分钟** —— 每天 120 分钟免费。一次 6 函数部署是几分钟，
一天内反复部署有可能接近上限。

此外，Firestore 存储若种子数据显著增长也会计费；出站流量在本项目可忽略
（媒体走 Cloudinary，不经 Firebase）。

### 控制措施

| 措施 | 是什么 | 是不是硬上限 |
| --- | --- | --- |
| Artifact Registry 清理策略 | 自动删 1 天以上的镜像 | 不是，但它直接消除主要成本来源 |
| `maxInstances` | 代码里已全局设为 20（`platform.ts:26`）。建议部署后**在控制台**把这 6 个 Cloud Run 服务各自改成 2 —— 改控制台不需要动 `functions/src`，也就不需要额外授权 | 限制并发规模，不是费用上限 |
| `minInstances` 保持 0 | 默认值。空闲时零实例、零成本 | — |
| 预算告警 | 邮件通知 | **不是。** |
| 用完即删项目 | 验收结束删掉整个项目 | **这是唯一真正可靠的停费手段** |

**关于预算告警必须讲明白**：Google Cloud 的预算告警**只发通知，不会停止扣费**。
把它描述成「上限」是错的。要做到真正的硬停，需要再搭一套
「告警 → Pub/Sub → 函数调用 Billing API 关闭计费」的自动化 ——
那本身又是一堆基础设施，而且一旦触发会让项目直接失能。

本项目不具备失控条件：没有公网流量、没有定时任务、没有对外入口，
唯一的调用方是手上这台手机。所以建议是**低阈值预算告警用于可见性，
加上验收结束后删掉项目**，而不是假装有一个不存在的硬上限。

---

## 6. 真机构建怎么识别测试环境

### 编译期

- 构建配置 `Debug-TestCloud`（`ios-native/Config/Debug-TestCloud.xcconfig`，已存在但**尚未构建过** ——
  现在没有项目可指）
- `PETNOTE_TEST_PROJECT_ID` 来自 `Config/Local.xcconfig`（gitignore 覆盖），
  经由 `PETNOTE_EXPECTED_PROJECT` → `Info.plist` → `AppEnvironment.expectedProjectID`
- plist 放 `Support/GoogleService-Info-Test.plist`，**已加入 gitignore**
  （这次补的 —— 之前只覆盖了 `GoogleService-Info.plist`，测试项目的 plist 是能被提交的）

### 启动时

`EnvironmentGuard.enforce` 的 5 种判定，见 §1。不符就 `fatalError`，不是打日志继续跑。

### 运行时（这次新加）

登录后的导航栏左上角显示 **`TESTCLOUD · petnote-devtest`** 这样的标识，
内容是 **Firebase 实际加载的** project id，不是编译期期望的那个。

加这个的理由很具体：真机验收产出的是截图，而一张 Feed 截图，
无论数据来自 emulator、测试项目还是生产，**看起来完全一样**。
分不清来源的证据不是证据。生产构建里这个标识不显示。

有一条 UI 测试专门断言它还在
（`PetNoteAppUITests/EnvironmentBadgeUITests.swift`）——
如果它哪天不渲染了，之后所有真机截图会悄无声息地失去意义，而别的测试一个都不会发现。

### 防回落到生产

`.firebaserc` 的默认项目是生产，这是最大的误操作风险。四道防线：

1. 所有命令**显式带 `--project`**，绝不依赖默认值
2. 种子脚本的三道守卫（§3）
3. `EnvironmentGuard` 的身份与传输双重检查（§1）
4. 界面上的环境标识（上一节）

---

## 7. 需要你一次性批准的操作

| # | 操作 | 为什么 | 费用依据 |
| --- | --- | --- | --- |
| 1 | 新建 Firebase 项目 `petnote-devtest`（备选 `petnote-devtest-1` / `petnote-ios-staging`）。**不要用 `petnote-test`**，emulator 已占用该 id | 账号下 8 个项目没有可用的 | 免费 |
| 2 | 开启 Authentication 的邮箱/密码登录 | 登录、会话、未验证邮箱门槛 | 5 万 MAU 免费 |
| 3 | 创建 Firestore（Native 模式，`us-central1`，与生产一致） | 全部数据 | 5 万读 / 2 万写 / 1 GiB 免费 |
| 4 | 部署 `firestore.rules` 与 `firestore.indexes.json` | 规则是授权真相；`likes` 集合组索引是批量点赞查询的前提 | 免费 |
| 5 | **升级 Blaze（需绑卡）** | 不升级就无法部署 Cloud Functions，评论功能在真机上验不了 | 见 §5。预计月费接近 $0，但**不是保证免费**，成本主要在镜像存储 |
| 6 | 部署 §2 那 6 个函数（**不含**任何媒体或定时函数） | 评论、点赞计数 | 同上 |
| 7 | **设置 Artifact Registry 清理策略**（`firebase functions:artifacts:setpolicy`） | 直接消除主要成本来源 | 免费，且省钱 |
| 8 | 部署后在 Cloud Run 控制台把这 6 个服务的 max instances 改为 2 | 限制失控规模。改控制台不动 `functions/src`，不需要额外授权 | 免费 |
| 9 | 设置低阈值预算告警（建议 $1） | 可见性。**明确：这不是停费上限** | 免费 |
| 10 | 你下载该项目的 `GoogleService-Info.plist`，我放到 `Support/GoogleService-Info-Test.plist`（已 gitignore，不提交） | 真机构建识别测试项目 | 免费 |

**不在申请范围内**：任何对 `petnote-a9dac` 的写入或部署；修改 `functions/src/**`、
`firestore.rules`、`firestore.indexes.json`、`firebase.json`；合并 PR；开启 OTP。

**不需要你在聊天里发送任何密钥、密码或凭据。**

---

## 8. 批准后我会怎么做（可复跑）

```bash
# 0. 确认目标，绝不依赖 .firebaserc 默认值
export PETNOTE_TEST_PROJECT=petnote-devtest
firebase use --project "$PETNOTE_TEST_PROJECT" && firebase projects:list

# 1. 规则与索引
firebase deploy --project "$PETNOTE_TEST_PROJECT" --only firestore:rules,firestore:indexes

# 2. 只部署那 6 个函数
firebase deploy --project "$PETNOTE_TEST_PROJECT" \
  --only functions:createCommentCallable,functions:deleteCommentCallable,\
functions:onLikeCreated,functions:onLikeDeleted,\
functions:onCommentCreated,functions:onCommentDeleted

# 3. 镜像清理策略
firebase functions:artifacts:setpolicy --project "$PETNOTE_TEST_PROJECT"

# 4. 种子（守卫要求显式指名，且不能有 emulator host 残留）
unset FIRESTORE_EMULATOR_HOST FIREBASE_AUTH_EMULATOR_HOST
node functions/scripts/seed-ios-native.mjs --project "$PETNOTE_TEST_PROJECT"

# 5. 真机构建
#    Config/Local.xcconfig 填 PETNOTE_TEST_PROJECT_ID=petnote-devtest
#    Support/GoogleService-Info-Test.plist 放好（不提交）
#    用 Debug-TestCloud 配置构建装机

# 6. 验证隔离（不是看界面，是看后端）
#    - 界面左上角必须显示 TESTCLOUD · petnote-devtest
#    - 点一次赞，到测试项目的 Firestore 里确认 likes 文档 counted:true 且 likeCount 变了
#    - 到生产项目只读确认：同一时段没有任何新增文档
```

# 独立测试 Firebase 环境 · 最终执行方案（待批准）

**状态**：全部未执行。生产项目 `petnote-a9dac` 零写入、零部署。没有创建任何云项目，
没有绑定任何账单，没有启用任何收费服务。

本文件是**一次性批准清单**，不再请你在技术方案之间做选择。所有事实来自本地只读核查，
给了文件和行号可以复核。

---

## 0. 需要你做的最少操作

只有两件事必须你亲自做，其余我在批准后执行：

1. **在 Firebase 控制台创建项目并绑定账单账户**（§1、§5）——建项目和绑卡都需要你的账号权限。
2. **下载新项目的 `GoogleService-Info.plist` 交给我**（§7）——我放进 `Support/`，不提交。

**不需要你在聊天里发送任何密钥、密码或凭据。**

---

## 1. 项目 ID

**`petnote-devtest`**，显示名 `PetNote DevTest`。
被占用时依次用 `petnote-devtest-1`、`petnote-ios-staging`。

Firebase 项目 ID 全球唯一，**可用性无法只读核查**——唯一的检验方式是尝试创建，那是写操作。
所以请带着备选去建。

### 绝对不要叫 `petnote-test`

本地 emulator 现在就跑在这个 ID 下（`ios-native/Support/GoogleService-Info-Emulator.plist`
的 `PROJECT_ID`）。两边同名的话，日志、崩溃报告、截图、控制台输出里，
「在本机跑的」和「在云上跑的」**完全无法区分**——而分得清这两者正是建独立环境的全部意义。

代码里已经按名字双向拒绝这种混淆（`EnvironmentGuard.emulatorProjectID`）。

### 账号下现有 8 个项目，没有一个能用

`petnote-a9dac`（生产）、`wayne-test-666`、`fir-flutter-codelab-6d0bf`、
`hypergaragesale-ad651`、`kova-flooring`、`remoteconfigdemo-f12ac`、
`tictactoe-63d2e`、`tictactoe2-9d04b`。

`wayne-test-666` 是唯一勉强的候选，不推荐：已有数据不明、计费状态不明，
且名字不说明用途——三个月后没人能从名字看出它是 PetNote 的测试环境。

---

## 2. 目标账单账户

**这一项我查不到，需要你在控制台确认。** 本机没有安装 `gcloud`，
Firebase CLI 不提供账单账户的只读列表。

请在绑定时确认两件事：

- 用**哪个**账单账户。如果生产 `petnote-a9dac` 已绑定某个账户，
  测试项目**可以用同一个**（费用会合并到同一张账单，但项目维度的用量是分开的），
  也可以另开一个以便清晰隔离。我的建议是**同一个**——另开账户不降低风险，只增加管理面。
- 绑定后立刻做 §5 的三项控制，不要等。

---

## 3. 六个函数

### 准确导出名与定义位置

| 导出名 | 位置 | 类型 | 触发路径 |
| --- | --- | --- | --- |
| `createCommentCallable` | `functions/src/posts.ts:768` | `onCall` | 客户端调用 |
| `deleteCommentCallable` | `functions/src/posts.ts:868` | `onCall` | 客户端调用 |
| `onLikeCreated` | `functions/src/notifications.ts:458` | `onDocumentCreated` | `posts/{postId}/likes/{likeId}` |
| `onLikeDeleted` | `functions/src/notifications.ts:538` | `onDocumentDeleted` | 同上 |
| `onCommentCreated` | `functions/src/notifications.ts:559` | `onDocumentCreated` | `posts/{postId}/comments/{commentId}` |
| `onCommentDeleted` | `functions/src/notifications.ts:679` | `onDocumentDeleted` | 同上 |

运行时 Node 22，v2 函数——跑在 Cloud Run 上，Firestore 事件经 Eventarc 投递，
镜像存 Artifact Registry，由 Cloud Build 构建。
全局 `setGlobalOptions({ maxInstances: 20 })` 在 `functions/src/platform.ts:26`。

### 它们读写的集合

`users/{uid}`、`posts/{postId}`、`posts/{postId}/likes/{likeId}`、
`posts/{postId}/comments/{commentId}`、`processedEvents/{id}`（幂等台账，`shared.ts:362`）、
限流文档、拉黑关系（`blocking.ts`）、`notifications`（**站内**文档，不是推送）。

种子必须建出 `users` 文档，否则 `getNotificationActor` 第一步就抛 `not-found`。

### 能支持什么

登录与会话、Feed 读取与分页、点赞（**且 `likeCount` 由真实异步触发器维护**——
这正是本阶段最难的一致性问题）、评论写入与删除（带真实服务端校验：
邮箱未验证拒绝、封禁拒绝、限流、拉黑）、`commentCount` 维护、站内通知文档。

### 不支持（本阶段也不需要）

发帖、媒体上传、宠物、地点、活动、搜索、推送送达、验证码重置密码、全部定时任务。

### 权限

不需要手工配 IAM。`firebase deploy` 会自动启用 Cloud Functions、Cloud Run、
Eventarc、Cloud Build、Artifact Registry 这几个 API，并使用默认服务账号。
Admin SDK 绕过 Firestore 规则，所以台账和限流集合不需要规则条目。

### 部署时的已知风险

`--only` 决定部署哪些，但 firebase-tools 仍会构建并分析**整个** `functions/` 代码库。
若某个**未被部署**的模块在分析阶段就要求 secret，部署会中止。

**中止就停下来报告，不用 `--force`，更不把生产密钥塞进测试项目。**

---

## 4. 第三方服务隔离

对 `notifications.ts` 和 `posts.ts` 全文 grep 过 `defineSecret` / `fetch(` / `axios` /
`nodemailer` / `resend` / `sendgrid` / `https://`：**这 6 个函数零 secret、零外部 HTTP 调用。**

| 依赖 | 风险 | 隔离方式 |
| --- | --- | --- |
| **Cloudinary** | cloud name 在 `functions/src/platform.ts:50` **硬编码成生产的 `dgeunvmmn`**，且 `media.ts:219` 会调 `.../destroy`。把媒体函数部到测试项目**有删掉生产图片的风险** | **一个媒体函数都不部署**；测试项目一个 Cloudinary 变量都不配，即使误调也没有凭据 |
| **邮件** | 这 6 个里没有任何邮件发送 | 账号用 Admin SDK 建并**预置 `emailVerified`**，Firebase 不发信。**不要点控制台的「发送验证邮件」**——那是唯一会真发信的入口，而收件域是 `example.com`，只会产生退信 |
| **Geoapify** | 只在地点/活动函数里 | 不部署 |
| **FCM 推送** | 全库 grep `getMessaging` / `admin.messaging` / `sendEachForMulticast`：**零命中**。通知只是 Firestore 文档 | 无需处理 |
| **定时任务** | 有 3 个 `onSchedule` | **一个都不部署**，也不在 `--only` 列表里 |

---

## 5. 费用：依据与控制

### 免费额度（2026-09-19 取自 firebase.google.com/pricing）

| 项目 | 免费额度 | 超出后 |
| --- | --- | --- |
| 函数调用 | 200 万次/月 | $0.40/百万 |
| GB-秒 | 40 万/月 | 按 Google Cloud 计价 |
| CPU-秒 | 20 万/月 | 按 Google Cloud 计价 |
| 出站流量 | 5 GB/月 | $0.12/GB |
| Firestore 读 / 写 / 删 | 5 万 / 2 万 / 2 万 每天 | 按量 |
| Firestore 存储 | 1 GiB | 按量 |
| Auth 月活 | 5 万 | 按量 |
| **Cloud Build 构建分钟** | **120 分钟/天** | **$0.003/分钟** |
| **容器镜像存储** | **500 MB** | 按 Google Cloud 计价 |

### 两句必须讲清楚的话

**免费额度不是零费用保证。** 真正会产生账单的不是调用量，是**部署本身**：

1. **Artifact Registry 镜像存储**——每次部署推新镜像，免费额度只有 500 MB，
   6 个 v2 函数反复部署很容易越过。函数运行**不需要**这些镜像，纯属历史堆积。
2. **Cloud Build 分钟**——每天 120 分钟免费；一次 6 函数部署是几分钟，一天内反复部署会逼近。

**预算告警不是费用硬上限。** Google Cloud 的预算告警**只发通知，不会停止扣费**。
要真正硬停需要另搭「告警 → Pub/Sub → 函数调用 Billing API 关闭计费」——
那本身又是一堆基础设施，且一旦触发项目直接失能。不建议为这个测试项目搭。

### 控制措施

| 措施 | 效果 | 是不是硬上限 |
| --- | --- | --- |
| `firebase functions:artifacts:setpolicy`（默认删 1 天以上镜像） | 直接消除主要成本来源 | 不是，但根治 |
| 部署后在 Cloud Run 控制台把 6 个服务 max instances 改为 **2** | 限制失控规模。改控制台不动 `functions/src`，不需要额外授权 | 不是 |
| `minInstances` 保持 **0**（默认） | 空闲零实例零成本。**测试项目永远不要设 >0** | — |
| 预算告警 **$1** | 可见性 | **不是** |
| **验收结束删掉整个项目** | — | **这是唯一真正可靠的停费手段** |

本项目不具备失控条件：没有公网流量、没有定时任务、没有对外入口，
唯一调用方是手上那台手机。

---

## 6. 种子与清理

### 账号

Admin SDK 创建，`emailVerified` 直接置位，**不发任何邮件**。

| 账号 | 已验证 | 用途 |
| --- | --- | --- |
| `accept-a@example.com` | 是 | 主验收账号 |
| `accept-b@example.com` | 是 | 第二个用户——验「别人点赞导致总数变化」必须有它 |
| `accept-new@example.com` | **否** | 验评论的权限拒绝分支 |

密码本机生成，写进 `ios-native/Config/Local.xcconfig`（gitignore 覆盖）。

### 数据

`functions/scripts/seed-ios-native.mjs`，210 帖。媒体指向 Cloudinary 公共 `demo` cloud，
**不是**生产的 `dgeunvmmn`。

**每轮独立命名空间** `ios-<runId>-post-NNN`，不复用任何旧文档 ID。
清理只删 `seedRuns` 登记表里记录过的轮次，不用「凡 ios- 开头都删」的通配规则——
那条规则本身就是之前那个缺陷（179/210 帖聚合计数错误，一个帖子显示 -10 条评论）的成因。
失败或崩溃的轮次同样会登记，所以残留永远可精确清理。

**脚本不写任何聚合值**，`likeCount`/`commentCount` 全部由触发器维护；
等待有截止时间，超时如实记「未在截止时间内收敛」并失败，不自动改对。

### 写入守卫：允许指定项目，继续拒绝生产

不是「放宽成非生产即可写」。三处各自独立：

- 种子脚本：显式允许列表 `[emulator, $PETNOTE_TEST_PROJECT]`，**无通配**，生产按名字拒绝；
  且 emulator 环境变量还设着时拒绝连云项目（防「以为在种本地、其实在种云上」）。
- `AppEnvironment.allowsWrites`：testCloud 必须**已编译进一个非生产的项目 ID** 才放行。
  空 ID 或生产 ID 一律拒绝。
- `EnvironmentGuard`：校验 Firebase 实际加载的项目 ID **和实际连接的主机**，
  两者任一不符即 `fatalError`。

### 触发器验收

不是看界面数字变了——界面有本地乐观增量。

| 动作 | 证据 |
| --- | --- |
| 点赞 | like 文档存在 **且** `counted: true` **且** `likeCount` 增加 |
| 取消 | like 文档消失 **且** `likeCount` 减少 |
| 评论 | 评论文档存在且内容一致 **且** `commentCount` 增加 |
| 未验证账号评论 | 调用被拒 **且** 没有任何评论文档产生 |

最后一行最容易糊弄：界面显示了错误提示，不等于服务端没写进去。

---

## 7. 真机构建怎么识别测试环境

- 构建配置 `Debug-TestCloud`（已存在，**尚未构建过**——现在没有项目可指）
- `PETNOTE_TEST_PROJECT_ID` 从 `Config/Local.xcconfig`（gitignore）流到
  `PETNOTE_EXPECTED_PROJECT` → `Info.plist` → `AppEnvironment.expectedProjectID`
- plist 放 `Support/GoogleService-Info-Test.plist`，**已在 gitignore**
- 启动时 `EnvironmentGuard.enforce` 的 5 种判定，不符即 `fatalError`
- 运行时导航栏左上角显示 `TESTCLOUD · petnote-devtest`，内容是
  **Firebase 实际加载的** project id。有 UI 测试钉住它还在渲染——
  真机验收产出的是截图，而一张 Feed 截图无论数据来自哪里看起来都一样，
  分不清来源的证据不是证据

### 防回落到生产

`.firebaserc` 默认是生产，这是最大的误操作风险。四道防线：所有命令显式带 `--project`；
种子脚本三道守卫；`EnvironmentGuard` 的身份 + 传输双重检查；界面环境标识。

---

## 8. 需要批准的操作（一次性）

| # | 操作 | 谁做 |
| --- | --- | --- |
| 1 | 创建 Firebase 项目 `petnote-devtest`（备选见 §1）。**不要用 `petnote-test`** | 你 |
| 2 | 开启 Authentication 的邮箱/密码登录 | 你或我 |
| 3 | 创建 Firestore（Native 模式，`us-central1`，与生产一致） | 你或我 |
| 4 | **升级 Blaze 并绑定账单账户**（§2、§5） | 你 |
| 5 | 部署 `firestore.rules` 与 `firestore.indexes.json` | 我 |
| 6 | 部署 §3 那 6 个函数（**不含**媒体与定时函数） | 我 |
| 7 | `firebase functions:artifacts:setpolicy` | 我 |
| 8 | Cloud Run 控制台把 6 个服务 max instances 设为 2 | 你 |
| 9 | 预算告警 $1（**不是硬上限**） | 你 |
| 10 | 下载 `GoogleService-Info.plist` 给我 | 你 |

**不在申请范围**：对 `petnote-a9dac` 的任何写入或部署；修改 `functions/src/**`、
`firestore.rules`、`firestore.indexes.json`、`firebase.json`；合并 PR；开启 OTP。

---

## 9. 执行序列（批准后，可复跑）

```bash
export PETNOTE_TEST_PROJECT=petnote-devtest
firebase use --project "$PETNOTE_TEST_PROJECT" && firebase projects:list

firebase deploy --project "$PETNOTE_TEST_PROJECT" --only firestore:rules,firestore:indexes

firebase deploy --project "$PETNOTE_TEST_PROJECT" \
  --only functions:createCommentCallable,functions:deleteCommentCallable,\
functions:onLikeCreated,functions:onLikeDeleted,\
functions:onCommentCreated,functions:onCommentDeleted

firebase functions:artifacts:setpolicy --project "$PETNOTE_TEST_PROJECT"

unset FIRESTORE_EMULATOR_HOST FIREBASE_AUTH_EMULATOR_HOST
GCLOUD_PROJECT="$PETNOTE_TEST_PROJECT" node functions/scripts/seed-ios-native.mjs
```

验证隔离（看后端，不看界面）：界面左上角必须显示 `TESTCLOUD · petnote-devtest`；
点一次赞后到测试项目确认 like 文档 `counted:true` 且 `likeCount` 变了；
到生产项目**只读**确认同一时段无任何新增文档。

---

## 10. 撤销步骤

按影响从小到大，任何一步都可以单独执行：

1. **删除本轮种子数据**：种子脚本的登记表记录了每一轮的命名空间，
   删掉对应 `seedRuns/*` 里记录的 `postIdPrefix` 下的文档即可，不影响其他数据。
2. **删除测试账号**：Admin SDK 建的那三个，按邮箱删。
3. **删除函数**：
   `firebase functions:delete createCommentCallable deleteCommentCallable onLikeCreated onLikeDeleted onCommentCreated onCommentDeleted --project petnote-devtest`
4. **清空 Artifact Registry**：删掉 `gcf-artifacts` 仓库，停止镜像存储计费。
5. **解绑账单账户**：项目保留但不能再用 Cloud Functions。
6. **删除整个项目**：控制台 → 项目设置 → 删除项目。有 30 天宽限期可恢复。
   **这是唯一能保证不留下任何持续计费的做法**，验收结束后建议直接做这一步。

生产项目 `petnote-a9dac` 在以上任何一步中都不受影响——它从头到尾没有被碰过。

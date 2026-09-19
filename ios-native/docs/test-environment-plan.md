# 独立测试 Firebase 环境 · 待批准清单

**状态** 本地准备已完成；**云端一步未做**。
**只读核查日期** 2026-09-19

---

## 1. 现有账号下有没有能用的

有，但没有一个能用。`firebase projects:list` 的 8 个项目：

| 项目 | 判断 |
| --- | --- |
| `petnote-a9dac` | **生产**。不碰 |
| `fir-flutter-codelab-6d0bf` · `hypergaragesale-ad651` · `kova-flooring` · `remoteconfigdemo-f12ac` · `tictactoe-63d2e` · `tictactoe2-9d04b` · `wayne-test-666` | 与 PetNote 无关的旧项目。复用会把 PetNote 的数据和规则混进别的东西里，而且它们的现有配置不明 |

**结论：需要新建一个。**

## 2. 测试环境需要什么（最小集）

第一阶段的核心链路是登录 → Feed → 详情 → 评论 → 点赞。为此需要：

| 组件 | 需要吗 | 说明 |
| --- | --- | --- |
| **Authentication**（邮箱密码） | **是** | 登录、会话恢复、未验证邮箱的门槛 |
| **Firestore** | **是** | posts / comments / likes / users / pets |
| **firestore.rules** | **是** | 点赞的 `counted == false` 约束、collection-group 读权限都靠它 |
| **firestore.indexes.json** | **是** | 批量点赞状态用的 `likes` collection-group 索引 `(userId, postId)` 已在文件里 |
| **Cloud Functions** | **是，但只要 6 个** | 见下 |
| Storage | 否 | 媒体走 Cloudinary |
| Hosting | 否 | 不部署网页 |
| Cloud Scheduler | **否** | 三个定时任务不部署，见 §3 |

**需要的 6 个函数**（核心链路真正会调到的）：

```
createCommentCallable      posts.ts   评论写入（客户端不能直写）
deleteCommentCallable      posts.ts   评论删除
onLikeCreated              notifications.ts  维护 likeCount，把 counted 翻成 true
onLikeDeleted              notifications.ts  维护 likeCount
onCommentCreated           notifications.ts  维护 commentCount
onCommentDeleted           notifications.ts  维护 commentCount
```

**这 6 个一个 secret 都不需要。** 逐个核实过：`posts.ts` 与
`notifications.ts` 里没有任何 `secrets:` 声明；Cloudinary 的 cloud name 是普通
常量不是 secret。

## 3. 外部副作用排查

这是决定"能不能安全部署"的部分。逐项实测：

| 外部资源 | 在哪 | 测试环境的风险 | 处理 |
| --- | --- | --- | --- |
| **Cloudinary 资产删除** | `media.ts:219` 调 `.../destroy`；cloud name 在 `platform.ts:50` **硬编码为生产的 `dgeunvmmn`** | **原样部署会让测试环境去删生产图片** | **不部署 `media.ts` 的函数**，且**不配置** `CLOUDINARY_API_KEY` / `CLOUDINARY_API_SECRET`。没有凭据，任何删除调用都会失败而不是误删 |
| **邮件发送** | `email.ts:42` → `https://api.resend.com/emails` | 配了同一个 key 就会真的发信给真实邮箱 | **不配置** `TRANSACTIONAL_EMAIL_API_KEY` / `TRANSACTIONAL_EMAIL_FROM`。OTP 本来就不开 |
| **Geoapify** | `geo.ts`，用 `GEOAPIFY_API_KEY` | 消耗生产配额 | **不部署 `geo.ts` 的函数**，不配置该 key |
| **定时任务** | `autoCompleteMeetups`（每 15 分钟）、`cleanupOldReadNotifications`（每 24 小时）、`resumeAbandonedPetDeletions`（每 6 小时） | 会在测试项目上自动运行并改数据；且需要 Cloud Scheduler | **不部署**。第一阶段不涉及聚会、通知清理、宠物删除 |

**换句话说：测试项目不持有任何生产密钥，也不部署任何会碰外部资产的函数。**
即使部署脚本出错，最坏结果是那些函数因缺少凭据而失败，而不是动了生产资源。

## 4. 防止漏配回落到生产

**当前最大的风险点：`.firebaserc` 的 `default` 是 `petnote-a9dac`。**
任何不带 `--project` 的 firebase 命令都会打到生产。

已经做好的防护（本地，已实测）：

| 防护 | 位置 | 实测 |
| --- | --- | --- |
| 种子脚本按名字拒绝生产 | `seed-ios-native.mjs` | `GCLOUD_PROJECT=petnote-a9dac` → `Refusing to seed petnote-a9dac: that is production.` |
| 云项目必须被显式命名，没有通配 | 同上 | 未设 `PETNOTE_TEST_PROJECT` 时 → `Refusing to seed project "petnote-test-9999"` |
| 指向云项目时不许带 emulator host | 同上 | 带 `FIRESTORE_EMULATOR_HOST` → 拒绝，理由是写会悄悄进 emulator 而项目还是空的 |
| **App 启动自检** | `EnvironmentGuard` | 编译期写入期望的 project id，与 Firebase 实际加载的比对，不符直接停；任何非生产配置加载到 `petnote-a9dac` 一律拒绝。8 个单元测试覆盖 |

**仍需在批准后做的**：给 `.firebaserc` 加一个 `test` 别名（不动 `default`），
这样命令写成 `--project test` 而不是记一串 id。

## 5. 真机构建怎么识别测试环境

新增第四套配置 `Debug-TestCloud`（已建好，缺的只是项目 id 与 plist）：

| Scheme | 后端 | 写入 |
| --- | --- | --- |
| `PetNote-Emulator` | 本地 emulator | 允许 |
| **`PetNote-TestCloud`**（待建） | **独立测试项目，HTTPS** | 允许 |
| `PetNote-Prod-ReadOnly` | 生产 | 禁止 |
| `PetNote-Release` | 生产 | 禁止 |

**为什么真机必须走这条**：Functions SDK 拒绝把认证令牌通过明文 HTTP 发给非
loopback 地址，所以真机连本地 emulator 时评论永远不可用
（见 `device-emulator-limits.md`）。测试项目是 HTTPS，这条限制不适用。

**怎么验证隔离**：

1. App 内登录页与已登录页都显示 `后端 · 构建戳`，一眼能看出连的是哪套。
2. 启动自检 `EnvironmentGuard`：期望 id 与实际加载的 id 不符即停；非生产配置
   加载到生产项目即停。
3. 测试数据全部带 `TEST CONTENT` 前缀、文档 id 带 `ios-` 前缀，肉眼可辨。
4. 批准后可加一条核验命令：只读列出测试项目的集合与文档数，确认与生产无交集。

## 6. 需要你一次性批准的操作

**按最少必需列出。不需要在聊天里发任何密钥。**

| # | 操作 | 为什么必需 | 费用依据 |
| --- | --- | --- | --- |
| 1 | 新建 Firebase 项目（建议 id `petnote-test`，若被占用则 `petnote-testing`） | 账号下没有可用的非生产项目 | 建项目本身免费 |
| 2 | 开启 Authentication 的**邮箱/密码**登录方式 | 登录、会话、未验证邮箱门槛 | 免费额度内（Auth 免费层每月 5 万次验证） |
| 3 | 创建 Firestore 数据库（**Native 模式**，区域建议 `us-central1`，与生产一致以免行为差异） | 全部数据 | 免费额度：50K 读 / 20K 写 / 1GB 存储 每天。测试用量远低于 |
| 4 | 部署 `firestore.rules` 与 `firestore.indexes.json` 到该项目 | 规则是授权真相；索引是批量点赞查询的前提 | 免费 |
| 5 | **升级到 Blaze（按量付费）** | **Firebase 自 2022 年起要求 Blaze 才能部署 Cloud Functions**。不升级就没有评论功能，真机验收还是做不了 | Blaze 保留全部免费额度；函数免费额度为每月 200 万次调用、40 万 GB-秒。本项目测试用量为**人工点几十次**，预计月费 **$0**。风险在于误部署大量函数或定时任务——所以 §2 只部署 6 个，且不部署任何定时任务 |
| 6 | 部署上述 **6 个函数**（用 `--only functions:createCommentCallable,functions:deleteCommentCallable,functions:onLikeCreated,functions:onLikeDeleted,functions:onCommentCreated,functions:onCommentDeleted`） | 评论与计数 | 同上 |
| 7 | 下载该项目的 `GoogleService-Info.plist`，我放到 `Support/GoogleService-Info-Test.plist`（**不提交**，已在 gitignore） | 真机构建识别测试项目 | 免费 |

**明确不做**：不建 Storage、不建 Hosting、不部署定时任务、不配置任何
Cloudinary / Geoapify / 邮件密钥、不开 App Check 强制、不动
`petnote-a9dac`。

**如果你不想升级 Blaze**：第 5、6 项跳过，测试项目只有 Auth + Firestore。
那么真机上可以验证登录、Feed、滚动、视频、深浅色、VoiceOver、性能，
**但评论仍然不可用**，那一条继续记为未验证。这是一个可接受的中间状态，
取决于你更在意费用还是覆盖面。

## 7. 批准后我会怎么做（可复跑）

```bash
# 1. 规则与索引（显式项目，绝不靠 default）
npx firebase deploy --only firestore:rules,firestore:indexes --project <test-id>

# 2. 只部署那 6 个函数
npx firebase deploy --only functions:createCommentCallable,... --project <test-id>

# 3. 种子（守卫要求同时给出两个变量，且不能有 emulator host）
cd functions
unset FIRESTORE_EMULATOR_HOST FIREBASE_AUTH_EMULATOR_HOST
GCLOUD_PROJECT=<test-id> PETNOTE_TEST_PROJECT=<test-id> node scripts/seed-acceptance.mjs
GCLOUD_PROJECT=<test-id> PETNOTE_TEST_PROJECT=<test-id> node scripts/seed-ios-native.mjs

# 4. 真机构建
#    Config/Local.xcconfig 填 PETNOTE_TEST_PROJECT_ID=<test-id>
#    Support/GoogleService-Info-Test.plist 放好（不提交）
xcodebuild -scheme PetNote-TestCloud -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

每一步都带 `--project`，没有一步依赖 `.firebaserc` 的 default。

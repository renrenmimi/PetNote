# 独立测试 Firebase 环境 · 照做指引

理由、费用依据和风险分析在 [`ios-native/docs/test-environment-plan.md`](../ios-native/docs/test-environment-plan.md)。
这份只讲**谁做什么、按什么顺序**。

**当前状态**：全部未执行。生产 `petnote-a9dac` 零写入、零部署。

---

## 已核实：不需要重新绑卡

只读查过 Cloud Billing API（用 Firebase CLI 已有凭据的 `cloud-platform` scope，
**没有安装 gcloud**）：

```
projects/petnote-a9dac/billingInfo
  billingAccountName: billingAccounts/01D4C4-0234BA-063448
  billingEnabled:     true
```

账号下可见的账单账户：

| 账户 | 名称 | 状态 |
| --- | --- | --- |
| `01D4C4-0234BA-063448` | Firebase 付款 | **open**，生产在用 |
| `01820B-9D26A6-EFF129` | 我的结算账号 | 已关闭 |

旁证：生产跑着 v2（gen2）函数，含 `scheduled` 触发器——两者都必须 Blaze。

**测试项目复用 `01D4C4-0234BA-063448` 即可。** 一个账单账户可以关联多个项目，
项目和数据仍然完全独立（独立 Firestore、独立 Auth、独立函数），只是账单汇总到一处。

## 三件事必须分开，不要混成「开通 Blaze」

| | 是什么 | 谁做 | 费用 |
| --- | --- | --- | --- |
| **1. 创建测试项目** | `firebase projects:create` | 我 | 免费，此时**没有**账单关联 |
| **2. 关联已有账单账户** | 把 `01D4C4-…` 关到新项目 | 见下 | 关联本身免费，它使新项目进入 Blaze |
| **3. 部署测试资源** | 函数、规则、索引、种子 | 我 | 增量费用见下 |

**第 2 步不是重新绑卡。** Cloud Billing API 的 `projects.updateBillingInfo` 我的令牌有权限，
技术上可以代做——**但那是写操作，需要你明确授权**。授权了我就一并做掉，你不用开控制台；
不授权就控制台一步：项目 → 升级 → 选 `Firebase 付款`。

## 你必须亲自做的：一件事

### 打开「电子邮件/密码」登录方式

控制台 → Authentication → Sign-in method → Email/Password → 启用。

需要你的原因：登录方式的开关没有 CLI 命令。**只有这一个开关**，
不要顺手打开其他方式。

### 关于密钥

**不需要你下载任何文件，也不需要在聊天里发送任何东西。**
`GoogleService-Info.plist` 我用 `firebase apps:sdkconfig` 直接取，
落到 gitignore 覆盖的路径。

---

## 我代做的：其余全部

批准后按顺序执行，每一步都显式带 `--project`：

```bash
# 1. 建项目
firebase projects:create petnote-devtest --display-name "PetNote DevTest"

# —— 你在这里做上面那两件事 ——

# 2. Firestore 数据库（与生产同区，避免行为差异）
firebase firestore:databases:create "(default)" \
  --project petnote-devtest --location us-central1 --type firestore-native

# 3. 规则与索引
firebase deploy --project petnote-devtest --only firestore:rules,firestore:indexes

# 4. 注册 iOS 应用并取回配置（不需要你手工下载）
firebase apps:create IOS "PetNote iOS" \
  --project petnote-devtest --bundle-id dev.local.petnote.native
firebase apps:sdkconfig IOS <appId> --project petnote-devtest \
  -o ios-native/Support/GoogleService-Info-Test.plist

# 5. 只部署这 6 个函数
firebase deploy --project petnote-devtest \
  --only functions:createCommentCallable,functions:deleteCommentCallable,\
functions:onLikeCreated,functions:onLikeDeleted,\
functions:onCommentCreated,functions:onCommentDeleted

# 6. 镜像清理策略（省钱，不是可选项）
firebase functions:artifacts:setpolicy --project petnote-devtest

# 7. 种子数据
unset FIRESTORE_EMULATOR_HOST FIREBASE_AUTH_EMULATOR_HOST
PETNOTE_TEST_PROJECT=petnote-devtest GCLOUD_PROJECT=petnote-devtest \
  node functions/scripts/seed-ios-native.mjs

# 8. 真机构建
#    Config/Local.xcconfig 填 PETNOTE_TEST_PROJECT_ID=petnote-devtest
#    用 PetNote-TestCloud scheme 构建装机
```

---

## 项目 ID 可用性

**无法只读核查。** Firebase / GCP 项目 ID 全球唯一，唯一的检验方式是尝试创建，
那本身就是写操作。所以第 1 步可能失败。

首选 `petnote-devtest`，备选依次 `petnote-devtest-1`、`petnote-ios-staging`。
**绝对不要用 `petnote-test`** —— 本地 emulator 已经占用这个 id，
两边同名会让日志、截图、控制台输出**完全无法区分本机运行和云端运行**，
而这正是建独立环境的全部意义。代码里已按名字双向拒绝这种混淆。

---

## 推荐配置与费用控制

| 项 | 值 | 理由 |
| --- | --- | --- |
| 区域 | `us-central1` | 与生产一致，避免行为差异 |
| Firestore 模式 | Native | 与生产一致 |
| 函数 max instances | **2**（部署后在 Cloud Run 控制台改） | 代码里全局是 20；改控制台不动 `functions/src`，不需要额外授权 |
| 函数 min instances | **0**（默认，别动） | 空闲零实例零成本 |
| 镜像清理策略 | 开（第 6 步） | **这是主要成本来源**，免费额度只有 500 MB |
| 预算告警 | $1 | 仅供可见性 |

**三句必须说清楚的话**：

- **预算告警不是费用硬上限。** 它只发通知，不会停止扣费。
- **免费额度不是零费用保证。** 真正会产生账单的不是调用量（人工点几十次远在额度内），
  是**部署本身**：Artifact Registry 镜像存储、Cloud Build 分钟。
- **复用账单账户时，免费额度是账户级共享的，不是每个项目一份。**
  这一点我先前写错了。生产已经在消耗这些额度，所以测试项目的镜像存储
  **很可能直接进入收费**：按 $0.10/GB/月、6 个函数镜像 1–2 GB 计，
  **每月约 $0.10–0.20**，开了清理策略后趋近于零。Cloud Build 每天 120 分钟同样与生产共享。

唯一可靠的停费手段是**验收结束删掉整个项目**。

---

## 撤销

从轻到重，任何一步可单独执行：

1. 删本轮种子数据（`seedRuns` 登记表记着每轮的命名空间，按前缀删）
2. 删测试账号（Admin SDK 建的那三个）
3. `firebase functions:delete <6 个函数> --project petnote-devtest`
4. 删 Artifact Registry 的 `gcf-artifacts` 仓库（停止镜像存储计费）
5. 解绑账单账户
6. **删除整个项目**（控制台，30 天宽限期）——唯一能保证不留持续计费的做法

生产 `petnote-a9dac` 在以上任何一步都不受影响。

---

## 与真机验收的先后

**先把测试环境弄好，再插手机。** 上面第 1–7 步不需要手机在场，
而其中有若干步要等云端资源就绪（函数首次部署几分钟）。
手机解锁着干等我搭环境是浪费。

手机要做的事见 [`device-session-checklist.md`](../ios-native/docs/device-session-checklist.md)：
开始前 2 步、中途 3 个动作、结束 1 步。

# PetNote 新人上手指南（Web 前端）

写给接手 **React + Vite + Firebase Web SDK** 这一侧的同学。iOS 原生客户端不在你的范围内，本文只在必要处提一句它的存在。

这份文档尽量写实。项目里乱的地方、有技术债的地方、以及「看起来能跑其实有坑」的地方，都直接写出来了——第 6 节是本文最值得先读的一节。

---

## 1. 这个项目是什么

PetNote 是一个宠物社交应用：发帖（图片/视频）、评论回复、点赞收藏、宠物档案（可与家人共享）、宠物友好场所的点评与打卡、线下聚会、通知、以及一套管理后台。

- **线上地址**：https://petnote.vercel.app
- **仓库**：`renrenmimi/PetNote`，默认分支 `main`
- **部署**：Vercel（前端）+ Firebase（后端）

### 分层

| 层 | 技术 | 说明 |
| --- | --- | --- |
| 前端 | React 19、TypeScript、Vite、Tailwind v4、React Router 7 | 你的主战场 |
| 后端 | Firebase Auth、Firestore、Cloud Functions v2 | `functions/` |
| 媒体 | Cloudinary 签名上传 | **Firebase Storage 从未开通** |
| 地理编码 | Geoapify（经由 Cloud Functions 代理） | 密钥不落前端 |
| 质量 | Vitest、ESLint、严格 TypeScript | |

**核心读写模型，先理解这条再看代码**：

- **读**：客户端直接读 Firestore，由安全规则把关。
- **写**：分两类，**不要记成「写一律走 callable」**。
  - **多数业务写入**走 **callable Cloud Functions**（发帖、评论、聚会、邀请码、管理操作等），在那里做校验、身份检查、事务和限流。
  - **一部分轻量的个人状态由客户端直接写**，靠安全规则校验。点赞就是其中之一：`src/services/posts.ts` 直接 `setDoc` / `deleteDoc` 到 `posts/{postId}/likes/{uid}`，规则里 `match /likes/{likeId}` 有对应的 `allow create`，并校验 `likeId == uid` 和 body 字段。收藏、个人设置、屏蔽名单是同一类。
- **派生数据**：计数器（如 `likeCount`）、通知扇出由 **Firestore 触发器**维护，**不由客户端写**。点赞的文档是客户端写的，计数不是。

所以想在前端直接写某个集合时，先去 `firestore.rules` 里找那个 `match` 看规则怎么说——有的路径明确允许，有的明确不允许，两种都是故意的。

---

## 2. 现在处于什么阶段

**生产环境是活的，有真实用户数据。** 这不是一个玩具项目，改动会影响线上。

- 核心功能已上线并经历过多轮外部审查与修复（见 `TECH_REPORT.md`、`SECURITY_MODEL.md`）。
- 有几项能力**故意关着**，不是没做完：
  - **数字验证码重置密码**（`VITE_PASSWORD_RESET_OTP`）默认关闭。打开它需要后端配好邮件服务的三个 secret，否则会把「本来就登不进来的人」送进一条走不完的流程。
  - **App Check** 默认不初始化，等控制台里配好 reCAPTCHA Enterprise 再说。见 `docs/app-check-rollout.md`。
- **另有一个 Swift 原生 iOS 客户端**在 PR #204（Draft）上开发中。**与你无关**，而且在 `main` 上**看不到它**——代码（`ios-native/`）和它自己的 CI 工作流（`ios-native.yml`）都只存在于分支 `feature/ios-native-prototype`。你在 `main` 上只会看到 Capacitor 的 `ios/` 目录。
- 仓库里还有一个 **Capacitor 壳**（`ios/`、`capacitor.config.ts`），是把当前 Web 应用打包成 iOS App 的那条路径。它仍然有效，所以**你改的前端代码会同时影响 App 内的表现**——第 6.4 节有几个只在 WebView 里才暴露的坑。

---

## 3. 本地跑起来

### 3.1 依赖

```bash
git clone https://github.com/renrenmimi/PetNote.git
cd PetNote
npm ci
```

Node 22（CI 用的就是 22）。

### 3.2 环境变量

```bash
cp .env.example .env.local
```

然后填 Firebase 的六个 `VITE_FIREBASE_*`。**问项目负责人要测试项目的配置，不要用生产项目的。**

`.env.example` 里每个可选项上面都有注释解释「留空会怎样」，先读一遍再填。

### 3.3 只跑前端（连真实后端）

```bash
npm run dev
```

这会连 `.env.local` 里配的 Firebase 项目。**如果那是生产项目，你的每一次点击都在写生产数据。** 确认清楚再动手。

### 3.4 连 Firebase Emulator（推荐的日常开发方式）

先在 `.env.local` 里加：

```
VITE_FIREBASE_EMULATORS=1
```

然后启动 emulator。**这里有两个必踩的坑，先处理：**

**坑 A：需要 JDK 21+，而系统自带的 java 版本不够。**

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk
export PATH="$JAVA_HOME/bin:$PATH"
```

（Mac 上如果没装：`brew install openjdk`。不要以为 `java -version` 有输出就够了，emulator 会明确拒绝低版本。）

**坑 B：端口是非默认的，因为默认端口被别的东西占了。**

| 服务 | 端口 | 备注 |
| --- | --- | --- |
| Firestore | **8088** | 不是默认的 8080 |
| Auth | 9099 | 默认 |
| Functions | **5101** | |
| Pub/Sub | 8085 | |
| Emulator UI | **已禁用** | 默认的 4000 端口被占 |

这些写在 `firebase.json` 里，前端的连接逻辑在 `src/services/firebase.ts`。**不要改端口**，除非你确认整条链路都跟着改了。

启动：

```bash
npx firebase emulators:start --only firestore,auth,functions --project petnote-test
```

**怎么确认自己连的是 emulator 而不是生产？** 打开浏览器控制台，连上 emulator 时会有一条 `console.warn` 横幅明确写出来。这条横幅是故意用 `warn` 而不是 `info` 的——见第 6.1 节。

**这条横幅只管 Firebase。** Cloudinary 和 Geoapify 不会被重定向，签名上传的 callable 仍然在跟真实的 Cloudinary 说话。

### 3.5 跑测试

```bash
npm test                      # src 下的单元/组件测试（vitest，21 个文件）
npm run lint
npm run build                 # tsc -b && vite build
npm run typecheck:tests

npm run test:rules:emulator   # Firestore 安全规则测试（会自己起 emulator）
```

`functions/` 目录下另有一套（21 个测试文件），在那个目录里 `npm ci` 后单独跑。

---

## 4. 代码结构

```
src/
  pages/        30 个文件 — 路由级页面
  components/   53 个文件 — 复用组件（含 components/post/）
  services/     27 个文件 — 所有与后端说话的代码都在这
  hooks/        24 个文件
  utils/        21 个文件
  contexts/     4 个 — 认证、主题等全局状态
  i18n/         文案
  types/
functions/src/  Cloud Functions（按领域拆：media / meetups / moderation / notifications / ...）
tests/rules/    Firestore 安全规则测试
firestore.rules 安全规则本体
```

### 关键约定

- **所有后端调用集中在 `src/services/`。** 页面和组件里不应出现裸的 `getDoc` / `httpsCallable`。新增后端交互先看这个目录里有没有现成的。
- **`src/services/firebase.ts` 是唯一的初始化点**，emulator 切换也在这里。
- **文案走 `src/i18n/messages.ts`**，不要在组件里写死字符串。

---

## 5. 开发流程

### 分支与 PR

- 从 `main` 切分支，分支名用 `feature/xxx` 或 `fix/xxx`。
- 提 PR 到 `main`。**仓库默认 squash 合并**——这一条会影响你，见第 6.6 节。
- PR 要能独立审查：说清楚改了什么、为什么、怎么验证的。

### CI

`ci` 工作流（`.github/workflows/ci.yml`）是 `main` 上**唯一**的工作流，也是和你相关的那个，**四个 job**：

| job | 跑什么 |
| --- | --- |
| `web` | `npm ci` → lint → test → build → typecheck:tests |
| `functions` | functions 的 lint / build / 两套 typecheck |
| `triggers` | 用真实 Firestore emulator 驱动触发器（需要 JDK） |
| `rules` | Firestore 安全规则测试 |

（Swift 客户端有自己的 `ios-native` 工作流，但它和那份代码一样只在那条功能分支上，`main` 上不存在。）

### 测试要求

不追求覆盖率数字，但有两条硬要求：

1. **改了 `firestore.rules` 必须在 `tests/rules/` 加对应测试。** 规则出错是安全问题，而且规则的语义很反直觉（第 6.2 节）。
2. **测试要能真的失败。** 一条永远通过的测试比没有测试更糟——它会让人以为某件事被验证过。写完新测试后，故意把被测代码改坏一下，确认它确实变红，再改回来。这个项目在这件事上栽过不止一次。

---

## 6. 坑

这一节是本文的重点。以下每一条都是**实际发生过**的，不是理论风险。

### 6.1 构建与环境

**`import.meta.env.DEV` 在生产模式的 `vite build` 里是 `false`。**
这是 Vite 的定义：`DEV` 只在 dev server 和 `--mode development` 下为真。我们的 `npm run build`（以及 Capacitor 的 `npm run ios:sync`，它内部就是 `npm run build`）走的是生产模式，所以任何「开发时才生效」的逻辑如果只用 `DEV` 判断，打包进 App 后等于永久关闭。emulator 开关因此用显式的 `VITE_FIREBASE_EMULATORS`，而不是 `DEV`。

**`console.info` 会被 `vite build` 当作纯函数删掉。**
`vite.config.ts` 里把它列进了 pure list。任何**必须在生产构建里活下来**的日志用 `console.warn`。emulator 横幅就因为这个从 warn 改过来——而那恰恰是最需要它的场景（打包后的 App）。

**`.gitignore` 只说明不提交，不说明不打包。**
Capacitor 的 `cap copy` 会把 `ios/App/App/public/` 原样塞进 `.app`，哪怕它被 gitignore。审查「包里有没有敏感内容」必须对着**构建产物**，不是对着源码。

### 6.2 Firestore 安全规则（最容易写错的地方）

**坑一：`request.resource.data` 在 update 时是「写入之后的整个文档」，不是「你改的那几个字段」。**

所以 `keys().hasOnly([...])` 的含义是「文档最终只能有这些 key」，而不是「只能改这些 key」。想限制「不许改某字段」必须用：

```
request.resource.data.diff(resource.data).affectedKeys()
```

这个误解造成过一次真实故障：老用户文档里残留的 `location.lat/lng` 让 `hasOnly(['city','state','updatedAt'])` 永久失败，而自愈迁移的错误被 `.catch(() => undefined)` 吞掉了，于是每次登录重试每次失败。**二阶效应**是那份残留字段卡住了该文档的**所有**合法写入。

顺带一个测试陷阱：`tests/rules/users.test.ts` 用的是 `updateDoc` + 整个 map，那是**替换**语义，抓不到这个 bug。复现必须用 `setDoc` + `merge: true`（嵌套 map 是深合并）。

**坑二：`!exists(someDoc)` 同时意味着「没问题」和「已经被删掉了」。**

账号删除级联故意先删 `users/{uid}`，最后删 Auth（为了失败可重试）。于是级联跑完后，检查「用户是否存在」的 helper 全部放行。而规则只校验 JWT 的签名和过期，**不校验 Auth 用户是否还存在**——未过期的 id token 还能写一小时。这个用墓碑集合（`userDeletionTombstones`）补上了。

### 6.3 Cloudinary

**签名只能签 Cloudinary 认识的参数。** 服务端多签一个它不认识的参数，签名永远匹配不上——它按自己收到并认识的参数重算，多余的直接丢掉。生产故障发生过一次，原因是 `max_file_size` 进了签名集。当前正确的参数集是 `folder` / `timestamp` / `upload_preset`。**加参数前先确认 Cloudinary 会签它。**

**上传大小上限只有一个地方能设：账户套餐。**

| 层 | 能不能限大小 |
| --- | --- |
| 账户套餐 | **能，而且是唯一能的**（免费版：图片 10MB、视频 100MB） |
| upload preset | 没有这个设置项 |
| 签名 | 不能，签名只证明请求来自我们 |

代码里的 10MB / 80MB 是**照套餐设的客户端提示**，不是强制。要更严的限制只能事后做（查完再删），无法事前拦。

**cloud name 是常量不是 secret**（在 `platform.ts` 里）。它出现在每个图片 URL 里，本来就是公开的。API key 和 secret 才在 Secret Manager。

### 6.4 移动端 WebView（Capacitor 壳里才暴露）

这几条在浏览器里完全看不出来，在「静止后截图」的模拟器里也看不出来。

**页面底部露黑 = `body` 没有背景色。**
每个页面只在自己的根元素上画背景（`min-h-screen bg-white dark:bg-slate-900`），所以在浏览器里永远是完整的。但页面根没盖住的地方会直接露出原生视图——橡皮筋过度滚动时，以及键盘弹出的瞬间（WebView 先缩小，键盘约 250ms 后才滑上来）。修法是 `html, body` 上设 `--app-backdrop`，配合 Keyboard 插件的 `autoBackdropColor: 'dom'`（**默认是 off**）。

**要在原生侧生效的颜色必须写字面 sRGB（如 `#0f172a`），不能用 `var(--color-slate-900)`。** Tailwind v4 用 oklch，而这个值要被原生代码解析。

**固定延时等不到中文输入法的候选栏。**
候选栏是在键盘出现**之后**才抬起来的，密码自动填充同理，定时器早就烧完了。用 `src/utils/keyboard.ts` 的 `onKeyboardSettled`——它不计时，每次变化后稳定 50ms 才报。**如果你在写任何「等键盘弹完再做某事」的逻辑，不要用 `setTimeout`。**

### 6.5 基础设施的几个「没有」

- **Firebase Storage 从未开通。** 媒体全走 Cloudinary。副作用是 Firestore 导出没有目标桶。
- **本机没装 gcloud，也没有 service account key。** 要调 GCP REST API 得用 Firebase CLI 的 refresh token 换 access token，有先例可抄。
- **定时任务 `state=ENABLED` 不等于跑过、更不等于跑成功。** Cloud Scheduler 的 `status={}` 只代表拿到 2xx；而函数体对每个任务单独 try/catch、失败只打一行 `console.error` 就继续。所以「Scheduler 全绿」和「每个任务都失败了」可以同时成立。要判断必须去 Cloud Logging 里查。

### 6.6 流程上的坑

**堆叠 PR + squash 合并会咬人。** 如果你开了 A → B（B 基于 A）：

1. **合并 A 时不要加 `--delete-branch`。** 删掉基分支会让 GitHub **直接关闭** B，而且关闭后无法重开也无法改基。
2. **squash 之后 GitHub 不会自动改基**，B 会变成冲突（A 被压扁成一个新提交，B 里还是原来那几个）。改基到 main 只是第一步，还得 `git rebase --onto origin/main <A的原提交> <B分支>` 重放。
3. **每次重放后必须本地重跑完整验证再推。** 能干净应用不代表结果能构建。

**不要 force push 别人的分支。**

---

## 7. 遇到问题怎么排查

**先确认你在跟谁说话。** 浏览器控制台里那条 emulator 横幅。没有横幅 = 你连的是真实 Firebase。这一步省下的时间比任何调试技巧都多。

**权限错误（`permission-denied`）**：
1. 先看 `firestore.rules` 里对应集合的规则。
2. 重读第 6.2 节两个坑——有一半的「规则明明写了却不生效」是这两个。
3. 在 `tests/rules/` 里写一个最小复现，比在浏览器里猜快得多。

**callable 报错**：
1. emulator 的 functions 日志（终端里直接输出）。
2. 生产的话去 Firebase 控制台的 Functions 日志。
3. 注意区分「函数抛错」和「规则拒绝」——错误码不一样。

**图片上传失败**：
1. 签名参数对不对（第 6.3 节）。
2. 文件大小是不是撞到套餐上限——客户端那个数字只是提示。

**只在手机 App 里复现的问题**：先怀疑第 6.4 节那三条。

**看起来是随机失败的测试**：不要靠「多跑几次就绿了」关掉它。先确认失败到底是产品问题还是测试设施问题——这两者的处理方式完全不同，而且这个项目里两种都出现过。

---

## 8. 技术债（实话）

- **`src/pages` 里有几个文件过大**：`Create.tsx` 1297 行、`AdminPanel.tsx` 1105 行、`MeetupDetail.tsx` 1056 行、`Search.tsx` 975 行。改动它们之前先读一遍，它们内部的状态比看起来复杂。
- **测试覆盖不均匀**：`services/` 和 `utils/` 有测试，页面级几乎没有。
- **一个仓库里有三套客户端形态**（Web、Capacitor 壳、Swift 原生），目录边界靠约定维持。
- **有一批 Dependabot PR 积压**（#196–#200 等）。升级前要确认 CI 真的覆盖了被升级的东西。
- **`main` 上有几十个已合并但未删除的分支**。

---

## 9. 还有哪些文档

| 文件 | 内容 |
| --- | --- |
| `README.md` | 项目概览、功能清单、架构表 |
| `SECURITY_MODEL.md` | 安全模型，改规则前必读 |
| `TECH_REPORT.md` | 技术决策与取舍的记录 |
| `QA_TESTING.md` | 测试策略 |
| `docs/acceptance-environment.md` | 验收环境怎么搭 |
| `docs/app-check-rollout.md` | App Check 上线计划 |
| `docs/trigger-idempotency.md` | 触发器幂等性设计 |
| `docs/ios-capacitor.md` | Capacitor 壳 |

---

## 10. 头几天建议

1. 把 emulator 跑起来，确认控制台里看得到那条横幅。
2. 跑一遍 `npm test` 和 `npm run test:rules:emulator`，看它们绿。
3. 读 `src/services/firebase.ts` 和 `src/services/posts.ts`——它们是「客户端怎么跟后端说话」的两个代表。
4. 读 `firestore.rules`，对照第 6.2 节。
5. 找一个小改动提第一个 PR，把流程走通。

有拿不准的地方，**先问再改**，尤其是涉及 `firestore.rules`、`functions/` 和任何会写生产数据的操作。

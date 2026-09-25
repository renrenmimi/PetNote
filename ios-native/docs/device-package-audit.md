# 真机包：构建、签名、审计

`PetNote-TestCloud` 真机包怎么造出来、怎么证明它连的是对的后端、里面有什么。

一条命令：

```
ios-native/scripts/build-testcloud-package.sh [--release-check]
```

它**不碰云端，不跑 firebase，不写任何项目**。用自己的 derived data
（`build/dd-pkg*`），不跟别人的构建抢。

## 四个状态是分开的

把"构建/签名/安装/启动"合成一个"成功"，就会出现"包造好了"然后手里拿着手机
才发现装不上。所以脚本分别报四个，而且**只承认前两个**：

| | 谁来做 | 2026-09-20 的结论 |
| --- | --- | --- |
| 1 构建 | 脚本 | **通过**，未签名，30 MB |
| 2 签名 | 脚本 | **通过**，`codesign --verify --strict` 过 |
| 3 安装 | 需要手机 | **未做** —— `devicectl` 报手机 `unavailable` |
| 4 启动 | 需要手机 | **未做** |

脚本会自己问一句 `xcrun devicectl list devices`，把手机的状态写进第 3、4 行，
所以"未做"后面永远跟着原因，而不是光一个 TODO。

3 和 4 脚本永远不会自己宣称通过。它把命令打出来：

```
xcrun devicectl list devices
xcrun devicectl device install app --device 00008150-0004492C3C87801C \
  ios-native/build/dd-pkg/Build/Products/Debug-TestCloud-iphoneos/PetNote.app
xcrun devicectl device process launch --device 00008150-0004492C3C87801C \
  --console dev.local.petnote.native -petnote-start-signed-out
```

**启动算不算通过，看 console 里有没有这一行**：

```
environment verified: petnote-devtest via firestore.googleapis.com
```

看到 `environment id unchecked` 就是**没有**通过 —— 那表示什么都没校验（见下面"还没到位的两件事"）。

## 审计查了什么，证据在哪

每次运行把完整报告写到 `ios-native/build/dd-pkg-logs/audit-<时间戳>.txt`，
里面每一条都附了它读的文件。

| 查什么 | 从哪读 | 2026-09-20 |
| --- | --- | --- |
| 实际能连的项目 | 包内 `GoogleService-Info-Test.plist` 的 `PROJECT_ID` | `petnote-devtest` 通过（bucket `petnote-devtest.firebasestorage.app`） |
| 后端标记 | 包内 `Info.plist` 的 `PetNoteBackend` | `testcloud` 通过 |
| Bundle ID | 包内 `Info.plist` 的 `CFBundleIdentifier` | `dev.local.petnote.native` 通过 |
| 签名身份 | `codesign -dvvv` | `Apple Development: fengweiren666@yahoo.com (CDMUZA9X3H)` 通过 |
| team | `codesign -dvvv` 的 `TeamIdentifier` | `FS3VY99GNA` 通过 |
| 描述文件设备 | `security cms -D -i embedded.mobileprovision` | 2 台，含你的 iPhone `00008150-0004492C3C87801C` 通过 |
| 描述文件过期 | 同上 | **2026-09-25** —— 只剩几天（注意） |
| 测试开关 | 扫整个 `.app` | 11 个，**这是应该的**，见下 |

**注意"后端标记"这一条读的是构建出来的包，不是 `-showBuildSettings`。**
两者会不一样：`build/dd-testcloud/` 里那个旧包（别的 agent 9-20 11:27 造的）
`PetNoteBackend` 是**空字符串**，而同一时刻 `-showBuildSettings` 说
`PETNOTE_BACKEND = testcloud`。构建设置说的是"打算怎么做"，包里的 Info.plist
才是"实际做成了什么"。审计只认后者。

## 扫描：只扫主二进制会得到假的"干净"

Debug 配置 `ENABLE_DEBUG_DYLIB = YES`，**所有 Swift 代码都在
`PetNote.debug.dylib` 里，主二进制只是个 92 KB 的壳**。实测同一个包：

```
主二进制 PetNote            (92 KB)   → 0 个命中
整个 PetNote.app 目录                 → 14 个命中
   其中 PetNote.debug.dylib (30 MB)   → 12 个
        GoogleService-Info-*.plist    →  2 个（两个项目 id）
```

所以扫描必须是：

```
LC_ALL=C grep -raoE 'petnote[A-Za-z-]+' <包路径> | sort -u
```

`-r` 递归到 dylib，`-a` 把二进制当文本。正则末尾是 `[A-Za-z-]+` 而不是
`-[a-z-]+`，因为有三个开关**没有 `-petnote-` 前缀**，它们是 UserDefaults 的
key，不是启动参数：`petnoteImageDelayMilliseconds`、`petnoteVideoURLOverride`、
`petnoteVideoPosterOverride`。按前缀 grep 会整整走过去（源码里
`Core/Media/MediaView.swift` 和 `Core/Media/RemoteImage.swift` 的注释专门写了这件事）。

## 阳性对照是必须的

"0 个命中"和"扫错地方了"长得一模一样。所以脚本每次都另外构建一个
`Debug-Emulator` 真机包，用**同一条命令**扫它，它必须吐出十几个。
少于 8 个就把主扫描判成 **UNVERIFIED**，不允许写"干净"。

2026-09-20 的对照：**11 个开关**，与被测包一致。对照有效。

`--skip-control` 可以跳过对照，但那样开关清单会被明确标成 UNVERIFIED。
也可以用 `--control-app <路径>` 复用已有的 Debug-Emulator 真机包。

## 11 个开关是应该的，别把它当不合格

`Debug-TestCloud` **本身就是 Debug 配置**
（`SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG PETNOTE_TEST_CLOUD`），
真机验收要用 `-petnote-start-signed-out` 登出起步、`-petnote-video-probe` 看播放状态。
**开关在这个包里是功能，不是缺陷。**

真正一个都不许有的是 **`Release` 配置的候选包**。那个是另一件事，
`--release-check` 会当场重新证明：构建 Release 真机包 → 同一条扫描 → 必须 0 个。
而且只有在对照有效时才敢报"0 = 干净"。

2026-09-20 实测（`--release-check`，同一次运行内）：

```
Debug-TestCloud 真机包  → 11 个开关
Debug-Emulator  真机包  → 11 个开关   （阳性对照，证明扫描有效）
Release         真机包  →  0 个开关   ← 干净，而且是在对照有效的前提下说的
```

### 命中数里要减掉三个不是开关的

`petnote-a`、`petnote-test`、`petnote-devtest` 是 **Firebase 项目 id**，不是开关。
脚本把它们单独列出来，不算进开关数 —— 否则"14 个开关"会把真正该看的数字淹掉。

`petnote-a` 是正则把 `petnote-a9dac` 截断后的样子（数字不在字符类里）。
它出现在每一个包里是**故意的**：`EnvironmentGuard.productionProjectID` 把生产
项目 id 编进二进制，就是为了能认出它、拒绝它。

## plist 到位前后

`Support/GoogleService-Info-Test.plist` 是 gitignore 的，主人 2026-09-20 18:23
放到位。**它不在的时候脚本不会崩** —— 那是一条前置检查：照样构建、照样签名、
照样审计其余各项，只把"连哪个项目"标成 BLOCKED。这个行为要保留，因为这个文件
以后在别人机器上、别的 checkout 里都会缺。

文件不在的后果本来就是明确的：`Core/Auth/FirebaseBootstrap.swift` 按**确切文件名**
找 plist，找不到就 `fatalError("Missing GoogleService-Info-Test.plist")`。
**它不会偷偷退回去用别的 plist**，哪怕包里就躺着一个 emulator 的。这是设计好的。

到位后重跑确认：`PROJECT_ID = petnote-devtest`。脚本会把 `petnote-test`
（本地 emulator）和 `petnote-a9dac`（生产）分别判成 FAIL 并说清是哪一种。

## 两件还没做的，都在 `Config/` 里，不归本次改动管

### 1. `PETNOTE_EXPECTED_PROJECT` 是空的 —— 正向校验其实没开

`Config/Debug-TestCloud.xcconfig` 里写的是：

```
PETNOTE_EXPECTED_PROJECT = $(PETNOTE_TEST_PROJECT_ID)
```

而 `Config/Local.xcconfig`（gitignore 的那个）**没有定义
`PETNOTE_TEST_PROJECT_ID`**，所以它展开成空字符串，包里的
`PetNoteExpectedProject` 也是空的。

后果是实打实的，不是洁癖：

- `EnvironmentGuard.verdict` 走到最后 `guard !expected.isEmpty` 返回 `.unchecked`
  —— **"这个包必须连 petnote-devtest" 这条正向校验根本没执行**。
  （"不许连生产"、"不许连 emulator" 两条反向检查仍然有效，它们不看 expected。）
- `AppEnvironment.allowsWrites` 对 testCloud 返回 **false**，因为它要求
  expectedProjectID 非空。

修法是在 `Config/Local.xcconfig` 加一行：

```
PETNOTE_TEST_PROJECT_ID = petnote-devtest
```

**加之前，第 4 个状态（启动）即使跑通，也只能证明"没连到生产"，
证明不了"连上了 petnote-devtest"。** console 里会是
`environment id unchecked` 而不是 `environment verified: ...`。

### 2. Release 候选包现在带上了测试项目的 plist

plist 一到位就立刻回归了 —— 这正是审计存在的理由。

```
Release 真机包 → 0 个开关，但包内有 GoogleService-Info-Test.plist
                 （PROJECT_ID = petnote-devtest）
```

原因：`Support/` 是 synchronised group，里面的东西被复制进**每一个**配置的包。
`Config/Release.xcconfig` 的 `EXCLUDED_SOURCE_FILE_NAMES` 只排掉了
`GoogleService-Info-Emulator.plist`，新来的这个没排。

这条 xcconfig 自己的注释就写过同一件事："a candidate package has no business
carrying the configuration of a backend it must never talk to"。现在它又发生了一次。

改法：

```
EXCLUDED_SOURCE_FILE_NAMES = GoogleService-Info-Emulator.plist GoogleService-Info-Test.plist
```

脚本把"有没有开关"和"有没有多余的 Firebase plist"分成两条独立判断，
所以不会出现"0 个开关 = 干净"这种把 plist 问题盖掉的结论。

## 一个顺带发现：包里有 emulator 的 plist

`Debug-TestCloud` 的包里有 `GoogleService-Info-Emulator.plist`
（`PROJECT_ID = petnote-test`）。原因是 `Support/` 是 synchronised group，
里面的东西会被复制进**每一个**配置的包；`Config/Release.xcconfig` 用
`EXCLUDED_SOURCE_FILE_NAMES` 显式排掉了它，`Debug-TestCloud` 没有。

**不是静默回退的风险**（按确切文件名找，见上），但它是"这个包不该认识的后端的
配置"。而且它就是扫描结果里 `petnote-test` 那一条的来源 —— 不是代码里的。
报告里记成 WARN，没当失败。要不要在 `Debug-TestCloud.xcconfig` 里也排掉，
是 `Config/` 归属方的决定。

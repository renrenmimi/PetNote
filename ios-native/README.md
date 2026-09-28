# PetNote 原生 iPhone 客户端（第一阶段）

一条核心链路的 Swift 原型：登录 → Feed（含图片与视频）→ 帖子详情 → 多行评论 →
返回并回到原滚动位置。范围、禁令与验收标准以
`PetNote-review-20260908/SWIFT-CLIENT-*.md` 四份文件为唯一来源。

**现有 Capacitor 客户端仍是交付客户端。** 这个工程与它共存：
Bundle ID `dev.local.petnote.native`，和 `dev.local.petnote` 可同时装在一台设备上。

## 本地配置（必须做一次，且不提交）

签名身份是个人凭据，emulator 地址是本机地址，两者都不进仓库：

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig
# 然后填入：
#   DEVELOPMENT_TEAM       = 你的 Team ID（Xcode → Settings → Accounts 可见）
#   PETNOTE_EMULATOR_HOST  = Mac 的局域网 IP（ipconfig getifaddr en0）
```

`Config/Local.xcconfig` 已在 `.gitignore` 里。`Config/Base.xcconfig` 用
`#include?` 可选包含它，所以缺这个文件时工程仍能打开，只是无法签名到真机。

**免费 Personal Team 的 profile 有效期约 7 天**，过期后插线重新构建即可重签。
新设备第一次装还需要在手机上手动信任一次：
设置 → 通用 → VPN 与设备管理 → 开发者 App → 信任。

## 三套环境

靠 `.xcconfig` 与 scheme 隔离，代码里没有判断环境的 `if`：

| Scheme | 配置 | 后端 | 用途 |
| --- | --- | --- | --- |
| `PetNote-Emulator` | `Debug-Emulator` | Firebase emulator | **第一阶段唯一使用的环境**，唯一允许写入 |
| `PetNote-Prod-ReadOnly` | `Debug-Prod` | 生产 | 只读排查，默认不用 |
| `PetNote-Release` | `Release` | 生产 | 性能测量，不写入 |

环境值通过 `Config/Info.plist` 的 `PetNoteBackend` / `PetNoteEmulatorHost`
从 xcconfig 传进 App。

## 跑起来

```bash
# 1) emulator + 测试数据（在仓库根）
export JAVA_HOME=/opt/homebrew/opt/openjdk PATH="$JAVA_HOME/bin:$PATH"

# 模拟器够用时：默认配置，绑 127.0.0.1
npx firebase emulators:start --only firestore,auth,functions --project petnote-test

# 真机要连时：必须换这份配置，它把 emulator 绑到所有网卡
#   默认的 firebase.json 绑 127.0.0.1，手机路由不到那个地址
npx firebase emulators:start --only firestore,auth,functions \
  --config firebase.emulator-lan.json --project petnote-test
cd functions && npm ci
export FIRESTORE_EMULATOR_HOST=127.0.0.1:8088 \
       FIREBASE_AUTH_EMULATOR_HOST=127.0.0.1:9099 \
       GCLOUD_PROJECT=petnote-test
node scripts/seed-acceptance.mjs     # 账号矩阵
node scripts/seed-ios-native.mjs     # 210 条帖子、视频、极端用例

# 2) 单元测试
cd ios-native
xcodebuild test -project PetNoteApp.xcodeproj -scheme PetNote-Emulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:PetNoteAppTests

# 3) 装到真机
xcodebuild -project PetNoteApp.xcodeproj -scheme PetNote-Emulator \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build
xcrun devicectl device install app --device <UDID> \
  build/dd/Build/Products/Debug-Emulator-iphoneos/PetNote.app
```

测试账号 `accept-a@example.com` / `accept-b@example.com`，密码 `Passw0rd!x`。
种子脚本**只写 emulator**：`GCLOUD_PROJECT` 不是 `petnote-test` 就拒绝运行。

真机连 emulator 时把 `PETNOTE_EMULATOR_HOST` 设成 Mac 的局域网 IP
（`ipconfig getifaddr en0`），并确认 emulator 用的是上面那份 LAN 配置——
`lsof -nP -iTCP:8088 -sTCP:LISTEN` 应该显示 `*:8088` 而不是 `127.0.0.1:8088`。

## 真机截图与像素测量

```bash
./scripts/device-screenshot.sh /tmp/shot.png          # 先终止再启动，确保前台是 PetNote
./scripts/sample-pixels.py /tmp/shot.png 0 1800 1206 400   # x y w h
```

`device-screenshot.sh` **总是先 `--terminate-existing` 再截图**，这不是为了方便：
上一轮有过连拍十张当作 PetNote 分析、实际是另一个 App 含个人内容的事故。
`sample-pixels.py` 报颜色数、亮度方差和全黑行数——用来判定"键盘下方有黑块"
（全黑行 > 0）和"图片没显示出来"（颜色数接近 1），这两个都是真机上出现过的缺陷。

本机**不能录屏**（缺 Screen Recording capability），需要动态证据时用连拍。

## 目录

```
App/            入口、根视图
Core/Model/     值类型与解码（PostDecoder 对照 src/services/posts.ts 的 toPost）
Core/Auth/      Firebase 初始化、会话、错误映射
Core/Repository/  数据访问协议与不透明游标
Core/Navigation/  路由枚举与深链接校验
Features/       Auth / Feed / PostDetail
DesignSystem/   间距、圆角、排版、语义色、令牌示例视图
Support/        环境读取 + **会被打包的资源**（Firebase 配置）
Config/         三套 xcconfig + Info.plist（**只被工程引用，不打包**）
docs/           工程决策记录
scripts/        真机截图与像素测量
```

**`Support/` 与 `Config/` 的区别不是风格问题**：
`App/ Core/ Features/ DesignSystem/ Support/` 是 Xcode 16 起的
file-system synchronized group——放进去的文件自动成为 target 的一部分，
资源会被打包。`Config/` 是普通分组，里面的文件在 Xcode 里看得见，
**但不会进 App 包**。

Firebase 的 `GoogleService-Info-*.plist` 一开始放在 `Config/` 下，
结果 App 一启动就 `fatalError` 退出，因为运行时找不到它。
所以**任何需要在运行时读取的文件必须放 `Support/`**。

同步组的另一个好处：**新增 Swift 文件不需要改 `project.pbxproj`**，
工程文件的历史保持很小，签名设置也不会在无关改动里被顺手带上。

## Firebase 配置

| 文件 | 在仓库里吗 | 说明 |
| --- | --- | --- |
| `Support/GoogleService-Info-Emulator.plist` | **在** | 全是占位值；emulator 不校验 App 身份 |
| `Support/GoogleService-Info.plist` | **不在**（gitignore） | 生产配置，需要时本地放置 |

## 已知的工程约束

- 部署目标 **iOS 18.0**（第一阶段暂定基线，实测可在 Xcode 27.0 / 仅 iOS 27 SDK 下构建并装到 iOS 27 设备）
- **Swift 6 语言模式 + 完全严格并发检查**（`SWIFT_STRICT_CONCURRENCY = complete`）
- **不得修改** `ios/App/App.xcodeproj/project.pbxproj`（Capacitor 工程，含有意不提交的本地签名改动）
- CI 只在 `ios-native/**` 变动时触发；**XCUITest 不进 CI**，只在本地与验收时跑

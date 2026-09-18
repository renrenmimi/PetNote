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
npx firebase emulators:start --only firestore,auth,functions --project petnote-test
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

## 目录

```
App/            入口、根视图
Core/Model/     值类型与解码（PostDecoder 对照 src/services/posts.ts 的 toPost）
Core/…          Repository / Auth / Media / Platform（随阶段填充）
Features/       Auth / Feed / PostDetail
DesignSystem/   间距、圆角、排版、语义色
Config/         三套 xcconfig + Info.plist
docs/           工程决策记录
```

源码目录用 Xcode 16 起的 file-system synchronized group，所以**新增 Swift 文件
不需要改 `project.pbxproj`**。这让工程文件的历史保持很小，也让签名设置不会
在无关改动里被顺手带上。

## 已知的工程约束

- 部署目标 **iOS 18.0**（第一阶段暂定基线，实测可在 Xcode 27.0 / 仅 iOS 27 SDK 下构建并装到 iOS 27 设备）
- **Swift 6 语言模式 + 完全严格并发检查**（`SWIFT_STRICT_CONCURRENCY = complete`）
- **不得修改** `ios/App/App.xcodeproj/project.pbxproj`（Capacitor 工程，含有意不提交的本地签名改动）
- CI 只在 `ios-native/**` 变动时触发；**XCUITest 不进 CI**，只在本地与验收时跑

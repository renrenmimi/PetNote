# 性能基线 · 测量边界与可复跑步骤

**原则**：先测量，再优化。每项结论附环境、样本数和局限。
**模拟器的数字不替代真机的启动、帧率、内存和发热结论。**

---

## 固定条件（不写死这些，数字之间就不可比）

| 项 | 值 |
| --- | --- |
| 构建配置 | `Debug-Emulator`（本地）/ `Debug-TestCloud`（真机） |
| 设备 | 模拟器 `iPhone 17` / 真机 `iPhone 17 Pro`（iPhone18,1） |
| 种子 runId | 每次记录 `seedRuns/current` 的 runId，**不硬编码帖子 id** |
| 媒体来源 | 图片走 Cloudinary `demo`；视频走本地 `127.0.0.1:8123`（确定性素材） |
| commit | 每次记录 |

**冷缓存与热缓存分开记。** 冷 = 新装或清过缓存；热 = 同一次会话内第二次进入。

---

## 测量边界（起点与终点必须写清楚，否则数字无意义）

| 指标 | 起点 | 终点 |
| --- | --- | --- |
| **冷启动** | 进程 `exec`（`kinfo_proc.p_starttime`，含 dyld） | **第一帧包含真实 feed 内容且已提交渲染**（`CATransaction` 完成回调） |
| Feed 首屏 | 会话解析完成 | 第一页 20 条全部有 `post.text` |
| 分页 | 触发加载更多 | 新一页的行出现在树里 |
| 打开详情 | 点击 | 评论列表首屏可读 |
| 评论反馈 | 点击发送 | 界面出现该条（占位或确认皆可，**要注明是哪一种**） |
| 滚动掉帧 | 首个滚动事件 | 第 210 条；Instruments `Animation Hitches` |
| 内存 | 启动 | 来回滚 3 轮后的 `phys_footprint`（**不是 `resident_size`**） |

**不要把 `navigationStart` 之后的时间叫完整 App 冷启动。** 那漏掉了 dyld、
Firebase 初始化和第一次布局。

---

## 已核实的结构性事实（读代码 + 实测，非推断）

### 读次数不随分页平方增长

`FeedViewModel.apply(for newPosts:)` 调用
`likes.likedPostIDs(among: newPosts.map(\.id))` —— **只查新到的那一页**，
不是全部已加载的帖子。

每页的读次数：

```
1 次   posts 查询（orderBy createdAt desc, limit 20）
1 次   likes 集合组查询（in 查询，分块上限 30，20 条帖子落在一块里）
────
2 次 / 页，与已加载页数无关
```

若将来改成对全部已加载帖子重查，读次数会变成 O(页数²)。这条值得留一个守卫。

### 图片缓存尺寸已量化

请求尺寸按 **128px 步长**量化，避免同一张图因为 401pt 和 402pt 被缓存两份
（这个缺陷发生过，实测两份副本）。

---

## 本地可跑的部分

```bash
cd ios-native
# 一次只跑一项重型任务
xcodebuild test -project PetNoteApp.xcodeproj -scheme PetNote-Emulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:PetNoteAppUITests/LaunchUITests \
  -derivedDataPath build/dd -clonedSourcePackagesDirPath build/spm
```

**模拟器上能得出的**：读次数、请求去重、布局是否跳动、资源是否累积（计数层面）。
**模拟器上得不出的**：启动耗时、帧率、真实内存、发热。这四项**保持未验证**。

---

## 真机部分：工具已备好，等主人回来直接跑

**不要在主人不在时连接设备。** 以下步骤是给他回来后用的，不是现在跑的。

### 前置（约 1 分钟，主人做）

1. iPhone 插线解锁，信任此电脑
2. 设置 → 显示与亮度 → 自动锁定 → 永不
3. 确认「设置 → 开发者 → 启用 UI 自动化」仍是开的

### 然后（我做，不需要他参与）

```bash
# 1. 描述文件若已过期（2026-09-25），先重新生成 —— 自动，不需要他操作
xcodebuild build -project PetNoteApp.xcodeproj -scheme PetNote-TestCloud \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates \
  -derivedDataPath build/dd-pkg

# 2. 包审计（构建/签名/安装/启动四个状态分开记）
bash scripts/build-testcloud-package.sh --release-check

# 3. 真机验收
xcodebuild test -project PetNoteApp.xcodeproj -scheme PetNote-TestCloud \
  -destination 'platform=iOS,id=00008150-0004492C3C87801C' \
  -only-testing:PetNoteAppUITests/DeviceAcceptanceUITests \
  -derivedDataPath build/dd-pkg -allowProvisioningUpdates
```

### 需要 Instruments 的四项（他回来后一次做完）

启动耗时、滚动帧率、内存曲线、发热。样本数 **≥20**（少于 20 不给 p95，
并打印理由）。离群值列出不删。

### 一条必须避开的测量陷阱

真机用例读状态时**不要单次读**。上一轮「评论计数没更新」的误报就是点下发送后
立刻读，读到写入尚未返回的值。连读若干次并打印序列：

```
MEASURED detail count over 6s: 5,6,6,6,6,6,6,6,6,6,6,6
```

**「它没变」和「我看的时候它还没变」是两个结论。**

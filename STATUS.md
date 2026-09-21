# PetNote Swift 第一阶段 · 状态表

这是**唯一**的状态表。每批工作收口后更新这一份，不另写过程总结。

**更新** 2026-09-21 · 分支 `feature/ios-native-prototype` · PR [#204](https://github.com/renrenmimi/PetNote/pull/204)（Draft，不合并）

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

## 未提交改动（HEAD = `4ba1c57`）

```
M  App/SignedInView.swift                  详情页回调接线
M  Core/Model/Post.swift                   withCommentCount
M  Features/Feed/FeedView.swift            用显示计数
M  Features/Feed/FeedViewModel.swift       评论计数收敛
M  Features/PostDetail/PostDetailView.swift    用实时计数
M  Features/PostDetail/PostDetailViewModel.swift  本屏偏移 + 回调
M  PetNoteApp.xcodeproj/.../PetNote-TestCloud.xcscheme  启用 UI 测试
M  PetNoteAppUITests/UITestSupport.swift   弹窗竞态
?? PetNoteAppTests/CommentCountSyncTests.swift      6 条回归
?? PetNoteAppUITests/DeviceAcceptanceUITests.swift  7 条真机用例
```

**待办**：跑完全量确认无回退后提交。

---

## 云测试环境（已就绪，不再扩大）

`petnote-devtest`：6 函数、`nam5` Firestore、规则已发布、25 索引、3 个测试账号、210 帖种子。
$1 预算告警（50/90/100%）+ 镜像清理策略。生产 `petnote-a9dac` 零写入零部署。

**仅用于已授权的定点验收。重复回归和压力场景在本地 emulator 跑。不做云端负载测试。**

---

## 资源

清理后：`build/dd`（2.6G）、`build/spm`（1.2G）、`build/dd-pkg`（785M）。
**一个**模拟器（iPhone 17）。已回收 12 GB。

# 原生推送：单独的方案（本轮不做）

## 先分清两件事

| | 站内通知 | 原生推送 |
|---|---|---|
| 是什么 | App 里铃铛上的红点和通知列表 | App 没打开时，锁屏和通知中心弹出的消息 |
| 旧版有没有 | 有（网页 `/notifications`） | **没有**：网页、旧 iPhone 壳、服务端都没有推送代码 |
| 这轮 | 已迁移（`e2379e2`） | 只写方案，不实现 |

核对方法：在 `functions/src`、`src`、`ios-native` 里搜 `getMessaging`、`firebase-admin/messaging`、`fcmToken`、`FirebaseMessaging`、`registerForRemoteNotifications`，都搜不到。

站内通知由服务端触发器写入（`functions/src/notifications.ts`）。写入前会先查收件人的设置（`users/{uid}/settings/preferences` 里的点赞、评论、关注三个开关），还会查屏蔽关系。推送如果要做，就接在这之后：先决定"该不该通知"，再决定"要不要也推到手机"。这样开关和屏蔽规则只有一份。

## 做推送需要什么

1. **付费的 Apple 开发者账号（每年 99 美元）**
   - 现在用的免费 Personal Team 不能开推送能力。这是新增付费服务，要你决定。
   - 没有它，真机收不到任何推送。模拟器可以用 `xcrun simctl push` 模拟一条推送，只能测 App 收到之后怎么处理。

2. **APNs 密钥（.p8）**
   - 在 Apple 开发者后台生成，再上传到 Firebase 控制台。先只传测试项目 `petnote-devtest`。
   - 这一步要账号本人操作。密钥不进仓库、不进聊天。

3. **客户端**
   - 用 `FirebaseMessaging`。它在已经在用的 firebase-ios-sdk 包里，不引入新的依赖来源。
   - 在合适的时机请求通知权限，而不是一打开 App 就弹。
   - 拿到设备令牌后保存，退出登录时删掉这台设备的令牌。

4. **新的数据位置和规则**
   - 设备令牌要存在某处，比如 `users/{uid}/devices/{deviceId}`。
   - 这需要改 `firestore.rules`：只有本人能写自己的设备令牌。
   - 注销账号（`deleteUserAccount`）也要一并删掉令牌。
   - 这些都属于改授权和删除规则，要你批准。

5. **服务端**
   - 在现有触发器"决定要通知"之后，再用 Admin SDK 发推送。
   - 发送失败、令牌失效时要清理掉。
   - 要部署新版 functions：先测试项目，生产另行批准。

6. **隐私**
   - 推送内容会显示在锁屏上，比如"Alice 赞了你的帖子"。
   - 隐私政策要加一条"推送令牌"。App Store 的隐私标签也要相应更新。
   - 这是 `legal-pages-ios-review.md` 之外的新增项。

## 建议的顺序（每一步都要单独批准）

1. 你决定是否开通付费开发者账号。
2. 开通后，本人生成 APNs 密钥，只上传到测试项目。
3. 客户端：权限、令牌、退出登录删令牌。先在模拟器上用 `simctl push` 验证点开推送能到对应帖子。
4. 规则和服务端：只部署到测试项目，用专用测试账号在真机上端到端验证。
5. 隐私文本修订经你确认后，再考虑生产。

## 这一轮明确不做的

- 不开推送能力，不改签名配置。
- 不加 `FirebaseMessaging`，不改规则，不部署任何函数。

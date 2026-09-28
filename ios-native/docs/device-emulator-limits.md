# 真机连 emulator：一条无法绕开的限制

**状态** 已实测确认 · 2026-09-19
**影响** 阶段 4.2 与阶段 5C 的真机部分

## 结论先说

**iPhone 真机连本机 emulator 时，callable（评论）用不了。** 读路径
（Firestore、Auth 登录）不受影响。这不是配置问题，是 Firebase iOS SDK 的
一条安全策略。

## 怎么发现的

评论在模拟器上一直返回"请先登录"，而同一个账号明明已登录。客户端日志显示
token 是拿到了的：

```
create: uid=O4mLM4 verified=false tokenLength=541
```

而用 curl 带同一形态的 token 直接打 emulator，服务端行为完全正确：

```
不带 token → {"message":"Must be logged in.","status":"UNAUTHENTICATED"}
带 token   → {"message":"Verify your email before commenting.","status":"PERMISSION_DENIED"}
```

把 App 的 functions 端口指向一个只打印请求头的本地服务器，它**一个请求都没收到**——
说明失败发生在发送之前。打出完整的 NSError 才看到原话：

```
domain=com.firebase.functions code=16
desc=Refusing to send Auth, FCM, and AppCheck tokens over HTTP to non-loopback host.
```

## 为什么

Functions SDK 不会把 Auth / FCM / AppCheck 的 token 通过**明文 HTTP** 发给
**非 loopback** 的主机。这是合理的：token 等同于凭据，明文发到局域网地址上
任何同网段的设备都能截获。

- **模拟器**与 Mac 共享网络栈，所以可以用 `127.0.0.1` —— 是 loopback，token 照发。
- **真机**只能用 Mac 的局域网地址（`192.168.x.x`），那不是 loopback，token 被
  SDK 自己拦下，请求根本不发出。服务端于是从未见过调用者，每个门槛都报
  "Must be logged in" —— 看起来像登录出了问题，其实不是。

## 当前处理

`AppEnvironment.emulatorHost` 按目标环境分开：模拟器强制 `127.0.0.1`，真机用
配置的局域网地址。

`AppEnvironment.supportsCallables` 在"真机 + emulator"这个组合下为 false。

**但这一行到 2026-09-19 为止是死代码 —— 全工程零引用。** 本文件此前写的是
"供 UI 据此说明"，那句话不成立：界面从来没有读过这个标志。真机上发评论时，
Functions SDK 的原始错误（`com.firebase.functions code=16`）会直接冒出来，
没有任何一层把它翻译成人能看懂的话。

写下来是因为：一个定义了却没人用的标志，比没有这个标志更糟 ——
它让读代码的人以为这种情况已经被处理过了。已派给负责评论失败分支的人接上，
按"确定失败、不重试"处理（重试一百次也不会成功），且**不以禁用输入框的方式绕过**。

## 如果将来要在真机上跑通 callable

按代价从低到高，**都没有做，也都需要先批准**：

| 办法 | 代价 |
| --- | --- |
| 本地 HTTPS 反代（如 caddy/mkcert 自签）+ 设备信任该根证书 | 要在测试机上装并信任一个根证书，属于设备信任边界的改动 |
| HTTPS 隧道（ngrok 之类） | 外部服务，emulator 数据经第三方，需要开通与授权 |
| 真机改连生产后端 | **明确禁止**：第一阶段唯一允许写入的是 emulator |
| 只在模拟器上验收 callable 相关项 | 免费，但真机上的评论链路就是未验证状态 |

**现状采用最后一条，并如实记为未验证**，而不是把模拟器结果写成真机通过。

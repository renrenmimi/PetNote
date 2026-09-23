# 真实邮件与 Google 登录：测试步骤（只在测试项目 `petnote-devtest` 上）

这份只列**需要你本人动手**的部分，以及每一步应该看到什么。
全部在测试项目上做，**不碰生产**。我不会用任何真实账号密码做自动化，也不会给你没指定的邮箱发信。
验证码（OTP）重置密码**保持关闭**，下面第 C 节就是确认它确实没出现。

测试项目当前的设置（2026-09-22 只读核对）：只开了邮箱密码登录；邮件里的链接地址是
`https://petnote-devtest.firebaseapp.com/__/auth/action`；防止探测账号是否存在的保护（enumeration protection）已开；
项目没有设密码规则，所以 Firebase 的网页只要求 6 位，而 App 自己注册时要求至少 8 位。

---

## 你需要准备的

- **一个你能收信的邮箱。** 可以用加号地址反复测，比如 `you+pn1@…`、`you+pn2@…`，都进同一个收件箱。
- 手机上装好测试版（左上角徽标写着 `TESTCLOUD · petnote-devtest`）。徽标不是这几个字，**就停下**，说明装的不是测试版。

---

## A. 注册后验证邮箱

1. 在 App 里用新地址注册，密码至少 8 位。
   - 应看到横幅：**Verify your email to start posting and commenting**。
2. **先不要打开邮件**，做两件事：
   - 点横幅上的 **I verified my email**，应提示还没验证。
   - 找一条帖子试着评论，应被拒绝（提示先验证邮箱）。
3. 打开邮箱，核对这封信：
   - 收到了没有、大约多久到（也看看垃圾箱）。
   - 信里链接的开头是 **`petnote-devtest.firebaseapp.com`**，里面有 `mode=verifyEmail`。
   - **如果写的是 `petnote-a9dac`，立刻停下告诉我**：那是生产项目。
4. 点链接，应打开 Firebase 的页面，写着邮箱已验证。然后手动切回 App。
5. 再点 **I verified my email**：横幅应消失，这时评论能发出去。
   之后我可以只读核对这个账号在服务端已是「已验证」，那条评论也在。
6. （可选）再点一次信里的旧链接，应提示已失效或已使用。

## B. 忘记密码

1. 退出登录，点 **Forgot your password?**，填同一个地址。
   - 应提示 **Reset link sent. Check your email.**，按钮 60 秒内不能再点。
2. 核对邮件：链接开头同样是 `petnote-devtest.firebaseapp.com`，里面有 `mode=resetPassword`。
3. 在打开的网页上设新密码。**请用 8 位以上**：网页只要求 6 位，但 6 位的密码在 App 注册时会被拒。
4. 回到 App：
   - 旧密码登录应失败，提示是笼统的「邮箱或密码不对」。这是故意的，不告诉别人这个邮箱有没有注册。
   - 新密码能登录，账号仍是已验证。
5. 用一个**没注册过**的地址点忘记密码：App 上的提示和第 1 步一样，但**不应收到任何邮件**。

## C. 确认验证码重置没有出现

做 B 的时候顺便看：App 里从头到尾**没有**输入验证码的框；邮件里是链接，**不是**一串数字。

---

## Google 登录：需要你在控制台做的两步

我这边已确认：测试项目目前**没开** Google 登录；App 的测试配置文件里还缺 Google 登录要用的两项
（`CLIENT_ID`、`REVERSED_CLIENT_ID`）。打开 Google 登录只能在网页控制台里点，没有命令可以代替。

1. 打开 Firebase 控制台，**先确认左上角选的是 `petnote-devtest`**，然后：
   **Authentication → Sign-in method → Add new provider → Google → Enable**，选一个支持邮箱，保存。
2. 打开 Google Cloud 控制台（同样是 `petnote-devtest`）→ **OAuth consent screen**（有的界面叫 Google Auth Platform）：
   - 如果状态是 **Testing**，把你自己的 Google 账号加进测试用户。
   - 看一眼有没有自动生成一个给 `dev.local.petnote.native` 用的 **iOS** 客户端；没有的话告诉我。

做完告诉我一声。之后我能自己做的：只读确认 Google 已开启；重新导出测试配置文件并换掉本地那份；
确认缺的两项已经有了（只看名字，不看内容）。

**还需要你定一件事**：iOS 上的标准做法要给 App 加一个新依赖（Google 官方的 GoogleSignIn）。
不加也有别的办法，但那不是 Google 给 iOS 的正式做法，我没验证过，不建议。

**要注意**：如果某个邮箱已经用邮箱密码注册、但**还没验证**，再用同一个邮箱的 Google 账号登录，Firebase 会把原来的密码登录方式替换掉。
所以测 Google 登录时，**请用和上面 A、B 不同的邮箱**。

真正点 Google 登录那一步只能在手机上手动做（要打开 Google 的真实页面），模拟器和 CI 都做不了。

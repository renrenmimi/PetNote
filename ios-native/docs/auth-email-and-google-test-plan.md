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

## Google 登录

### 已经做好的（2026-09-23）

- App 已接入 Google 官方的 GoogleSignIn 10.0.0，并已获批准。
- 按钮只在同时满足三个条件时出现：测试云这个配置、测试项目给了 iOS 客户端 ID、URL scheme 已登记。缺一个都不显示。GoogleSignIn 在缺配置时会让 App 直接崩溃，所以必须全部先检查。
- Firebase 那一半已在本地 emulator 上用替身跑通：新账号建资料、退出再登录还是同一账号、中途退出、失败后重试、同邮箱不同登录方式。见 `PetNoteAppUITests/GoogleSignInUITests.swift`。

### 同一个邮箱、不同登录方式：Firebase 会怎么做

App 自己**不会**合并任何账号：不调用 link，也不去查某个邮箱用哪种方式登录。以下是 Firebase 本身的行为：

| 情况 | 结果 | 依据 |
| --- | --- | --- |
| 已有**已验证**的密码账号，再用同一个 Gmail 的 Google 登录 | **Firebase 自动把 Google 挂到原账号上**：同一个账号，两种方式都能登录 | emulator 实测（界面测试） |
| Google 没有替这个邮箱担保（例如非 Gmail 的企业邮箱） | Firebase 拒绝。App 显示旧版原话：「This email is set up with another sign-in method. Use that one, or reset your password.」账号仍只有密码一种 | emulator 实测（界面测试） |
| 已有**未验证**的密码账号，再用 Google 登录 | Firebase 删掉原来的密码登录，账号改由 Google 登录 | Firebase 文档和 emulator 源码，**未实测** |
| 已有 Google 账号，再用同一邮箱注册密码账号 | 提示「已有账号」，不会挂在一起 | Firebase 文档和 emulator 源码，**未实测** |

前两种是 Firebase 的规则，App 关不掉。只有在项目设置里允许「一个邮箱多个账号」才会变，这由你决定。

### 你要在控制台做的（只在 `petnote-devtest`）

1. 打开 Firebase 控制台，**先确认左上角选的是 `petnote-devtest`**，然后：
   **Authentication → Sign-in method → Add new provider → Google → Enable**，选一个支持邮箱，保存。
2. 不需要添加测试用户：只读取姓名、邮箱、头像的应用，在「Testing」状态下也能登录（Google 的说明）。

也有命令行做法（在 firebase.json 里写 auth 配置再部署），但它会在项目里顺带建一个网页应用；而仓库默认项目是生产，一旦漏写 `--project` 就会改到生产。所以**不用**这个办法。

做完告诉我一声。之后我能自己做的：

- 只读确认 Google 已开启；
- 重新导出测试配置文件，换掉本地那份；
- 确认新增了 `CLIENT_ID`、`REVERSED_CLIENT_ID` 两项（只看名字，不看内容），把后者填进本地配置，重新打包。

如果导出的配置里还是没有这两项，说明没有自动生成 iOS 客户端，要在 Google Cloud 控制台里建一个（Credentials → Create OAuth client ID → iOS，Bundle ID 填 `dev.local.petnote.native`）。

### 留到真机集中验收、需要你本人的

真的点一次「Continue with Google」，用你自己的 Google 账号走完 Google 的页面。依次确认：

1. 登录后进入引导或 Feed；
2. 退出后再登录，还是同一个账号；
3. 在 Google 页面中途点取消，回到登录页，没有报错。

**请用和上面 A、B 不同的邮箱**：未验证的密码账号会被 Google 登录顶替（见上表）。

另外，一个只用 Google 登录的邮箱，如果在网页上点「忘记密码」，Firebase 会发重置邮件。emulator 上，完成重置会把 Google 登录方式去掉、只留密码；生产上是否一样**未验证**，真机验收时顺便看一下。

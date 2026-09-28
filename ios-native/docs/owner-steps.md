# 需要你动手的几件事（2026-09-25）

每件事都写了：打开哪个链接、点哪里、做完发什么、什么**不能发**。
任何密码、验证码、key、secret，都**不要**发进聊天。

## 0. 现在就要：在 Xcode 里登录你的 Apple ID（约 2 分钟）

手机上测试版的签名**已经在今天（9 月 25 日）上午 9:21（美西时间）到期**，现在那个 App 打不开。
这台 Mac 的 Xcode 里没有登录任何账号，所以没法签新的；你登录后，我重签一份 7 天的，覆盖安装，数据保留。

1. 打开 Xcode，点屏幕左上角菜单 **Xcode → Settings…**（或按 ⌘ 加逗号）。
2. 点窗口上方的 **Accounts**。
3. 点左下角的 **+** → 选 **Apple ID**（新版 Xcode 可能写作 Apple Account）→ 点 **Continue**。
4. 输入你以前给这台 Mac 装 PetNote 用的那个 Apple ID 和密码。要验证码的话，在你自己的设备上输入。
5. 成功后，右边会出现一行团队名，通常带 **(Personal Team)**。

- **发给我们：**「Xcode 登好了」，加上右边那行团队名。
- **不要发：** Apple ID 密码、验证码。

## 三件事一览

- **1. 测试用 Cloudinary 账号**：约 10 分钟，做完**只发 cloud name**。
- **2. 测试项目打开 Google 登录**：约 2 分钟，做完发「Google 开好了」。
- **3. 一个能收信的测试邮箱**：约 1 分钟，**只发邮箱地址**。

## 1. 测试用 Cloudinary 账号（约 10 分钟）

1. 打开 https://cloudinary.com/users/register_free ，点 **SIGN UP WITH EMAIL**，用一个**从没注册过 Cloudinary 的新邮箱**注册，再去邮箱点验证链接。
   不要点 Google / GitHub 注册：如果那个账号就是正式版在用的，会直接进到正式账号里。注册后的问卷随便选或跳过。
2. 登录后打开 https://console.cloudinary.com/app/settings/api-keys 。这页上有 **Cloud name**、**API Key**、**API Secret**。先别复制到任何地方。
   如果 Cloud name 是 `dgeunvmmn`，那是**正式账号**，停下告诉我们。
3. 打开「终端」：按 ⌘ 加空格，输入 `终端`（或 `Terminal`），回车。
4. 把下面这一整行粘进去，回车：

   ```
   cd ~/Downloads/Vide/PetNote-iOS && node functions/scripts/setup-test-cloudinary.mjs
   ```

5. 它会一个一个问，照这样回答：
   - `Test account cloud name:` → 打上 cloud name，回车。**这一问会显示在屏幕上，只输 cloud name，别粘别的。**
   - `API key (hidden):` → 回网页复制 API Key，回终端按 ⌘V，回车。**屏幕上什么都不显示是正常的。**
   - `API secret (hidden):` → 用 API Secret 那一行旁边的复制按钮复制，回终端按 ⌘V，回车。
   - 如果问 `Delete them from this TEST account now? [y/N]` → 输入 `y`，回车（新账号自带一个谁都能往里传的预设，要删掉）。
   - 最后问 `Store the key and secret as secrets of petnote-devtest now? [y/N]` → 输入 `y`，回车。
6. 最后一行是 `Done. Send only the cloud name.` 就成功了。
   如果是 `Not finished — see FAIL above.`，把终端截图发给我们：脚本从不把 key 和 secret 打到屏幕上，截图是安全的。
7. 做完随便复制一段别的文字，把剪贴板里的 secret 冲掉。

- **发给我们：** 只发 cloud name。它本来就是公开的，每张图片的地址里都有。
- **不要发：** API Key、API Secret、网页上以 `cloudinary://` 开头的那一行（里面同时有 key 和 secret）、这一页的截图、Cloudinary 登录密码。

之后我们做：把两个测试用的媒体函数（上传签名、删除自己的文件）只部署到测试项目 `petnote-devtest`，这是你已经有条件批准过的。
提醒一句：只部署这两个，上传能成功，但带图发帖、换头像仍会被测试项目上 5 个旧版函数拒掉；重新部署那 5 个要你另外点头（见 `test-cloudinary-setup.md` 的「还需要你另外批准的一项」）。

## 2. 测试项目打开 Google 登录（约 2 分钟，只在 petnote-devtest）

1. 用你自己的 Google 账号打开：
   https://console.firebase.google.com/project/petnote-devtest/authentication/providers
2. 先看页面左上角的项目名：必须是 **petnote-devtest**。如果是 `petnote-a9dac`（正式版），**停下**。
3. 在 **Sign-in method** 这一页，点 **Add new provider**。
4. 在 **Additional providers** 里点 **Google**。
5. 打开 **Enable** 开关。
6. **Project support email** 下拉框里选你自己的邮箱（用户在 Google 登录页上可能看到它）。
7. 点 **Save**。回到列表，Google 那一行显示 **Enabled** 就好了。
8. Google 面板里有一块可以展开的 **Web SDK configuration**，里面有 client secret：**不用打开，不要复制**。

- **发给我们：**「Google 开好了」。
- **不要发：** Web client secret，或任何拍到它的截图。

**如果提示没有权限：** 打开 https://console.cloud.google.com/iam-admin/iam?project=petnote-devtest ，在列表里找你的邮箱，看 **Role**（角色）那一列。
需要 **Owner** 或 **Editor**（**Firebase Admin** 也可以）。只有 **Firebase Authentication Admin** 不够：按 Google 的权限表，它没有「新建 OAuth 客户端」这一项，而打开 Google 登录时正要新建它。把你看到的角色名告诉我们。

**为什么这一步只能你来点：**
- 我们的工具要打开 Google 登录，必须同时交出一对「OAuth 客户端 ID + 密钥」
  （Firebase 文档：https://firebase.google.com/docs/auth/configure-oauth-rest-api ）。
- 这对东西平时就是你在控制台点 **Enable** 那一刻由 Firebase 自动建的，Google 的列表里叫
  "Web client (auto created by Google Service)"（https://firebase.google.com/docs/auth/android/play-games ）；iOS 用的那个客户端也是这样来的。
- Google 没有开放「用程序新建这种客户端」的接口。以前唯一能建的接口 2026-03-19 已关停，而且建出来的只能给另一个产品（IAP）用
  （https://cloud.google.com/iap/docs/programmatic-oauth-clients ）；现在 IAM 里的 OAuth 客户端接口只服务企业员工登录
  （https://docs.cloud.google.com/iam/docs/reference/rest/v1/projects.locations.oauthClients ）；
  Firebase 自己的教程也是让人先去控制台手动建（https://firebase.google.com/codelabs/firebase-terraform ）。
  Google 文档没有一句话直说「没有接口」，这是由上面几条合起来得出的。
- 这个按钮在网页控制台里，要用你登录的 Google 身份点；我们手上只有命令行工具，碰不到网页上的按钮。

之后我们做：用只读命令重新下载测试项目的 iOS 配置文件（`GoogleService-Info-Test.plist`，不进仓库），确认多了 `CLIENT_ID` 和 `REVERSED_CLIENT_ID` 两项，把后者填进本机配置 `Config/Local.xcconfig`（也不进仓库）的 `PETNOTE_TEST_GOOGLE_REVERSED_CLIENT_ID`，重新打包，Google 按钮才会出现。
如果下载下来还是没有这两项，说明 iOS 客户端没有自动建出来，到时再请你在 Google Cloud 控制台点一次（我们会给链接）。

## 3. 一个能收信的测试邮箱（约 1 分钟）

- **发给我们：** 一个你能收到信的邮箱地址，只要地址。
  如果是 Gmail，并且同意我们用 `名字+pn1@gmail.com`、`+pn2` 这种变体（都进同一个收件箱），顺便说一声。
- 我们只在测试项目 `petnote-devtest` 里用它建测试账号，然后发「验证邮箱」和「重置密码」两种信。正式版一概不碰。
- 信来自 **noreply@petnote-devtest.firebaseapp.com**（Firebase 默认发件人，格式是 `noreply@项目名.firebaseapp.com`）。
- 很可能进**垃圾邮件**，请也翻一下垃圾箱。
- 收到后告诉我们：到了没有、大约几分钟到、在收件箱还是垃圾箱。信里的链接**你自己点**。
- **不要发：** 这个邮箱的登录密码；信里的链接本身（拿到链接就能验证或改掉测试账号的密码）。
- 以后测 Google 登录要换一个邮箱，别用这一个：同一个邮箱的两种登录方式会互相顶替。

Firebase 这边不需要你开任何东西：测试项目的邮箱密码登录已经开着（2026-09-22 只读核对过），「验证邮箱」「重置密码」用的是默认模板，不需要单独开启。**Templates** 页面你不用去；发件人和链接地址我们会只读核对。

## 不需要你做的（我们自己来）

- Cloudinary 里的两个上传预设、删掉自带的公开预设、传一张图和一段视频再删掉：第 1 件的脚本自动做。
- 部署两个测试媒体函数，并确认它们只在 `petnote-devtest`。
- Xcode 登好后：签名、打包、装到手机。
- Google 开好后：下载配置、填本机配置、重新打包。
- 用你给的邮箱建测试账号、发测试邮件、核对发件人和链接。
- 不需要你去 Google Cloud 控制台建任何东西（除非第 2 件最后说的那种情况）。
- 正式版（`petnote-a9dac`、Cloudinary 正式账号）什么都不用动。

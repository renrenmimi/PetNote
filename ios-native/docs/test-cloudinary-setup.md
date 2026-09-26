# 测试用 Cloudinary：你要做的，和之后要部署的

测试项目 `petnote-devtest` 用一个**单独的免费 Cloudinary 账号**，不复制、不读取、不使用生产的媒体密钥。

服务端已经改成按项目选账号（`functions/src/platform.ts`，`22fd12e`）：

- 生产项目拿到的值和以前完全一样。
- 测试项目在配好自己的账号之前，签名、删除、媒体地址校验三处**都会拒绝**，不会退回到生产账号。
- 这个改动还没有部署。

## 你要做的：最短步骤（约 10 分钟）

1. 用一个**新的**邮箱注册免费 Cloudinary 账号（https://cloudinary.com/users/register_free），验证邮箱。**不要**在生产账号里新建子账号或项目。
2. 登录后打开 Settings → API Keys，找到 cloud name、API key、API secret。先不要复制到任何地方。
3. 在你自己电脑的终端里，进到仓库根目录，运行：

   ```
   node functions/scripts/setup-test-cloudinary.mjs
   ```

   - 先输入 cloud name（会显示，它本来就是公开的）。
   - 再输入 API key、API secret：**输入时屏幕上不显示**，直接粘贴后回车。
   - 如果它说账号里有「unsigned」预设，回答 `y` 让它删掉（新账号通常自带一个）。
   - 最后问要不要存进 `petnote-devtest`，回答 `y`。
4. 看到 `Done. Send only the cloud name.` 之后，**只把 cloud name 发给我**。

密钥去了哪里、没去哪里：

- 只经过隐藏输入，直接交给 firebase-tools 存进测试项目的 Secret Manager。
- 不进聊天、不进仓库、不进 shell 历史（没有出现在任何命令行参数里）。
- firebase-tools 会把请求连同密钥写进它的调试日志 `firebase-debug.log`。脚本让它在一个私有临时文件夹里运行，运行完连文件夹一起删掉。
- 项目名在脚本里写死为 `petnote-devtest`，碰不到生产。
- 输入生产的云名 `dgeunvmmn` 会在联网前直接拒绝（已实测）。

## 脚本会检查什么（有一项不过就停，不存密钥）

| 步骤 | 检查 |
| --- | --- |
| 1 | 不是生产账号：输入时查一次；拿密钥问 Cloudinary 之后，再查一次它报的云名 |
| 2 | key 和 secret 属于这个云名 |
| 2b | 账号里没有 unsigned 预设。有的话任何人都能往里传文件，包括传进 `petnote/users/某人/`，而删除函数会把它当成那个人的文件 |
| 3–4 | 建好 `petnote_image_signed`、`petnote_video_signed` 两个**签名**预设，不设文件夹、public ID 前缀、文件名规则；再读回来核对 |
| 5 | 用 App 的方式各传一张小图、一段示例视频，核对地址形状，核对 App 用的尺寸变换能打开；然后删掉这两个测试文件。中途出错也照样删 |
| 6 | 用写死的 `--project petnote-devtest` 存两个密钥：值走 stdin，带 `--non-interactive`，不会重新部署，也不会删旧版本 |

脚本不打印 key、secret、签名，也不打印 Cloudinary 的原始返回或报错原文，只打印状态码和固定说明。原因是 Cloudinary 的签名错误会把被签名的字符串原样带回来。

两个预设为什么要这样设（依据 Cloudinary 官方文档：upload presets、folder modes、authentication signatures）：

| 设置 | 值 | 原因 |
| --- | --- | --- |
| 模式 | **Signed** | 服务端会把预设名发给每个客户端；设成不签名，任何人都能传 |
| folder、asset folder、public ID 前缀、public ID | **都不设** | 服务端要求地址里有 `/petnote/`。新账号是「动态文件夹」模式，签名里的 `folder` 会成为 public ID 的前缀；预设里一旦设了这些，就可能把它覆盖掉 |
| Use filename | 不开 | 和生产一致，ID 随机 |
| 大小上限 | 设不了 | 在账户套餐上。免费版：图片 10 MB、视频 100 MB |
| Strict Transformations | 保持关闭（默认） | App 会在地址上加尺寸参数，开了之后这些都会失败 |

## 你授权的两个测试媒体函数：名称、用途、权限

| 函数 | 做什么 | 谁能调 | 读写 | 用到的密钥 | 对外副作用 |
| --- | --- | --- | --- | --- | --- |
| `getCloudinaryUploadSignature` | 签一次上传：`folder=petnote/users/{本人}`、`timestamp`、`upload_preset` | 已登录；被封、注销中、已注销的都拒绝；每人每分钟 30 次 | 读 `users/{uid}`、`users/{uid}/admin/state`、`userDeletionTombstones/{uid}`；写限流记录 | 测试账号的 `CLOUDINARY_API_KEY`、`CLOUDINARY_API_SECRET` | 无：签名在服务端本地算，不调用 Cloudinary |
| `deleteCloudinaryAssetsCallable` | 删文件 | 已登录；每人每分钟 30 次，每次最多 30 个 | 写限流记录 | 同上 | **会删除测试账号里的文件** |

**删除能删到哪里（按代码核实，`functions/src/media.ts`）：**

- **云名**只来自按项目 ID 查的表。测试项目那一行没填之前是空的，函数直接拒绝；填了也只能是测试账号：部署入口会拒绝任何指向生产云名的配置。删除请求本身不能指定云名。
- **能删的文件**：只有 public ID 以 `petnote/users/{调用者本人}/` 开头的文件。别人的文件删不了；这个文件夹以外的文件删不了，包括脚本的探针文件夹 `petnote/users/setup-probe`。
- **「只能删测试流程创建的文件」代码做不到，能保证的就是上面这条前缀规则。** 在这个前缀下的任何文件，调用者都能删，不管是谁放进去的。所以上面 2b 那一步要求账号里不能有 unsigned 预设，防止别人往里放文件。
- **什么情况下会被调用**：
  - 服务端没有任何触发器或定时任务会删媒体。
  - 发帖的自动回收保持停用，不会恢复。
  - App 里唯一调用它的地方：换头像时，图片已上传、而服务端**明确拒绝**了这次保存，App 会删掉刚传的那张。这和网页版现有做法一样（网页版在打卡、写评价、引导、添加地点失败时也这样做）。结果未知时不删。
  - 这个函数部署到测试项目后，测试版的这条路就会真的开始删。

**部署入口的保护**（`functions-testcloud/index.js`，本地已实测加载）：

- 只要目标项目不是 `petnote-devtest`，入口在加载时就报错，一个函数都不会生成。实测过：给生产项目 ID 会拒绝，不给项目也会拒绝。
- 两个媒体函数只在测试账号配好之后才进导出清单。
  - 没配时：导出 34 个，三个密钥声明全部去掉。
  - 模拟配好时：导出 36 个，只保留 Cloudinary 的两个密钥声明，去掉 Geoapify 的。
- Cloudinary 的两个密钥只允许这两个函数使用，别的函数用了就报错，部署失败。
- 部署命令逐个点名，不会顺带部署别的函数、定时任务，也不会碰生产：

  ```
  node functions/scripts/prepare-testcloud-deploy.mjs
  firebase deploy --config firebase.testcloud.json --project petnote-devtest --non-interactive \
    --only functions:testcloud:getCloudinaryUploadSignature,functions:testcloud:deleteCloudinaryAssetsCallable
  ```

## 还需要你另外批准的一项（不在这次的两个函数里）

测试项目上已部署的 34 个函数，是 `9c6a461` 时的代码，那时生产云名还写死在代码里。其中 5 个会校验图片地址属于哪个账号：

- `ensureUserProfileCallable`
- `updateUserProfileCallable`
- `createPetCallable`
- `updatePetCallable`
- `createPostCallable`

只部署两个媒体函数的话，上传能成功，但这 5 个函数会把测试账号的图片地址一律拒掉。结果是：带图发帖、换头像、给宠物换头像都保存不了。

要让「上传后保存」真正走通，这 5 个要用现在的代码在测试项目上**重新部署一次**。它们本来就在授权清单里，只是代码更新了。按你这次「不夹带其他函数」的要求，这一步要你单独点头。

## 真实联调时要验证的（部署之后）

不会因为上传 HTTP 成功就宣布发帖链路通过。每一项都核对 App 的界面和服务端的文档：

- **上传成功，发布成功**：帖子的媒体地址在测试账号下，前缀是 `petnote/users/{本人}/`。
- **取消**：选图后取消，或上传中取消；服务端没有帖子；App 回到可编辑状态。
- **失败后恢复**：断网或签名失败时 App 说明原因，恢复后能重试；重试时复用已上传的文件，不重复上传。
- **重复点击**：发布连点两下，只有一篇帖子。
- **结果未知**：请求发出但没收到回复时，App 不说「失败」也不重发；去查服务端这篇到底有没有发出去。
- **上传后发布被拒**：比如文字超长、账号被封。App 说出服务端的原因，已上传的文件留着（不自动回收），草稿还在。

## 顺带发现，要你在生产控制台看一眼的（只读，不需要改）

- **生产账号里有没有「Unsigned」模式的预设？** 例如四月以前 README 里提到的 `petnote_unsigned`。
  - 如果还在，任何人都能不经签名往生产账号上传，而且能通过服务端的地址校验。
  - 这是推测的风险，**未证实**。
- **文件夹名能不能以 `v` 加数字开头？** Cloudinary 文档说文件夹名的某一段不能这样开头。
  - 如果这条对前缀也生效，用户 ID 恰好以 `v3…` 这类开头的人（约 385 分之一）在生产上会传不了。
  - **未证实**。测试账号建好后，可以用一个 `petnote/users/v1probe` 探针试出来。

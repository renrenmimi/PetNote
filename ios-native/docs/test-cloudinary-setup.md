# 测试用 Cloudinary：你要做的，和之后要部署的

测试项目 `petnote-devtest` 用一个**单独的免费 Cloudinary 账号**，不复制生产密钥。

服务端已经改成按项目选账号（`functions/src/platform.ts`，`22fd12e`）：

- 生产项目拿到的值和以前完全一样。
- 测试项目在没配账号之前，签名、删除、媒体地址校验三处**都会拒绝**，不会退回到生产账号。
- 这个改动还没有部署。

## 两个上传预设：为什么要、怎么设（已核实）

App 和网页上传时都带 `upload_preset`，服务端也把它签进签名（`functions/src/media.ts:102-116`）。所以测试账号里要有**同名**的两个预设：`petnote_image_signed` 和 `petnote_video_signed`。

Cloudinary 本身不要求签名上传必须带预设。但去掉它等于改动签名参数集合（2026-09-05 的生产故障就出在这里），也会改生产行为，所以不改。

| 设置 | 值 | 原因 |
| --- | --- | --- |
| 模式 | **Signed** | 服务端会把预设名发给每个客户端；如果设成不签名，任何人都能往 `petnote/` 下传东西，还能通过服务端的地址校验 |
| folder / asset folder / public ID 前缀 / public ID | **都不设** | 服务端要求地址里有 `/petnote/`。新账号是「动态文件夹」模式，签名里的 `folder` 会成为 public ID 的前缀；预设里一旦设了这些，就可能把它覆盖掉 |
| Use filename | 不开 | 和生产一致，ID 随机 |
| 格式限制、预处理变换 | 不设 | 客户端只读 `secure_url` 和 `public_id`；乱设格式可能拒掉正常文件 |
| 大小上限 | 设不了 | 预设没有这个选项。免费版上限：图片 10 MB、视频 100 MB |

另外，账号的 **Strict Transformations 保持关闭**（默认就是关闭）。App 显示图片时会在地址上加 `w_300,h_300,c_fill` 这类尺寸参数，开了之后这些都会失败。

以上依据 Cloudinary 官方文档：upload presets、folder modes、authentication signatures。

## 你要做的（约 10 分钟）

1. 注册一个免费 Cloudinary 账号，验证邮箱。
2. 打开 Console → Settings → API Keys，准备好 cloud name、API key、API secret。
3. 在你自己的终端、仓库根目录运行：

   ```
   node functions/scripts/setup-test-cloudinary.mjs
   ```

   脚本会：
   - 先问 cloud name，再用隐藏输入问 key 和 secret；
   - 如果是生产的 `dgeunvmmn`，直接拒绝；
   - 建好两个预设并读回来核对；
   - 用和 App 一样的方式各传一张小图、一段示例视频，确认地址形状对、尺寸变换能用，然后删掉这两个探针文件。

   最后它问要不要把 key 和 secret 存进 `petnote-devtest` 的 Firebase 密钥：回答 `y`，它会用写死的测试项目名去存，不会碰生产，也不会自动重新部署任何函数。
   全程不打印 key、secret、签名或原始返回内容。
4. **只把 cloud name 发给我。**它本来就公开，每个图片地址里都有。

## 之后我要做的（其中部署那一步要你另外批准）

1. 把 cloud name 填进 `platform.ts` 的测试项目那一行，单独提交。
2. **测试项目的媒体函数部署清单，请逐项批准：**

| 函数 | 做什么 | 用到的密钥 | 读写 | 对外副作用 |
| --- | --- | --- | --- | --- |
| `getCloudinaryUploadSignature` | 给已登录、未被封、未在注销中的用户签一次上传（`folder` / `timestamp` / `upload_preset`） | 测试账号的 `CLOUDINARY_API_KEY`、`CLOUDINARY_API_SECRET` | 读 `users/{uid}`、`users/{uid}/admin/state`；写限流记录 `callableRateLimits` | 无：签名在本地算，不调用 Cloudinary |
| `deleteCloudinaryAssetsCallable` | 删掉调用者自己刚传、但保存失败的文件（只限 `petnote/users/{本人}/` 下，一次最多 30 个） | 同上 | 写限流记录 | **会删除测试账号里的文件** |

   - 只有这两个。没有任何触发器会删媒体。
   - 地点、签到、聚会用到的图片不在这次范围内：它们还需要别的函数，以及 Geoapify。
   - 部署入口 `functions-testcloud/index.js` 需要相应放开这两个函数的两个 Cloudinary 密钥（Geoapify 仍然剥离），导出数从 34 变成 36。
3. 部署后用 App 的测试云包在真机上发一张带图的帖子、换一次头像，再在服务端核对地址。

## 顺带发现，要你在生产控制台看一眼的（只读，不需要改）

- **生产账号里有没有「Unsigned」模式的预设？** 例如四月以前 README 里提到的 `petnote_unsigned`。如果还在，任何人都能不经签名，往 `petnote/users/任意 ID/` 下上传文件，而且能通过服务端的地址校验。这是推测的风险，**未证实**。
- 文档提到，文件夹名的某一段不能以 `v` 加数字开头。如果这条对前缀也生效，用户 ID 恰好以 `v3…` 这类开头的人（约 385 分之一）在生产上会传不了。**未证实**。测试账号建好后，可以用一个 `petnote/users/v1probe` 探针试出来。

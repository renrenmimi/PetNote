# 隐私政策与服务条款：和 iOS 实际行为逐条对照（草案，未发布）

**这份只是对照和草案，没有改动、也没有发布任何法律文字。** 定稿和发布由主人决定。

## 现在的做法

iOS App 在登录页、注册页和设置页放「Terms of Service」「Privacy Policy」两个入口，点开后在 App 内的 Safari 视图里打开正式网页：

- https://petnote.vercel.app/terms
- https://petnote.vercel.app/privacy

右上角的 Done 可以回到 App。两页已确认能打开（2026-09-23，HTTP 200）。
网页顶部自带的「←」在新打开的视图里没有上一页，按了没反应，要用 Done 返回。

**这只决定展示方式，不代表网页上的文字已经覆盖 iOS。** 下面列的就是不覆盖或不准确的地方。

问题类型：

- **W**：只适用于网页的说法
- **I**：对 iOS 不准确
- **N**：iOS 还没有这个功能
- **S**：服务端代码不支持这个说法
- 标「网页也错」的，网页用户看到的也不对

证据都是仓库里的文件和行号，写在最后一列。

## 隐私政策

| # | 原文 | 问题 | iOS 实际情况（证据） |
| --- | --- | --- | --- |
| P3 | "Profile photo (uploaded by you)" | 不完整（网页也错） | 还有简介 bio（`Features/Profile/EditProfileModel.swift:54`）；没上传头像时用 DiceBear 生成（`Core/Repository/FirestoreUserRepository.swift:50-52`） |
| P4 | "Pet name, species, breed, gender, birthday, bio, and photos" | 不完整（网页也错） | 还存和宠物的关系、共同主人名单，任何人可读（`firestore.rules:399-400`） |
| P7/P8 | 地点评价、签到、聚会 | N | iOS 没有这些功能（`STATUS.md` 第 4 批） |
| P9 | "Your approximate location (city/state)" | N；**网页也错** | iOS 不读位置（`Config/Info.plist` 无定位权限说明）。网页私下保存的是**精确经纬度**，公开的才是城市/州（`src/services/location.ts:64-90`） |
| P11 | "clear your location at any time in Settings" | N / W | iOS 还没有设置页；网页有 |
| P12 | "Pages you visit within the app" / "Features you use" | **S，网页也错** | 两端都没有任何统计或分析 SDK（`PetNoteApp.xcodeproj` 只链接 Auth/Firestore/Functions；两份 plist 的 `IS_ANALYTICS_ENABLED` 都是 false） |
| P14 | "notifications about likes, comments, and meetup updates" | N | iOS 没有通知页，也没有推送；关注也会产生通知，原文没写 |
| P17 | Firebase 用途 | 不完整 | 还用了 Cloud Functions |
| P18/P20/P23 | 各服务的托管地区 | 未知 | 仓库里查不到，需要主人确认 |
| P21 | Geoapify | N / W | iOS 不调用；网页是由我们的服务器去调，设备不直接连 Geoapify（`functions/src/geo.ts:149`） |
| P22 | DiceBear "No personal data is shared" | I（网页也错） | 头像地址里带用户 ID 或宠物 ID，DiceBear 也能看到设备 IP（`Features/Feed/PostCard.swift:282`） |
| P24 | "stored on Firebase servers in the United States" | I | iPhone 本机还存了：图片缓存最多 256 MB（`Core/Media/ImageLoader.swift:33-37`）、按账号保存的发帖草稿（`Features/Compose/ComposeDraft.swift`）、钥匙串里的登录凭据、选视频时的临时副本（`Features/Compose/ComposePicking.swift:28-36`），以及见文末 A1 的 Firestore 磁盘缓存 |
| P27/P29/P30 | 在设置里查看数据、注销账号、清除位置、通知偏好 | N | iOS 暂无设置页和注销（本轮在做） |
| P32 | 注销时删除个人资料、宠物、帖子、评论、点赞 | 部分 S | 实际删得更多（签到、评价、聚会、关注、收藏、屏蔽、通知……，`functions/src/users.ts:534-662`）；共同拥有的宠物**不删**，转给其他主人；添加过的地点保留你的名字（`functions/src/places.ts:527-528`） |
| P33 | "Photos may take additional time to be removed from Cloudinary storage" | **S，网页也错** | **没有任何服务端路径会删除 Cloudinary 上的图片和视频**：删帖只删数据库文档（`functions/src/cleanup.ts:17-28`），注销没有删媒体这一步，自动回收是有意关闭的 |
| P34 | "anonymized data may remain in backups for up to 30 days" | **S，网页也错** | 仓库里没有备份配置；手动导出是完整副本，不是匿名的 |
| P36 | 草稿存在 session storage，关浏览器就清除 | W / I | iPhone 草稿存在 UserDefaults，按账号分开，退出登录和重启后还在，24 小时过期（`ComposeDraft.swift:61-107`） |
| P37 | local storage 存深色模式和已看过的帖子 | W | iOS 跟随系统外观，不存这些 |
| P39 | "notify users of significant changes through the app" | N | iOS 暂无通知或公告的地方 |

其余各条对 iOS 准确，未列出：邮箱、显示名、帖子、评论、密码只由 Firebase 处理、HTTPS、安全规则、不卖数据、不做广告、13 岁以下、联系我们。

## 服务条款

| # | 原文 | 问题 | 说明 |
| --- | --- | --- | --- |
| T1 | "By using our app, you agree to these terms." | 链接缺失 | iOS 注册页原来只有一行纯文字，本轮改成可以点开 |
| T2 | 服务包括地点和聚会 | N | iOS 暂无 |
| T5 | 删掉的帖子「会在一段时间后从存储服务中完全移除」 | **S** | 同 P33，媒体不会被删 |
| T6 | 虐待动物内容「immediately」删除并封号 | 需主人定 | 这是对人工处理速度的承诺 |
| T9 | "You can delete your account at any time in Settings." | N | iOS 暂无（本轮在做） |
| T10 | 数据删除后「部分可能留在备份里一段时间」 | S | 同 P32–P34 |

## 需要主人回答的问题（草案里留了空）

1. 托管地区：生产 Firestore 在哪里（是否 `nam5`）？Cloudinary、Vercel 分别在哪个地区？
2. 备份：有没有定期导出？保留多久？
3. Cloudinary 上的媒体，三选一：
   - (a) 如实写明不会自动删除；
   - (b) 承诺收到请求后 N 天内手动删除；
   - (c) 先把自动删除做出来。
4. 注销后，添加过的地点保留原来的显示名，可以吗？
5. 照片里的位置等元数据：写进政策，还是先改 App 统一去掉？
6. 给登录不了或被封的人一个联系邮箱？
7. 政策变更怎么通知 iPhone 用户？
8. 导出数据的请求手动处理吗？多久内处理？
9. 「immediately」保留还是改成「promptly」？

## 顺带发现的问题（未处理）

- **A1**：测试云和生产配置的 iPhone 包，会把 Firestore 数据缓存到磁盘。`Core/Auth/FirebaseBootstrap.swift:85-93` 在设置「只用内存缓存」（`:97-103`）之前就返回了，和同一处注释「和网页一样，不做离线持久化」（`:100-101`）不符。这是改一行的事，但它改变 App 的行为，要先问主人。
- **A4**：App Store 审核要求能注册的 App 在 App 内提供注销（5.1.1(v)）；项目里还没有 `PrivacyInfo.xcprivacy`，而 App 用到了 UserDefaults 这类需要声明理由的接口。发布前要补。

---

## DRAFT — FOR OWNER REVIEW（未发布）

### Privacy Policy

Your privacy matters to us. This policy explains what data we collect and how we use it. It covers the PetNote web app (petnote.vercel.app) and the PetNote iPhone app. Where the two work differently, we say so.

**1. Data We Collect**

Account Information:
- Email address (for login and communication). It is not shown on your profile.
- Display name and bio (chosen by you)
- Profile photo (uploaded by you). If you don't upload one, we show a generated default avatar.

Pet Information:
- Pet name, species, breed, gender, birthday, bio, photo, and your relationship to the pet
- The people who co-own the pet with you

Content You Create:
- Posts (photos, videos, text, tags, and the pet they are about)
- Comments and replies
- Likes, follows and saved posts
- Reviews and check-ins at places, and meetup details (web app only for now)

Safety and Support:
- People you block, and posts you report
- Messages you send through Contact us, stored with your user ID, display name and email address so we can reply

Location Data (web app only):
- If you choose to set your location, the web app asks your browser for your position. We keep the exact coordinates privately and show only your city and state on your profile.
- Used to show distances to meetups and places
- You can clear your location at any time in Settings on the web app
- The iPhone app does not access your location.

Photos and Videos:
- Larger photos are re-encoded before upload, which removes hidden details such as where they were taken. Smaller photos, GIFs and videos are uploaded as they are, including any such details. [OWNER: keep this, or change the apps first]

Usage Data:
- We do not use analytics, advertising or tracking tools in the web app or the iPhone app.
- Our service providers keep technical logs, such as IP addresses and request times, to run and protect the service. [OWNER: confirm]
- We do not track you across other apps or websites.

What Others Can See:
- Your profile (name, photo, bio, and city/state if set), your pets and their co-owners, and your posts, comments and likes can be seen by anyone, including people who are not signed in.
- Photos and videos you post are stored at public web addresses. Anyone with the link can open them.

**2. How We Use Your Data**
- To provide the PetNote service (showing your posts, connecting with other pet lovers)
- To show in-app notifications about likes, comments, follows and meetup updates. Neither app sends push notifications.
- To improve the app, using the feedback you send us
- To enforce our Terms of Service and protect users
- We do NOT sell your data to anyone
- We do NOT use your data for advertising

**3. Third-Party Services**

Firebase (Google): authentication (login), Firestore (database) and Cloud Functions (our server code). Hosted in [OWNER: confirm].

Cloudinary: photo and video storage and delivery. Both apps upload your photos and videos directly to Cloudinary. Hosted in [OWNER: from the Cloudinary account settings].

Geoapify (web app only): address search, and turning coordinates into a city name. Our servers send Geoapify the address you type or the coordinates you choose; your device does not contact Geoapify directly.

DiceBear: generates default avatars for people and pets without a photo. Your name, email and content are not sent. The avatar's web address contains the account's or pet's internal ID, and, as with any image, DiceBear can see the IP address of the device showing it.

Vercel: hosts the PetNote web app, including the Privacy Policy and Terms pages the iPhone app opens. Hosted in [OWNER: confirm].

**4. Data Storage and Security**
- Your account and content are stored on Firebase (Google Cloud) servers [OWNER: in the United States?]. Photos and videos are stored on Cloudinary.
- Passwords are handled entirely by Firebase Authentication. PetNote's own servers and database never receive or store your password.
- We use Firestore security rules to protect your data.
- We use HTTPS for all data transmission.

**5. Your Rights**

You can:
- View your profile, pets and posts in either app, and your settings in either app
- Edit your profile, pets, and posts at any time
- Delete your posts and comments, and pets you are the only owner of
- Delete your entire account in Settings
- Clear your location data and control notification preferences in Settings on the web app [OWNER: update when the iPhone app has them]
- Request a copy of your data by contacting us through Contact us [OWNER: and/or email]

**6. Data Deletion**

When you delete your account:
- Your profile, your posts (with their comments and likes), and your comments and likes on other posts are deleted from our database. So are your check-ins, reviews, meetups you organized or joined, follows, saved posts, blocks, notifications, the reports and messages you sent us, and your login.
- Pets you share with other owners are not deleted; they stay with the remaining owners. Pets you are the only owner of are deleted.
- Places you added stay on PetNote with the display name you had when you added them. [OWNER: accept, or change the server]
- A small record containing only your user ID is kept for about a day, so the account can't be recreated by accident.
- Photos and videos are not currently deleted from Cloudinary automatically when you delete a post, a pet or your account. They stop appearing in PetNote but remain at their web addresses until we remove them. [OWNER: choose (a), (b) or (c) from question 3]
- [OWNER: describe backups as they really are]

**7. Children's Privacy**

PetNote is not intended for children under 13. We do not knowingly collect data from children under 13. If we discover a child under 13 has created an account, we will delete it.

**8. Cookies, Local Storage and Data on Your Device**

Web app:
- Session storage: an unfinished post draft (cleared when you close the tab, or after 24 hours)
- Local storage: your dark mode and language choice, featured posts you have already seen, and onboarding progress
- Your sign-in session, kept by Firebase in your browser

iPhone app:
- An unfinished post draft: its text, tags, chosen pet, and the addresses of photos already uploaded (never the photos themselves). It is kept for each account on this device, even after you close the app or sign out, until you post or discard it, or after 24 hours.
- Recently viewed images, cached to load faster (up to 256 MB)
- [OWNER: only if the on-device Firestore cache is kept — see A1] A copy of recently loaded PetNote content, so screens load faster
- Your sign-in session, kept by Firebase in the iOS Keychain
- Videos you pick for a post are copied to the app's temporary folder, which iOS clears on its own

We do not use tracking cookies, advertising identifiers or tracking tools.

**9. Changes to This Policy**

We may update this policy from time to time. We will tell users about significant changes [OWNER: how]. The date below shows when it last changed.

**10. Contact**

For privacy questions or data requests, use Contact us in the app (on iPhone: Profile → Contact us). [OWNER: if you can't sign in, email …]

Last updated: [OWNER: publication date]

### Terms of Service（只列改动的段落）

**1. About PetNote.** … organize meetups. Some features, such as Places and Meetups, are currently available only in the web app. The service is provided as-is and may change over time.

**3. Content You Post** (last bullet). Deleted posts are removed from the app right away. Photos and videos in them are not currently deleted from our media storage automatically, and may remain at their web addresses [OWNER: until removed on request / within N days].

**4. Pet Safety** (second bullet). Content depicting or promoting animal cruelty will be [OWNER: "immediately" or "promptly"] removed and the account will be banned.

**8. Account Termination.** You can delete your account at any time in Settings. We may suspend or terminate accounts that violate these terms. When you delete your account, your data is removed as described in section 6 of the Privacy Policy, including what is kept and for how long.

**11. Contact.** Contact us through the in-app feedback form (on iPhone: Profile → Contact us) [OWNER: or email].

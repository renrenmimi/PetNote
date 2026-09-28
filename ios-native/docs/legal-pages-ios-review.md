# 隐私政策与服务条款：和 iOS 实际行为逐条对照（草案，未发布）

**这份只是对照和草案。我们没有改动、也没有发布任何法律文字**，网页上的正式文字还是 2026 年 2 月那一版。定稿和发布都由你决定。

**先看这里：** 要你拍板的只有第 5 节的 7 个问题。其余都已经从代码里查清（第 3 节），或者要有控制台权限的人去看一眼（第 6 节）。

## 0. 这一版改了什么

- 上一版写于提交 `5acf54d`（2026-09-23 上午）。那之后 App 多了这些：设置页和注销账号（`67333fa`）、App 内通知（`e2379e2`）、分享帖子（`d9dfb61`、`7e020ac`）、地点和聚会的浏览与报名（`44f8d99`）。上一版查出来的 A1，加上注销后手机上还留着草稿和图片，这两个缺陷已经修好（`22c0246`，见第 4 节）。
- 这一版按提交 `6057f8d` 核对，行号也都是这一版的。之后 iPhone 能写地点评价了（`1186220`，不带照片），P7、T2 两行和草稿里的两句已按它改过。之后又多了：发帖滤镜（滤过的照片重新编码、不带原图的元数据，和其他重新编码一样）、「我的打卡」列表（只读，不新增收集任何数据）。首页生日横幅和「人气萌宠」做过但没有放进这次候选（`0bd374b`），所以这里不写；放回来时要补一句：它会在手机上按账号记下点开过的帖子。2026-09-24 按 `be8bdac` 又核了一遍，改了这几处：滤镜（第 3 节第 5 条、问题 3、草稿里讲照片的两句）、打卡列表（P27、草稿「5. Your Rights」）、分享地点（第 3 节"外部服务"）、给聚会的地点打分（P7）。这几处和 P8、P41、T8 的行号是 `be8bdac` 的，其余还是 `6057f8d` 的。
- 生产环境的几项设置（数据库在哪、有没有备份、日志留多久、服务器代码在哪）是 2026-09-23 用只读方式查的：只看了设置，没看任何用户数据。本文照抄结果，没有重查。
- 网页原文是照仓库里的 `src/pages/PrivacyPolicy.tsx` 和 `src/pages/TermsOfService.tsx` 核对的（和 `main` 分支一样）。下面写的"`:51`"这种，就是这两个文件的行号。

## 现在的做法

iOS App 在登录页（`Features/Auth/LoginView.swift:58`）、注册页（`Features/Auth/SignUpView.swift:199-205`）和 设置 → About（`Features/Settings/SettingsView.swift:190-193`）放了「Terms of Service」「Privacy Policy」两个入口。点开后，在 App 里的 Safari 视图中打开正式网页（`Features/Legal/LegalPages.swift:21-26`、`:40-44`）：

- https://petnote.vercel.app/terms
- https://petnote.vercel.app/privacy

点右上角的 Done 回到 App。上一版确认过两页都能打开（2026-09-23，HTTP 200），这一版没有重新打开。
网页顶部自带的「←」在新打开的视图里没有上一页可回，按了没反应，要用 Done 返回。

**这只决定文字在哪里显示，不代表网页上的文字已经把 iOS 写对了。** 下面列的就是没写到或写得不准的地方。

问题类型：

- **只适用网页**：说的是网页，iPhone 上没有这回事
- **不完整**：说得对，但漏了
- **说法不对**：代码做不到或做的不是这样
- 标「网页也错」的，网页用户看到的也不对

证据都是仓库里的文件和行号，写在最后一列。iOS 文件路径都从 `ios-native/` 开始算。

## 1. 隐私政策逐条对照

| # | 原文 | 问题 | iOS 现在的实际情况（证据） |
| --- | --- | --- | --- |
| P0 | 整份政策 | 不完整 | 全文只讲网页，一句都没提 iPhone App |
| P3 | "Profile photo (uploaded by you)" `:36` | 不完整（网页也错） | 还存了简介 bio（`Features/Profile/EditProfileModel.swift:54`）。没上传头像的人用 DiceBear 生成的默认头像（`Core/Repository/FirestoreUserRepository.swift:50-52`） |
| P4 | "Pet name, species, breed, gender, birthday, bio, and photos" `:40` | 不完整（网页也错） | 还存了每一位共同主人，以及他和宠物是什么关系。任何人（包括没登录的人）都能读到（`firestore.rules:399-400`）。每只宠物被谁关注，也是公开的（`firestore.rules:413-414`） |
| P7 | "Reviews and check-ins at places" `:46` | 不完整 | iPhone 能看地点、评价和打卡（`44f8d99`），也能写评价（`1186220`）：打分、三个小项、标签和一段文字，经服务器的 `submitReviewCallable` 写入，**不带照片**；评价里存着你的名字、头像和用户 ID。给一场已结束的聚会的地点打分时，评价里还会存这场聚会的 ID（`meetupId`，`functions/src/places.ts:688`、`:708`），和评价的其他内容一样谁都能读。iPhone 还不能打卡、不能添加地点。评价和打卡谁都能读（`firestore.rules:536-537`、`:545-546`） |
| P8 | "Meetup details" `:47` | 不完整 | iPhone 现在能报名、退出聚会，组织者能取消聚会（`Features/Meetups/Meetups.swift:331`、`:343`），但不能发起聚会。报名记录里有你的名字、头像和你带去的宠物，谁都能读（`firestore.rules:499-500`，`functions/src/meetups.ts:761-770`）。如果组织者设了"地址只给参加的人看"，准确地址只有组织者和已报名的人能看到（`firestore.rules:515-520`） |
| P9 | "Your approximate location (city/state) if you choose to enable it" `:51` | 只适用网页；**网页也错** | iPhone 不读位置：没有定位权限说明（`Config/Info.plist`），代码里没用系统定位，设置页也没有"我的位置"（`Features/Settings/SettingsView.swift:9-10`）。网页私下存的是**精确经纬度**，放在只有本人能读的 `users/{uid}/settings/location`（`firestore.rules:302-303`），公开资料里只写城市和州（`src/services/location.ts:65-92`）。但早期账号的公开资料里可能还留着精确经纬度，规则允许它们原样留着（`firestore.rules:175-194`，提交 `c96edb9` 的说明）。生产上到底有没有，要查（第 6 节第 3 项） |
| P11 | "You can clear your location at any time in Settings" `:53` | 只适用网页 | 网页设置页能清除（`src/services/location.ts:126-133`）。iPhone 本来就不存位置 |
| P12 | "Pages you visit within the app" / "Features you use" `:57-58` | **说法不对，网页也错** | 两边都没有任何统计或分析工具。iPhone 工程只用了 Auth/Firestore/Functions/GoogleSignIn 这四个包（`PetNoteApp.xcodeproj/project.pbxproj:312-347`），网页的依赖（`package.json`）里也没有。仓库里的两份 iPhone 配置 `IS_ANALYTICS_ENABLED` 都是 false（`Support/GoogleService-Info-Test.plist:19-20`、`Support/GoogleService-Info-Emulator.plist:28-29`） |
| P14 | "To send notifications about likes, comments, and meetup updates" `:71` | 不完整 | iPhone 现在有通知铃铛和通知列表（`e2379e2`）。通知的种类比原文写的多：点赞、评论、回复、关注宠物、有人报名、聚会取消、共同宠物换了主要主人、管理员警告（`functions/src/notifications.ts:666`、`:715`、`:753`、`:822`，`functions/src/family.ts:270`）。点赞、评论、关注这三类可以在设置里关掉（`SettingsView.swift:121-134`）。两边都**没有推送**：iPhone 没有推送相关的配置（`Config/Info.plist`，也没有 entitlements 文件），也没装推送用的包 |
| P17 | Firebase 用途（"Authentication"、"Firestore"）`:85-86` | 不完整 | 漏了 Cloud Functions，也就是我们的服务器代码（`functions/src/`） |
| P18 | Firebase "Hosted in the United States" `:87` | **对**（这次查清） | 生产数据库在 `nam5`（美国的多地区），67 个云函数都在 `us-central1`（美国）。这是只读方式查到的。登录服务（Firebase Authentication）的数据放在哪，仓库里没有，这次也没查 |
| P20 | Cloudinary "Hosted on AWS/Google Cloud" `:92` | 未核实 | 仓库里查不到，要去 Cloudinary 控制台看（第 6 节第 1 项） |
| P21 | Geoapify `:96-97` | 只适用网页 | iPhone 不用。网页也是由我们的服务器去调，设备本身不连 Geoapify（`functions/src/geo.ts:149`） |
| P22 | DiceBear "No personal data is shared" `:101-102` | **说法不对（网页也错）** | 默认头像的网址里带着账号 ID 或宠物 ID（`functions/src/shared.ts:821`），设备去加载它时，DiceBear 也看得到设备的 IP。iPhone 在帖子卡片、个人主页这些地方会去加载（`Features/Feed/PostCard.swift:284`、`Features/Profile/ProfileView.swift:81-86`）。名单类页面不加载，改成显示名字的首字母（`Features/Social/SocialUI.swift:22-26`） |
| P23 | Vercel "Hosted in the United States" `:107` | 关系不大 | Vercel 只放网页文件：`vercel.json` 只有转发规则，仓库里也没有 `api/` 目录，所以它不存账号数据。iPhone 打开的两份法律页面就放在这里 |
| P24 | "Your data is stored on Firebase (Google Cloud) servers in the United States." `:115-116` | 不完整 | 数据库确实在美国（见 P18）。但照片和视频在 Cloudinary（在哪个地区还没核实）。iPhone 本机也存了一些东西：图片缓存最多 256 MB（`Core/Media/ImageLoader.swift:33-37`）、按账号分开的发帖草稿（`Features/Compose/ComposeDraft.swift:80-121`）、钥匙串里的登录凭据、选视频时复制出来的临时文件（`Features/Compose/ComposePicking.swift:28-36`）。帖子、资料这些 PetNote 内容现在只放在内存里，不再存到手机上（`22c0246`，见第 4 节） |
| P27 | "View your data in your Profile and Settings" `:131` | 不完整 | 能看到自己的资料、宠物、帖子、收藏、关注的宠物、自己的打卡（只能看，`9b591fa`，`App/ProfileLinks.swift:57-62`）和屏蔽名单（`App/ProfileLinks.swift`）。但没有一个地方能看到我们存的全部数据，比如你点过赞的帖子、你发过的举报和反馈 |
| P29 | "Delete individual posts, pets, or your entire account" `:133` | 基本对 | iPhone 能删帖、删评论。宠物只有**唯一的主人**能删，和别人共有的宠物只能退出（`functions/src/pets.ts:542-547`）。注销账号在 设置 → Danger Zone → Delete Account（`SettingsView.swift:175-184`），要先重新输入密码（或者再登一次 Google），再输入 DELETE（`Features/Settings/DeleteAccount.swift:9-11`、`:31`） |
| P30 | "Clear your location data" `:134` | 只适用网页 | 同 P11 |
| P31 | "Control notification preferences" `:135` | **现在对了** | iPhone 设置页有点赞、评论、关注三个开关（`SettingsView.swift:121-134`），和网页用的是同一份设置（`firestore.rules:205-210`） |
| P32 | "Request a copy of your data by contacting us through the feedback form" `:136-138` | **说法不对（网页也错）** | 没有导出功能，只能有人到后台手工查出来、整理好。反馈表必须登录才能用（网页 `src/App.tsx:296-302`，服务器 `functions/src/moderation.ts:113-116`），被封的账号会被拒（`functions/src/moderation.ts:119-121`） |
| P33 | "Your profile, pets, posts, comments, and likes are deleted from our database" `:147` | 不完整 | 实际删掉的比这多，也有不删的，见第 3 节"注销账号时删什么、留什么" |
| P34 | "Photos may take additional time to be removed from Cloudinary storage" `:149-150` | **说法不对，网页也错** | **没有任何一步会删掉 Cloudinary 上的照片和视频。** 删帖只删数据库里的记录（`functions/src/cleanup.ts:17-28`），注销也没有删照片视频这一步（`functions/src/users.ts:485-684`）。唯一能删照片视频的接口（`functions/src/media.ts:144`）只在"刚上传完、保存却被服务器拒绝"时由 App 自己调用。iPhone 上只有头像这一处会这样做（`Features/Profile/AvatarUpload.swift:149-160`、`Features/Profile/EditProfileModel.swift:155-157`） |
| P35 | "Some anonymized data may remain in backups for up to 30 days" `:152` | **说法不对，网页也错** | 生产上没有定期备份。只有 2026-09-07 手动导出的一份**完整**副本（没有匿名处理），放在美国的存储桶里，90 天后自动删除（大约 2026-12-06）。详见第 3 节 |
| P36 | "We use session storage for draft posts (cleared when you close the browser)" `:168` | 只适用网页 | iPhone 的草稿存在 UserDefaults 里，每个账号一份。关掉 App、退出登录后都还在。过了 24 小时就不再显示，但要等这个账号下次打开发帖页，才会真正删掉（`ComposeDraft.swift:94-110`）。在这台手机上注销账号，会马上删掉（`22c0246`） |
| P37 | "We use local storage for dark mode preference and seen posts" `:169` | 只适用网页 | iPhone 的外观和语言都跟着手机设置走，这些都不存 |
| P39 | "We will notify users of significant changes through the app." `:177-178` | **说法不对** | 两边都没有公告功能，也没有推送；也没有记录谁同意过哪一版条款 |
| P41 | "contact us through the in-app feedback form" `:185-186` | 不完整 | 同 P32：要登录才能用，被封的人用不了。代码里任何地方都没有联系邮箱。iPhone 上的入口：个人页 → Contact us（`App/ProfileLinks.swift:73-78`），或者 设置 → Contact Us & Feedback（`SettingsView.swift:188`） |

没列出来的其余各条，对 iOS 都准确：邮箱、显示名、帖子、评论、密码只交给 Firebase 处理、全程 HTTPS、有安全规则、不卖数据、不做广告、不跨网站追踪、不面向 13 岁以下（不过没有任何年龄检查，见 T3）。

## 2. 服务条款逐条对照

| # | 原文 | 问题 | 说明 |
| --- | --- | --- | --- |
| T1 | "By using our app, you agree to these terms." `:25` | 已处理 | iPhone 注册页有"创建账号即表示同意"这句话，后面跟着两个链接（`SignUpView.swift:199-205`），登录页有两个链接（`LoginView.swift:58`）。只有一个例外：Google 登录目前只在测试包里有（`Core/Auth/GoogleSignInService.swift:50-55`），用它在登录页新建账号时，只看得到链接，看不到这句话（`LoginView.swift:56-58`） |
| T2 | §1 "discover pet-friendly places, and organize meetups" `:30-32` | 不完整 | iPhone 能浏览地点、写评价（不带照片）、报名和退出聚会。添加地点、打卡、发起聚会，目前只有网页能做（见 P7、P8） |
| T3 | §2 "You must be at least 13 years old" `:39` | 没有检查 | 两边注册都不问年龄。管理员也没有删别人账号的功能：注销接口只允许本人删自己（`functions/src/users.ts:495-497`），管理员只能删内容、封号（`src/services/admin.ts` 里的 `resolveReport`、`deleteContentAndWarn`、`blockUserByAdmin`） |
| T5 | §3 "Deleted posts are removed from the app but may take time to be fully removed from our storage services." `:63-64` | **说法不对** | 同 P34：照片和视频永远不会被删 |
| T6 | §4 "will be immediately removed and the account will be banned" `:74-75` | 要你定 | 举报只是存下来，标成"待处理"（`functions/src/moderation.ts:92`）。服务器不会因为举报自动做任何事（没有针对举报的自动处理）。删内容和封号都要管理员手工操作（`src/services/admin.ts`）。见问题 5 |
| T7 | §5 Meetups `:87-99` | 现在也适用 iPhone | iPhone 能报名聚会了，这一节原样保留就行 |
| T8 | §6 "not verified by PetNote unless marked as 'Verified.'" `:103-106` | **说法不对（网页也错）** | 两边显示的"✓ Verified"只表示这个地点累计有 3 次以上打卡，是系统自动算的（`functions/src/places.ts:422-423`，`Features/Places/PlaceDetailView.swift:84-85`，`src/pages/LocationDetail.tsx:392`），不是 PetNote 核实过 |
| T9 | §8 "You can delete your account at any time in Settings." `:130` | **现在对了** | iPhone 设置页有注销（`SettingsView.swift:175-184`） |
| T10 | §8 "some data may persist in backups for a limited time" `:133-134` | 要你定 | 现在的情况见 P35。写"保留多久"是问题 7 |
| T11 | §10 "Continued use of PetNote after changes means you accept the updated terms." `:159-160` | 做不到记录 | 系统不记录谁同意过哪一版（问题 6） |
| T12 | §11 "contact us through the in-app feedback form" `:168-169` | 不完整 | 同 P41 |

## 3. 已从代码查清（不需要你决定）

### 谁能看到什么（按数据库规则 `firestore.rules`）

- **任何人都能读，包括没登录的人：**
  - 个人资料 `users/{uid}`：显示名、头像、简介、城市和州、账号创建时间、关注了多少只宠物（`:238-239`）。不含邮箱：服务器写个人资料时不写邮箱（`functions/src/users.ts:336-343`）
  - 帖子、谁点了赞、评论（`:337-338`、`:343-344`、`:384-385`）
  - 宠物（包括生日）、共同主人和他们跟宠物的关系、每只宠物的关注者（`:393-394`、`:399-400`、`:413-414`）
  - 聚会、报名的人和他们带去的宠物（`:493-494`、`:499-500`）。"地址只给参加的人看"的聚会，准确地址不公开（`:515-520`）
  - 地点、评价、打卡（`:529-530`、`:536-537`、`:545-546`）
- **只有本人能读：** 收藏（`:256-257`）、关注的宠物列表（`:275-276`，不过每只宠物的关注者名单是公开的）、屏蔽名单（`:287-288`）、设置，包括通知开关和网页存的精确位置（`:302-303`）、通知（`:480-482`）、自己发的举报和反馈（`:565-567`、`:575-577`）。举报、反馈和通知，管理员也能看。
- **邮箱**只在两个地方：Firebase 登录服务里，和你发出的反馈里（`functions/src/moderation.ts:145-148`）。
- **照片和视频**放在公开网址上，路径是 `petnote/users/{uid}/`（`functions/src/media.ts:57-61`）。知道网址的人不用登录就能打开。

### iPhone App 会连哪些外部服务

- Firebase（登录、数据库、我们的服务器代码）
- Cloudinary：照片视频直接从手机传上去，显示时也从那里加载
- `api.dicebear.com`：默认头像，只在部分页面加载，见 P22
- Apple 地图：只有你点"导航"时才打开，带过去的是地点的坐标和名字（`Features/Places/Places.swift:113-121`、`Features/Meetups/Meetups.swift:52-60`）。App 不发送你自己的位置
- `petnote.vercel.app`：打开两份法律页面时连
- Google 登录：目前只在测试包里有（`Core/Auth/GoogleSignInService.swift:50-55`）
- 分享帖子：生成的链接指向网页上的帖子页（`Features/Share/PostSharing.swift:17`、`:22-23`），分享图片是在手机上当场画出来、交给系统分享面板的。App 自己不把内容发给任何别的服务，发到哪里由你在分享面板里选。地点也能分享，分享的只是一条指向网页地点页 `…/location/{地点 ID}` 的链接（`Features/Places/PlaceDetailView.swift:117`）；测试包里，帖子和地点的链接都改用 App 自己的 `petnote://` 开头（`7e020ac`，`Features/Share/PostSharing.swift:19-35`）

从源代码和工程文件看，没有统计、崩溃上报、推送、广告标识、跟踪授权或定位（import 的只有系统框架和那四个包）。已编译好的安装包本身，这一轮没有核对。

服务器那边，除了 Firebase 还会连：Geoapify（只为网页服务，`functions/src/geo.ts`）、Cloudinary 的删除接口（只用于 P34 说的那种情况），以及 Firebase 自己发的验证邮件和重置密码邮件。另有一个发邮件的服务 Resend，写好了但没启用：它要两个密钥才会工作（`functions/src/email.ts:1-35`），iPhone 也不调用它（`Core/Backend/Callables.swift:19-24`）。

### 注销账号时删什么、留什么

**会删掉的**（`functions/src/users.ts:485-684`）：

- 你的帖子，连同帖子下的点赞和评论，还有别人对这些帖子的收藏、举报和相关通知（`:534-541`，`functions/src/cleanup.ts:17-28`、`:85-113`）
- 你发起的聚会，连同所有人的报名（`:567-574`，`cleanup.ts:51-57`）
- 发给你的通知、因为你的操作产生的通知；你在别处的评论、点赞、打卡、评价、聚会报名、共同主人记录；你发的举报和反馈；你的收藏、关注、屏蔽名单、设置（包括网页存的位置）、管理员状态（`:576-610`）
- 你的个人资料和用户名，最后删登录账号（`:630-676`）
- 宠物：和别人共有的宠物**不删**，交给剩下的主人里最早加入的那位（`functions/src/family.ts:77-93`、`:207-214`）。只有你一个主人的宠物会删掉（`:552-565`，`cleanup.ts:30-49`）
- 如果注销中途断了，账号会一直停在"正在删除"的状态，设置页会提示"完成删除"（`SettingsView.swift:84-106`）

**会留下的：**

- Cloudinary 上的所有照片和视频（见 P34）
- 你添加过的地点。网页上添加的，以及公开聚会自动建的地点都算。地点记录里一直带着你的账号 ID 和当时的显示名（`functions/src/places.ts:527-528`、`:266-267`）。两个 App 的页面都不显示这个名字（只有 `src/pages/AddPlace.tsx` 写它，没有页面读它），但地点记录谁都能从数据库直接读到（`firestore.rules:529-530`）。见问题 2
- 你评价里的照片：写评价时，这些照片会被复制进地点的公开照片列表（`functions/src/shared.ts:627-632`），评价删了也不会从那里拿掉（`functions/src/places.ts:372-402`）。所以注销以后，它们还会出现在地点的照片里。这是缺陷，见第 4 节
- 别人举报你本人、或举报你评论的记录（只有举报帖子的记录会跟着帖子一起删，`cleanup.ts:98-105`）
- 两种小的技术记录：一个"这个账号正在删除"的标记，只含账号 ID，设定 24 小时后过期（`users.ts:510-523`）；还有限制请求频率的计数，设定最多 2 小时后过期（`functions/src/shared.ts:449-463`）。**但"过期自动删除"要在控制台单独打开，仓库里没有打开它的配置**（`users.ts:512-514` 的注释就是这么说的）。没打开的话，这些记录会一直留着（第 6 节第 2 项）
- 备份里的副本，见下面"上一版的 9 个问题"第 2 条
- 什么都没有做匿名处理

**手机上**（只有在这台手机上注销时才会做，`SettingsView.swift:71-75`）：退出登录，登录凭据由 Firebase 和 Google 的组件从钥匙串里清掉（`Core/Auth/SessionStore.swift:186-219`，钥匙串这一步没在真机上核对）；这个账号的草稿，以及内存和磁盘上的图片缓存，都会清掉（`Features/Settings/AccountLocalData.swift:11-19`）。PetNote 内容本来就只放在内存里。如果账号是在网页上注销的，手机上的草稿和磁盘图片缓存不会被清掉。

### 上一版的 9 个问题，现在的答案

1. **托管地区。** 生产数据库在 `nam5`（美国多地区），67 个云函数都在 `us-central1`，都是只读方式查到的。仓库里也没有给函数指定地区（`functions/src/platform.ts:27` 只设了实例数上限）。Vercel 只放网页文件。只剩 Cloudinary 的地区不知道，要去控制台看（第 6 节第 1 项），这不是要你做的决定。
2. **备份**（只读方式查到）。生产上没有设定任何定期备份，"按时间点恢复"（PITR）是关着的，数据库只自带 1 小时的历史版本，"防止误删数据库"的保护也没开。备份用的存储桶 `petnote-a9dac-firestore-backups` 在美国，设了"90 天后自动删除"。里面只有 2026-09-07 那一次手动导出（3 个文件），所以大约 2026-12-06 会被自动删掉。那是整个数据库的**完整**副本，没有匿名处理。登录账号（邮箱）不在数据库导出里（`functions/scripts/production-reset.md:56-60`），那次有没有另外导出，没核实（第 6 节第 4 项）。服务器日志留 30 天；Google 固定的 `_Required` 日志留 400 天，按 Google 的说明，里面是项目管理操作的记录。还要不要承诺一个备份期限，是问题 7。
3. **Cloudinary 上的照片视频。** 服务器从来不删（见 P34）。发帖页也不回收：草稿过期或丢弃后，已经传上去的文件照样留着（`ComposeDraft.swift:102-107`），宠物照片保存失败也不删（`Features/Pets/PetEditorViewModel.swift:300-312`）。怎么处理是问题 1。
4. **注销后地点上的名字。** 见上面"会留下的"。iPhone 不能添加地点。要不要改，是问题 2。
5. **照片里的隐藏信息（比如拍摄地点）。** iPhone 上会重新压缩、从而去掉这些信息的有：所有头像（`Features/Profile/AvatarUpload.swift:277-285`）；加了滤镜（Normal 以外）的帖子照片，不管多大、什么格式（`Core/Media/UploadPreparation.swift:134-154`、`Features/Compose/ComposeViewModel.swift:638`）；所有 HEIC/HEIF 照片，以及大于 2 MB 或长边超过 1920 像素的照片（`UploadPreparation.swift:71-86`、`:156-184`、`:250-260`）。原样上传、可能带着拍摄地点的有：没加滤镜、不超过 2 MB 又不超过 1920 像素的 JPEG/PNG/WebP 帖子照片；同样大小的宠物照片（宠物照片没有滤镜，`Features/Pets/PetEditorViewModel.swift:333`）；所有 GIF（GIF 不能加滤镜）；所有视频（`Features/Compose/ComposeViewModel.swift:626-632`）。网页上是：HEIC 会转换；加了滤镜的帖子照片（GIF 除外）会在浏览器里重画成 JPEG，也不带这些信息（`src/pages/Create.tsx:614-627`、`:848-884`）；其余照片只要不超过 2 MB 就原样上传，GIF 全部原样上传（`src/utils/imageCompressor.ts:173-174`）。选图时系统交给 App 的原始文件里到底有没有拍摄地点，没在真机上核对。怎么办是问题 3。
6. **联系方式。** "联系我们"必须登录，被封的账号会被拒（见 P32）。代码里任何地方都没有联系邮箱。要不要放邮箱，是问题 4。
7. **政策修改怎么通知。** 两边都没有公告功能，没有推送，也不记录谁同意过哪一版。怎么通知，是问题 6。
8. **数据副本。** 没有导出功能，只能手工整理。承诺多快，是问题 5。
9. **"immediately"。** 举报只是存成"待处理"，删内容和封号都要人手工做（见 T6）。承诺多快，是问题 5。

### 上架相关（A 类）

- **A1**：已修，见第 4 节。
- **A4**：
  - App 里已经能注销账号（`SettingsView.swift:175-184`），满足 App Store 审核指南 5.1.1(v)。
  - 项目里还没有 App 自己的 `PrivacyInfo.xcprivacy`。App 用到了 UserDefaults（草稿 `ComposeDraft.swift:80-121`，还有一个"旧缓存已清"的标记 `Core/Auth/FirebaseBootstrap.swift:127-143`），要在这个文件里声明用它的理由（`CA92.1`）。发布前要补上。
  - Google 登录目前只在测试包里有。如果以后正式包也开，要先看审核指南 4.8 对第三方登录的要求。
  - App Store Connect 里的"App 隐私"问卷，可以照这一节的"谁能看到什么"和第 7 节草案的数据清单来填。

## 4. 已修的缺陷

两个都在提交 `22c0246` 里，都是这次对照时读代码发现的，不涉及要你做决定的事。

1. **A1：手机上会存一份数据库内容。** 以前连测试云和正式环境的包，会把 Firestore 查回来的内容（帖子、资料、通知）存到手机磁盘上，退出登录也还在。代码注释写的却是"和网页一样，不做离线存储"。现在所有的包都只放在内存里（`Core/Auth/FirebaseBootstrap.swift:85-92`、`:119-125`）。启动时，还会把旧版本留在磁盘上的那一份删掉一次（`:127-143`）。
2. **注销后，手机上还留着这个账号的草稿和图片。** 草稿"24 小时过期"只在这个账号下次打开发帖页时才检查，账号注销了就永远等不到那一天，所以草稿的文字、标签、已上传文件的网址会一直留到 App 被删掉。现在在这台手机上注销，会马上删掉这个账号的草稿，并清空内存和磁盘上的图片缓存（`Features/Settings/AccountLocalData.swift:11-19`、`Core/Media/ImageLoader.swift:139-143`、`SettingsView.swift:71-75`）。

**还没验证的：**

- "删掉旧版本留在磁盘上的那一份"只有连云端的包才会执行，所以要等下一次装到真机上才能确认。如果删除失败，App 会记一条错误，下次启动再试（`FirebaseBootstrap.swift:133-142`）。
- 提交说明里写着 811 个单元测试全部通过。这一轮我没有重新跑测试。

**查到了、还没修的（也不需要你决定）：**

- 你评价里的照片，评价删了（包括注销时）以后还留在地点的公开照片列表里（`functions/src/shared.ts:627-632`，`functions/src/places.ts:372-402`）。只有服务器能读的 `photoEntries` 里也一直存着上传人的账号 ID，只有整个地点删掉时才会删（`places.ts:86-110`、`:479`）。
- 选视频时复制出来的临时文件，App 从来不删（`ComposePicking.swift:28-36`），要等 iOS 自己在它觉得合适的时候清理临时文件夹。注销也不会清。
- 退出登录只清内存里的图片，磁盘上的图片缓存留着（`Core/Auth/SessionStore.swift:363-368`），草稿也留着。这是有意这么设计的：磁盘上缓存的都是公开图片，下一个人刷首页会快一些；草稿本来就按账号分开存。但就像上面第 2 条说的，一个再也不回来的账号，它的草稿要等到 App 被删掉才会消失。
- 在网页上注销的账号，手机上的草稿和磁盘图片缓存不会被清掉（手机上的清理只从手机的设置页触发）。

## 5. 只需要你决定的业务问题

1. **删掉的照片视频还能被打开。** 删帖、删宠物、注销账号以后，照片和视频还留在 Cloudinary 的公开网址上，知道网址的人照样能打开。三选一：
   - (a) 政策里如实写"不会自动删除"；
   - (b) 承诺收到请求后，若干天内手工删掉（天数和问题 5 一起定）；
   - (c) 先把自动删除做出来，再发布政策。
2. **注销以后，添加过的地点还带着原来的名字。** 两个 App 的页面都不显示这个名字，但任何人直接读数据库都能看到。二选一：
   - (a) 接受，政策里写明；
   - (b) 改服务器：注销时把名字换成"已注销用户"，并去掉账号 ID。
3. **照片视频里可能带着拍摄地点。** iPhone 上没加滤镜、不超过 2 MB、不超过 1920 像素的 JPEG/PNG/WebP 照片，还有所有 GIF 和所有视频，都是原样上传的；网页上没加滤镜、不超过 2 MB 的照片也是原样上传。加了滤镜的帖子照片，两边都会重新编码，不带这些信息。二选一：
   - (a) 先改 App，上传前统一去掉；
   - (b) 政策里写明。
4. **被封或登录不了的人联系不到我们。** "联系我们"要登录，被封的账号用不了，全站也没有任何联系邮箱。另外，App Store 对有用户内容的 App 有公开联系方式的要求（审核指南 1.2，原文这次没上网核对）。要不要放一个邮箱？放的话用哪个？
5. **靠人手做的事，承诺多快。** 这几件事都没有自动处理，全靠人手：
   - 帮用户整理数据副本；
   - 删掉虐待动物的内容并封号（条款现在写的是"立即"）；
   - 删掉未满 13 岁的账号（管理员没有删别人账号的功能，要用控制台手工删）；
   - 问题 1 如果选 (b)，还有删照片视频。

   每件事写一个天数或小时数，还是只写"尽快"（promptly）？
6. **政策修改了怎么通知用户。** 两边都没有公告功能，没有推送，也不记录谁同意过哪一版。三选一：
   - (a) 只改页面上的"最后更新"日期；
   - (b) 给注册邮箱群发（现在没有群发邮件的工具）；
   - (c) 先在 App 里做一个公告，再发布。
7. **备份留多久写进政策。** 现在没有定期备份，"按时间点恢复"也关着，只有 2026-09-07 手动导出的一份完整副本，大约 2026-12-06 自动删除。二选一：
   - (a) 如实写现状；
   - (b) 先打开定期备份或"按时间点恢复"（要花钱），再写一个保留天数。

## 6. 需要有控制台权限的人查一下

这几项不是决定，是去看一眼就知道的事实：

1. **Cloudinary 的数据存在哪个地区**（账号 `dgeunvmmn`）。在 Cloudinary 控制台 → Settings → Account（或 Product environment）里看地区。我们不能用正式环境的 Cloudinary 凭据，所以只能由你来看。草案第 3、4 节有两处要填它。
2. ~~Firestore 的"过期自动删除"（TTL）有没有打开~~ **已查（2026-09-23，只读读取正式环境的字段设置，没读任何用户数据）**：`userDeletionTombstones.expiresAt` 和 `processedEvents.expiresAt` 的 TTL 是**开着的**，注销记录会按时自动删；`callableRateLimits.expiresAt` **没开**——代码每次都写了过期时间（`functions/src/shared.ts:458-460`），但没人去删，所以按用户 ID 命名的限流记录会一直留着，包括账号注销之后；`geoapifyRateLimits` 也没有 TTL。给 `callableRateLimits` 开 TTL 是改正式环境的设置，要你另外批准；在那之前，草案里不能说这些记录会自动删除。
3. **早期账号的公开资料里还有没有精确经纬度。** 在 Firebase 控制台 → Firestore Database → 数据 → `users` 集合，用查询功能筛 `location.lat` 这个字段。这一步会看到用户数据，所以要你来做。真有的话，清掉它们要改正式环境的数据，到时候再单独问你。草案第 1 节"只显示城市和州"这句取决于这个结果。
4. **2026-09-07 那次导出时，有没有另外导出登录账号**（`firebase auth:export`，`functions/scripts/production-reset.md:56-60`），导出的文件放在哪？这要问做那次导出的人。那个文件里会有所有人的邮箱。
5. （不急）**服务器日志里具体记了什么，比如有没有 IP 地址。** 在 Google Cloud 控制台 → Logging → 日志浏览器里，打开一条云函数的请求记录看看。草案第 1 节里"技术日志"那句要靠它来确认。

---

## 7. DRAFT — 草案，未发布，等你定稿

标记说明：【待定：问题 N】是等你在第 5 节做的决定；【待查：第 6 节第 N 项】是等控制台的查询结果；【待修】是等代码修好以后要删掉的句子；【待改】是 iPhone 功能变了（比如能写评价了）以后要改的句子。其余每一句都已经和代码核对过。

### Privacy Policy

Your privacy matters to us. This policy explains what data PetNote collects, who can see it, where it is kept, and what happens when you delete it. It covers the PetNote website (petnote.vercel.app) and the PetNote iPhone app. Where the two work differently, we say so.

**1. Data We Collect**

Account information:
- Your email address, used for signing in and for account emails such as verification and password reset. It is not shown on your profile.
- Your display name and bio, chosen by you.
- Your profile photo, if you upload one. If you don't, we show a generated default avatar.
- If you sign in with Google (currently website only), Google shares your name, email address and the address of your Google profile photo with our sign-in service. A new account starts with your Google name.

Pet information:
- Each pet's name, species, breed, gender, birthday, bio and photo.
- Who owns the pet: each co-owner and their relationship to the pet.

Content and activity:
- Posts: photos, videos, text, tags, and the pet a post is about.
- Comments and replies.
- Likes, the pets you follow, and the posts you save.
- Meetups you organize or join, including the pet you bring. (On iPhone you can join and leave meetups; organizing them is currently website only.)
- Reviews and check-ins at places, and places you add. (On iPhone you can read reviews and check-ins and write reviews without photos; checking in and adding places are currently website only.)

Safety and support:
- People you block, and content you report.
- Messages you send through Contact us. We store them with your user ID, display name and email address so we can reply.

Location (website only):
- If you choose to set your location on the website, your browser shares your position with us. We keep the exact coordinates in a private part of your account that only you can read, and show only your city and state on your profile.【待查：第 6 节第 3 项——早期账号若还有公开的坐标，这句要改或先清理】
- It is used to show distances to meetups and places.
- You can clear it at any time in Settings on the website.
- The iPhone app does not access your location.

Photos and videos:
- Some photos are re-encoded before upload, which removes hidden details such as where they were taken. In both apps: any post photo you apply a filter to, except a GIF. On iPhone: every profile photo, every HEIC photo, and any photo larger than 2 MB or 1920 pixels. On the website: HEIC photos, and photos larger than 2 MB.
- All other photos, and all GIFs and videos, are uploaded exactly as you picked them, including any hidden details they contain, which can include where they were taken.【待定：问题 3】

Usage data:
- We do not use analytics, advertising or tracking tools on the website or in the iPhone app, and we do not record which pages you visit or which features you use.
- Our servers keep technical logs to run and protect the service. These logs are kept for 30 days.【待查：第 6 节第 5 项——确认日志里有哪些内容（例如 IP 地址）后再写】
- We do not track you across other apps or websites.

What others can see:
- Anyone, including people who are not signed in, can see:
  - your profile (display name, photo, bio, your city and state if set, and when the account was created);
  - your pets, including their birthday, their co-owners and each co-owner's relationship to the pet, and who follows each pet;
  - your posts, who liked them, and comments;
  - meetups, including who is going and which pet they bring;
  - places, reviews and check-ins.
- For a meetup whose organizer chose to show the location only to participants, the exact address is shown only to the organizer and to people who have joined.
- Only you can see your email address, your saved posts, your list of followed pets (although each pet's followers are visible on that pet), the people you block, your settings, your saved location (website), your notifications, and the reports and messages you sent us. Our moderators can see reports, messages and notifications.
- Photos and videos you post are stored at public web addresses. Anyone who has the link can open them.

**2. How We Use Your Data**
- To provide the PetNote service: showing posts, pets, places and meetups, and connecting pet lovers.
- To show in-app notifications about likes, comments and replies, follows, meetup activity, changes to pets you share, and messages from our moderators. You can turn off notifications for likes, comments and follows in Settings. Neither the website nor the iPhone app sends push notifications.
- To improve the app, using the feedback you send us. We do not collect usage statistics.
- To enforce our Terms of Service and protect users.
- We do NOT sell your data to anyone.
- We do NOT use your data for advertising.

**3. Third-Party Services**

Firebase (Google): sign-in (Firebase Authentication), our database (Cloud Firestore) and our server code (Cloud Functions). The database is stored in Google Cloud's United States multi-region, and our server code runs in the United States. Firebase Authentication also sends account emails, such as verification and password reset.

Cloudinary: stores and delivers photos and videos. Both the website and the iPhone app upload your photos and videos directly to Cloudinary. Stored in 【待查：第 6 节第 1 项】.

Geoapify (website only): address search, and turning coordinates into a city name. Our servers send Geoapify the address you type or the coordinates you choose. Your device does not contact Geoapify directly.

DiceBear: generates default avatars for people and pets without a photo. Your name, email address and content are not sent to DiceBear. The avatar's web address contains the account's or pet's internal ID, and, as with any image, DiceBear can see the IP address of the device that loads it.

Apple Maps (iPhone): only when you tap Directions, the app opens Apple Maps with the place's coordinates and name. PetNote does not send your own location.

Vercel: hosts the website, including the Privacy Policy and Terms pages that the iPhone app opens. It serves web pages only and does not store your account data. Like any web host, it can see the IP address of the device loading a page.

**4. Data Storage and Security**
- Your profile and content are stored in Cloud Firestore in the United States. Your sign-in details are held by Firebase Authentication. Photos and videos are stored by Cloudinary 【待查：第 6 节第 1 项】.
- Some data is also kept on your own device. See section 8.
- Passwords are handled entirely by Firebase Authentication. PetNote's own servers and database never receive or store your password.
- We use Firestore security rules to control who can read and change data, as described under "What others can see".
- All data is sent over HTTPS.

**5. Your Rights**

You can:
- See your profile, pets, posts, saved posts, followed pets, check-ins and blocked people in either app. There is not yet one place that shows all the data we hold about you.
- Edit your profile, pets and posts at any time.
- Delete your posts and comments, and pets you are the only owner of. A pet you share stays with its other owners when you leave it.
- Delete your entire account in Settings, in either app. On iPhone, you confirm with your password (or by signing in with Google again) and by typing DELETE.
- Turn off notifications for likes, comments and follows in Settings, in either app.
- Clear your location in Settings on the website. The iPhone app never has your location.
- Ask for a copy of your data through Contact us. There is no automatic export; we prepare the copy by hand within 【待定：问题 5】.

**6. Data Deletion**

When you delete your account, we delete from our database:
- your profile and your username;
- your posts, with their likes and comments, and other people's saves, reports and notifications about them;
- your comments and likes on other posts, your check-ins and reviews, the meetups you organized (with everyone's sign-ups), and your sign-ups to other meetups;
- your follows, saved posts, blocks, settings (including a saved location), and notifications, both those sent to you and those your activity created;
- the reports and messages you sent us;
- your sign-in account.

Pets you share with other owners are not deleted; they pass to the owner who joined earliest. Pets you are the only owner of are deleted.

What is not deleted:
- Places you added, and places created for public meetups you organized, stay on PetNote. They keep your user ID and the display name you had when they were created. The apps do not show this name, but it is part of the place's public record.【待定：问题 2】
- Photos from your reviews that were added to a place's photo list stay in that list.【待修：第 4 节"还没修"第 1 条，修好后删掉这一条】
- Reports that other people filed about your account or your comments are kept for our moderators.
- Small technical records containing only your user ID, used to stop the account from being recreated by accident and to limit how often requests can be made, are removed automatically within a day.【待查：第 6 节第 2 项——自动删除没开的话，这句要改】
- Photos and videos are not deleted from Cloudinary when you delete a post, a pet or your account. They stop appearing in PetNote but remain at their web addresses, where anyone who has the link can still open them.【待定：问题 1——选 (b) 或 (c) 的话改写这一条】
- Backups: we do not currently make regular backups. One full copy of our database was made on 7 September 2026. It is deleted automatically after 90 days, in early December 2026. If your account existed on that date, a copy of its data remains in that backup until then. Separately, our database keeps its own recent history for one hour.【待定：问题 7】【待查：第 6 节第 4 项——那次若也导出了登录账号，补一句】

If you delete your account in the iPhone app, the app also removes, on that iPhone, your sign-in session, your unfinished post draft and its cached images.

**7. Children's Privacy**

PetNote is not intended for children under 13. We do not ask for your age, and we do not knowingly collect data from children under 13. If we discover that a child under 13 has created an account, we will delete it【待定：问题 5——多快】.

**8. Cookies, Local Storage and Data on Your Device**

Website:
- Session storage: an unfinished post draft, which is cleared when you close the tab or after 24 hours, and your scroll position.
- Local storage: your dark mode and language choices, featured posts you have already seen, and your onboarding progress.
- Your sign-in session, kept by Firebase in your browser.

iPhone app:
- An unfinished post draft: its text, tags, chosen pet, and the web addresses of photos already uploaded (never the photos themselves). One draft is kept for each account on this iPhone, and it stays after you close the app or sign out. After 24 hours it is no longer offered. It is removed when you post or discard it, the first time that account opens the composer after those 24 hours, when you delete the account in this app, or when you remove the app.
- Recently viewed images, cached so they load faster (up to 256 MB). Signing out clears the copy held in memory but keeps the copy on the iPhone, which contains only images that anyone can see. Deleting your account in this app clears both.
- PetNote content you load, such as posts, profiles and notifications, is kept in memory only while the app runs and is not saved on the iPhone.
- Your sign-in session, kept by Firebase in the iOS Keychain and removed when you sign out.
- Videos you pick for a post are copied to the app's temporary folder, which iOS empties on its own schedule.

We do not use tracking cookies, advertising identifiers or tracking tools.

**9. Changes to This Policy**

We may update this policy from time to time. We will tell users about significant changes 【待定：问题 6】. The date below shows when it last changed.

**10. Contact**

For privacy questions or data requests, use Contact us while signed in: on iPhone, Profile → Contact us or Settings → Contact Us & Feedback; on the website, Settings → Contact Us & Feedback.【待定：问题 4——给不能登录或被封的人一个邮箱】

Last updated: 【待定：发布日期】

### Terms of Service（只列要改的段落）

**1. About PetNote.** PetNote is a pet-focused social platform where pet lovers can share photos, discover pet-friendly places, and organize meetups. In the iPhone app you can browse places with their reviews and check-ins, write reviews, and join and leave meetups; adding places, checking in and organizing meetups are currently available only on the website. The service is provided as-is and may change over time.

**2. Your Account**（第一条后面加一句）. You must be at least 13 years old to use PetNote. We do not check your age.

**3. Content You Post**（最后一条）. Deleted posts are removed from the app right away. Photos and videos in them are not deleted from our media storage and remain at their web addresses【待定：问题 1】.

**4. Pet Safety**（第二条）. Content depicting or promoting animal cruelty will be removed and the account banned 【待定：问题 5——保留 "immediately"，还是写成 "promptly" 或 "within … of a report"】. Reports are reviewed by a person.

**6. Places**（第一条）. Place information is submitted by users and is not verified by PetNote. The "✓ Verified" mark means that a place has at least three check-ins from users; it is not a check by PetNote.

**8. Account Termination.** You can delete your account at any time in Settings, in either app. We may suspend or terminate accounts that violate these terms. When you delete your account, your data is removed as described in section 6 of the Privacy Policy, including what is kept and for how long.

**10. Changes to Terms**（第二条）. We will tell users about significant changes 【待定：问题 6】. Continued use of PetNote after changes means you accept the updated terms.

**11. Contact.** If you have questions about these terms, use Contact us while signed in (on iPhone: Profile → Contact us, or Settings → Contact Us & Feedback)【待定：问题 4】.

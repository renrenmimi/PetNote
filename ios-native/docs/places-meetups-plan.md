# 地点、打卡、聚会：逐项现状、卡在哪、要你定什么

更新于 2026-09-23。每一条都对着代码和测试核过，括号里是文件和行号。

**「能浏览、能报名」不等于这个功能做完了。** 下面分成 15 项：做到 ③ 的有 7 项（1a、1b、2、3、5、13、14），但都只是在本机模拟环境里，没有一项到 ④；而且 1b 里「按宠物种类」「我报名的」两个筛选还算 ②，第 5 项不带照片。第 4 项（权限）跟着各项走。其余 7 项（6 到 12）还是 ①，其中第 6 项只有只读的部分做到 ③。

等级和 `STATUS.md` 用同一把尺，只记已经达到的最高一级：

① 未实现 · ② 单元测试通过（不经界面）· ③ 界面测试通过（本机模拟器 + 本机模拟后端）· ④ 在测试云 `petnote-devtest` 上通过 · ⑤ 真机通过 · ⑥ 被外部卡住

## 测试云上现在有什么

- 34 个函数，是 `9c6a461` 时的代码（`test-cloudinary-setup.md:93`）。地点和聚会的函数只有一个：宠物主页读打卡用的 `getPetCheckinsCallable`（`functions-testcloud/index.js:80`）。其余地点、打卡、评价、聚会的函数一个都没有（`index.js:60-104`）。
- 没有地点和聚会数据。
- 没有 Geoapify 密钥，也没有 Cloudinary 账号。

## 旧版（网页）的范围

- 地点：列表（按类别筛；按附近、评分、评价数、最新排；搜索框既能按名字搜，也能搜地址），详情（照片、设施、评价、打卡、在这里办的聚会、导航），添加地点，写评价（总评分、三个小项、标签、最多 3 张照片）。
- 打卡：必须带照片，宠物可选，同一地点每人每天一次。
- 聚会：列表（附近、本周、我的、按宠物种类），详情，报名，退出，发起人取消，结束后给地点打分，发起，编辑（含封面图、仅参与者可见的地址）。
- 设置里的「我的位置」。
- App 不能直接写地点、聚会、评价、打卡，全部经过服务端函数。App 能直接做的只有：读，删自己的评价或打卡，删自己的报名记录（就是「退出」）。

## 1. 逐项表

| # | 能力 | 现在 | 证据 | 卡在哪 | 要什么才能往下走 |
| --- | --- | --- | --- | --- | --- |
| 1a | 浏览地点 | **③**（排序和按名字搜的界面测试 `a06458f` 补上：`testEachSortOrdersThePlacesByTheServersNumbers`、`testSearchingPlacesByTheStartOfTheirNameAndClearingIt`）。另有单元测试 `aCategoryAndASortAreReadAsChosen`、`aNameSearchReplacesTheListAndClearingItComesBack`、`aSlowOldAnswerDoesNotOverwriteANewerChoice`、`aFullPageMeansMoreAndTheNextPageStartsAfterTheLast`（`1186220`） | `44f8d99`。`testThePlacesListAPlaceAndAMeetupHeldThere`：列表上的「4.5（2 条评价）」「2 次打卡」是服务端触发器算出来的，和服务端一致；选「狗公园」后咖啡馆不再显示；详情页 2 条评价、2 次打卡、有苹果地图导航；从地点能进到在那里办的聚会。单元测试：`aStoredPlaceBecomesAPlace`、`anUnreviewedPlaceSaysSoAndOneWithoutCoordinatesHasNoDirections`、`thereIsNoOtherFilter`。分享链接：`DeepLinkTests` | 本机没有阻塞。测试云上：没有数据；种子脚本的自检（`seed-ios-native.mjs` 的 `gatheringChecks`，`:676`）要等评价、打卡触发器算完数，这些触发器不在测试云上 | ④：部署清单 B 里的 4 个触发器，再用种子脚本往测试云写 3 个地点、6 个聚会 |
| 1b | 浏览聚会 | **③**：即将举行、本周、我发起的、仅参与者可见的聚会在列表里只露城市。**②**：按宠物种类；我报名的（界面上间接走过一次，见右边） | `testJoiningLeavingAPrivateAddressAndAFullMeetup` 前半：已取消的不在「即将举行」里，十天后的不在「本周」里，私密聚会列表里只有 Somerville、没有街道。`testAnOrganiserCancelsTheirMeetupFromMyMeetups`：我发起的在「我的」里。我报名的：`testRatingThePlaceOfACompletedMeetup` 里新账号只是一个聚会的参与者（报名记录是测试直接写进去的，没有点报名），它能在「我的」里找到并打开这个聚会；但这是那个测试路过的一步，不是专门验这个筛选，没有核对「我的」里还有什么、少了什么。单元测试：`eachFilterAsksForItsOwnList`、`theFiltersFollowTheMeetupsPetType`、`aMeetupWithoutAVisibilityIsPrivate`、`theRequirementsAreTheServersRules` | 同 1a | 同 1a |
| 2 | 报名、退出 | **③** | `testJoiningLeavingAPrivateAddressAndAFullMeetup`：带宠物报名后，服务端人数从 1 变 2，退出后回到 1；报名前看不到私密地址，报名后看到「12 Elm St」；满员时显示服务端原话「Meetup is full.」，服务端什么也没写。单元测试：`aRefusedJoinSaysTheServersReasonAndChangesNothing`、`leavingIsOnlyForAParticipantAndCancellingOnlyForTheOrganiser` | 测试云上没有 `joinMeetupCallable` 和 `onParticipantDeleted`。退出是 App 直接删自己的报名记录，人数靠 `onParticipantDeleted` 减（`meetups.ts:209-227`） | ④：清单 B |
| 3 | 发起人取消 | **③** | `testAnOrganiserCancelsTheirMeetupFromMyMeetups`：服务端状态变成 cancelled，页面显示已结束，不再有报名按钮 | 测试云上没有 `cancelMeetupCallable` | ④：清单 B |
| 4 | 权限（谁能做什么） | App 按服务端规则显示按钮：**②/③**。服务端规则本身有服务端自己的测试（`tests/rules/meetups.test.ts`、`functions/src/__tests__/meetup-privacy.test.ts`、`place-contributions.test.ts`），这一轮没有重跑 | 私密地址只在允许的时候才去读：`thePrivateAddressIsReadOnlyByThoseAllowedIt`；界面上报名后才出现地址（第 2 项）。逐条规则见下面第 2 节 | 无 | 跟着各项走 |
| 5 | 文字评价；聚会结束后给地点打分 | **③**（emulator，不带照片） | `1186220`。`testWritingAReviewOfAPlace`：新账号给公园打总分、选一个标签、写一段话，服务端读回这三项，触发器把评价数加 1；写过后按钮不再出现（三个小项只在单元测试里验过）。`testRatingThePlaceOfACompletedMeetup`：种子里有一个已结束、开放打分的聚会（发起人是种子账号 Accept B）；测试新建一个账号，直接把它写成这个聚会的参与者，再从「我的」打开聚会、给地点打 5 分；服务端读回的记录编号是 `{用户}_{聚会}`，里面有聚会编号和 5 分，按钮变成「你已给这次聚会的地点打过分」。发起人自己打分这种情况没有测试。单元测试：只发给了的小项、聚会编号、打分条件、连点只发一次、服务端拒绝时显示它的原话、留言按 UTF-16 数（和网页、服务端一样，表情算 2）。服务端 `submitReviewCallable`（`places.ts:593-759`）：照片可选，最多 3 张（`:715`），这一版 App 不带照片 | 测试云上没有这个函数和两个评分汇总触发器 | ④：清单 B 里的 `submitReviewCallable`、`onReviewCreated`、`onReviewDeleted`、`checkMeetupStatusCallable`。带照片要测试 Cloudinary |
| 6 | 打卡 | 发打卡 **①**。只读的部分：地点详情里的最近打卡 ③（1a）；「我的打卡」列表 ③（`9b591fa`，个人主页 → 打卡，只能看）；宠物主页那一栏界面没验 | 「我的打卡」：`CheckinHistoryUITests.testMyCheckinNamesItsPlaceAndOpensIt`，用种子账号 Accept A 登录，个人主页 → 打卡，列表里有自己在公园的那次打卡，写着地点名和留言，同一个公园里别人的打卡不在里面，点开进到那个地点。发打卡：`checkInCallable`（`places.ts:761-858`）：必须带照片（`:784-792`）；宠物可选，但必须是自己能管的（`:803-813`）；同一地点每人每天一次（`:815-816`） | 必须带照片 → 要上传 → 测试云要一个测试 Cloudinary 账号（`test-cloudinary-setup.md`，等你开） | 本机：用本地上传替身做到 ③（和换头像一样，标「上传为替身」），现在就能做。④：你开 Cloudinary 账号 → 部署两个媒体函数 + `checkInCallable`、`onCheckinCreated`、`onCheckinDeleted` |
| 7 | 照片：评价照片、地点照片、聚会封面 | **①**（地点详情里能看照片，那属于浏览） | 评价最多 3 张（`places.ts:715`）；添加地点时最多 5 张（`:216`）；给已有地点加照片（`addLocationPhotosCallable`）**只有建这个地点的人或管理员能做**（`:582-585`），别人只能通过评价或打卡带照片；聚会封面可选（`meetups.ts:365-373`） | 同第 6 项：测试 Cloudinary | 本机：上传替身做到 ③。④：Cloudinary 账号 + 两个媒体函数 + `addLocationPhotosCallable`，以及带照片的评价、发起和编辑聚会。另外：测试云上已有的 5 个旧函数要重新部署才认测试账号的图片（`test-cloudinary-setup.md:93-103`）。那是发帖和头像的事，和地点无关，但属于同一次批准 |
| 8 | 添加地点 | **①** | `addPlaceCallable`（`places.ts:486-548`）不用密钥；要邮箱已验证（`:490`）；名字、地址、坐标必填，服务端只检查格式和范围，不去查地址（`:179-193`）；同坐标同名字的地点已经存在时不新建，返回已有的那条（`:506-512`）；照片可选 | 坐标只能来自地址搜索或「用我的位置」，网页版不允许手输地址（`src/pages/AddPlace.tsx:120-121`、`:351-363`）。两条路都要 Geoapify | 决定 1。部署 `searchAddressesCallable`、`addPlaceCallable`；「用我的位置」还要 `reverseGeocodeCallable` 和决定 3 |
| 9 | 发起、编辑聚会 | **①** | `createMeetupCallable`（`meetups.ts:229-423`）：要邮箱已验证（`:233`）；时间必须在将来（`:274`）；不选时默认「仅参与者可见」（`:279-280`）；地址和坐标由 App 给，服务端只校验（`:53-91`）；公开聚会会顺带建一个地点（`:286-292`）；发起人自动成为第一个参与者（`:401-418`）。`updateMeetupCallable` 只允许发起人或管理员（`:462`） | 地址要 Geoapify，同第 8 项 | 决定 1。部署 `searchAddressesCallable`、`createMeetupCallable`、`updateMeetupCallable`；带封面还要 Cloudinary |
| 10 | 地址搜索 | **①** | `searchAddressesCallable`（`geo.ts:212-252`）要密钥 `GEOAPIFY_API_KEY`（`:213`）；只搜美国和加拿大（`:242`），最多 5 条，英文（`:243-244`）；至少 2 个字（`:223`）；每人每分钟最多 30 次没命中缓存的查询（`:31`、`:177-210`）；同一句话 5 分钟内再搜走缓存（`:29`）。网页版停手 0.3 秒才查（`AddressAutocomplete.tsx:58-73`）。网页版地点列表的搜索框也用它：选中一个地址后，按离那里的远近排（`Places.tsx:292-300`）；iOS 现在只按名字开头搜 | 测试云上没有密钥，也没部署这个函数。本机模拟后端里也没有 Geoapify 密钥（`functions/.secret.local` 里只有两个假的 Cloudinary 值），本机也查不到 | 决定 1 |
| 11 | 附近 | **①** | 网页版「附近」**从不调用 Geoapify**：读已经保存的位置，在手机上算距离排序。地点见 `src/services/locations.ts:245-257`；聚会是取 50 个即将举行的，留下 50 英里内的（`src/services/meetups.ts:280-301`）。位置从 `users/{uid}/settings/location` 读（`src/services/location.ts:94-124`） | 读已保存的位置什么都不卡；卡在 iOS 上还没法保存位置（第 12 项） | 现在就能做：有保存的位置（网页版存过，或种子写进去）才显示「附近」，在模拟环境做到 ③。要完整，得等第 12 项 |
| 12 | 我的位置（设置） | **①** | 网页版的流程：取手机位置 → 调 `reverseGeocodeCallable` 查城市 → 精确坐标写进 `users/{uid}/settings/location`（只有本人能读，`firestore.rules:302-313`），城市和州写进公开的用户资料（`src/services/location.ts:65-91`；用户资料谁都能读，`firestore.rules:239`；个人主页会显示城市，`UserProfile.tsx:231-235`）。保存这一步是 App 直接写，不需要函数 | 一、iPhone 定位要在 Info.plist 里写一句用途说明，现在一句都没有（`ios-native/Config/Info.plist`），文字要你定（决定 3）。二、查城市要 `reverseGeocodeCallable`（决定 1） | 决定 1 + 决定 3。iOS 保存时，把公开资料里的位置整个换成「城市、州」，顺便去掉老账号可能还公开留着的坐标（规则允许删，不允许改：`firestore.rules:175-194`） |
| 13 | 聚会到点自动结束 | **③**（`a06458f`，`testOpeningAMeetupThatHasEndedSettlesIt`：测试里写一个时间已过、状态还是 upcoming 的聚会，打开后页面显示已结束，服务端变成 completed、开放打分；切换筛选后它不在「即将举行」里） | 服务端有个每 15 分钟跑一次的定时任务 `autoCompleteMeetups`（`meetups.ts:788-816`）；测试云的部署入口拒绝一切定时任务（`functions-testcloud/index.js:137-141`）。所以 App 打开一个已过结束时间的聚会时，会请服务端 `checkMeetupStatusCallable` 结算：改成已结束，并开放打分（`meetups.ts:818-851`）。单元测试：`anEndedMeetupIsSettledByTheServer`、`aMeetupStillOnIsNotSettled` | 本机无。测试云上：过了时间、又没人打开过的聚会会一直排在「即将举行」最前面（列表只按状态和时间查，见 `Meetups.swift` 里的 `upcoming(limit:)`） | ④：清单 B 的 `checkMeetupStatusCallable`。定时任务不上测试云 |
| 14 | 聚会通知（站内） | **③**（`a06458f`，`testAJoinTellsTheOrganiserAndACancellationTellsWhoJoined`：两个新账号，一个报名、一个取消，两边的通知列表和服务端的通知记录都核对，点开标为已读、停在列表上） | 有人报名 → 发起人收到「joined your meetup」（`notifications.ts:696-722`）；发起人取消 → 每个参与者收到「cancelled the meetup」（`:724-762`）。这两种通知在设置里关不掉（`:162-166`）；取消通知连拉黑了发起人的人也会收到（`:208-212`）。App 的通知列表认得这两种；点开停在列表上，因为通知里没有聚会编号，网页版也一样（`Notifications.swift:40-52`；`NotificationsTests.swift:98`）。手机推送：旧版就没有，本轮不做（`native-push-proposal.md`） | 本机无，模拟后端里这两个触发器在跑。测试云上没有 | ④：清单 B 的 `onMeetupParticipantCreated`、`onMeetupUpdated` |

## 2. 谁能做什么（服务端实际怎么管）

| 动作 | 谁可以 | 另外的限制 | 依据 |
| --- | --- | --- | --- |
| 看地点、评价、打卡、聚会、参与者名单 | 任何人，不登录也行 | — | `firestore.rules:494`、`:500`、`:530`、`:537`、`:546` |
| 看「仅参与者可见」聚会的详细地址 | 发起人、已报名的人、管理员 | 公开的那份里没有街道和坐标，名字只写「Meetup near 某城市」 | `firestore.rules:515-520`；`meetups.ts:107-117`、`:294-303` |
| 报名 | 已登录、没被封、账号不在注销中；**不要求邮箱已验证** | 和发起人之间有拉黑就不行；已取消、已结束、满员都不行；必须选一只自己能管的宠物（发起人可以不带）；发起人设的要求：发过帖、有宠物资料、关注数、只限狗或猫或其他 | `meetups.ts:598-782`（`:636-638`、`:648-658`、`:665-693`、`:695-754`） |
| 退出 | 本人，删自己的报名记录 | 人数由触发器减。发起人和管理员也能删任何人的报名记录，等于「踢人」，但网页版和 iOS 都没有这个按钮 | `firestore.rules:504-508` |
| 取消聚会 | 发起人、管理员 | 服务端不看聚会是否已结束；App 只在「即将举行」时给这个按钮 | `meetups.ts:563-596` |
| 编辑聚会 | 发起人、管理员 | 时间必须在将来 | `meetups.ts:425-561` |
| 发起聚会、添加地点 | 已登录、**邮箱已验证**、没被封、账号不在注销中 | 限流比一般写操作严 | `meetups.ts:229-242`；`places.ts:486-499` |
| 给已有地点加照片 | 建这个地点的人、管理员 | — | `places.ts:582-585` |
| 写评价 | 已登录、邮箱已验证、没被封、账号不在注销中 | 每人每地点一条；聚会后打分的条件见第 5 项 | `places.ts:593-606`（注销检查在 `:605`）、`:688` |
| 打卡 | 已登录、邮箱已验证、没被封、账号不在注销中 | 必须带照片；每人每地点每天一次 | `places.ts:761-816`（注销检查在 `:773`） |
| 删评价、删打卡 | 本人、管理员 | App 直接删；网页版没有删除按钮 | `firestore.rules:539-540`、`:549-550` |
| 结算已过时的聚会 | 任何已登录的人 | 只会把过了结束时间的改成「已结束」 | `meetups.ts:818-851` |
| 地址搜索、查城市 | 已登录、没被封 | 每人每分钟最多 30 次没命中缓存的查询 | `geo.ts:170-175`、`:212-218` |

## 3. Geoapify：建议走方案 (a)

### 一句话

测试云用一个**你新开的、独立的** Geoapify 免费账号。它的 key 只存在测试项目的密钥 `GEOAPIFY_API_KEY` 里。生产的 key 不复制、不读取、不使用。

- **为什么要单独的账号**：免费版每天 3,000 个额度，不要信用卡，可以正式使用（官网 pricing 页，2026-09-23 查）。地址搜索、查城市每次各算 1 个额度（官网 pricing-details 页）。官网没写同一个账号下的多个项目是不是共用额度，所以不在生产账号里建项目。用超了不会马上封 key，Geoapify 会先联系你。
- **为什么只能靠「存对 key」保护生产**：服务端不按项目选 key，拿到哪个就用哪个（`geo.ts:235`、`:279`）。Cloudinary 不一样，它是按项目查表选账号的（`platform.ts:69-81`）。所以测试项目里存的是哪个账号的 key，测试云就花哪个账号的额度。如果存成了生产的 key，测试就会花生产的额度，代码拦不住。

### 要部署到 `petnote-devtest` 的函数

**清单 A：Geoapify 这一组，5 个**

| 函数 | 做什么 | 密钥 | 对外的影响 |
| --- | --- | --- | --- |
| `searchAddressesCallable` | 输入文字，返回最多 5 个美国或加拿大的地址 | `GEOAPIFY_API_KEY` | 调 Geoapify；没命中缓存的每次算 1 个额度 |
| `reverseGeocodeCallable` | 坐标变成城市和地址 | `GEOAPIFY_API_KEY` | 同上 |
| `addPlaceCallable` | 建地点 | 无 | 只写测试项目的数据库 |
| `createMeetupCallable` | 发起聚会（公开的会顺带建地点） | 无 | 只写测试项目的数据库 |
| `updateMeetupCallable` | 编辑聚会（只给发起人和管理员） | 无 | 只写测试项目的数据库 |

**清单 B：可选，11 个。都不用密钥，也不连任何外部服务**

- 报名、退出、取消、结算：`joinMeetupCallable`、`cancelMeetupCallable`、`checkMeetupStatusCallable`、`onParticipantDeleted`
- 聚会站内通知：`onMeetupParticipantCreated`、`onMeetupUpdated`
- 评价和评分汇总：`submitReviewCallable`、`onReviewCreated`、`onReviewDeleted`
- 打卡计数（种子数据的自检要用）：`onCheckinCreated`、`onCheckinDeleted`

**不部署**：`autoCompleteMeetups`（定时任务，入口会拒绝）；`checkInCallable`、`addLocationPhotosCallable`（要照片，等 Cloudinary）；`recomputeLocationReviewAggregatesCallable`（已停用）；`onLocationDeleted`（App 不能删地点）。

### 你要做的（最短，约 5 分钟）

1. 用一个**新**邮箱在 https://myprojects.geoapify.com/ 注册，免费，不用信用卡。**不要**用生产的 Geoapify 账号，也不要在它里面建项目。
2. 登录后点「Create a project」，名字随便起，比如 `petnote-devtest`。它会自动生成一个 API key。复制下来，**不要发给我**。
3. 打开终端，依次运行下面三行。第二行会让你输入：粘贴 key，然后回车。输入时屏幕上不显示。如果它问要不要重新部署什么，回答 No。

   ```
   d="$(mktemp -d)" && cd "$d"
   firebase functions:secrets:set GEOAPIFY_API_KEY --project petnote-devtest
   cd ~ && rm -rf "$d"
   ```

   - 为什么先进一个空的临时文件夹：firebase-tools 出错时，会把你刚输入的值写进当前文件夹的 `firebase-debug.log`，而且不删（Cloudinary 那个脚本也是因为这个才这样做，见 `setup-test-cloudinary.mjs:133-137`）。第三行会把这个文件夹连同里面的东西一起删掉。
   - 用 `firebase`，不用 `npx firebase`：仓库里别的步骤用的都是 `firebase`。
   - 如果它说没登录，先运行 `firebase login`。
   - **不要**运行 `firebase functions:secrets:access`：它会把值直接打印在屏幕上。
4. 告诉我「存好了」。只说这一句，不发 key。

验证完之后，还有一步只有你能做：打开**生产** Geoapify 账号的 Statistics 页面看一眼（见下面「之后验证什么」）。

### 主线程要做的

1. 只改测试云的部署入口 `functions-testcloud/index.js`，不改 `functions/src`：
   - 加上清单 A，以及你批准的清单 B。
   - 密钥检查：两个地址函数只许、而且必须用 `GEOAPIFY_API_KEY`，别的函数照旧一个密钥都不许用。现在的检查只放行两个媒体函数的 Cloudinary 密钥（`:154-172`，放行在 `:159`）。
   - 把核对的导出个数从 34 提高到 34 加批准的个数（`:129`）。
   - 更新文件里「测试项目没有 Geoapify key」这类说明（`:4-9`、`:23-24`、`:184-185`）。载入聚会模块会多构造一个定时任务 `autoCompleteMeetups`，现在的「禁止定时任务」检查（`:137-141`）照样拦得住，只是注释里的个数要改（`:134-136`）。
   - 在本机加载实测：给生产项目的编号仍然拒绝；导出个数对；打印出来保留的密钥只有 `GEOAPIFY_API_KEY`（媒体函数还没配的时候）。
2. 你存好 key 后，用 `firebase functions:secrets:get GEOAPIFY_API_KEY --project petnote-devtest` 确认有一个启用的版本。这条命令只看版本信息，不看值。
3. 部署时逐个点名：

   ```
   node functions/scripts/prepare-testcloud-deploy.mjs
   firebase deploy --config firebase.testcloud.json --project petnote-devtest --non-interactive \
     --only functions:testcloud:searchAddressesCallable,functions:testcloud:reverseGeocodeCallable,functions:testcloud:addPlaceCallable,functions:testcloud:createMeetupCallable,functions:testcloud:updateMeetupCallable
   ```

   批准了清单 B，就把 B 的名字加在同一行。
4. App 这边：地址搜索、添加地点、发起和编辑聚会的界面。本机能验的部分先在本机验（本机查不到地址，见第 10 项），然后连测试云验。

### 之后验证什么

不会因为「部署成功」「请求返回 200」就说通过。

- **部署本身**：部署日志里，入口打印的保留密钥只有 `GEOAPIFY_API_KEY`（媒体函数还没配的时候）；`firebase functions:list --project petnote-devtest` 只多出批准的那些名字。
- **App 连测试云**：
  - 搜「Cambridge MA」有结果，而且只出美国、加拿大的地址。
  - 选一个结果添加地点：服务端地点记录里的坐标和城市，就是选中的那个结果；同一个地方再加一次，返回已有的那条，不会重复建。
  - 发起公开聚会：聚会和它的地点都在，列表里能看到。发起「仅参与者可见」的：公开的那份里没有街道和坐标，只给参与者看的那份里有。
  - 编辑时间和地址：服务端跟着改了。换一个不是发起人的账号，改不了，App 显示服务端的原话。
  - 断网或服务端报错时，App 说清楚是怎么回事，已经填的内容不丢。
- **额度花在哪个账号（最重要的一条）**：
  - 记下测试期间一共搜了几次、查了几次城市。
  - 测试 Geoapify 账号的 Statistics 显示有调用，次数不超过这个数（5 分钟内重复的搜索走缓存，不算）。每次请求只带一个 key（`geo.ts:245`、`:287`），所以只要测试账号这边的数对得上，就说明请求走的是测试账号。Statistics 可能要过一会儿才更新。
  - **你**打开生产 Geoapify 账号的 Statistics：同一时段**没有多出这一截**。生产本来就有真实用户在搜，所以看的不是「是不是零」，而是有没有跟着多出同样的一截。
- **生产没被动过**：入口在加载时就拒绝任何别的项目（`functions-testcloud/index.js:44-49`），这次不往生产部署任何东西。

### 没推荐的几种做法

- **(b) 只在本机模拟环境里验，用一个假的 Geoapify**：测试云和真机上永远走不通；而且得改 `geo.ts`，让它按项目换请求地址，等于给生产代码多加一条路。
- **(c) 让用户手输地址**：服务端确实只检查格式、不查地址，但手输的地址没有坐标，网页版从来不允许这样（`AddPlace.tsx:120-121`）。硬要做就得另想办法拿坐标，「附近」和导航会跟着出错。
- **(d) 用 iPhone 自带的苹果地图搜地址（不要 key）**：地址和城市的写法跟网页版的 Geoapify 不一样；地点编号是按坐标和名字算的（`places.ts:145-161`），同一个公园从网页和 iPhone 各加一次，会变成两条；而且这样测的就不是生产实际走的那条路了。
- **在地点页加「在这里办聚会」，直接用地点已经存好的坐标**：网页版没有这个入口，等于加新功能；而且解决不了添加地点。

## 4. 要你做的决定（新的 3 个）

1. **Geoapify**：同意方案 (a)，并同意把清单 A 的 5 个函数部署到 `petnote-devtest`。同意的话，就照上面「你要做的」操作。
2. **清单 B 要不要一起部署**（11 个，不用密钥，不连外部服务）。不部署也可以：这些功能在本机都已经做到 ③，只是在测试云上走不通（到不了 ④）。
3. **定位权限的文字**。这句话会出现在系统弹窗里，App Store 审核也会看。草稿：
   - 中文：「PetNote 在你使用 App 时读取位置，用来按远近排列附近的地点和聚会，以及在你添加地点或发起聚会时帮你填写地址。」
   - English: "PetNote uses your location while you use the app to sort nearby places and meetups by distance, and to fill in the address when you add a place or create a meetup."
   - 只申请「使用 App 期间」，不申请「始终」。
   - 另外建议在设置的「我的位置」下面加一句。网页版现在没有这句话，但城市确实会公开：
     - 中文：「保存后，你所在的城市会显示在你的个人主页上；其他人看不到你的精确位置。」
     - English: "Once saved, your city appears on your profile. Other people can't see your exact location."

还有一个**以前就在等、不算新的**：测试 Cloudinary 账号（`test-cloudinary-setup.md`）。打卡和所有照片都在等它。

## 5. 不用等任何人，现在就能做的

1. 打卡、评价照片、地点照片、聚会封面：用本地上传替身在模拟环境做到 ③，标注「上传为替身」。
2. 「附近」：有保存的位置才显示，在手机上按距离排；种子给测试账号写一个位置，做到 ③。
3. 发起聚会、编辑聚会、添加地点这几个表单里，**除了地址以外**的部分（标题、说明、时间、时长、要求、可见范围、带哪只宠物；编辑只给发起人）：用替身数据做到 ②。
4. 只读核对测试云：把地点和聚会用到的查询加进 `functions/scripts/verify-client-features.mjs`（现在里面一条地点、聚会的查询都没有），在测试项目上跑一遍，提前发现缺的索引。不部署，不留数据。

这张清单上原来还有几条，已经做完，拿掉了：地点三种排序和按名字搜的界面测试、打开过了时间的聚会时的结算、聚会站内通知的界面测试（都在 `a06458f`，见第 1a、13、14 项）；文字评价和聚会后打分（`1186220`，见第 5 项）。

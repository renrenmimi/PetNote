# PetNote 项目技术报告

## 一、项目定位

PetNote 是一个以宠物为中心的社交应用。它不是单纯的“发帖 App”，而是把社交内容、宠物档案、地点发现、线下聚会、通知和管理后台放在同一个产品里。

当前版本已经完成从“前端直接写 Firestore”向“后端权威写入”的迁移，核心业务写入主要由 Firebase Callable Functions 处理，聚合与同步由 Trigger Functions 处理。

---

## 二、技术栈

### 前端

- React 19
- TypeScript 5.9
- Vite 7
- Tailwind CSS 4
- React Router 7
- Lucide React

### 后端与云服务

- Firebase Authentication
- Firestore
- Firestore Security Rules
- Firebase Cloud Functions
- Cloudinary
- Geoapify

### 其他依赖

- heic2any：处理 HEIC 图片
- DiceBear：默认头像
- Browser Geolocation API：获取当前位置

### 部署

- Vercel：前端部署
- Firebase：Rules 与 Cloud Functions 部署

Cloud Functions 当前运行在 Node 22 环境上。

---

## 三、当前功能概览

### 1. 账户系统

- 邮箱密码注册、登录、忘记密码
- Google 登录
- 邮箱验证
- 新用户用户名生成和 onboarding
- 个人资料编辑
- 删除账户

### 2. 社交内容

- 文字、图片、视频帖子
- 点赞
- 评论与回复
- 收藏
- 话题标签
- 全局 Feed
- 关注宠物 Feed

### 3. 宠物系统

- 创建、编辑、删除宠物
- 宠物头像、物种、性别、生日、简介
- 宠物家庭
- 邀请码加入家庭
- 关注宠物与粉丝统计
- 宠物主页与宠物相关帖子

### 4. 地点系统

- 创建地点
- 地点评价
- 地点图片
- 签到
- 地点详情页
- 附近地点与搜索

### 5. Meetup 系统

- 创建、编辑、取消 Meetup
- 加入与退出 Meetup
- 参与资格校验
- 私密地址与公开地址分离
- 活动结束后评价

### 6. 通知与后台

- 实时通知
- 服务端通知生成
- 举报与反馈
- 管理员警告
- 管理后台审核与封禁

---

## 四、当前架构模型

### 1. Firestore Rules 的职责

当前 Rules 主要负责两类事情：

- 控制谁能读哪些路径
- 只放行极少量简单的 owner-only 写入

复杂业务约束已经不再依赖 Rules 表达。

### 2. Callable Functions 的职责

当前大部分核心业务写入走 Callable Functions，例如：

- 创建 / 更新 / 删除帖子
- 创建 / 删除评论
- 关注 / 取消关注宠物
- 提交评价
- 提交签到
- 创建 / 编辑 / 取消 / 加入 Meetup
- 创建 / 兑换邀请码
- 创建 / 更新 / 删除宠物
- 创建地点 / 增加地点图片
- 举报 / 反馈
- 删除账户
- 生成 Cloudinary signed upload 签名

这套模式的核心价值是：

- 服务端从 `auth.uid` 推导身份
- 服务端做参数校验
- 服务端做事务和资格校验
- 客户端不再直接写关键业务文档

### 3. Trigger Functions 的职责

Trigger Functions 现在主要负责：

- 聚合计数维护
- 用户名称 / 头像反规范化同步
- 通知 fan-out
- 删除后清理关联数据
- 地点评分 / 标签 / 照片重算

---

## 五、当前数据模型

下面写的是“当前实现里最重要的字段”，不是把每个文档所有字段逐个抄出来。

### 1. User

公开 `users/{userId}` 文档当前主要承载：

- `displayName`
- `displayNameLower`
- `avatarUrl`
- `bio`
- `createdAt`
- `role`
- `banned`
- `followerCount`
- `followingCount`
- `followingPetsCount`
- `onboardingComplete`
- `pinnedPostId`
- `location.city`
- `location.state`

当前**不会再把精确 `lat/lng` 放在公开用户文档里**。  
精确位置已经迁到 owner-only 路径：

- `users/{userId}/settings/location`

### 2. Pet

`pets/{petId}` 当前主要包含：

- `ownerId`
- `primaryOwnerId`
- `name`
- `nameLower`
- `species`
- `breed`
- `birthday`
- `gender`
- `bio`
- `avatarUrl`
- `followerCount`
- `createdAt`

子集合：

- `family/{userId}`
- `followers/{userId}`
- `invitations/{inviteCode}`

### 3. Post

`posts/{postId}` 当前主要包含：

- `authorId`
- `authorName`
- `authorAvatar`
- `text`
- `media`
- `petId`
- `petName`
- `petAvatarUrl`
- `tags`
- `likeCount`
- `commentCount`
- `createdAt`

子集合：

- `likes/{userId}`
- `comments/{commentId}`

### 4. Location

`locations/{locationId}` 当前主要包含：

- `name`
- `category`
- `description`
- `address`
- `lat`
- `lng`
- `city`
- `state`
- `features`
- `photos`
- `locationPhotos`
- `averageRating`
- `totalRatings`
- `totalPhotos`
- `totalCheckins`
- `verifiedByCheckins`
- `tags`
- `addedBy`
- `addedByName`
- `source`

子集合：

- `reviews/{reviewId}`
- `checkins/{checkinId}`

### 5. Meetup

`meetups/{meetupId}` 当前主要包含：

- `organizerId`
- `organizerName`
- `organizerAvatar`
- `title`
- `description`
- `coverImage`
- `date`
- `duration`
- `location`
- `locationId`
- `locationVisibility`
- `requirements`
- `status`
- `participantCount`
- `isRatingOpen`
- `createdAt`
- `updatedAt`

私密地址已拆到：

- `meetups/{meetupId}/private/address`

子集合：

- `participants/{userId}`

### 6. Notification

`notifications/{notificationId}` 当前常见类型：

- `like`
- `comment`
- `pet_follow`
- `reply`
- `meetup_join`
- `meetup_cancelled`
- `warning`

通知文档由服务端生成，客户端不再直接创建。

---

## 六、当前安全模型

当前项目遵循 callable-first 模型，重点规则如下：

### 1. 客户端不再维护聚合字段

例如：

- `likeCount`
- `commentCount`
- `participantCount`
- `averageRating`
- `totalRatings`
- `totalCheckins`
- `hashtags.postCount`

这些字段由 Cloud Functions 维护。

### 2. 客户端不再决定公共身份快照

关键业务写入里的身份信息，现在尽量由后端从：

- `auth.uid`
- 当前 profile

派生，而不是信任前端自填。

### 3. 复杂业务约束尽量转到后端

例如：

- Meetup 加入资格
- Meetup 容量
- 邀请码兑换
- 签到
- 评价
- 删除账户

这些不再只靠前端和 Rules。

### 4. Cloudinary 已切换到 signed upload

上传流程现在是：

1. 前端调用 Firebase callable 拿签名
2. 后端校验登录和封禁状态
3. 浏览器带签名直传 Cloudinary

当前使用的 signed presets：

- `petnote_image_signed`
- `petnote_video_signed`

---

## 七、当前目录结构

```text
src/
  components/   UI 组件
  contexts/     Auth / Theme / Toast 等上下文
  hooks/        自定义 hooks
  pages/        路由页面
  services/     Firebase 与第三方服务封装
  types/        类型声明
  utils/        工具函数

functions/
  src/          Cloud Functions 源码

firestore.rules
README.md
TECH_REPORT.md
SECURITY_MODEL.md
QA_TESTING.md
```

---

## 八、当前部署方式

### 前端

- 由 Vercel 部署
- GitHub push 后可自动部署

### Firebase

- `firestore.rules` 通过 Firebase CLI 部署
- Cloud Functions 通过 Firebase CLI 部署
- Cloudinary 相关密钥通过 Firebase Functions Secrets 管理

---

## 九、当前状态总结

当前 PetNote 已经不再是“前端直接写库、靠 Rules 硬拦”的早期形态，而是一个：

- 关键写路径后端化
- 计数聚合后端化
- 私密位置与私密 Meetup 地址分离
- 通知服务端生成
- Cloudinary 改为 signed upload

的完整版本。

从工程角度看，当前版本已经达到可上线状态；后续更适合做的是性能优化、依赖升级和文档持续维护，而不是继续补同一类权限漏洞。

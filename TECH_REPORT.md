# PetNote 项目技术分析报告

---

## 一、技术栈

### 前端框架与语言
- **React** v19.2.0 + **TypeScript** v5.9.3（严格模式）
- **Vite** v7.2.4 作为构建工具
- **Tailwind CSS** v4.1.18 做样式
- **React Router** v7.13.0 做路由
- **Lucide React** v0.563.0 做图标库

### 后端与云服务
- **Firebase** v12.8.0 — Auth（邮箱密码 + Google OAuth）+ Firestore（NoSQL 数据库）
- **Cloudinary** — 图片/视频上传与 CDN 托管
- **Geoapify** — 地理编码与地址自动补全
- **DiceBear** — 默认头像生成
- **Browser Geolocation API** — 用户定位

### 部署
- **Vercel** 托管前端 SPA

### 其他
- **heic2any** — iOS HEIC 图片格式转换
- **ESLint** + TypeScript 插件做代码规范

---

## 二、数据结构（Firestore 集合）

| 数据模型 | 核心字段 | 子集合 |
|----------|---------|--------|
| **User** | displayName, email, avatar, bio, location, role(admin/user), banned, followerCount | bookmarks, followingPets, followers, blockedUsers, settings |
| **Pet** | name, species(8种), breed, birthday, gender, bio, avatar, followerCount, relationship | family, followers, invitations |
| **Post** | text, media(image/video), petId, tags(hashtags), likeCount, commentCount | likes, comments |
| **Comment** | text, authorId, replyTo(支持嵌套回复) | — |
| **Location** | name, address, lat/lng, category(9类), features(12种), averageRating, totalCheckins | reviews, checkins |
| **Meetup** | title, description, date, duration, location, requirements, status, participantCount | participants |
| **Notification** | type(7种), fromUser, message, read | — |
| **Report** | targetType(post/comment/user), reason, status | — |
| **Feedback** | type(bug/feature/complaint/other), subject, message, status | — |
| **Hashtag** | name, postCount, lastUsed | — |

### 详细数据模型

#### User (`UserProfile`)
```typescript
{
  id: string;
  displayName?: string;
  displayNameLower?: string;
  email?: string;
  avatarUrl?: string;
  bio?: string;
  createdAt?: Timestamp;
  followerCount?: number;
  followingCount?: number;
  followingPetsCount?: number;
  role?: "admin" | "user";
  banned?: boolean;
  onboardingComplete?: boolean;
  pinnedPostId?: string;
  location?: {
    lat: number;
    lng: number;
    city: string;
    state: string;
    updatedAt?: Timestamp;
  };
}
```

#### Pet
```typescript
{
  id: string;
  ownerId: string;
  primaryOwnerId?: string;
  name: string;
  species: "dog" | "cat" | "bird" | "rabbit" | "hamster" | "fish" | "reptile" | "other";
  breed?: string;
  birthday?: Timestamp;
  age?: string;
  gender: "male" | "female" | "unknown";
  bio: string;
  avatarUrl: string;
  followerCount?: number;
  createdAt?: Timestamp;
  relationship?: PetFamilyRelationship;
  customRelationship?: string;
  role?: "primary" | "member";
}
```

#### Pet Family (`FamilyMember`)
```typescript
{
  userId: string;
  userName: string;
  userAvatar: string;
  relationship: "mom" | "dad" | "brother" | "sister" | "grandma" | "grandpa" | "auntie" | "uncle" | "best_friend" | "caretaker" | "other";
  customRelationship?: string;
  role: "primary" | "member";
  joinedAt?: Timestamp;
}
```

#### Post
```typescript
{
  id: string;
  authorId: string;
  authorName: string;
  authorAvatar: string;
  text: string;
  media?: { url: string; type: "image" | "video"; thumbUrl?: string }[];
  petId?: string;
  petName?: string;
  petAvatarUrl?: string;
  createdAt: Timestamp;
  likeCount: number;
  commentCount: number;
  tags: string[];
}
```

#### Comment
```typescript
{
  id?: string;
  authorId: string;
  authorName: string;
  authorAvatar?: string;
  text: string;
  createdAt?: Timestamp;
  replyTo?: {
    commentId: string;
    authorName: string;
  };
}
```

#### Location
```typescript
{
  id: string;
  name: string;
  address: string;
  lat: number;
  lng: number;
  city: string;
  state: string;
  category: "dog_park" | "hiking_trail" | "beach" | "community_park" | "cafe" | "green_space" | "pet_store" | "vet" | "other";
  description: string;
  features: ("off_leash" | "fenced" | "water_access" | "waste_bags" | "parking" | "restrooms" | "seating" | "shade" | "lighting" | "beach_access" | "trails" | "food_nearby")[];
  photos: string[];
  addedBy: string;
  addedByName: string;
  averageRating: number;
  totalRatings: number;
  totalPhotos: number;
  totalCheckins?: number;
  verifiedByCheckins?: boolean;
  tags: string[];
  source: "user" | "meetup";
  verified: boolean;
  createdAt?: Timestamp;
  updatedAt?: Timestamp;
}
```

#### Meetup
```typescript
{
  id: string;
  organizerId: string;
  organizerName: string;
  organizerAvatar: string;
  title: string;
  description: string;
  coverImage?: string;
  date: Timestamp;
  duration: number;
  location: { name: string; address: string; lat: number; lng: number; city?: string; state?: string };
  locationId?: string;
  locationVisibility?: "everyone" | "participants_only";
  requirements: {
    dogSize: string;
    petType: string;
    maxPets: number;
    mustHavePosts: boolean;
    mustHavePetProfile: boolean;
    minFollowers: number;
    additionalNotes: string;
  };
  status: "upcoming" | "ongoing" | "completed" | "cancelled";
  participantCount: number;
  isRatingOpen?: boolean;
  createdAt?: Timestamp;
  updatedAt?: Timestamp;
}
```

#### Notification (`NotificationItem`)
```typescript
{
  id: string;
  userId: string;
  type: "like" | "comment" | "follow" | "pet_follow" | "reply" | "meetup_join" | "meetup_cancelled" | "warning";
  fromUserId: string;
  fromUserName: string;
  fromUserAvatar: string;
  postId?: string;
  commentId?: string;
  postImage?: string;
  message: string;
  warningReason?: string;
  warningDetails?: string;
  read: boolean;
  createdAt: Timestamp;
}
```

#### Report (`ReportItem`)
```typescript
{
  id: string;
  reporterId: string;
  reporterName: string;
  reporterAvatar?: string;
  targetType: "post" | "comment" | "user";
  targetId: string;
  reason: string;
  description?: string;
  status: "pending" | "reviewed" | "resolved";
  createdAt?: Timestamp;
  postId?: string;
}
```

#### Feedback
```typescript
{
  id: string;
  userId: string;
  userName: string;
  userEmail: string;
  type: "bug" | "feature" | "complaint" | "other";
  subject: string;
  message: string;
  status: "new" | "read" | "resolved";
  createdAt?: Timestamp;
}
```

---

## 三、功能模块

### 1. 认证系统
- 邮箱密码注册/登录、Google OAuth、邮箱验证、密码重置
- 自动生成随机用户名、新用户引导流程（Onboarding）
- 账户删除（级联清理所有关联数据）

### 2. 社交动态 Feed
- 帖子 CRUD，支持图片/视频轮播
- 点赞、评论（支持嵌套回复）、收藏、分享
- Hashtag 标签系统
- "全部" / "关注" 两种 Feed 模式
- 游标分页无限滚动、置顶帖子

### 3. 宠物档案
- 每用户最多 5 只宠物，8 种物种支持
- 宠物家庭系统（邀请码机制，48 小时过期，11 种关系类型）
- 宠物关注/粉丝系统、生日庆祝提醒

### 4. 宠物友好地点
- 9 种地点分类（狗公园、徒步、海滩、咖啡馆、宠物店、兽医等）
- 12 种设施特征标签
- 评分系统（含宠物友好度：空间/安全/清洁三维度）
- 签到系统（带照片验证，3 次签到自动认证地点）
- Geoapify 地址搜索与反向地理编码

### 5. 线下聚会 Meetups
- 创建聚会：设定地点、时间、时长、参与要求
- 参与要求：宠物体型、类型、最大数量、最低粉丝数等
- RSVP 管理、状态追踪（upcoming → ongoing → completed）
- 聚会评分系统

### 6. 搜索与发现
- 搜索用户、宠物、帖子、Hashtag
- 热门趋势帖子（7 天窗口）、热门标签
- 推荐宠物、热门地点、即将到来的聚会

### 7. 通知系统
- 7 种通知类型：点赞、评论、关注、宠物关注、回复、聚会加入、聚会取消、管理员警告
- 可配置通知偏好、已读/未读管理

### 8. 管理后台
- 举报审核（帖子/评论/用户）
- 用户封禁、发送警告
- 内容审核与删除
- 用户反馈管理

### 9. 其他
- 深色模式（系统检测 + 手动切换）
- 用户屏蔽系统
- 图片压缩上传、HEIC 格式支持
- 骨架屏加载、懒加载图片
- PWA 支持

---

## 四、架构概览

### 目录结构
```
src/
├── components/    # 45+ 可复用 UI 组件
├── contexts/      # ThemeContext, ToastContext（全局状态）
├── hooks/         # 12 个自定义 Hook（auth, posts, likes, notifications 等）
├── pages/         # 28 个路由页面
├── services/      # 21 个服务模块（Firebase + API 封装）
├── utils/         # 工具函数（图片压缩、时间格式化、密码校验等）
└── types/         # TypeScript 类型声明
```

### 状态管理
无 Redux/Zustand，采用 React Context + Custom Hooks + Firestore 实时监听的轻量方案。

### 数据流模式
- Firestore 实时监听（auth/profile/notifications）
- 游标分页（cursor-based pagination）
- 批量状态查询（batch like/bookmark status）
- Firestore 事务操作（关注/点赞/RSVP）

### 路由守卫
- `RequireAuth` 组件保护需登录页面
- `RequireAdmin` 保护管理后台

### Firestore 数据库结构
```
firestore/
├── users/{userId}
│   ├── bookmarks/{postId}
│   ├── followingPets/{petId}
│   ├── followers/{userId}
│   ├── blockedUsers/{userId}
│   └── settings/preferences
├── posts/{postId}
│   ├── likes/{userId}
│   └── comments/{commentId}
├── pets/{petId}
│   ├── family/{userId}
│   ├── followers/{userId}
│   └── invitations/{code}
├── notifications/{notificationId}
├── meetups/{meetupId}
│   └── participants/{userId}
├── locations/{locationId}
│   ├── reviews/{reviewId}
│   └── checkins/{checkinId}
├── hashtags/{tagName}
├── reports/{reportId}
└── feedback/{feedbackId}
```

### 路由架构（React Router v7）
- **认证页面**: `/login`, `/signup`, `/forgot-password`
- **主要页面**: `/`(Feed), `/search`, `/places`, `/meetups`
- **详情页面**: `/post/:postId`, `/pet/:petId`, `/profile/:userId`, `/meetups/:meetupId`, `/location/:locationId`
- **用户页面**: `/profile`, `/edit-profile`, `/settings`, `/notifications`, `/contact`, `/blocked-users`
- **创建页面**: `/create`, `/add-pet`, `/add-place`, `/create-meetup`
- **编辑页面**: `/edit-pet/:petId`, `/edit-post/:postId`, `/edit-meetup/:meetupId`
- **管理后台**: `/admin`（RequireAdmin 守卫）
- **法律页面**: `/terms`, `/privacy`

### 性能优化
- 游标分页无限滚动
- 批量状态检查减少 Firestore 读取
- 用户资料缓存（useUserCache）
- 懒加载图片（LazyImage）
- 上传前客户端图片压缩
- Firestore 实时监听（高效）
- 乐观 UI 更新（点赞/评论）

### 外部服务集成

| 服务 | 用途 | 集成方式 |
|------|------|---------|
| **Firebase Auth** | 用户认证 | SDK v12.8.0 |
| **Firestore** | NoSQL 数据库 | SDK v12.8.0 |
| **Cloudinary** | 图片/视频上传 | REST API |
| **Geoapify** | 地理编码与地址补全 | REST API |
| **DiceBear** | 头像生成 | REST API |
| **Browser Geolocation** | 用户定位 | Web API |

---

## 总结

PetNote 是一个功能完整的**宠物社交平台**，涵盖社交动态、宠物档案管理、宠物友好地点发现、线下聚会组织、搜索发现、通知系统和管理后台。技术上采用 React + TypeScript + Firebase 的全栈方案，Cloudinary 处理媒体，Vercel 部署。

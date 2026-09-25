# CareHive — App Privacy 答案表（App Store Connect 专用）

**为什么这份文件存在**：App Privacy 是**唯一无法用 API 完成**的上架步骤之一。
`GET /v1/apps/{id}/appPrivacyDetails` 返回 **404**，没有任何写入端点。只能用网页填。
它是法律声明，不能靠猜，所以下面每一条都标注了它在代码里的取证位置。

**本文件不是代码，不参与构建。** 放在仓库里是因为它记录的正是代码所决定的事实。

---

## 填写位置

App Store Connect → CareHive → **App Privacy** → *Data Types* → **Edit**

先回答顶部第一个问题：

> **Do you or your third-party partners collect data from this app?**

→ **Yes**

（答 No 是错的。app 会把用药记录发到自有服务器，这就是 collect。）

---

## 逐项答案

下表是**要勾选的全部**。没列出的类别一律**不勾**。

| 类别 (Category) | 数据项 (Data Type) | Linked to You | Used for Tracking | Purposes |
|---|---|---|---|---|
| Contact Info | **Name** | Yes | No | App Functionality |
| Contact Info | **Email Address** | Yes | No | App Functionality |
| Health & Fitness | **Health** | Yes | No | App Functionality |
| User Content | **Photos or Videos** | Yes | No | App Functionality |
| User Content | **Other User Content** | Yes | No | App Functionality |
| Identifiers | **User ID** | Yes | No | App Functionality |
| Purchases | **Purchase History** | Yes | No | App Functionality |

每个勾选项里的 **Purposes** 只勾 `App Functionality`。**不要**勾
Analytics / Advertising / Product Personalization / App Functionality 以外的任何一项。

---

## 每条为什么这么答（取证）

### Contact Info → Name
Apple 首次登录时给一次 `fullName`，之后再也不给。
写入点：`routers/auth.py` 的 `INSERT INTO users (id, apple_sub, email, email_verified,
display_name, ...)`；字段定义在 `migrations/001_init.sql:34` (`display_name TEXT`)。
用户在 app 内可改。→ 属于收集，且与账号绑定。

### Contact Info → Email Address
`routers/auth.py:493` `email = claims.get("email")`，存进 `users.email`
(`migrations/001_init.sql:31`)。多数用户拿到的是 Apple 的 **private relay 地址**。
**可选** —— 用户在 Apple 弹窗里可以选 "Hide My Email"，app 无邮箱照样能用。
声明里 Linked = **Yes**（因为它挂在账号上，即使是个 relay 地址）。

### Health & Fitness → Health
这是本 app 的核心数据，**必须声明**，漏掉是 5.1.1 级别的拒审。
来源：`medications`、`medication_phases`、`medication_slots`、`dose_events`、
`dose_administrations`、`prn_administrations`、`medication_supply`
（`migrations/001_init.sql:149-330`、`002_*.sql:85`）。
包含药名、剂量、服用时间、实际服用记录、漏服、按需用药及原因。

> **注意 Health 不等同于 HealthKit。** 政策 `legal/privacy.html:112-113` 已明确
> 本 app 不读写 HealthKit。App Privacy 里的 "Health" 指的是**你收集的健康数据**，
> 不是 HealthKit 权限。这两件事必须分开理解 —— 不读 HealthKit **也要**声明 Health。

### User Content → Photos or Videos
Journal 照片。`journal_photos` 表（`migrations/002_*.sql:58`），
字节存 R2、库里只存 key。**即使线上 R2 凭据尚未配置，能力已经声明、代码路径已经存在，
就必须声明** —— 声明描述的是 app 能做什么，不是你的服务器今天配没配好。

### User Content → Other User Content
Journal 正文与 mood。`journal_entries.body` / `.mood`（`migrations/002_*.sql:27-56`）。
注释里写明了 mood 是自由文本而不是枚举 —— 家属会写进健康状况，所以归 Other User Content。

### Identifiers → User ID
`users.apple_sub`（`migrations/001_init.sql:30`），Apple 给的账号标识符。
它就是我们识别"你是谁"的 ID。

### Purchases → Purchase History
订阅状态。`entitlements` / `entitlement_events`
（`migrations/001_init.sql:358-380`），从 Apple 校验的结果落库。
政策 `legal/privacy.html:93-99` 已写明：我们知道计划与到期日，**看不到卡号与账单信息**。

---

## 两个判断项（需要你自己拍板）

这两条我**没有**替你决定，因为它们取决于你对"声明口径"的取舍，而声明是你签的字。

### 1. Identifiers → Device ID（推送 token）

`devices.token`（`migrations/001_init.sql:62`）存的是 APNs 推送 token。

- **不勾（我倾向这个）**：APNs token 是 app 作用域的，不跨 app，不用来识别设备或追踪。
  Apple 对 "Device ID" 的典型口径是 IDFA / IDFV 这类设备级标识符。业界普遍不声明它。
- **勾上**：更保守。**多声明不会被拒，少声明才会。**

如果你不放心，勾上它，Purposes 同样只勾 App Functionality、Tracking 选 No。
代价只是列表多一行，没有别的后果。

### 2. 被照护者的出生日期

`care_recipients.date_of_birth`（`routers/recipients.py:119`）。
这是**关于被照护的人**，不是关于用户本人。政策 `legal/privacy.html:176-180`
已经用同样的口径解释过（第 9 节 Children）。

我的建议：**不单独声明**。App Privacy 的数据类型是按"用户"组织的，
被照护者不是本 app 的用户，且这条已经落在 `Health` 的语义范围内。
政策里的那句说明已经足够回答审核员可能的追问。

---

## 填完之后

App Privacy 页面上应该出现：

- **Data Used to Track You** — 空
- **Data Linked to You** — 7 项
- **Data Not Linked to You** — 空

**Tracking 全选 No 有一个硬前提**：app 里不能有任何第三方分析／广告 SDK。
这一点已经实测确认过 —— CareHive 链接的全部框架是：

```
AuthenticationServices, CommonCrypto, Foundation, StoreKit, SwiftUI
```

没有任何分析、广告、崩溃上报 SDK。**这也是本 app 不需要 ATT
(App Tracking Transparency) 弹窗、Info.plist 里没有 `NSUserTrackingUsageDescription`
的原因，两者必须一致。** 如果哪天加了分析 SDK，这一页和 ATT 都要一起改。

---

## 另一件同样只能在网页做的事：Content Rights

App Store Connect → CareHive → App Store 标签页 → **Content Rights**

> **Does your app contain, show, or access third-party content?**

→ **No**

理由：app 里的全部内容都是用户自己在家庭圈子里输入的。没有授权音乐、
没有影视、没有新闻源、没有第三方品牌素材、没有抓取来的内容。
图标、界面文字、演示数据（`DemoAPI`）全部自制。

（API 侧已实测确认这条**不可写**：`PATCH /v1/appInfos/{id}` 与
`PATCH /v1/appStoreVersions/{id}` 带 `contentRightsDeclaration` 均返回
**409 ENTITY_ERROR.ATTRIBUTE.UNKNOWN**。只能网页填。）

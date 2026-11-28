# 跑满了吗 iOS 版（v1.0.0）

原生 SwiftUI 打造的 iOS 双向测速与 Wi-Fi 信息工具（支持 **iOS 15.0+**，快捷指令 Wi-Fi 底层参数同步推荐 **iOS 17.0+**）。

## 快速下载

- **最新未签名安装包（`PaoManLeMa.ipa`）**：前往 [GitHub Releases 最新版本](https://github.com/usnskkd/paomanlema_ipa/releases/latest) 直接下载 `PaoManLeMa.ipa`（每次代码更新后由 GitHub Actions 自动编译并刷新）。
- **配套快捷指令（`跑满了吗WiFi`）**：在 iPhone 上直接点击一键导入 👉 [https://www.icloud.com/shortcuts/bdb3f7b290b0414297bc042e921e9c7a](https://www.icloud.com/shortcuts/bdb3f7b290b0414297bc042e921e9c7a)

---

## 核心功能

### 1. 测速页（第一个界面）
- **同时上传与下载（双向并发）**：点击底部 **`双向`** 同时开启多连接下载与上传（下载、上传独立 `URLSession` 连接池，互不阻塞），也可单独点击 **`下载`** / **`上传`** 启停。
- **实时速率曲线**：下载（蓝）与上传（紫灰）独立实时滚动曲线、红色平均参考线、平均/实时/最终速率及总流量统计。
- **内置国内多节点 + 兼容 Android `.conf` 配置**：
  - 默认内置国内高速多节点配置（64 下载节点 + 119 上传节点）以及 Cloudflare 全球双向方案。
  - 点击左上角 **`v1.0.0`** 可切换方案、调整并发线程数、手动编辑 URL，或导入任意 `PAOMAN_SPEED_TEST_CONFIG` 格式的 `.conf` 文件（也支持在微信/“文件” App 中点击 `.conf` 选择用「跑满了吗」打开）。
  - 点击右上角 **`总流量`** 卡片可一键清零流量与曲线记录。

### 2. Wi-Fi 信息页（第二个界面）
- 原生实时读取并展示：**`已连接 Wi-Fi`**、**`安全性`**、**`路由器 MAC (BSSID)`**、**`IPv4 地址`**、**`全部 IPv6 地址`**（点击任意地址行可一键复制）。
- 联动 Apple 官方「快捷指令」`x-callback-url` 回调，一键同步完整 iOS 系统级 Wi-Fi 射频参数：**`技术标准（如 Wi-Fi 6 / 802.11ax）`**、**`信号强度（RSSI dBm）`**、**`连接速度（RX / TX Mbps）`**、**`频段与信道（2.4G / 5G / 6G）`**、**`硬件 MAC 地址`**。

---

## 完整使用步骤

### 第一步：自签安装 `PaoManLeMa.ipa`
1. 打开本仓库 [Releases 页面](https://github.com/usnskkd/paomanlema_ipa/releases/latest) 下载最新的 **`PaoManLeMa.ipa`**。
2. 使用你常用的自签工具（如爱思助手、iloader、AltStore、SideStore、Sideloadly、企业签或巨魔 TrollStore 等）签名并安装到 iPhone。
   > 提示：若使用带 `Access WiFi Information` 权限的签名证书或巨魔，并在首次打开时允许定位权限，App 可直接原生读取当前 Wi-Fi 名称、加密类型与路由器 BSSID。

### 第二步：一键导入配套快捷指令（用于获取完整 Wi-Fi 参数）
1. 在 iPhone Safari 中打开快捷指令分享链接：  
   https://www.icloud.com/shortcuts/bdb3f7b290b0414297bc042e921e9c7a
2. 点击 **「添加快捷指令」**，确认快捷指令名称为 **`跑满了吗WiFi`**（无需任何修改）。
   > 也可以在 App 的 **Wi-Fi** 页面点右上角 **`?`** 按钮，直接点击「一键安装配套快捷指令（iCloud）」或修改对应的快捷指令名称。

### 第三步：开始使用
- **双向跑满带宽**：在底部 **`测速`** 页直接点 **`双向`** 即可同时高并发上传 + 下载；想换节点或导入新 `.conf` 文件，点左上角 **`v1.0.0`** 即可。
- **查看完整 Wi-Fi 信息**：切换到下方 **`Wi-Fi`** 页，点右上角 **`同步`** 按钮，首次运行时在系统弹窗点「始终允许」，之后点一下不到 1 秒即可自动跳回并显示全部 9 项真实 Wi-Fi 参数。

---

## 开发者本地构建（可选）
本仓库已配置 [.github/workflows/build-ipa.yml](.github/workflows/build-ipa.yml)，推送代码到 `main` 分支即自动云端编译并更新 Release 中的 `PaoManLeMa.ipa`。如需在已安装 Xcode 的 Mac 上本地打包：
```bash
chmod +x build_ipa.sh
./build_ipa.sh
```

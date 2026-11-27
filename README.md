# 跑满了吗 iOS 版（单界面双向测速）

按照截图还原的单界面原生 SwiftUI iOS 应用（支持 **iOS 15.0+**），支持：
- **同时上传与下载（双向并发）**：独立 `URLSession` 多连接池，上传与下载互不阻塞
- **单独下载 / 单独上传 / 双向一键启停**
- **实时速率曲线 + 红色平均线 + 实时总流量 / 下载流量 / 上传流量统计**
- **点击左上角 `V4.3.2`** 可自定义下载/上传测速 URL、线程数及单次上传块大小（默认内置 Cloudflare 全球双向测速接口）
- **点击右上角 `总流量` 卡片** 可一键清零统计与曲线

## 如何生成未签名 `.ipa`（供自签 / 爱思助手 / iloader / TrollStore 安装）

### 方式一：GitHub Actions 云端免费编译（无需本机安装 Xcode，推荐）
1. 在 GitHub 新建一个仓库（公开或私有均可）。
2. 将本目录 `PaoManLeMaIOS/` 内的全部文件（含隐藏目录 `.github/workflows/build-ipa.yml`）推送到该仓库的 `main` 分支。
3. 打开 GitHub 仓库的 **Actions** 页面，等待约 1~2 分钟构建完成。
4. 点击构建记录底部的 **Artifacts -> `PaoManLeMa-iOS-IPA`** 下载解压，即可拿到 `PaoManLeMa.ipa` 进行自签安装。

### 方式二：本机安装 Xcode 后一键打包
```bash
chmod +x build_ipa.sh
./build_ipa.sh
```
构建完成后会在当前目录生成 `PaoManLeMa.ipa`。

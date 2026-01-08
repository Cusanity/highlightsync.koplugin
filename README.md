# 📚 Highlight Sync 插件 - KOReader

跨设备同步 KOReader 的划线、笔记和书签。

> Fork 自 [koreader-Highlight-Sync](https://github.com/gitalexcampos/koreader-Highlight-Sync)，增加了中文本地化支持, [修复了多设备同步时的重复标注问题](https://github.com/gitalexcampos/koreader-Highlight-Sync/pull/20)。

![Platform](https://img.shields.io/badge/平台-KOReader-green.svg)
![License](https://img.shields.io/badge/许可-MIT-yellow.svg)

---

## 功能

- 🔄 **手动同步**：划线、笔记、书签
- 📝 **智能合并**：离线在多设备做的标注会自动合并
- ☁️ **云存储**：支持 WebDAV 和 Dropbox
- 📅 **时间戳**：基于最新更新时间决定保留哪个版本
- 🌐 **中文支持**：完整的简体/繁体中文界面

---

## 安装

1. 从 [GitHub](https://github.com/Cusanity/highlightsync.koplugin) 下载插件
2. 解压后找到 `highlightsync.koplugin` 文件夹
3. 将该文件夹复制到 KOReader 设备的 `koreader/plugins/` 目录

---

## 使用方法

1. 打开 KOReader
2. **主菜单 → 工具 → Highlight Sync → Sync Cloud**
3. 配置云服务（WebDAV 或 Dropbox）
4. 选择存储 JSON 文件的文件夹
5. 选择 **同步** 同步标注

⚠️ **注意**：如果更改同步文件夹，需要手动移动已有的 JSON 文件到新位置。

---

## 已测试环境 (KOReader 2025.10)

- Linux
- Kindle Scribe
- Android 16
---

## 已知限制

- 书籍文件名必须在各设备上**完全相同**
- 若两个划线起始位置相同但结束位置不同，保留最新的那个
- Beta 阶段，请定期备份标注数据

---

## 贡献

欢迎 PR 和 Issue！

---

## 许可

MIT License

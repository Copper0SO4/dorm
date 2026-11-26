# Dorm 项目交接文档 (agents.md)

## 1. 项目概览

- **应用名称**：Dorm（全称：`Dorm Organizes Roomates' Matters`，包名：`dormos`，当前版本：`0.18.14+41`）
- **定位**：离线优先的寝室协作应用，支持可选的 GitHub Git/SSH 云同步、局域网网页工作台以及原生/网页斗地主牌桌。
- **技术栈**：
  - Flutter（`>=3.50.0`）/ Dart（`>=3.14.0 <4.0.0`）
  - 本地存储：`sqlite3`
  - Git 同步与加密：`git2dart`、`cryptography`、`crypto`
  - 桌面与移动端能力：`file_selector`、`path_provider`、`url_launcher`、`zxing2`、`mobile_scanner`（Android 扫码）
- **平台支持**：Windows、Android、Linux（`linux/` runner 已从历史提交 `68b33c5^` 恢复）。更多历史演进见 [docs/development.md](docs/development.md)。

---

## 2. 目录结构

- `lib/main.dart`：应用入口（`DormBootstrap`、`_openDorm`），负责打开本地数据库与初始化 `CloudSync`。
- `lib/app_identity.dart`：应用名称常量（`dormName`、`dormFullName`）。
- `lib/domain/`：纯 Dart 领域模型与业务计算（整数分账本 `ledger.dart`、批量结算 `settlement.dart`、事务 `matters.dart`、卫生排班 `schedule.dart`、采购 `procurement.dart`、消费 `spending.dart`、抽签/分组/骰子 `draw.dart` / `party_tools.dart`、云同步协议 `cloud.dart`、设备身份 `identity.dart` 等）。
- `lib/data/`：SQLite 仓储与传输层（`sqlite_repository.dart`、`sqlite_cloud.dart`、`sqlite_identity.dart`、`data_location.dart`、`local_directory.dart`、`cloud_sync.dart`、`github_transport.dart`、`ssh_vault.dart`、`cloud_proxy.dart`、`dorm_invite.dart`、`invite_qr.dart`、`qr_image.dart`、`lan_server.dart`、`lan_api.dart`）。
- `lib/game/`：斗地主规则、房间状态、AI 机器人、局域网与 Git 在线联机逻辑。
- `lib/ui/`：Flutter 页面与组件（`app.dart`、各业务页面、`card_table.dart`、`camera_qr.dart`、`save_document.dart`、`tools/` 等）。
- `assets/`：内置字体 `NotoSansSC.ttf`、局域网工作台前端资源 `assets/lan/`、牌桌音效 `assets/cards_audio/`。
- `test/`：单元测试与 Widget 测试。
- `linux/`、`windows/`、`android/`：各平台原生 Runner。

---

## 3. 平台差异与实现细节

- **数据目录（`lib/data/local_directory.dart`）**：
  - 支持通过环境变量 `DORM_DATA_DIR` 指定独立数据目录（适合测试隔离，Windows 与 Linux 均生效）。
  - 默认路径：Windows 为 `%APPDATA%\org.dormos\dormos\dormos`；Linux 为 `getApplicationSupportDirectory()/dormos`（通常为 `~/.local/share/org.dormos.dormos/dormos`）。
  - 数据目录迁移向导（`DormDataLocation.open`）目前仅在 `Platform.isWindows` 启用。
- **SSH 凭据权限（`lib/data/ssh_vault.dart`）**：
  - Windows 使用 `icacls.exe` 限制目录 ACL；Linux 等非移动平台使用 `chmod 700`（目录）和 `chmod 600`（文件）。
- **原生 MethodChannel**：
  - `dorm/cards/audio`：Windows 通过 `PlaySoundW` 播放 WAV 音效；Linux/Android 回退至 `SystemSound.play(SystemSoundType.click)`。
  - `dorm/cards/window`：Windows 与 Linux 均支持 F11 牌桌全屏切换；Android 用于进出牌桌横屏切换。
  - `org.dormos.dormos/documents`：仅 Android 使用原生保存通道；Windows 与 Linux 直接通过 `file_selector` 保存文件。
- **二维码导入与扫码**：
  - 摄像头扫码（`mobile_scanner`）仅在 `Platform.isAndroid` 显示入口；Linux 与 Windows 通过 `file_selector` 选择二维码图片或粘贴文本导入。
- **牌桌手牌间距（`lib/ui/card_table.dart`）**：
  - `TargetPlatform.windows` 与 `TargetPlatform.linux` 均启用桌面端紧凑手牌间距（`tightSpacing`）。

---

## 4. 常用开发与验证命令

```bash
# 获取依赖并生成平台插件配置
flutter pub get

# 静态分析
flutter analyze

# 运行全部测试
flutter test --reporter expanded

# Linux 桌面端调试运行（建议使用独立数据目录）
DORM_DATA_DIR=/tmp/dorm-test flutter run -d linux

# Linux Release 构建
flutter build linux --release --target-platform linux-x64
```

---

## 5. 当前交接状态

- 已恢复 `linux/` 桌面端 Runner（来自历史提交 `68b33c5^`）。
- 已更新 [lib/data/local_directory.dart](lib/data/local_directory.dart)（使 `DORM_DATA_DIR` 在 Linux 等平台同样生效）和 [lib/ui/card_table.dart](lib/ui/card_table.dart)（为 `TargetPlatform.linux` 启用桌面紧凑手牌间距）。
- 已在主机（Fedora Linux 45）安装 Flutter 3.50.1 / Dart 3.14.0 至 `~/.local/share/flutter`，并在 `~/.zshrc` 配置国内镜像与 `PATH`。
- 已完成验证：`flutter analyze` 无问题；`flutter test` 161 项通过（1 项仅限 Windows 的测试跳过）；`flutter build linux --release --target-platform linux-x64` 成功生成 `build/linux/x64/release/bundle/dormos`。

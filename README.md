# Dorm

**Dorm Organizes Roomates' Matters**

Dorm 是寝室公用账本、卫生排班和物资清单。首次打开应用时，账本和清单均为空。添加实际寝室成员后即可开始使用。数据保存在本机 SQLite，支持离线操作和可选的 GitHub 云同步。

## 从源码运行 Linux 版

在 x86_64 Debian 13 或兼容的 Linux 环境使用 Linux Flutter Stable。项目在 WSL2 Debian 13 上以 Flutter 3.50.0 和 Dart 3.14.0 为基线。开发时需要 Clang、CMake、Ninja、pkg-config 和 GTK 3 开发头文件。SDK 和其自带的 Dart 可以放在 `~/.local/opt/flutter`。以下操作在 Linux 原生文件系统中的仓库目录执行。

```bash
export PATH="$HOME/.local/opt/flutter/bin:$PATH"
flutter doctor -v
flutter pub get --enforce-lockfile
flutter run -d linux
```

## 使用方式

| 模块 | 操作 |
| --- | --- |
| 公共账本 | 打开「寝室成员」添加成员，再新建账单。填写公共费用和付款人，按需调整均摊成员。点「添加个人费用」给指定成员记一笔由本人承担的费用。账单详情可登记一笔或多笔实际转账，成员汇总显示累计应收、应付及未结清余额。 |
| 卫生排班 | 在「任务设置」添加每日或每周任务，选择开始日期。点击日历查看某日或整月，过去的月份可查看历史。待完成班次可改派或与同任务的其他待完成班次交换。 |
| 公共物资 | 录入名称、分类、数量、位置、备注和采购状态，按关键词、分类或状态查找。点击「记录采购」将支出记入总账，点击「采购账单」回看关联开销。 |
| 寝室事务 | 在看板上指派负责人、设截止日期、标记优先事项并跟进进度。完成事项可归档，也可从归档中恢复。 |

例如丙垫付 30 元公共餐费，三人均摊，另外替甲付了 8 元饮料。账单总额为 38 元，甲转给丙 18 元，乙转给丙 10 元。纯个人代付时可将公共费用留空。个人费用明细会随账单同步，使用同一个 GitHub 仓库的设备需要升级至 v0.5.0 才能读取含个人费用的快照。

宽屏显示侧边导航和账单表格，窄屏显示底部导航和卡片。点击右上角齿轮打开「设置」。宽屏在左侧选分类，窄屏点分类进入详情。「外观」中的主题选择会保存在本机。成员和卫生任务归在「寝室管理」，GitHub、SSH 密钥、代理和邀请归在「云同步」。

### 结算中心与事务看板

「公共账本 → 结算中心」按付款方向列出待付账单。选择账单并登记本次实际转账金额，Dorm 会从最早的账单开始核销。支持部分金额，在「结算记录」可展开查看分摊到每张账单的金额。登记只更新账本，不会发起支付。

「寝室事务」适合记录报修、活动准备等共同事项。支持负责人、截止日期、优先处理、完成时间与归档。桌面宽屏并排列出三个状态，窄屏可在状态之间切换。

### 月度预算与公共采购

「公共账本 → 月度分析」汇总每月的公共支出、个人代付、当前待结清金额和付款人垫付情况，展示近六个月趋势。「设置 → 账本偏好」可设本机的月度公共预算。预算按本月公共支出计算。

「公共物资 → 采购清单」汇总手动待采购、低库存和采购中的物资。可复制清单、标记采购中、记录采购账单，或在到货后增加库存。「设置 → 物资偏好」可调整低库存阈值或关闭低库存提醒。

启动页面、账本筛选、新账单均摊默认项和事务视图均可在「设置」调整。这些偏好保存在本机，应用在相应页面下次打开时使用新的默认选项。

### 账单查找、导出与备份

「账单历史」可按账单名称、付款人或关联物资搜索，也可筛选本月或待结清账单。「导出当前结果」生成 CSV，在「设置 → 本机数据」也可以导出全部账单。账单详情提供「复制待付清单」，方便转发当前余额。

「设置 → 本机数据 → 创建本地备份」生成 .dormbak 文件，其中保存成员、账单、转账、排班及物资。寝室事务与批量结算历史也会包含在备份中。备份采用 SQLite 格式，排除云同步配置与本机凭据。应用内提供导出，恢复可在应用完全退出后先另存现有数据库，再将备份复制到原位置并命名为 dormos.sqlite3。

## GitHub 云同步

1. 创建私有 GitHub 仓库。在 Dorm 右上角打开「设置」，找到「GitHub 云同步」，点击「生成 SSH 密钥」，再点击「复制公钥」。
2. 在仓库的 Settings → Deploy keys 添加这段公钥，勾选 Allow write access。不同设备各自生成密钥，都可以连接同一个仓库。 [GitHub Deploy keys](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys)
3. 回到 Dorm，点击「配置仓库」，输入仓库地址与操作者名称，保留「使用设备 SSH 密钥」，然后保存。仓库的 HTTPS 地址会转换为 SSH 地址，操作者和可选邮箱会保留并用于 Git 提交。已有 OpenSSH 私钥仍可通过「粘贴 SSH 私钥」导入，若私钥已加密，请填写口令。

Dorm 随应用提供 Git 和 SSH 运行库，生成密钥及同步均可直接在应用中完成。生成的 Ed25519 私钥存放在本机受操作系统权限保护的应用目录。界面以星号遮挡公钥中段。「复制公钥」可将完整公钥复制到剪贴板。断开仓库后仍可继续使用该设备密钥。

### 代理设置

在「GitHub 云同步」点击「代理设置」，启用后选择 HTTP CONNECT 或 SOCKS5，再填写本机或网络代理的主机、端口。代理要求认证时，填写用户名和密码。云同步通过代理连接 `ssh.github.com:443`，拉取和推送继续核验 GitHub SSH 主机指纹。代理配置保存在本机受权限保护的应用目录，不随快照或 `.dorm` 分享。关闭代理后恢复直连。

### 分享 .dorm 邀请

仓库配置完成后，在「GitHub 云同步」点击「导出 .dorm」。默认导出仓库地址，接收者可使用自己的 SSH 密钥。如果需要共享已授权的私钥，勾选「用口令加密后共享当前 SSH 私钥」，输入独立的邀请口令。文件与口令应通过不同渠道发送。能解锁该文件的成员会获得这把密钥对应的 GitHub 权限。

接收者在同一页面点击「导入 .dorm」，选择文件并按提示输入邀请口令，再核对仓库地址、填写自己的操作者名称并保存。邀请不包含寝室业务数据或发送者身份。当前 Dorm 只有一套本机寝室数据，切换同步仓库前请核对目标。

### 同步行为

应用在启动时优先同步，本地写入后短延迟同步，运行时每 30 秒检查云端更新。启动等待最多 8 秒，网络慢时仍可进入本机界面，连接完成后继续同步。数据只写入专用的 `dormos-data` 分支，其中的 `dormos.json` 保存业务快照。连接采用 GitHub 的 SSH 443 入口并核对官方主机指纹。 [GitHub SSH 443](https://docs.github.com/en/authentication/troubleshooting-ssh/using-ssh-over-the-https-port) · [主机指纹](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints)

含寝室事务或批量结算的快照需要同步设备升级至 v0.10.0。没有使用这两个模块的快照仍保持原有版本。

本机和云端基于上次同步的快照自动合并独立改动。同一条记录的不同改动会在「解决同步冲突」里并列显示，可逐条保留本机或云端版本。首次连接已有两份不同数据时可选一份完整版本。合并会核对账单总额、转账余额和记录关联。

私钥与口令文件保存在应用数据目录的 `cloud-credentials` 下，依赖操作系统的当前用户目录权限或移动设备应用沙盒保护。该目录不进入 Git 分支、同步快照或 Android 系统备份。断开连接会移除此仓库在本机保存的私钥。可复制关闭应用后的 SQLite 文件备份本机数据。

## 局域网工作台

在宿舍电脑打开「设置 → 局域网服务器」，确认端口后点击「启动服务器」。把设置中显示的局域网链接和访问码发给同一网络上的室友。手机和电脑都可以用浏览器打开链接。Dorm 在所有 IPv4 接口监听，室友应使用设置显示的实际 IP 地址。

网页和桌面端共用数据库。室友可以新建含个人费用的账单、登记转账、生成排班和打卡、维护物资和采购，以及更新或归档事务。重置访问码会让已连接的浏览器重新验证。退出 Dorm 或点击「停止服务器」会结束服务，下次打开 Dorm 时需要手动启动。

连接使用 HTTP，请在信任的局域网内使用。若 Windows 防火墙提示是否允许，选择专用网络。同一 Wi-Fi 上的访客隔离也可能阻止设备互访。

## 测试和构建

```bash
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test --reporter expanded
flutter build linux --release --target-platform linux-x64
./build/linux/x64/release/bundle/dormos
```

Linux 分发需要整个 `build/linux/x64/release/bundle`。解包后从图形会话运行 `dormos`。WSL2 中需要能显示 Linux 窗口的 WSLg。可用 `ldd build/linux/x64/release/bundle/dormos` 排查目标机器缺失的共享库。应用更新时保留用户数据目录。

### Windows x86_64 构建

从同一个 Git 提交克隆到独立的 Windows 原生工作目录，使用对应版本的 Windows Flutter。Visual Studio 需要「使用 C++ 的桌面开发」工作负载及 MSVC x64、Windows SDK 和 CMake 工具。用 Windows 端的 `flutter doctor -v` 检查 Visual Studio。可以从 WSL 启动 `powershell.exe -NoProfile`。在 Windows PowerShell 中，将 `$bundle` 指向交付的 `Dorm-source.bundle`，并指定新的 Windows 工作目录和 SDK 路径。

```powershell
git clone --branch main $bundle $windowsWorktree
Set-Location -LiteralPath $windowsWorktree
git rev-parse HEAD
& $windowsFlutter doctor -v
& $windowsFlutter pub get --enforce-lockfile
& $windowsFlutter build windows --release
& '.\build\windows\x64\runner\Release\Dorm.exe'
```

在 x86_64 Windows 主机使用 x64 Flutter。Flutter 3.50 按 Windows 宿主架构选择构建目标。归档整个 `build\windows\x64\runner\Release`，其中包含程序、Flutter 引擎、插件 DLL 和数据文件。

### Android ARM64 构建

在 Debian 的同一 Git 提交使用 Linux Flutter、OpenJDK 21 和 Linux 版 [Android SDK Command-line Tools](https://developer.android.com/studio#command-tools)。JDK 负责运行 Gradle 与编译 Java，Android SDK 提供 API 36 的编译库及 APK 工具。可以请设备维护人运行 `sudo apt install openjdk-21-jdk-headless`，再将命令行工具解压至 `~/.local/opt/android-sdk/cmdline-tools/latest`。`bin/sdkmanager` 应直接位于该目录下。以下环境变量只用于当前终端。

```bash
export JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
export ANDROID_HOME="$HOME/.local/opt/android-sdk"
export GRADLE_USER_HOME="$HOME/.cache/dormos-gradle"
"$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$ANDROID_HOME" --licenses
"$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$ANDROID_HOME" \
  "platform-tools" "platforms;android-35" "platforms;android-36" \
  "build-tools;36.0.0" "ndk;28.2.13676358"
```

Flutter 3.50 的 Android runner 使用 Gradle 9.5.0 和 API 36，最低设备版本为 API 24。锁定的 Android 路径插件通过 `jni` 依赖使用 API 35 和 CMake 编译 JNI，因此需要该版本的 NDK。Debian 13 的现有 CMake 和 Ninja 用于本机构建，若 Gradle 另有诊断，按诊断补齐对应组件。

```bash
flutter doctor -v
flutter pub get --enforce-lockfile
flutter build apk --release --target-platform android-arm64
unzip -Z1 build/app/outputs/flutter-apk/app-release.apk | grep '^lib/'
```

所有 `lib/` 下的 ABI 应为 `arm64-v8a`。Debug 构建面向调试，Release 构建采用发布优化，正式发布还需要专用签名或由 Google Play 管理应用签名。用开发签名签出的 Release APK 可用于内部安装验证。签名配置和密钥须保存在仓库外。构建及 ABI 检查与真机安装、启动和交互测试分别记录。

## 项目结构与数据

| 路径 | 内容 |
| --- | --- |
| `lib/domain/` | 跨平台业务模型、整数分金额、轮换规则及仓储接口 |
| `lib/data/` | SQLite schema、事务、状态更新及查询 |
| `lib/ui/` | Material 3 布局、页面和表单 |
| `test/` | 数据、业务规则和 Widget 测试 |
| `docs/development.md` | 开发与 AI 辅助记录 |

SQLite 文件位于平台的应用支持目录下 `dormos/dormos.sqlite3`。Linux 应用支持目录默认使用 `$XDG_DATA_HOME`（未设置时为 `~/.local/share`）。Windows 沿用早期版本在 `org.dormos/dormos` 下的应用支持目录。关闭应用后可以复制该数据库文件做备份。业务数据在同一台设备上重启后保留。

Dorm 随包提供 [Noto Sans SC](https://github.com/google/fonts/tree/main/ofl/notosanssc) 作为中文回退字体。字体按 SIL Open Font License 1.1 发布，许可文本保存在 `assets/fonts/OFL-NotoSansSC.txt`。

- 金额以整数分持久化。余分依成员 ID 升序分配。付款者若在参与名单中，其本人份额计入消费，免于给自己转账。累计应收和应付均按成员间实际债权统计。
- 每项卫生任务独立轮换。启用云同步时，设备使用相同的记录顺序。已生成班次保留原负责人，成员变动自下一未生成班次起生效。已停用成员的旧班次会标记状态，可手动改派。打卡记录保存完成时间。
- 创建采购账单时，待采购物资更新为采购中。到货后可手动调整库存和状态。删除物资会从清单隐藏该物资，关联账单及采购名称快照仍可追溯。
- 仓储接口与独立转账记录为接入 Supabase/PostgreSQL、撤销与审计预留扩展点。账本暂未提供债务抵消及修改历史账单的功能。

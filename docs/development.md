# DormOS 开发记录

## 原始 Prompt 摘要

- 以 Flutter 和 Dart 为高校 AIGC 应用创新大赛实现可操作的寝室协作原型。
- 首先检测 WSL2，优先在 Linux 原生工作目录交付 Linux x86_64，再处理 Windows x86_64 与 Android ARM64。
- 公共账本优先，金额按分精确分摊，区分消费和转账。实现自动卫生轮换、打卡、换班与公共物资采购账单。
- 缺少工具链时提供对应发行版的安装命令，由用户安装。分析、测试、构建和启动结果以实际命令为准。

## AI 辅助环节

| 环节 | 实现与检查 |
| --- | --- |
| 环境 | Codex 探测 WSL2、检查 GTK 与编译工具，并让用户完成缺少的 Flutter、Clang 与 GTK 开发库安装。 |
| 领域建模 | Codex 编写整数分计算、SQLite DDL 和仓储接口。重点检查余分守恒、付款人不参与时的全额应收、部分转账、数据库重开和超额转账拦截。 |
| 业务迭代 | 采购链路在单事务内关联物资、保存账单和分摊。排班存储下次生成日期与成员游标，手动换班只更改当次班次。 |
| UI | Codex 编写宽屏与窄屏布局，加入表单反馈、空状态、轻量动效和浅深主题。 |
| 构建 | Flutter 3.50 模板使用独立 `material_ui` 包。首轮分析确认迁移要求后切换 Material 3 导入并重新检查。Debian 图形环境缺少中文字体，随应用打包 Noto Sans SC 解决显示问题。 |
| 回归测试 | 新增端到端 Widget 流程发现采购历史弹窗与 `LayoutBuilder` 的尺寸计算冲突。采购弹窗改用卡片列表，账本主页仍能按宽度显示表格。修复后重跑全部测试并重建 Linux Release。 |

## 交付验证

| 验证 | 结果 |
| --- | --- |
| WSL2 Debian 13 x86_64 | Flutter Stable 3.50.0，Dart 3.14.0，Clang 19，GTK 3.24。 |
| `flutter analyze` | 无问题。 |
| `flutter test --reporter expanded` | 13 项通过，含金额守恒、超额拦截、SQLite 重开、排班和采购关联以及桌面、窄屏界面。 |
| `flutter build linux --release --target-platform linux-x64` | 成功生成完整 Linux 运行目录。`readelf` 验证 ELF64 x86_64，`ldd` 未发现缺失库，运行包包含 SQLite 与 Flutter 引擎。 |
| Linux Release WSLg 窗口 | 使用单独的测试数据目录启动并生成 SQLite 文件。窗口实测覆盖中文账本、日历、物资页、深色主题与物资表单。 |
| Windows x86_64 | 已生成 runner。原生 Flutter、Visual Studio C++ 工具链及 Windows SDK 待安装。Windows Release 待构建及运行验证。 |
| Android ARM64 | 已生成 runner。Debian 中 JDK 和 Linux Android SDK 待安装。APK 构建、签名校验、ABI 检查和设备验证待执行。 |

## 维护与人工复核

- 检查固定小数与整数分的转换以及付款方、参与方和实际转账的对应关系。
- 用真实宿舍数据试用前，核对系统日期和成员名单。试用后关闭再打开以检查数据保留。
- Windows 建议在目标主机从原生目录验证完整 Release 目录。Android 建议在 ARM64 真机验证输入法、返回键、打卡、安装和数据保留。
- 多设备同步接入前需要补充身份、共享规则、离线冲突处理、版本迁移和操作审计约定。

# 源码结构与依赖

目录用于定位功能，Swift Package target 用于建立真正的编译与依赖边界。应用目录内的类型仍属于同一个 `Marr` 模块，不应将分目录误认为已经实现模块隔离。

```text
Marr/
  App/              应用入口和总协调器
  Capture/          区域截图、标注、统一图像预处理
  Conversation/     会话状态、上下文、请求协调、输入与草稿
  History/          历史存储适配和历史界面
  Workspace/        工作区、运行时协议、任务、归档和侧栏
  PersonalAgent/    Agent 档案、技能、定时唤醒、独立运行协议及工作区界面
  Translation/      识别、数学保护、区域合并、图像渲染
  Settings/         设置页面及设置控件
  Presentation/     回答面板、Markdown/工具/附件等展示
  DesignSystem/     字体、颜色、图标、表面和动效
  Infrastructure/   快捷键、附件读取和后台执行支持
  Assets.xcassets/   资源路径保持稳定
  Resources/        字体与授权文件

MarrTests/
  Capture/ Conversation/ History/ Presentation/
  Settings/ Support/ Translation/ Workspace/
  Fixtures/         保留原资源位置

Packages/MarrModules/
  Sources/
    MarrCore/
    MarrText/
    MarrNetworking/
    MarrPersistence/
    MarrSettings/
  Tests/            各模块的独立测试

```

Xcode 的功能分组与磁盘目录一致。原有 target 身份、资源、entitlements、协议字段和持久化键保持兼容；辅助程序沿用原安装身份。

应用依赖包模块；`MarrNetworking`、`MarrPersistence`、`MarrSettings` 依赖 `MarrCore`；`MarrText` 独立于这些业务模块。包边界与运行命令见 [MarrModules](../Packages/MarrModules/README.md)。

此次继续去重：

- 删除渲染器中已被公共分行器替代的旧代码定位、分词和空格拼接逻辑。仍使用的 CJK 字符判断由文本模块统一提供。
- 两条截图路径统一使用 `CaptureImagePreparation`，保持最长边 2,200 像素、JPEG 压缩系数 0.88 和原有文件名。
- 流式响应在读取事件和结束刷新时使用同一个错误转换入口。
- 文本解析、高亮、diff 和分行实现迁入 `MarrText`；21 项已有测试同步迁移，原应用中不保留第二份实现或第二份相同测试。
- 更新语料审计脚本、文档路径和质量预算。翻译布局文件已降至 800 行以内，移除其超限例外。

文件移动与包迁移不计作代码删除。本轮生产 Swift 代码按全仓库汇总净减少 213 行，新增的截图共用组件、包公开 API 和 import 已计入。

验证结果：包测试共 152 项通过（其中 21 项为迁移后的 `MarrText` 测试）；应用默认回归执行 710 项，31 项按默认策略跳过，0 失败。新增两项截图预处理测试覆盖尺寸上限、横竖比例、禁止放大小图及文件元数据。Xcode 分组中的所有源码引用已逐项验证存在，路径检查、质量检查与 `git diff --check` 均通过。

Codex 运行时由 `RuntimeWorkspaceController` 直接管理子进程；主应用不启用 App Sandbox，保留 Hardened Runtime。旧沙盒数据与设置兼容由共享模块的 `MarrStorage` 处理。

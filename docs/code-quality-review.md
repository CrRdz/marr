# 代码质量审查与重构（2026-10-26）

本次以工作区已有修改为基线，不重置暂存区，不改变现有服务配置、协议字段或持久化键。重点是职责边界、重复请求代码、服务命名与后续扩展成本。

## 发现与处理

| 问题 | 影响 | 本次处理 |
| --- | --- | --- |
| `AnswerPanel` 同时负责窗口、任务列表、历史、消息渲染和 Markdown 解析 | 修改一种展示行为容易影响其他功能 | 分出窗口控制、主视图、工作时间线、历史侧栏、消息展示和 Markdown 解析 |
| 会话文件同时包含翻译数据、提示词、容错 JSON 解析、区域合并和会话状态 | 翻译与会话生命周期混杂 | 独立 `ConversationSession`、`ConversationContext`、`ImageTranslationModels`、`ImageTranslationPrompt`、`ImageTranslationResponseParser`、`ImageTranslationMerger` |
| 多协议客户端以单个服务命名，普通/流式请求分别构造 URL、消息体和鉴权头 | 新增格式或修复配置时容易遗漏一条路径 | 改为 `InferenceClient`；共用 `InferenceRequestEncoder`，独立 HTTP 传输、响应解码、流处理及三种协议载荷 |
| 工作区控制器还负责历史数据解码、截图会话连接与归档模型 | 纯数据处理依赖整个运行时控制器 | 抽出 `RuntimeHistoryProjection`、`RuntimeConversationClient`、`RuntimeWorkspaceModels`；工作台分出模型、归档写入器和 store |
| 活动模型调用工具卡展示层来解析 JSON | 数据层反向依赖 UI 展示层 | JSON 解析收回协议层，模型和视图共同使用 |
| 设置入口混合连接、鉴权、工作区、外观、用量和控件 | 功能扩展容易继续堆积到入口 | 各设置域独立文件，共用控件集中到 `SettingsControls` |
| 翻译渲染器同时实现颜色采样、背景拟合和排版 | 图像算法与渲染调度高度混杂 | 独立 `TranslationColorSampling`、`TranslationBackgroundRestoration`、`TranslationTypography`；这些组件不依赖渲染入口 |

## 文件规模变化

下表比较入口文件，不表示其原有逻辑被删除；抽离的实现仍在对应职责文件中。

| 原入口 | 重构前 | 当前入口 | 重构后 |
| --- | ---: | --- | ---: |
| `AnswerPanel.swift` | 5,291 | `AnswerPanel.swift` | 978 |
| `ConversationHarness.swift` | 2,495 | `ConversationSession.swift` | 349 |
| `SettingsView.swift` | 3,240 | `SettingsView.swift` | 430 |
| `OpenAIClient.swift` | 1,057 | `InferenceClient.swift` | 159 |
| `CodexWorkspace.swift` | 5,247 | `RuntimeWorkspace.swift` | 4,645 |
| `TranslationRenderer.swift` | 3,806 | `TranslationRenderer.swift` | 2,538 |

网络客户端及其抽出组件合计从 1,057 行减至 1,001 行，包括新增文件的 import 与类型声明。实际去重集中在请求编码、HTTP 配置与普通响应的传输/校验路径；其他拆分主要改善职责定位和依赖方向。

## 命名与兼容

- 源码和测试文件按功能或协议命名：`RuntimeWorkspace`、`WorkbenchStore`、`RuntimeProtocol`、`AgentComposerView`、`DesktopSidebarSnapshot`、`InferenceClient`、`PlanSession`、`TranslationGatewayClient`。
- 通用类型同步使用 `RuntimeWorkspaceController`、`WorkbenchStore`、`SavedWorkspace`、`SavedTask`、`WorkActivity` 和 `AgentComposer…`。
- 具体服务适配器内部仍可保留准确的服务类型名称。真实的 HTTP 字段、端点、产品文案、OAuth 标识及 `codex.*` 存储键不做机械替换，避免损坏互操作和旧数据。
- 后台辅助程序源码目录改为 `MarrRuntimeServer`。已安装 helper 的产品名与 bundle 身份保留，以兼容启动路径。
- `InferenceClient` / `InferenceClientError` 替代旧的公开 Swift 类型；本仓库调用及测试已迁移。如果有仓库外调用方，需要同步迁移类型名。

## 扩展约定

1. 新增推理协议时，修改请求编码与响应解码边界，增加协议载荷和流事件处理；不要在界面中拼装 HTTP 请求。新增协议必须覆盖普通/流式请求的一致性。
2. 新增翻译解析、区域合并或绘图策略时，进入对应组件；会话状态不负责图像算法，纯算法不读取运行时控制器。
3. 新增设置功能时，放入对应设置域文件，共享控件复用 `SettingsControls`。
4. 新增 Swift 源文件默认最多 800 行。行数是审查信号，不是通过压缩格式满足的目标。现有超限文件使用明确预算，新增职责应先抽离再接入。
5. 仅在跨文件调用确实需要时将顶层类型或入口设为模块内部可见；组件内部成员继续保持 private。不通过把整个控制器成员改成 internal 来拆分扩展文件。

`python3 scripts/check-code-quality.py` 检查服务名文件路径、文件规模、Xcode 源文件注册、共享包 UI 依赖，以及关键纯组件的反向依赖。该检查已加入 Swift CI。`scripts/code-quality-baseline.json` 中的 14 个历史规模预算按本轮规模向上取整至百行，为小范围修复留出空间，后续应随重构下调；它们是未消除的技术债，不代表已经达到理想规模。

## 剩余重点

- `RuntimeWorkspace` 仍集中管理连接、审批、设置请求、历史同步和断线恢复。下一阶段应按状态所有权引入独立的连接会话、历史同步器与请求追踪器，保留请求世代校验、草稿恢复及单活动任务约束。单纯移到 extension 会扩大成员可见性，不能解决这些耦合。
- `AnswerPanelView` 仍有较多会话编排；`TranslationRenderer` 仍包含源区域布局、擦除和文字绘制。后续应继续沿输入/输出边界抽取组件。
- `MarrController`、`ScreenshotOverlay`、`TranslationRecognition`、`TranslationMathProtection` 与持久化仓库仍有较大文件。本次未重写这些已有行为。
- 测试工程仍有现存的 `UserDefaults` Sendable 警告；迁移应用工程到 Swift 6 严格并发前，需要调整测试数据的隔离方式。
- 静态规则无法证明完整架构独立性；真正的新服务接入仍需要协议适配和端到端回归。

## 验证

- 重构前 Swift 包基线：130 项测试通过。
- 重构后 Swift 包：131 项测试通过；新增参数化测试覆盖三种 API 格式，检查普通/流式请求的历史消息、附件、URL、超时、鉴权头、请求载荷及响应结果一致。
- 应用默认回归：独立构建目录中执行 729 项测试，31 项按默认策略跳过，0 失败。此前发现的题号保留回归在旧渲染器中也能复现；共享工作区相关修复纳入最终测试后通过。
- 对完整回归期间更新的文字识别文件再做增量构建，补跑 41 项识别测试，全部通过。
- 源码质量检查、Xcode 工程格式检查及 `git diff --check` 通过；质量检查器的反例验证覆盖服务命名、行数上限、反向依赖和漏注册源码。

## 第二轮：实际去重与模块组织

继续执行的结构调整、去重范围和最新目录见 [源码结构与依赖](source-structure.md)。新增 `MarrText` 编译模块，迁移 21 项文本测试；生产 Swift 净减少 213 行。历史规模例外从 14 个降为 13 个。前文表格保留第一轮时点的规模。

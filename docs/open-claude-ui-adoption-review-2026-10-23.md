# open-claude-ui 深度研究与 Marr 采纳建议

研究日期：2026-10-23（Asia/Shanghai）。项目目录为 OpenLens，当前产品名称为 Marr。

**建议优先采纳：完整的视觉语义体系、统一图片查看器、可追踪的工具过程卡片。工程上同时优化 Work 流式持久化，再补断线后的状态核对。** 我们现有的输入、草稿、网络和审批实现已有扎实基础，继续沿用 SwiftUI/AppKit，并将参考项目的交互思路转译为原生组件。

**研究范围与版本**

- 参考仓库已克隆至 `/private/tmp/openlens-open-claude-ui-20261023`，固定版本为 [`c1f923ae0051a871941b98a0e2e3183a545e6a85`](https://github.com/Caho1/open-claude-ui/tree/c1f923ae0051a871941b98a0e2e3183a545e6a85)，提交时间为 2026-10-21 16:39:16 +08:00。
- 检查了包入口、CSS 令牌、核心交互组件与 hooks、v1/v2 文档、预览页及 CI；与 Marr 当前工作区的源码和测试逐项对照。当前工作区包含未提交改动，因此仅用本地 HEAD 无法完整复现这次 Marr 基线。
- 本地已有 [旧审计](/Users/crzhu/Projects/OpenLens/docs/open-claude-ui-gap-audit.md)。其参考版本 `07caa0d` 到本次版本只有 4 个 README/Logo 提交，没有组件源码变更；本次价值在于重新核实当前实现与剩余机会。[版本比较](https://github.com/Caho1/open-claude-ui/compare/07caa0d695e066effaad4714acf087b0205b155e...c1f923ae0051a871941b98a0e2e3183a545e6a85)
- 这是源码与设计审计。没有安装参考项目依赖、运行其界面或执行真实 AI 请求；没有进行新的 Marr 实机视觉、性能或 VoiceOver 测试。文中“已有”表示源码中存在相应实现，不代表本轮重新验证过所有运行场景。

**这个项目实际提供了什么**

它的交付物是三个层次：CSS 设计令牌与表现规则、React 交互组件及 hooks、解释桌面交互和架构的分析文档。令牌层集中管理表面、边框、阴影、文字、尺寸和过渡；组件层把输入、消息、工具卡、媒体和分栏做成独立参考。这种“规则集中、组件消费规则、行为有明确边界”的组织方式最有价值。[包配置](https://github.com/Caho1/open-claude-ui/blob/c1f923ae0051a871941b98a0e2e3183a545e6a85/package.json)、[导出入口](https://github.com/Caho1/open-claude-ui/blob/c1f923ae0051a871941b98a0e2e3183a545e6a85/src/index.ts)

它不是 Anthropic 官方源码，也没有提供文档中全部后端能力。尤其需要分开看待“对官方客户端的分析”“仓库中可执行的参考组件”“本项目作者提出的解释”。例如当前弹簧文件明确承认 `SPRING_GENTLE` 为项目自建值；v1 描述、后续客户端用途与预设命名也不能混为一谈。[弹簧来源说明](https://github.com/Caho1/open-claude-ui/blob/c1f923ae0051a871941b98a0e2e3183a545e6a85/code-examples/ClaudeMotionPresets.ts#L57-L119)

**我们已经拥有的能力，应保留并继续验证**

| 能力 | 当前 Marr 实现 | 本次判断 |
| --- | --- | --- |
| CJK 输入保护与指令补全 | [AgentComposerView.swift:163](/Users/crzhu/Projects/OpenLens/Marr/Conversation/AgentComposerView.swift) 优先处理 `hasMarkedText()`，已有键盘补全 | 不需要换成 Web 的 `keyCode=229` 或固定 500ms 补丁 |
| 草稿、附件、引用与来源恢复 | [ComposerDraftStore.swift:193](/Users/crzhu/Projects/OpenLens/Marr/Conversation/ComposerDraftStore.swift)、[RuntimeWorkspace.swift:1034](/Users/crzhu/Projects/OpenLens/Marr/Workspace/RuntimeWorkspace.swift) | 已有落盘、任务归属、未确认提交恢复；不应再次列成缺失功能 |
| 实际流式、取消与受限重试 | [InferenceStream.swift:215](/Users/crzhu/Projects/OpenLens/Packages/MarrModules/Sources/MarrNetworking/InferenceStream.swift:215)、[ConversationRequestCoordinator.swift:35](/Users/crzhu/Projects/OpenLens/Marr/Conversation/ConversationRequestCoordinator.swift) | 已支持三协议流、代际隔离、部分回答保留；仅明确的 429/503 在输出前重试 |
| 审批、提问与 MCP 交互 | [RuntimeProtocol.swift:253](/Users/crzhu/Projects/OpenLens/Marr/Workspace/RuntimeProtocol.swift)、[RuntimeWorkspace.swift:2902](/Users/crzhu/Projects/OpenLens/Marr/Workspace/RuntimeWorkspace.swift) | 真实协议比参考工具卡复杂完整，应改善呈现，不替换协议逻辑 |
| 阅读时暂停自动跟随 | [MarrSurface.swift:365](/Users/crzhu/Projects/OpenLens/Marr/DesignSystem/MarrSurface.swift) | 已有 48pt 底部容差、live scroll、键盘优先和旧回调隔离，不必生搬 40px/150ms |
| 消息、代码复制与文件 diff | [MarrResponseComponents.swift:112](/Users/crzhu/Projects/OpenLens/Marr/Presentation/MarrResponseComponents.swift)、[diff:335](/Users/crzhu/Projects/OpenLens/Marr/Presentation/MarrResponseComponents.swift) | 复制反馈、语言标签、按文件折叠、行号、增删与预览限额均已有 |
| 原生动效降级 | [MarrAgentMotion.swift:80](/Users/crzhu/Projects/OpenLens/Marr/DesignSystem/MarrAgentMotion.swift) | 已响应减少动态效果、减少透明度、高对比度及窗口隐藏 |

**建议采纳清单**

优先级表示建议实施顺序，不表示缺陷严重度；成本为相对工程量，尚未做工期承诺。

| 顺序 | 建议 | 收益 | 成本 | 与现有代码的关系 |
| --- | --- | --- | --- | --- |
| 1 | 补全视觉语义和排版规则，贯穿真实页面 | 高：直接改善整体一致性 | 中 | 扩展现有 MarrUI/MarrTypography |
| 1 | 统一原生图片查看器 | 高：直接服务截图问答和多图阅读 | 中 | 合并现有附件和产物预览入口 |
| 1 | Work 持久化合并写入与后台存储 | 高：降低长任务中重复编码负担 | 中至大 | 优先复用 Conversation 的已有模式 |
| 2 | 工具请求、审批、执行、结果关联展示 | 高：让用户理解任务过程 | 中 | 基于真实 runtime 事件构建视图模型 |
| 2 | 断线后自动连接恢复与只读状态核对 | 高：减少任务状态不明 | 中至大 | 扩展现有 recovery，保留不重复执行原则 |
| 2 | 原生组件状态目录与完整键盘路径验证 | 高：减少视觉和交互回归 | 中 | 汇总已有测试 fixture，增加关键缺口 |
| 3 | 代码阅读增强、宽窗分栏 diff、滚动边缘处理 | 中 | 小至中 | 按场景增量添加 |

1. **把视觉系统从“常量集合”补成“语义规则”。**

   参考 CSS 的优势是把画布、内容、卡片、浮层，以及普通边界、悬停、焦点、选中分开管理，并为明暗模式分别定义。借鉴的是角色与层级，而不必采用其品牌配色。[表面与边框规则](https://github.com/Caho1/open-claude-ui/blob/c1f923ae0051a871941b98a0e2e3183a545e6a85/code-examples/cds-theme.css#L94-L157)

   Marr 的 [Surface:28](/Users/crzhu/Projects/OpenLens/Marr/DesignSystem/MarrAgentMotion.swift) 目前只有 `canvas/raised` 两种通用表面；[Typography:6](/Users/crzhu/Projects/OpenLens/Marr/DesignSystem/MarrTypography.swift) 集中了字号，但行高、段距、字重和缩进仍分散指定。[附件 chip:114](/Users/crzhu/Projects/OpenLens/Marr/Conversation/ComposerContextStrip.swift) 与 [审批卡:833](/Users/crzhu/Projects/OpenLens/Marr/Workspace/RuntimeSupportViews.swift) 仍各自组合填充和几何参数。

   建议为现有系统补齐 `canvas/content/card/popover`、`border/subtle/focus`、`running/needsInput/error` 等角色；将字号、行距、段距、字重组成可复用文字样式。先统一 Conversation、Work、历史和设置的公共组件，再处理局部例外。Liquid Glass 是材质选择，仍需明确该表面在信息层级中的职责。

   验收看相同角色是否在各页面保持一致、长中文与长模型名是否稳定、明暗与降低透明度后正文是否清楚、焦点是否仍明显。截图翻译的原文排版属于内容，应保留独立规则。

2. **统一图片查看器是最贴合 Marr 定位的新功能。**

   上游真正有用的机制是围绕光标缩放、平移、前后切图、方向键/Escape 和关闭后恢复焦点。[MediaLightboxViewer](https://github.com/Caho1/open-claude-ui/blob/c1f923ae0051a871941b98a0e2e3183a545e6a85/code-examples/MediaLightboxViewer.tsx#L134-L286)

   目前附件图片停留在 [360×300 预览:70](/Users/crzhu/Projects/OpenLens/Marr/Conversation/ComposerContextStrip.swift)，生成图片采用 [内嵌预览和外开 Preview:1130](/Users/crzhu/Projects/OpenLens/Marr/Workspace/RuntimeSupportViews.swift)。这足够辨认图片，但不利于查看截图中的小字、代码、图表或多图差异。

   建议让待发附件、已发附件、生成图片进入同一原生查看器：适应窗口、100% 比例、触控板缩放、平移、上一张/下一张、复制和外部打开。缩略图仅负责进入，图像列表和选中项由共享模型管理。用 AppKit/SwiftUI 实现，与现有图片数据和文件访问规则衔接。

   第一版验收为长截图能读清文字、多图切换不丢失当前会话、Escape 回到原控件。原图/译图共享缩放位置可作为后续增强，是从 Marr 使用场景推导的建议，并非参考仓库现成能力。

3. **工具卡片应把同一次操作的全程连起来。**

   参考工具卡将来源、工具名、输入参数、授权选项、执行结果放在一个上下文内，能降低理解成本。[工具卡结构](https://github.com/Caho1/open-claude-ui/blob/c1f923ae0051a871941b98a0e2e3183a545e6a85/code-examples/McpToolDecisionCard.tsx#L79-L184)

   当前 Marr 的 [审批视图:764](/Users/crzhu/Projects/OpenLens/Marr/Workspace/RuntimeSupportViews.swift) 和 [活动日志:3638](/Users/crzhu/Projects/OpenLens/Marr/Presentation/AnswerPanel.swift) 分开呈现。建议基于真实 thread/turn/item/request 标识关联：一句话操作摘要 → 影响对象或服务 → 需要用户选择时显示权限 → 运行结果与产物。完整参数和原始 JSON 放在可展开详情中；已经完成的工具默认收起，失败或待处理状态优先可见。若协议无法可靠关联请求与 item，就保留独立记录，不凭标题猜测合并。

   审批选项继续以 runtime 返回的真实决策为准，不固定成上游的三按钮；耗时也只展示真实数据。等待用户时不显示“正在执行”，批准后不能直接显示成功。验收覆盖拒绝、取消、执行失败、迟到结果以及多个待处理请求。

   现有 `thinkingMessages` 实际包含普通进度消息；不能将其包装成模型完整思维链。只有运行时确实提供的可展示 reasoning summary 才适合独立呈现。现状依据：[消息分组:3287](/Users/crzhu/Projects/OpenLens/Marr/Presentation/AnswerPanel.swift)、[delta 处理:3011](/Users/crzhu/Projects/OpenLens/Marr/Workspace/RuntimeWorkspace.swift)。

4. **先改善长任务的数据流，再增加更多连续动画。**

   这是本次对照审计发现的 Marr 自身优化机会，不是上游提供的现成方案。每个 Work delta 会经过 [recordDelta:3369](/Users/crzhu/Projects/OpenLens/Marr/Workspace/RuntimeWorkspace.swift) → `syncActiveTask` → `updateTask` → [save:469](/Users/crzhu/Projects/OpenLens/Marr/Workspace/WorkbenchStore.swift)，在主 actor 重新编码整个任务归档并调用 UserDefaults 保存。归档包含历史任务与活动，持续文本增长会增加重复处理量。尚未测量实际卡顿或延迟，不能将性能风险写成已经发生的故障。

   建议先合并高频内容更新，将持久化移到串行后台存储；再按 task/turn/item 更新记录。终态、任务切换和应用退出需要明确 flush。未确认提交和审批相关记录仍需及时持久化，不能与普通文本 delta 一起任意延迟。

   Marr 自己已有可复用模式：[Conversation 流式保存节流:2094](/Users/crzhu/Projects/OpenLens/Marr/Conversation/ConversationSession.swift) 和 [后台存储队列:89](/Users/crzhu/Projects/OpenLens/Marr/History/ConversationHistoryStore.swift)。验收用长历史、高频 delta、连续切换和强制中断恢复场景，测主线程耗时、写入次数和恢复正确性。

5. **断线恢复应先查询任务事实，再决定后续动作。**

   当前 [handleTransportFailure:3565](/Users/crzhu/Projects/OpenLens/Marr/Workspace/RuntimeWorkspace.swift) 能保留恢复信息，并提示重新连接、刷新任务，但没有完整自动连接恢复与状态核对流程。

   建议增加有界连接重试，成功后读取原 thread，按 turn/item 标识合并：仍运行则继续观察，已完成则展示结果，无法确定则保留未确认提示。用户原始指令不应因断线自动重复执行；恢复审批同样必须依据运行时有效请求，不自动接受缓存权限。这是 v2“输入不丢失”理念在当前真实执行链路中的合理延伸，上游 `ChatComposerChin` 只提供计数和回调，并没有实现持久队列。[参考组件](https://github.com/Caho1/open-claude-ui/blob/c1f923ae0051a871941b98a0e2e3183a545e6a85/code-examples/ChatComposerChin.tsx#L4-L38)

   为支撑后续扩展，可逐步把约 3,990 行的 `RuntimeWorkspace.swift` 拆出 transport、协议适配、每线程运行状态、持久化职责。先从持久化与连接恢复提取模块，避免一次性重写已经有测试覆盖的审批和提交逻辑。

6. **建立可浏览的原生组件状态目录，并补整条键盘路径。**

   参考项目的展示页便于把按钮、输入、状态、媒体放在一起观察；值得采纳的是这种检查方式。它的页面从 CDN 加载 React/Tailwind/Babel，并含独立演示代码，不等于离线、自动化或与导出组件完全一致的测试系统。[预览页依赖](https://github.com/Caho1/open-claude-ui/blob/c1f923ae0051a871941b98a0e2e3183a545e6a85/docs/claude-components-storybook.html#L1-L15)

   Marr 已有 [消息与 diff fixture:165](/Users/crzhu/Projects/OpenLens/MarrTests/Presentation/MarrResponseComponentsTests.swift)、[窄窗输入组合:323](/Users/crzhu/Projects/OpenLens/MarrTests/Conversation/AgentComposerViewTests.swift)、[动效与辅助偏好 fixture:35](/Users/crzhu/Projects/OpenLens/MarrTests/Presentation/MarrAgentMotionTests.swift)。建议复用真实组件做开发用 gallery，覆盖空白、输入、运行、待审批、失败、长内容、长附件名和多图片。

   在明暗模式、窄窗、减少透明度/动态效果下检查相同状态。键盘验收至少覆盖“输入 → 选择附件 → 预览 → 关闭回到原位置 → 审批 → 查看结果”，同时验证 VoiceOver 标签。现有局部 focus 代码和渲染截图不能证明整条辅助功能路径已通过。

   工程测试应补真实本地传输边界：用假 app-server 子进程或 loopback WebSocket 覆盖 initialize、拆包、超时、断线和重启，不需要真实模型请求。现有 [WorkspaceFixture:1623](/Users/crzhu/Projects/OpenLens/MarrTests/Workspace/RuntimeWorkspaceTests.swift) 注入闭包，生产请求计时路径在注入时关闭，存在可补充的验证层次。

7. **代码阅读与边缘动效按使用频率补齐。**

   代码块可补文件名、可选行号和真正的语法高亮；大 diff 可在宽窗口或独立查看器中提供分栏，紧凑面板继续保留统一 diff。现有 diff 有预览上限和 LazyVStack，但源变化会重新解析；先确认更新频率与测量结果，再决定后台解析、缓存或增量处理。[当前 diff:335](/Users/crzhu/Projects/OpenLens/Marr/Presentation/MarrResponseComponents.swift)

   滚动边缘渐隐可作为较小的质感改进：只在对应方向确实有隐藏内容时出现，触顶/触底消失；与现有 NSScrollView 观察逻辑共用状态。避免渐隐覆盖焦点或关键按钮，高对比度下可关闭。上游提供了明确边缘条件，但渐变的具体数值应按我们的材质和窗口尺度验证。[ScrollFadeContainer](https://github.com/Caho1/open-claude-ui/blob/c1f923ae0051a871941b98a0e2e3183a545e6a85/code-examples/ScrollFadeContainer.tsx#L49-L81)

**不宜直接照搬的部分，以及原因**

| 参考内容 | 实际核查结果 | 对 Marr 的选择 |
| --- | --- | --- |
| 工具卡执行状态 | 允许后用 1.2 秒定时器无条件变为成功 | 只借信息层级，状态来自 runtime。[源码](https://github.com/Caho1/open-claude-ui/blob/c1f923ae0051a871941b98a0e2e3183a545e6a85/code-examples/McpToolDecisionCard.tsx#L53-L71) |
| Cowork 编排与同步 | 使用静态 agent/artifact 数据；协同和审计按钮没有处理函数，文件没有 BroadcastChannel | 可参考任务/产物关系，不视作多 Agent 基础设施。[源码](https://github.com/Caho1/open-claude-ui/blob/c1f923ae0051a871941b98a0e2e3183a545e6a85/code-examples/CoworkAgentCanvas.tsx#L93-L98) |
| “增量”diff 引擎 | 实际每次 rawDiff 变化都整串 parse，没有文档描述的 Worker/Shadow DOM 管道 | 分栏布局可参考；性能方案需自行实现。[源码](https://github.com/Caho1/open-claude-ui/blob/c1f923ae0051a871941b98a0e2e3183a545e6a85/code-examples/StreamingDiffViewer.tsx#L125-L147) |
| Artifact 桥接 | 有 iframe source 检查，但 `hasBeenActive` 无法证明本次请求来自新鲜用户手势 | 若以后运行生成 HTML，单独设计 WKWebView 与宿主能力边界。[源码](https://github.com/Caho1/open-claude-ui/blob/c1f923ae0051a871941b98a0e2e3183a545e6a85/code-examples/EpitaxyIframeBridge.tsx#L41-L75) |
| 重试 hook | ±15% jitter，并把 Retry-After 混入指数计算；可能早于服务要求重试 | 保留我们已有的有界 Retry-After 处理。[源码](https://github.com/Caho1/open-claude-ui/blob/c1f923ae0051a871941b98a0e2e3183a545e6a85/code-examples/useRateLimitBackoff.ts#L36-L57) |
| 生成中强制展开思考 | `isThinkingLive` 时用户不能收起 | 保留当前 Activity 可自由折叠，更适合紧凑面板。[源码](https://github.com/Caho1/open-claude-ui/blob/c1f923ae0051a871941b98a0e2e3183a545e6a85/code-examples/ThinkingAccordion.tsx#L39-L48) |
| 具体颜色、弹簧和 Web 几何值 | 部分文档与当前实现/版本并不一致；Web 参数与 SwiftUI 参数体系也不同 | 用作用途参考，保留 Marr 品牌、系统字体与原生交互 |

**后续产品扩展的取舍**

- **多任务后台运行**：如果用户确实需要任务 A 执行时查看或发起 B，再引入每线程 runtime store 和统一待处理请求列表。当前运行中禁止切换任务，是现有单活动任务模型的一部分；不能只去掉 UI guard。[切换约束:1630](/Users/crzhu/Projects/OpenLens/Marr/Workspace/RuntimeWorkspace.swift)
- **产物侧栏**：先做真实文件、图片和 diff 的入口及查看器。任意 HTML 执行、隔离宿主权限、网络访问和多窗口同步属于独立功能项目。上游文档并没有替我们完成这些基础设施。
- **语音与音效**：波形、降噪门限和提示音值得作为未来参考，但需要先确认听写/语音是产品需求。对当前截图和文字任务，优先改善图片阅读和任务结果访问。

**建议落地顺序**

第一轮并行做三件边界清楚的工作：补全并应用现有视觉语义；统一原生图片查看器；测量并优化 Work 高频保存。第二轮做工具卡片和连接恢复，同时完善对应状态 fixture、键盘路径和传输测试。第三轮依据使用反馈加入代码阅读、宽窗 diff、边缘渐隐及产物入口。

视觉变更完成的标准应是跨页面规则一致、状态清楚、长内容稳定，而不是动画数量。工程变更完成的标准应是输入和权限不丢、不重放不确定执行、持续输出时主线程负担可控，并有针对性回归证据。

**研究阶段验证记录**

- 已核对两个参考版本的 GitHub compare；新增提交只影响 README 与 Logo。
- 阅读后运行了无依赖、只读的 `node scripts/check-tokens.mjs`：检测到 194 个 `--cds-*` 定义，AGENTS 文档中 36 个被检查引用均存在，退出码为 0。该脚本不检查所有别名传递、值一致性、可访问性或交互正确性，不能把这个结果扩大为完整设计系统验证。
- 上游 CI 只有 typecheck、token 检查和 build；本轮未运行其 typecheck/build。也未运行 Marr 测试、性能基准或实机界面检查；引用测试文件仅作为已有覆盖的证据。[上游 CI](https://github.com/Caho1/open-claude-ui/blob/c1f923ae0051a871941b98a0e2e3183a545e6a85/.github/workflows/ci.yml)
- 这次仅新增本研究报告，没有修改应用源码或覆盖旧审计。如后续直接复用实质代码片段，应按仓库 [MIT LICENSE](https://github.com/Caho1/open-claude-ui/blob/c1f923ae0051a871941b98a0e2e3183a545e6a85/LICENSE) 保留相应版权与许可声明，并记录参考版本。


**实施记录：2026-10-23**

用户授权全量实施本报告的近期采纳项，并要求保留回滚基线、默认测试不打扰桌面。实施前已将当时全部 123 个变更文件暂存，保存 tree `bceb60e7acb12da70a650f2f2ea1e096753b0665`，固定引用为 `refs/checkpoints/pre-open-claude-ui-fixes-20261023`。本轮修复全部留在工作区、未再次暂存或提交，暂存区与该基线保持一致。

已落地的范围：

- 视觉语义：补齐内容、卡片、浮层、输入表面及边界和状态角色；正文、标题、段距组成共享文字样式，应用于设置、历史、正文与过程卡。保留截图翻译的独立内容排版。
- 图片查看器：待发和已发图片、生成图片共用原生入口；支持适应窗口、按物理像素计算的 100%、光标锚点缩放、平移、多图切换、复制、Preview 及关闭后的焦点恢复。远程读取须点击，只有当前图片全尺寸解码；读取及解码有数据与像素上限。
- Work 保存：高频 delta 每 0.5 秒合并快照，后台串行编码和保存，最多保留一个待写快照；终态、切换、关闭连接和退出时完成待写保存。保留 `codex.workbench.v1` 格式和草稿原有立即保存语义。本轮未迁移 SQLite，也不把 UserDefaults 写入返回等同于强制磁盘同步。
- 工具与审批：来源、参数、真实状态、结果和真实耗时聚合呈现；失败和待处理优先可见。审批以 thread/turn/item 精确关联，归属在首次显示后固定，防止新 steer 消息重建正在填写的表单；无法可靠关联时留在固定区域。
- 断线恢复：最多三次退避后只读原 thread，不重发提交、不自动批准；完整有效快照才能解除不确定状态。断线后的发送锁与“正在运行”分开表示，旧终态事件不能解锁新任务。
- 阅读体验：有界词法着色、文件名和行号，原文完整复制；宽窗可选双栏 diff，窄窗保留 unified。解析、着色和双栏测宽有后台缓存及取消机制。滚动渐隐仅指示实际隐藏内容，高对比及减少透明度时关闭。
- 验证工具：Debug 菜单显式打开真实组件目录；默认脚本只运行无可见窗口的测试，实机窗口测试须 `--ui`。独立 macOS CI 明确启用实机测试。测试专用启动路径不创建生产窗口、状态栏和全局热键；离屏窗口类会阻止意外前台排序。新增本地 loopback WebSocket 服务覆盖真实拆包、断线及 RPC 超时，运行结束后清理。

高亮是轻量词法着色，双栏按连续变更行配对；本轮没有增加 AST 分析、任意 HTML 执行、语音、多任务并发 runtime 或改变现有模型权限。这些仍属于本报告列出的后续产品扩展。

实施后验证：

- 应用完整静默回归：519 项，488 项通过、31 项按配置跳过、0 失败。包含 3 项真实本地 WebSocket 传输测试；未调用真实模型。日志与结果包：`build/validation/complete-app-tests.log`、`build/validation/complete-app-tests.xcresult`。
- Swift 包：7 个测试组、78 项全部通过，日志 `build/validation/package-tests.log`。
- Release 构建通过，日志 `build/validation/complete-release-build.log`。
- 最后一次修改仅加固离屏截图 fixture：显式外观和尺寸、完成布局及显示事务、等待图像稳定后原子保存。随后单独复跑响应组件 16 项，全部通过，结果包 `build/validation/offscreen-review.xcresult`。检查了宽/窄、明/暗预览；宽窗分栏切换控件与代码内容正常显示。
- 完整回归日志未出现 Thread Performance Checker 优先级反转警告或 SQLite vnode-unlinked 清理警告。Git 差异检查通过；暂存区仍与上述 checkpoint 完全一致。

本轮遵守不打扰桌面的要求，未运行需要可见窗口的交互验收。离屏渲染与单元测试不能代替实际键盘焦点、拖拽和 VoiceOver 全流程验收；这些保留在显式 `scripts/test-marr.sh --ui` 及后续手工验收范围。测试脚本默认不创建可见窗口、不注册生产全局热键。

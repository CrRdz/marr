# open-claude-ui 对照与剩余工作

审计日期：2026-10-20 至 2026-10-21。

参考仓库：[Caho1/open-claude-ui](https://github.com/Caho1/open-claude-ui)，固定版本
[`07caa0d695e066effaad4714acf087b0205b155e`](https://github.com/Caho1/open-claude-ui/tree/07caa0d695e066effaad4714acf087b0205b155e)。
范围包括 README、实际导出的组件、v1/v2 文档及 Marr 当前工作区实现。

此前的改动解决了 Marr 自身的输入、状态和滚动问题；当时尚未拿到此链接，不能将它们描述为已经完成本仓库的逐项迁移。下文保留首次差距审计，并记录 2026-10-21 按此参考完成的原生实现。

该仓库是第三方设计分析与参考实现，不是 Anthropic 官方源码。本次以可读代码为设计依据，不独立背书文档对官方版本、性能或内部架构的描述。参考代码只读检查，未执行脚本、安装依赖或运行示例。Marr 使用 SwiftUI/AppKit 原生实现，没有引入参考仓库的 Web/Electron 运行环境。

## 结论

本轮已实现任务草稿持久化与恢复、统一附件/引用条、Conversation 真实增量回答与受限重试、逐条回答及代码复制、分文件 diff、长提问折叠、真实 Work 用量提示、任务排序，以及环境光和用途明确的弹簧动画。

仍需区别对待的内容包括：真实服务及系统辅助功能端到端验证、Conversation 上下文容量数据、完整 reasoning 数据呈现，以及 Artifact 沙箱、语音和多窗口等独立扩展。它们没有被装饰动画或演示数值替代。

## 2026-10-21 实施结果

| 范围 | 已实现 | 边界 |
| --- | --- | --- |
| 草稿与恢复 | 按 Conversation 或工作区/本地任务 UUID 存储文字、选择范围、编辑轮次、附件文件及引用绑定；面板重建和重启读取；新任务取得远端 ID 保持归属；恢复到原任务后启动读取 | 未确认提交保留人工恢复入口，不自动重复执行 Work。读写失败显示错误且保留已有数据 |
| 发送确认 | 持久化待确认提交；RPC 或任务开始/完成事件确认后清理；处理事件先于回复、初始化失败和 `/review`、`/goal` 新任务归属 | 不宣称提供后台自动发送队列 |
| Conversation 流式回答 | Responses、Chat Completions、Anthropic Messages 的实际 SSE 增量；取消忽略迟到事件；错误/取消保留部分回答；受限缓冲、截断检测 | 离线传输测试验证协议，不代表所有服务商线上兼容性已验证 |
| 重试 | 仅在收到内容前，对 429/503 最多重试两次，尊重有界 Retry-After 并显示倒计时；显式不支持 streaming 时回退 | 不重放不确定是否被接收的网络失败；不叠加 Work runtime 重试 |
| 附件及引用 | 两种模式共享逐项预览、图片缩略图、元数据及移除；已发送附件可查看；技能/文件/插件 chips 对应真实绑定 | 继续使用现有文件选择和附件提交服务 |
| 回答与变更 | 单条回答/代码复制及反馈；保留 fence language；未闭合代码块仍可渲染；长提问展开/收起；diff 文件折叠、行号、增删标记、完整复制 | diff 预览有长度上限；未新增语法着色或任意 HTML 执行 |
| 模型与资源 | 展示运行时模型/effort 说明；Work 使用服务器 `thread/tokenUsage/updated` 的最近请求和真实容量 | 最近请求占比不等于当前剩余上下文；Conversation 无容量数据时明确提示不可用；不混用账户配额 |
| 控件与任务组织 | 共享圆角、表面、按钮按压/焦点/禁用状态；长模型名让出发送/停止空间；模型弹层 Escape 关闭并返回编辑器；模式方向键切换；任务拖拽和菜单上下移动，顺序持久化 | 运行中任务、跨项目或跨置顶分组不能重排；完整 VoiceOver/Full Keyboard Access 尚需实机审计 |
| 环境光与弹簧 | 执行时低幅环境光、160 ms 淡入淡出；按压/切换/附件/折叠/面板分别使用短弹簧；窗口不可见时停止动态光晕调度 | 无逐 token 动画；Reduce Motion 静态反馈；Reduce Transparency/高对比度改为实线描边 |

## README 第一至第六篇复核：覆盖与质感

结论：六篇都有实际借鉴或原生等效能力，但覆盖深度不均衡；交互可靠性的完成度高于整体视觉系统。已有组件、测试通过和局部动画，不能证明完整设计语言已经落地。以下核对结合固定参考版本的六篇文档、当前工作区源码和已有原生截图；属于设计审计，不新增运行时验证结果。

| 篇章 | 当前实际覆盖 | 仍未充分吸收 |
| --- | --- | --- |
| 1. 设计哲学与令牌 | 字体角色、语义文字色、部分间距/圆角和玻璃降级 | 画布/内容/卡片/浮层的稳定表面阶梯；统一边框及阴影角色；字重、行高、段间距和光学对齐组合；跨页面执行一致性 |
| 2. 原子组件与控件 | 共用按钮状态、模式分段、活动指示、原生弹层、附件条；轻量 Edit/Copy | 共用规则尚未覆盖设置、历史、审批和全部菜单；相同层级控件仍有局部样式；完整状态视觉对照尚缺 |
| 3. 会话与指令 | IME、防误发、草稿归属、补全、真实流式、消息操作、长提问折叠、模型与真实用量、工具审批 | 完整 reasoning 数据；工具过程和审批的统一信息层级；任务标题/气泡/活动的整体排版与重复信息取舍 |
| 4. 动效与光影 | 用途化弹簧、运行环境光、淡入淡出、减少动效、隐藏停调度 | 滚动边缘渐隐；媒体共享元素转场；跨页面/状态切换的整体节奏标定。持续正文模糊吐字不作为默认迁移目标 |
| 5. 媒体与产物 | 图片/文件预览、代码语言及复制、分文件 diff/行号/折叠 | 统一画廊的缩放/平移/切换；语法高亮和分屏 diff；产物分栏、执行沙箱；语音与提示音链路 |
| 6. 桌面与协作 | 原生窗口材质、任务持久化排序、上翻暂停跟随、返回底部、窄窗关键按钮、部分键盘路径和有界重试/恢复 | 完整 VoiceOver/Full Keyboard Access 审计；拖拽落点呈现和更多密度状态；多 Agent 共享资产看板及跨窗口同步 |

### 当前“质感不足”的主要依据

1. **全局表面角色仍不完整。** `MarrUI.Surface` 目前定义 canvas/raised 两个通用角色；`MarrSurfaceMode` 的 clear/regular/unfocused 是材质状态，不能代替画布、内容、卡片、浮层的语义层级。很多局部组件继续直接组合透明填充、描边和阴影，整体观感依赖背景和页面。
2. **排版系统主要统一了字号。** `MarrTypography` 提供字号角色，但行距、字重、段间距、正文与卡片的缩进仍由视图分别指定。设置、历史、Conversation 和 Work 没有形成同一套完整排版节奏。
3. **结构线的视觉权重偏强。** 当前深色截图中输入框亮轮廓和 Activity 分隔线比较显眼。后续应分别标定常态边界、悬浮边界和键盘焦点，保留辅助功能所需的明确焦点，减少普通结构线与正文争夺注意力。
4. **信息层级仍可精简。** 短任务截图中任务标题与提问可能重复，Activity 另占一层，正文及操作也有独立间隔。应按导航、用户输入、回答、过程这四种职责重新分配密度；空白本身不是缺陷，重复信息和不明确的间距角色才需要处理。
5. **局部修饰还未形成统一产品气质。** Edit/Copy 与运行光晕已经改善，但相同规则需要贯穿输入框、附件、工具卡片、菜单、历史和设置。增加语音、Artifact 或更多动画的视觉收益低于先统一这些基础。

建议下一轮先做第一篇的表面/排版/边框规则，再落实第二篇的跨页面控件状态，最后标定第四篇的过渡与滚动边缘。保留 Marr 自身的品牌与原生语义，不以复制陶土色、商业字体或所有演示效果作为完成标准。

代码依据：[视觉常量与动效](/Users/crzhu/Projects/OpenLens/Marr/DesignSystem/MarrAgentMotion.swift)、[排版](/Users/crzhu/Projects/OpenLens/Marr/DesignSystem/MarrTypography.swift)、[材质](/Users/crzhu/Projects/OpenLens/Marr/DesignSystem/MarrSurface.swift)、[会话布局](/Users/crzhu/Projects/OpenLens/Marr/Presentation/AnswerPanel.swift)、[设置](/Users/crzhu/Projects/OpenLens/Marr/Settings/SettingsView.swift)、[消息与 diff](/Users/crzhu/Projects/OpenLens/Marr/Presentation/MarrResponseComponents.swift)。

“等效已有”表示已经用原生方式解决同一交互问题；“部分”表示已有基础但缺少某些能力；“未做”不等于本产品必须引入。下面的 P0–P3 是实施顺序，不是故障严重性或完成比例。

## 首次审计的优先落地清单（实施前证据）

此表及其行号保留为初次审计记录，不代表当前代码位置或当前完成状态；本轮结果见上表。

| 顺序 | 剩余工作 | 当前证据 | 完成标准 |
| --- | --- | --- | --- |
| P0 | 按项目、任务保存完整草稿；恢复前核对归属 | [AnswerPanel.swift:645](/Users/crzhu/Projects/OpenLens/Marr/Presentation/AnswerPanel.swift) 仅有 Conversation/Work 两份视图状态；[恢复方法:2583](/Users/crzhu/Projects/OpenLens/Marr/Presentation/AnswerPanel.swift) 没有使用失败草稿中保存的 workspaceID/threadID | A/B 任务往返、项目切换、面板重建和应用重启都能恢复各自的文字、光标、附件及文件/技能/插件绑定；新任务取得远端 ID 后正确迁移；恢复不会把 A 的输入放进 B |
| P0 | Conversation 接入真实增量回答 | [ConversationRequestCoordinator.swift:34](/Users/crzhu/Projects/OpenLens/Marr/Conversation/ConversationRequestCoordinator.swift) 等待完整结果后一次 complete | 有真实首段输出即显示，取消后忽略迟到事件，失败保留已收到内容；Markdown 重排和用户上翻不跳动；各支持的 provider 分别验证 |
| P1 | 统一待发送附件与上下文条 | [AnswerPanel.swift:991](/Users/crzhu/Projects/OpenLens/Marr/Presentation/AnswerPanel.swift) Work 仅文件名与移除，Conversation 主要显示数量；补全已有真实绑定 | 两种模式都能逐项确认文件名、类型、图片缩略图和必要的大小信息，预览/移除；技能、文件、插件的可视标签与真实提交内容一致 |
| P1 | 代码块与变更阅读 | [代码块:3830](/Users/crzhu/Projects/OpenLens/Marr/Presentation/AnswerPanel.swift) 只有等宽文本；[解析:3923](/Users/crzhu/Projects/OpenLens/Marr/Presentation/AnswerPanel.swift) 丢弃 fence language；[diff:336](/Users/crzhu/Projects/OpenLens/Marr/Workspace/RuntimeSupportViews.swift) 为纯文本 | 代码块保留语言、独立复制、成功/失败反馈；diff 按文件/hunk 分组、显示行号和增删状态，支持定位与折叠；长内容保持可操作 |
| P1 | 逐条消息操作与长提问收起 | [Work 消息:3192](/Users/crzhu/Projects/OpenLens/Marr/Presentation/AnswerPanel.swift) 缺少长提问折叠及逐条回答复制；Conversation 编辑入口依赖 hover | 每条回答有可发现的复制操作和反馈；长提问可展开/收起；编辑操作在键盘聚焦时可发现、可执行 |
| P1 | 共享视觉规则与窄窗操作优先级 | 已有字体、语义文字色、玻璃降级；[底栏:1878](/Users/crzhu/Projects/OpenLens/Marr/Presentation/AnswerPanel.swift) 仍为固定排列 | 统一间距、圆角、表面、边框、焦点和按钮状态；在 420pt 窗口、长模型名、运行/编辑/附件状态组合下，发送与停止始终可见，次要内容按明确顺序折叠 |
| P1 | 失败、限流和重试的完整状态 | 已有失败草稿 Restore/Discard、真实 runtime 重试提示及账户限额；尚无持久化待发队列与会话内重试倒计时 | 区分未发送、确认未知、正在重试和最终失败；保留输入与目标任务；仅对确认可重试的请求应用退避，未知是否已接收的任务先核实，避免重复执行 |
| P2 | 模型选择中的解释与资源反馈 | 模型和 effort 已接真实运行时；[模型弹层:1724](/Users/crzhu/Projects/OpenLens/Marr/Presentation/AnswerPanel.swift) 主要呈现名称与滑杆 | 展示运行时允许的档位及简洁说明；有当前任务上下文数据时才显示占用，缺数据明确标记未知；账户配额、累计用量与上下文占用分开 |
| P2 | 完整键盘路径及任务组织 | 已有补全键盘操作、按钮标签、项目分组和持久化 pin | 验证 Tab/方向键/Escape 的进入、选择、关闭与焦点返回；补充任务手动排序与持久化；VoiceOver、Full Keyboard Access、Reduce Motion/Transparency 覆盖关键状态 |

草稿持久化和重试互相关联，应先明确任务身份与确认状态，再设计自动重发。不能只持久化文本而遗漏附件、引用绑定和附件文件本身的生命周期。

## README 与实际组件逐项对照（初次审计）

以下为改动前基线。草稿、流式回答、附件、代码/diff、任务排序、环境光和弹簧的当前状态已经在实施结果中更新；独立扩展的适配边界仍成立。

| 参考能力 | Marr 状态 | 尚可借鉴／适配边界 |
| --- | --- | --- |
| [语义 tokens、表面与圆角][tokens] | 部分 | 字体角色、文字语义色和原生表面已有；跨页面间距、圆角、阴影和按钮状态尚未统一。学习层级关系，不必改成相同品牌色 |
| [按钮变体与状态][buttons] | 部分 | 已有原生按钮及业务禁用逻辑；样式分散，需要统一 hover、pressed、focus、disabled/loading 规则 |
| [分段切换][segmented] | 视觉等效 | Conversation/Work 有选中滑块和减少动效；尚需组内键盘行为验证。参考分段组件也没有实际接入独立 roving-focus hook |
| [活动、thinking dots、skeleton][indicators] | 活动反馈等效；其余未做 | 已有固定尺寸活动指示器和真实状态文案。骨架屏仅适用于确有固定结构的加载；不为未知回答制造虚构段落 |
| [确认弹窗][dialog] | 原生方式处理 | 沿用原生 sheet/alert 与真实操作流程；重点是键盘焦点返回与取消结果，不需要移植 DOM focus trap |
| [Composer、输入法和自动增高][composer] | 核心等效 | NSTextView 已处理 marked text、Return/换行、补全及稳定焦点；WebKit compositionend 的时间补丁不适用于原生编辑器 |
| [文件与指令引用][mentions] | 部分 | 已有 `/`、`@`、`$` 补全及真实引用处理；缺少统一可检查的可视上下文条、跨任务持久化。参考本身也是 textarea 加外置 chips，不是完整富文本编辑引擎 |
| [用户/助手消息层级][messages] | 部分 | 用户消息容器、助手 Markdown 和阅读列已有；逐条复制、长提问折叠、代码操作及 Conversation 增量渲染仍待补齐 |
| [推理折叠区][thinking] | 活动折叠部分等效；推理数据未完整接入 | Marr 展示进度消息与工具活动，尚无独立 reasoning 增量模型，不能将普通 commentary 称为模型推理。Marr 允许运行中折叠；参考强制展开并禁止收起不适合直接照搬到紧凑面板 |
| [模型与 token gauge][model]、[v2 effort][effort] | 模型/档位已有；解释与 gauge 未完成 | 继续以运行时返回的模型与档位为准。已有账户统计不等于当前上下文占用，不能照用样例的固定模型、默认 token 或固定 200k 容量 |
| [工具审批卡片][tool] | 真实业务已有，呈现可完善 | Marr 已连接真实审批、问题表单和结果状态；可强化工具名、权限范围、参数、失败及结果层级。参考使用定时器模拟成功，不应迁移该状态来源 |
| [滚动跟随][scroll] | 等效已有 | 上翻暂停、靠近底部重新跟随、Jump to latest、输出重排/窗口变化已有；48pt 与参考 40px 的阈值差异不算缺项 |
| [滚动边缘渐隐][fade] | 未做，P3 | 可作为溢出提示，但需保证首尾正文、选择内容和按钮不被遮挡；标题随滚动淡出不等同于此能力 |
| [用途化动效][motion]、[环境光][glow]、[v2 动效展示][motionv2] | 短过渡与减少动效已有；其余可选 | 可以统一控件按压、列表增删和弹层过渡。持续光晕、模糊吐字、大幅弹跳不是当前优先项；不将流式正文逐 token 动画 |
| [附件卡片][attachments] | 部分 | Work 可移除，已发送文件已有部分元数据；待发内容的逐项检查和图片预览仍不足。参考没有实现上传服务 |
| [媒体查看器][media]、[共享元素过渡][shared] | 部分 | Work 有图片查看/打开 Preview；Conversation 缩略图缺少大图入口。优先补原生预览，之后再考虑统一缩放、切换和过渡 |
| [Artifact 分栏][split] | 未做，P3 宽窗扩展 | 参考两栏最小宽度合计 800px，不能塞入默认 420pt 面板。可在宽窗口提供可调整分栏，窄窗保留详情弹层 |
| [Artifact iframe 桥][bridge] | 未做，独立能力 | 当前图片/链接预览不等于 HTML/MCP Apps 运行。需要完整隔离、消息授权和生命周期设计，不能以嵌入 WebView 视为完成 |
| [代码块][code]、[diff][diff] | 部分，P1 | 代码独立复制、语言标识和 diff 分段是直接收益。参考也无真正语法高亮，且 diff 按完整字符串重新解析，不是增量解析引擎 |
| [会话拖拽排序][sessions] | 部分，P2 | Marr 有真实项目分组、置顶和状态；缺少手动顺序与键盘重排。参考列表是本地演示状态，没有持久化 |
| [Cowork 多 Agent 面板][cowork] | 状态查看部分等效；编排另议 | Marr 已读取真实 agentsStates；可以借鉴卡片层级与详情入口。参考固定样例数据不提供真实委派和共享资产同步 |
| [提示音][audio]、[麦克风波形][mic] | 未做，P3 | 波形接收外部 MediaStream，不提供转写/对话服务。需先有真实语音链路；提示音需有用户偏好控制 |
| [桌面窗口][window]与标题栏 | 原生等效 | NSWindow、resize、材质和透明度降级已有；不需要 Electron 交通灯缩放补丁 |
| [响应工具栏][responsive]、[roving focus][focus] | 部分 | 根据当前最小窗口与原生控件重新制定折叠规则；完整键盘路径需要验证，不以添加标签代替 |
| [限流退避][backoff] | 部分 | 已显示 runtime 重试和账户限额；尚无结构化倒计时/恢复队列。退避策略须尊重服务端与任务确认状态，避免在 runtime 已重试时再开一层自动请求 |
| [v2 离线队列、独立聊天窗口、离线图表][v2features] | 多为未做，P0/P3 分开 | 队列恢复可优先；多聊天窗口、当前会话全文查找、交互图表是后续扩展。历史搜索已有，但不是当前对话内匹配定位 |
| [v2 compact/comfortable][density] | 未统一 | 可借鉴密度与有效点击区域分离的思路；不是必须添加两套用户设置。源码 CSS 与 v2 文档取值并不完全一致 |

## 参考本身尚未闭环的部分

以下内容不能算作“上游已提供，Marr 只差搬过来”：

1. [ChatComposerChin:22][chin] 只接收失败数量和重试回调，界面虽然写着本地已存储，但没有实现 IndexedDB 队列；附件与发送按钮也没有对应业务回调。
2. [McpToolDecisionCard:65][tool] 在允许后以 1.2 秒定时器设为 success；真实工具成败需要外部运行时驱动。
3. [ModelSwitcherWithTokenGauge:85][model] 带默认示例 token；缓存输入、累计用量、上下文窗口的语义需要重新核对，不能将默认仪表数值带入产品。
4. [DraggableSessionList][sessions] 与 [CoworkAgentCanvas][cowork] 使用演示数据，没有完整的存储、服务写回或多 Agent 通信。
5. [StreamingDiffViewer:136][diff] 每次 rawDiff 改变重算完整 diff，没有 README 描述的完整增量解析/worker 链路。
6. v2 描述的 [离线队列和多窗口][v2features] 主要是文档片段；[ChatComposerChin][chin] 和 [ModelSelectorEffort][effort] 的存在不代表底层能力已经完成。[v2 密度表][density] 也尚未完整体现在导出的主题 CSS。
7. [ClaudeMotionPresets:87][motion] 明确说明一组 spring 是作者自拟参数。参考中若干 README、注释和实现存在差别，不能笼统宣称采用“Claude 官方统一参数”。

本次未逐个复现参考组件的所有边界行为。因此，若实际移植算法，仍需验证拖拽、取消、焦点、授权和 Reduce Motion 等路径。MIT 许可允许使用；若复制实质代码，应保留其版权与许可声明。

## 验收与记录边界

初次审计没有重跑测试；2026-10-21 的实现使用新的包级及原生回归记录，不沿用此前的通过数。

本轮验证结果：

- 包级测试：**78 项通过，7 个 suite**。覆盖三种 provider 流式协议、真实首段回调、UTF-8/SSE 分片、限流退避、取消、部分输出保留及明确不支持 streaming 的回退。日志：`/tmp/marr-streaming-package-tests.log`。
- 原生相关回归：按每个用例最后一次运行结果去重，**336 项通过、2 项跳过、无剩余失败**，共 338 项。不是一次全仓库测试，也不表示下面三个结果包各自全部成功；较早运行的失败由后续相关组/单例修复验证覆盖。
- 两项跳过为显式启用的真实桌面登录推理及本地 app-server 集成检查。本轮没有实际请求线上模型，也没有操作真实系统权限。
- 原生窗口验证覆盖 A/B 任务与跨项目草稿、选区、附件和引用；420/720pt、明/暗主题、长模型名加四个附件的运行状态；实际发送/停止点击、模型弹层读取、Escape 关闭及原编辑器焦点返回。
- 环境光 fixture 的 20 个场景检查实际窗口及生产可见性观察器。运行态必须进入动态调度分支，窗口隐藏后停止；减少动态效果/透明度和高对比度分别验证。截图是原生视图渲染，不是逐帧 GPU 性能测量。
- 已查看代码/diff 明暗截图、实际 Work 窗口和 420pt 组合截图；工程文件校验与相关 `git diff --check` 通过。

本轮最终验证依据位于 `build/agent-ui/Logs/Test/`：

1. `Test-Marr-2026.10.21_00-43-39-+0800.xcresult`：全部十个相关测试组；其余八组完成验证，两个窗口用例继续修正 fixture。
2. `Test-Marr-2026.10.21_00-47-11-+0800.xcresult`：完整 Composer 与 Motion 两组；真实可见环境光、编辑器身份和选区验证通过，模型弹层组合单例继续修正。
3. `Test-Marr-2026.10.21_00-51-57-+0800.xcresult`：最终模型弹层与窄窗组合单例通过；四个明暗/宽度组合均验证 Escape、焦点、发送和停止。

截图保存在测试沙箱的 `marr-agent-ui-preview` 目录，也作为相关测试附件保留。独立 Motion fixture 用于验证同一编辑器和动效组件；`work-*` 截图才是实际 AnswerPanel，不能混称产品截图。

### Edit / Copy 视觉调优（2026-10-21 后续）

参考 [MessageActions][messages] 的轻量操作栏、hover/focus 反馈及短暂复制确认，
将 Edit 胶囊和文字 Copy 统一为 28pt 图标控件；提问操作靠右，回答靠左，
代码/diff 头部共用同一控件。保留可访问名称、tooltip、焦点轮廓与减少动态效果，
复制后仅图标切换成勾选，固定尺寸避免跳动。操作保持可发现，不完全依赖悬停。

本次相关原生回归 **11 项通过**，并检查消息操作组件及实际 Work 的明暗截图。
结果包：`Test-Marr-2026.10.21_01-09-11-+0800.xcresult`；日志：
`/tmp/marr-message-actions-ui-tests.log`。新增组件预览复用既有渲染用例，
不代表完整 VoiceOver 或线上模型测试。

实际玻璃窗口另使用已解析的明暗颜色和单色 SF Symbols，避免系统语义前景混色。
颜色调整后的两项渲染/流式窗口用例复查通过：
`Test-Marr-2026.10.21_01-11-47-+0800.xcresult`，日志
`/tmp/marr-message-actions-colors-tests.log`；已检查实际 Work 明暗截图。

优先场景：A/B 项目与任务草稿往返、未确认发送后重启、420pt 长模型名与附件组合、中文输入法、流式中断、长代码/diff、键盘全流程、浅色/深色及减少动效/透明度。

文件拖入、截图权限恢复、首次配置引导也值得改善，但应分别记录为 Marr 自身体验工作；不能仅因合理就声称来自本参考仓库的现成实现。

[tokens]: https://github.com/Caho1/open-claude-ui/blob/07caa0d695e066effaad4714acf087b0205b155e/code-examples/cds-theme.css#L89
[buttons]: https://github.com/Caho1/open-claude-ui/blob/07caa0d695e066effaad4714acf087b0205b155e/code-examples/CdsButton.tsx#L16
[segmented]: https://github.com/Caho1/open-claude-ui/blob/07caa0d695e066effaad4714acf087b0205b155e/code-examples/SegmentedControl.tsx#L77
[indicators]: https://github.com/Caho1/open-claude-ui/blob/07caa0d695e066effaad4714acf087b0205b155e/code-examples/StatusIndicators.tsx
[dialog]: https://github.com/Caho1/open-claude-ui/blob/07caa0d695e066effaad4714acf087b0205b155e/code-examples/ConfirmationDialog.tsx
[composer]: https://github.com/Caho1/open-claude-ui/blob/07caa0d695e066effaad4714acf087b0205b155e/code-examples/ChatComposer.tsx
[mentions]: https://github.com/Caho1/open-claude-ui/blob/07caa0d695e066effaad4714acf087b0205b155e/code-examples/RichComposerWithMentions.tsx
[messages]: https://github.com/Caho1/open-claude-ui/blob/07caa0d695e066effaad4714acf087b0205b155e/code-examples/ChatMessageBubbles.tsx
[thinking]: https://github.com/Caho1/open-claude-ui/blob/07caa0d695e066effaad4714acf087b0205b155e/code-examples/ThinkingAccordion.tsx#L39
[model]: https://github.com/Caho1/open-claude-ui/blob/07caa0d695e066effaad4714acf087b0205b155e/code-examples/ModelSwitcherWithTokenGauge.tsx#L85
[effort]: https://github.com/Caho1/open-claude-ui/blob/07caa0d695e066effaad4714acf087b0205b155e/code-examples/ModelSelectorEffort.tsx
[tool]: https://github.com/Caho1/open-claude-ui/blob/07caa0d695e066effaad4714acf087b0205b155e/code-examples/McpToolDecisionCard.tsx#L65
[scroll]: https://github.com/Caho1/open-claude-ui/blob/07caa0d695e066effaad4714acf087b0205b155e/code-examples/useClaudeScrollPinning.ts
[fade]: https://github.com/Caho1/open-claude-ui/blob/07caa0d695e066effaad4714acf087b0205b155e/code-examples/ScrollFadeContainer.tsx
[motion]: https://github.com/Caho1/open-claude-ui/blob/07caa0d695e066effaad4714acf087b0205b155e/code-examples/ClaudeMotionPresets.ts#L87
[glow]: https://github.com/Caho1/open-claude-ui/blob/07caa0d695e066effaad4714acf087b0205b155e/code-examples/ReasoningAmbientGlow.tsx
[motionv2]: https://github.com/Caho1/open-claude-ui/blob/07caa0d695e066effaad4714acf087b0205b155e/code-examples/CdsMotionEngine.tsx
[attachments]: https://github.com/Caho1/open-claude-ui/blob/07caa0d695e066effaad4714acf087b0205b155e/code-examples/AttachmentCard.tsx
[media]: https://github.com/Caho1/open-claude-ui/blob/07caa0d695e066effaad4714acf087b0205b155e/code-examples/MediaLightboxViewer.tsx
[shared]: https://github.com/Caho1/open-claude-ui/blob/07caa0d695e066effaad4714acf087b0205b155e/code-examples/useClaudeSharedElementTransition.ts
[split]: https://github.com/Caho1/open-claude-ui/blob/07caa0d695e066effaad4714acf087b0205b155e/code-examples/ArtifactsSplitPaneResizer.tsx#L38
[bridge]: https://github.com/Caho1/open-claude-ui/blob/07caa0d695e066effaad4714acf087b0205b155e/code-examples/EpitaxyIframeBridge.tsx
[code]: https://github.com/Caho1/open-claude-ui/blob/07caa0d695e066effaad4714acf087b0205b155e/code-examples/CodeBlock.tsx
[diff]: https://github.com/Caho1/open-claude-ui/blob/07caa0d695e066effaad4714acf087b0205b155e/code-examples/StreamingDiffViewer.tsx#L136
[sessions]: https://github.com/Caho1/open-claude-ui/blob/07caa0d695e066effaad4714acf087b0205b155e/code-examples/DraggableSessionList.tsx
[cowork]: https://github.com/Caho1/open-claude-ui/blob/07caa0d695e066effaad4714acf087b0205b155e/code-examples/CoworkAgentCanvas.tsx#L47
[audio]: https://github.com/Caho1/open-claude-ui/blob/07caa0d695e066effaad4714acf087b0205b155e/code-examples/ClaudeAudioPlayer.ts
[mic]: https://github.com/Caho1/open-claude-ui/blob/07caa0d695e066effaad4714acf087b0205b155e/code-examples/LiveMicActivityBars.tsx
[window]: https://github.com/Caho1/open-claude-ui/blob/07caa0d695e066effaad4714acf087b0205b155e/code-examples/createClaudeMainWindow.ts
[responsive]: https://github.com/Caho1/open-claude-ui/blob/07caa0d695e066effaad4714acf087b0205b155e/code-examples/ContainerResponsiveBar.tsx
[focus]: https://github.com/Caho1/open-claude-ui/blob/07caa0d695e066effaad4714acf087b0205b155e/code-examples/useClaudeRovingFocus.ts
[backoff]: https://github.com/Caho1/open-claude-ui/blob/07caa0d695e066effaad4714acf087b0205b155e/code-examples/useRateLimitBackoff.ts
[chin]: https://github.com/Caho1/open-claude-ui/blob/07caa0d695e066effaad4714acf087b0205b155e/code-examples/ChatComposerChin.tsx#L22
[v2features]: https://github.com/Caho1/open-claude-ui/blob/07caa0d695e066effaad4714acf087b0205b155e/docs/v2/02-新增特性深度逆向.md
[density]: https://github.com/Caho1/open-claude-ui/blob/07caa0d695e066effaad4714acf087b0205b155e/docs/v2/03-架构重构与对比分析.md#L77

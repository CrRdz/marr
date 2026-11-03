# Codex CLI 命令与补全兼容审计

核对日期：2026-10-16。基线：`openai/codex` main 的提交 [`6ae8b8aa7c608730d4315d59c5c081897ae02780`](https://github.com/openai/codex/commit/6ae8b8aa7c608730d4315d59c5c081897ae02780)。这是一份能力边界清单，不表示整个 CLI 已全量移植。

主要依据：

- [内置命令枚举、运行态及参数元数据](https://github.com/openai/codex/blob/6ae8b8aa7c608730d4315d59c5c081897ae02780/codex-rs/tui/src/slash_command.rs)
- [命令查找、别名、功能开关、动态服务等级](https://github.com/openai/codex/blob/6ae8b8aa7c608730d4315d59c5c081897ae02780/codex-rs/tui/src/bottom_pane/slash_commands.rs)
- [命令实际分发及参数处理](https://github.com/openai/codex/blob/6ae8b8aa7c608730d4315d59c5c081897ae02780/codex-rs/tui/src/chatwidget/slash_dispatch.rs)
- [编辑器及新版 mention 菜单](https://github.com/openai/codex/blob/6ae8b8aa7c608730d4315d59c5c081897ae02780/codex-rs/tui/src/bottom_pane/chat_composer.rs)
- [光标附近 token 与 shell 变量排除](https://github.com/openai/codex/blob/6ae8b8aa7c608730d4315d59c5c081897ae02780/codex-rs/tui/src/bottom_pane/chat_composer/completion_target.rs)

## 完整静态命令目录

上游枚举共 65 项，保持其菜单顺序。表中“参数”和“运行时”是上游元数据，**并不表示本客户端已实现所有参数形式**。本客户端分类：RPC = 控制器调用真实 app-server/本地状态；界面 = 本客户端菜单操作；CLI = 本轮未接入，显示原因并保留输入，不能发送普通模型请求冒充执行。CLI 类也包含尚未移植的通用能力，并非声称这些功能只能在终端实现。服务器/账号/功能开关仍可拒绝标为 RPC 的能力。

| 命令 | 别名 | 上游行内参数 | 上游运行中可用 | 本客户端 | 边界 |
| --- | --- | --- | --- | --- | --- |
| /model | — | 是 | 是 | 界面 | 无参数打开选择器；有参数由 runtime 校验已发现的模型/推理强度。 |
| /presets | — | 否 | 是 | CLI | 管理可复用提示词；本轮未接入。 |
| /daybreak | — | 否 | 是 | CLI | 切换 Daybreak；本轮未接入。 |
| /ide | — | 是 | 是 | CLI | 添加 IDE 上下文；本轮未接入。 |
| /permissions | — | 是 | 是 | CLI | 设置操作权限；本轮未接入。 |
| /keymap | — | 是 | 否 | CLI | 配置终端快捷键；本轮未接入。 |
| /vim | — | 否 | 否 | CLI | 切换 Vim 输入；本轮未接入。 |
| /setup-default-sandbox | — | 否 | 否 | CLI | 配置增强沙箱；本轮未接入。 |
| /experimental | — | 否 | 否 | CLI | 实验功能；本轮未接入。 |
| /approve | — | 否 | 是 | CLI | 重试自动审批拒绝的操作；本轮未接入。 |
| /memories | — | 否 | 否 | CLI | 配置记忆；本轮未接入。 |
| /skills | — | 否 | 是 | 界面 | 打开设置中的 Skills；用 $name 显式引用选定路径。 |
| /import | — | 否 | 否 | CLI | 导入 Claude Code 配置与历史；本轮未接入。 |
| /hooks | — | 否 | 是 | CLI | 管理生命周期 Hooks；本轮未接入。 |
| /review | — | 是 | 否 | RPC | review/start；无参选未提交修改。base/commit/custom 前缀是本客户端扩展，见下文。 |
| /rename | — | 是 | 是 | RPC | thread/name/set；需要名字和当前线程。 |
| /new | — | 是 | 否 | 界面 | 本客户端新任务；不保证上游 inline 参数的全部语义。 |
| /archive | — | 否 | 是 | 界面 | 线程归档；本客户端等待运行回合结束。 |
| /delete | — | 否 | 否 | CLI | 永久删除任务；本轮未接入。 |
| /resume | — | 是 | 是 | 界面 | 打开本地历史选择后按线程 ID 恢复；运行时禁止切换，尚不支持行内参数或按名字恢复。 |
| /fork | — | 是 | 否 | 界面 | 当前线程分叉；尚未声明 inline 参数兼容。 |
| /worktree | — | 否 | 否 | CLI | 在新工作树继续任务；本轮未接入。 |
| /app | — | 否 | 是 | CLI | 转到 Codex 桌面应用；本轮未接入。 |
| /init | — | 否 | 否 | CLI | 生成 AGENTS.md；本轮未接入。 |
| /compact | — | 否 | 否 | RPC | thread/compact/start；需要空闲线程。 |
| /config | — | 否 | 否 | 界面 | 本客户端设置；不是 Codex 全部 config.toml 参数编辑器。 |
| /recap | — | 否 | 否 | CLI | 生成当前会话摘要；本轮未接入。 |
| /plan | — | 是 | 否 | RPC | 使用 collaborationMode=plan；任意行内文本均作为计划提示词。 |
| /voice | — | 是 | 是 | CLI | 语音会话与设置；本轮未接入。 |
| /goal | gooo…al（任意多个 o） | 是 | 是 | RPC | thread/goal/get、set、clear；无参或 edit 打开目标编辑器。 |
| /agents | — | 否 | 是 | CLI | 打开代理管理中心；本轮未接入。 |
| /side | — | 是 | 是 | CLI | 开始临时分支对话；本轮未接入。 |
| /btw | — | 是 | 是 | CLI | 开始临时分支对话；本轮未接入。 |
| /copy | — | 否 | 是 | 界面 | 复制最近回复；尚未支持上游的部分内容选择菜单。 |
| /export | — | 是 | 否 | 界面 | 本客户端 Markdown 导出；尚未声明上游任意路径参数兼容。 |
| /raw | — | 是 | 是 | CLI | 切换终端原始滚动模式；本轮未接入。 |
| /tui | — | 否 | 否 | CLI | 设置下次启动的终端界面；本轮未接入。 |
| /diff | — | 否 | 是 | 界面 | 显示本客户端读取/接收的 diff；不等同于完整 git diff 含未跟踪文件。 |
| /mention | — | 否 | 是 | 界面 | 激活文件引用补全。 |
| /status | — | 否 | 是 | RPC | 当前线程及本地连接状态；不保证上游所有 token/配置字段。 |
| /daemon | — | 否 | 是 | CLI | 管理后台服务；本轮未接入。 |
| /warnings | — | 否 | 是 | RPC | 本客户端保留的能力/连接诊断。 |
| /cd | — | 是 | 否 | CLI | 切换工作目录；本轮未接入。 |
| /pwd | cwd | 是 | 是 | RPC | 显示所选工作区路径；cwd 为同义命令。 |
| /usage | — | 是 | 是 | CLI | 查看额度与重置时间；本轮未接入。 |
| /debug-config | — | 否 | 是 | CLI | 检查配置来源；本轮未接入。 |
| /title | — | 是 | 是 | CLI | 配置终端标题；本轮未接入。 |
| /statusline | — | 是 | 是 | CLI | 配置终端状态栏；本轮未接入。 |
| /theme | — | 否 | 否 | 界面 | 本客户端外观设置；不是终端语法高亮主题列表。 |
| /pets | pet | 是 | 否 | CLI | 选择终端宠物；本轮未接入。 |
| /mcp | — | 是 | 是 | 界面 | 设置中的 MCP；login <name> 走真实 OAuth 登录。 |
| /apps | — | 否 | 是 | 界面 | 设置中的 Apps。 |
| /plugins | — | 否 | 是 | 界面 | 设置中的插件列表/安装能力。 |
| /logout | — | 否 | 否 | CLI | 退出 Codex 登录；本轮未接入。 |
| /quit | — | 否 | 是 | CLI | 终端退出；不会偷偷退出宿主 macOS app。 |
| /exit | — | 否 | 是 | CLI | 终端退出；不会偷偷退出宿主 macOS app。 |
| /feedback | — | 否 | 是 | CLI | 向维护者发送诊断；本轮未接入。 |
| /rollout | — | 否 | 是 | CLI | 上游 debug 构建专属，普通补全不显示。 |
| /ps | — | 否 | 是 | CLI | 列出后台终端；本轮未接入。 |
| /stop | clean | 否 | 是 | CLI | 停止所有后台终端；绝不映射为中断当前模型回合。 |
| /clear | — | 是 | 否 | 界面 | 清空本客户端任务视图并新建任务；没有终端 scrollback。 |
| /test-approval | — | 否 | 是 | CLI | 上游 debug 构建专属，普通补全不显示。 |
| /subagents | — | 否 | 是 | CLI | 切换子代理；本轮未接入。 |
| /debug-m-drop | — | 否 | 否 | CLI | 上游标记调试专用，不执行。 |
| /debug-m-update | — | 否 | 否 | CLI | 上游标记调试专用，不执行。 |

上游的 `/exit` 与 `/quit`、`/side` 与 `/btw` 是独立枚举项，行为接近但没有被去重。明确别名是 `/cwd` → `/pwd`、`/pet` → `/pets`、`/clean` → `/stop`，另有任意多个 `o` 的 `/gooo…al` → `/goal`。命令本身大小写行为以实际 dispatcher 为准；目录查找保持上游的小写名称。

## 功能开关、动态命令与运行状态

- 上游目录受 Plan、Apps、Plugins、Usage、Goals、Voice、Worktrees、Daybreak、增强沙箱等开关过滤。`rollout`、`test-approval` 只在 debug 构建可见；`app` 只在 macOS/Windows 可见；`copy` 在 Android 隐藏。
- 模型可以在 `/model` 后提供动态 service-tier 命令（例如 `fast`；名字与能力来自模型服务，而不是固定枚举）。本客户端尚未接入该动态目录。Presets、自定义提示词也不能用这 65 项静态目录声称兼容。
- 上游 `/review` 还在 dispatcher 校验线程状态，不能先消耗草稿再发现无法执行。本客户端应保留拒绝/失败时的输入。
- 本客户端额外在运行期间禁用 `/resume` 和 `/archive`，避免切走拥有活跃回合的线程。其它具体命令还会验证连接、选择、线程可写状态。
- 上游 side conversation 只允许 `copy agents export raw diff mention status daemon warnings pwd usage ide`；本客户端尚未提供这一临时分支运行模式。
- 上游不可写线程可用白名单是 `new clear resume agents subagents quit exit status warnings debug-config pwd rollout copy raw`，仍要求服务连接。本客户端尚未声称覆盖整个不可写线程状态机。

## 参数兼容和明确扩展

- `/help` 与 `/default` 是明确标记的本客户端命令，不在上游 65 项中。`/default` 退出 Plan，且要求当前回合结束。
- `/plan <文本>` 按上游切入 Plan 并提交该文本；`/plan off`、`/plan on` 分别提交正文 `off`、`on`，不能改写为模式开关。
- 上游 `/goal` 无参打开目标菜单；`clear/edit/pause/resume` 是保留控制词，其余内容是目标正文。本客户端无参或 `edit` 打开状态/目标编辑界面，并提供暂停、恢复、清除操作。`/goal status` 的目标就是 `status`；`--token-budget N` 作为目标正文保留，不能偷偷转换为预算。上游预算通过目标编辑器设置，本轮尚无预算编辑控件；替换现存目标的确认流程仍需保持与上游一致。
- 上游 `/review <文本>` 把全部文本视为自定义审查要求。本客户端 `base <branch>`、`commit <sha>`、`custom <text>` 为调用结构化 review target 的扩展；不能让用户误以为上游以相同规则解析这些前缀。
- `thread/goal/set` 的 active goal 可以立即注入目标或启动空闲回合；客户端不能再补发一个 `turn/start`。见 [goal 服务端处理](https://github.com/openai/codex/blob/6ae8b8aa7c608730d4315d59c5c081897ae02780/codex-rs/app-server/src/request_processors/thread_goal_processor.rs) 与 [CLI 目标控制](https://github.com/openai/codex/blob/6ae8b8aa7c608730d4315d59c5c081897ae02780/codex-rs/tui/src/app/thread_goal_actions.rs)。
- `supportsInlineArguments` 只记录上游元数据；它不是本地参数解析器，也不是允许丢弃未知参数的理由。界面命令遇到尚未支持的参数应清楚拒绝并保留草稿。

## @ 文件、$ Skills 的真实含义

上游开启 `mentions_v2` 时，`@` 同时搜索插件、文件和 Skills；如果插件已展示，会隐藏属于该插件的 Skills。`$` 搜索单个 Skills 与 Apps，不含插件。关闭该开关恢复旧行为：`@` 只有文件，`$` 额外包含插件。因此“@ 只能文件、$ 只能 Skills”不是当前上游的全量行为。

本轮实现限定为 **@ 工作区文件与 $ 已发现 Skills**，其它 mention 类型仍是明确缺口。Skill 候选用真实路径作为身份，不能只把名字插入文本而丢失所选路径；文件候选身份使用完整路径，显示可用相对路径；包含空格或标点的文件名以引号引用。相同 Skill 名字但不同路径不可折叠成一个候选。

上游文件选择后会把 `@token` 替换为普通文件路径（有空格时加引号），图片则走图片附件路径；文件不是 `UserInput::Mention`。该结构化类型在 CLI 提交器中用于 `app://`、`plugin://`，Skills 使用独立的 `UserInput::Skill`。本客户端即使界面保留 `@` 标记，提交也必须包含真实可读路径，不能认为一个 schema 合法的 filesystem `mention` 就等于已传入文件。见 [CLI input_submission.rs](https://github.com/openai/codex/blob/6ae8b8aa7c608730d4315d59c5c081897ae02780/codex-rs/tui/src/chatwidget/input_submission.rs)。

本地纯模型层提供以下确定性约束：

- 以 NSTextView 的 UTF-16 光标坐标查找 token，支持中文、组合字符、emoji；只用光标之前的词片段筛选，同时替换整个 token，以保留正文和后缀。
- `/` 仅在草稿第一行的起始命令位置触发；`@/$` 必须位于词边界，邮箱、URL、反斜线转义和 Markdown 行内/围栏代码不触发。
- `$HOME`、`$PATH` 等上游常见环境变量，纯数字位置参数、`${…}`、`$(…)` 等 shell 形式不触发；`$home`、`$plugin:skill` 可搜索。
- 支持引号文件名；替换后复用一个横向空白或增加一个空格，绝不把光标移入下一行。异步候选对应的原 token 已变化时拒绝替换。
- 匹配顺序为完全匹配、前缀、路径/词段前缀、包含、子序列；大小写和音调不影响搜索，同分排序稳定，同一路径去重。

仍未复制上游的所有编辑器细节：跨同一行分隔空白的双侧候选仲裁、atomic text element 硬边界及绑定历史编码、按 token occurrence 精确记忆 Escape、shell `!` 模式、提示词粘贴占位符、Tab 活跃回合队列、Vim 与终端键映射。原生编辑器必须继续让输入法组合输入先处理 Return/Escape/方向键。

## 验证

`MarrTests/Conversation/AgentComposerSupportTests.swift` 的 14 项确定性回归覆盖全部静态目录、别名、支持边界、光标中间替换、UTF-16、邮箱/URL、代码、shell、带空格/引号的文件名、保留换行、陈旧候选、排序去重与忙状态。纯模型独立 XCTest 已通过；界面和 runtime 集成由应用测试验证。

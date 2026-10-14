# Marr 产品网站

启动：`python3 -m http.server 42861 --directory website/dist --bind 127.0.0.1`。

本地预览：http://127.0.0.1:42861/ 。独立演示：http://127.0.0.1:42861/demo/index.html 。线上地址：https://marr.crrdz.com/ 。

## 部署

`.github/workflows/website.yml` 使用 GitHub Actions 发布到 GitHub Pages。PR 运行资源完整性、JavaScript 语法和交互逻辑测试；`main` 上的网站变更通过检查后自动部署，也可以在 Actions 的 Website 工作流中手动运行。

发布目录为 `website/dist`，不包含开发截图、测试代码或旧视频。网站无需构建依赖、服务端或额外部署密钥，使用 GitHub 提供的短期令牌。

仓库 Settings → Pages 的 Source 为 GitHub Actions，Custom domain 为 `marr.crrdz.com`。Spaceship 中为 `marr` 配置 CNAME 指向 `crrdz.github.io`，不带协议或路径；GitHub 签发证书后启用 Enforce HTTPS。自定义 Actions 部署的域名绑定以 Pages 设置为准，单独修改 CNAME 文件不会修改 GitHub 的绑定。

本地部署前检查：`python3 website/scripts/check_site.py` 与 `node --test website/tests/*.test.cjs`。

## 页面结构

- 宽幅阅读主窗与较小的 Marr 对话窗，首屏尺寸随视口高度调整。
- 三张横向亮点卡片；支持触控滚动、前后按钮、分页点和方向键。默认不自动播放。
- 截图翻译与 Capture & Ask 共用同一块演示画面：框选 → 原位翻译 → Original 对照 → 提问 → Conversation。桌面随滚动推进和回看，每个动作完成后留出阅读时间；也可直接选择步骤或播放。
- ONE MORE THING 交叉淡入 Work，随后演示选择 → 方框 → 箭头 → Work 任务与文件变更卡片。已合并原先重复的 Work 介绍段落。

配色与交互依据见 [Apple 页面研究](design/apple-study.md)。Apple 图片、商标与产品素材未用于页面。使用白/浅灰/近黑的中性色，蓝色用于操作，红色用于截图标注。

## 实现

`dist/story.js` 管理图集、章节和滚动。页面不拦截滚轮或劫持滚动。此前 55vh 的固定停留与最长 20.7 秒的自动播放互不对应；本轮改为让固定画面的滚动距离推进演示内容。

- 宽度至少 541px、高度至少 700px，且未开启减少动态效果时，翻译与提问章节为 350svh，Work 为 300svh。541–700px 的窄桌面窗口会按可用高度适配画布。100svh 的画面固定在顶部，滚动位置决定当前步骤和动作进度；向上滚动可以回看。
- `dist/scroll-timeline.js` 提供纯函数进度映射：首尾各保留约 5% 停顿，中间均分步骤，每步后段保留阅读时间。分页直接切换当前画面，不移动整页；显式分页或播放取得控制权，后续滚动和响应式切换不会覆盖该选择。点击“跟随滚动”恢复滚动驱动。
- 宽度不超过 540px 的手机与矮屏使用自然文档流和显式播放，不在进入视野时自动播放。播放在可见比例不足 55% 或进入后台时暂停计时，结尾停止；已完成步骤接播进入下一步，不从该步骤开头倒退。
- 手动框选、输入和拖动停止外部演示同步；离开章节、返回或调整窗口尺寸仍保留手动状态。点击“返回演示”、分页或播放才主动退出操作。
- ONE MORE THING 使用 165svh 的桌面过场，从标题过渡到 Work；手机与减少动态效果时按文档顺序展示。图集保持原生横向手势，纵向滚轮继续浏览页面。

系统减少动态效果时取消固定滚动及过渡动画，保留显式播放与全部步骤访问。该分支本轮通过 CSS 和代码审查，未做浏览器模拟实测。

`dist/demo/` 以 1000×700 逻辑画布呈现产品；`product=1` 使用透明背景并隐藏模拟菜单栏。阅读窗 570×492；对话窗保留 420×596 的内部坐标并以 .78 等比呈现为约 328×465。手机端固定 166% 的画面比例，只平移到当前文档或回答窗口，避免切换时同时缩放和平移；舞台使用 `overflow: clip`，避免输入框获得焦点时浏览器产生内部滚动。Original 可以拖动，四角等比缩放整个窗口；方向键移动，加减键缩放，Esc 重置。

`dist/demo/capture-layout.js` 联合计算工具栏与输入条位置，保留原有按钮尺寸，并保持至少 12 点间隔。父页面把实际可见画布范围传入演示，避免手机裁切或控件伸入分页区。Original 初始位置避开 Compare，拖动与缩放受可见范围约束；选择标注工具会收起截图预览。

翻译、Conversation 回答及 Work 的任务、代码文件和结果均为本地预设；演示不请求 AI、不上传截图、不修改项目文件。框选、方框、箭头、编号、画笔、撤销、拖拽、缩放与表单输入为实际浏览器交互。Work 的结果卡片样式以实际 CodexActivityTimeline 为依据。

## 产品 UI 依据

- `Marr/TranslationOverlay.swift`：译文保留 anchorRect；原文窗口候选位置左、右、上、下；Compare 为 104×32。网页按用户要求去掉缩放胶囊，改为拖角调整窗口。
- `Marr/ScreenshotOverlay.swift`：42 点圆形按钮，8 点间距；46 点高、23 点圆角的输入条；38×30 截图缩略图；白/黑双层选区描边。
- `Marr/AnswerPanel.swift`：420×596 窗口、24 点圆角、356 点输入区、16 点底部间距、Conversation / Work 与 CodexActivityTimeline。
- `Marr/ScreenshotAnnotation.swift`：红色标注、3 点线宽、26 点编号圆。

## 本轮验证

- `node --test website/tests/scroll-timeline.test.cjs website/tests/capture-layout.test.cjs`：21 项通过。
- 进度测试 11 项：正反向滚动、分页定位的正反映射、首尾停顿、完成步骤接播、多步推进、末尾停止、可见比例与浏览器全局导出。
- 布局测试 10 项：包含 1600 组位置/尺寸组合、桌面和手机裁切、最小可见范围、控件避让及 Original 比例。
- 浏览器实测尺寸：1440×900、592×828 与 375×812，检查桌面滚动推进、分页与手动交互、手机自然文档流及窗口切换。
- 减少动态效果：仅审查对应 CSS 与状态切换逻辑，未声称浏览器实测。

此前已验证的产品交互包括小选区和底部控件避让、截图预览收起、箭头绘制、Original 拖动与等比缩放、输入条发送及 Work 结果展示。

旧视频脚本与素材仅供稿件追溯，当前页面不引用旧模拟视频。

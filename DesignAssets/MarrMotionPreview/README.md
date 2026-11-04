# Marr 原生 Rive 动效试作

独立预览，2026-10-31。使用 Rive CLI 1.8.0 创建，未接入 App 或官网。

双击 `preview.command` 打开原生交互窗口，点击底部按钮切换：

- **Idle**：4 秒循环，轻微上下悬浮及呼吸。
- **Hello**：4 秒循环，轻压缩后跳起、回弹，余下时间停留。
- **Thinking**：3 秒循环，小幅左右倾斜，三点依次明暗变化。
- **Still**：静止姿态。可用预览窗口的暂停命令冻结任意当前帧。

本次 CLI 装在 `/tmp/marr-rive-tools`，未修改 shell 配置。临时目录清理后，可安装官方 Rive CLI，再运行启动器。

## 文件和编辑

`scene.rml` 是可继续编辑的原生 Rive 场景，包括四条关键帧时间线、状态机、可访问按钮和数据绑定。`rive.yaml` 是项目入口。`assets/glass-companion.png` 是当前批准母图的逐字节副本：保留高光、透明度及眼睛，动画只作用于整个图层。尚未拆分眼睛或制作独立眨眼。

`assets/Inter.ttf` 来自官方 Rive CLI 1.8.0 的 `text_island` 示例，仅用于预览文字。Inter 使用 SIL Open Font License，见 `assets/Inter-OFL.txt`。

`MarrMotion.mood` 数值为 0=Idle、1=Hello、2=Thinking、3=Still。Hello 在此试作中循环演示；产品接入时应改成单次触发并自动返回 Idle。

`build/MarrMotionPreview.riv` 是本地构建的原生文件（未签名、无脚本），包含整个预览界面。可编辑源文件是本目录的 RML/YAML；尚未导出编辑器 `.rev` 或上传到 Rive 账号。产品用的独立透明组件及目标运行库兼容性需在实际接入时另行整理和验证。

## 验证

- `rive . --verify`：0 errors，0 warnings。
- `rive inspect . --summary`：`problems: []`，4 条时间线，1 个状态机，4 个交互按钮。
- 通过原生 Metal 渲染查看 Idle、Hello、Thinking、Still。
- 点击 Hello、Thinking 后读取 mood=1/2；通过语义操作 Still 读取 mood=3；从 Thinking 点击 Idle 读取 mood=0。
- 静态模式供手动选择；此独立预览尚未自动读取系统减少动态效果设置。

录制文件保存在 `../../output/marr-motion-preview/`：GIF 和 MP4 均由本项目原生 Rive 渲染帧编码，按 Idle → Hello → Thinking 顺序演示。

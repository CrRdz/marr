# MarrModules

可独立构建、测试的基础模块。应用通过库产品链接这些模块，包内不导入 AppKit 或 SwiftUI，也不反向引用应用类型。

| 模块 | 职责 | 包内依赖 |
| --- | --- | --- |
| `MarrCore` | 会话、附件、推理连接、历史与存储的基础模型 | 无 |
| `MarrText` | Markdown 块解析、代码高亮与预览、diff 解析与配对、文本分行 | 无；使用 Foundation / CoreGraphics 几何类型 |
| `MarrNetworking` | HTTP 传输、推理协议适配、流事件、账户授权、翻译网关 | `MarrCore` |
| `MarrPersistence` | 对话和工作区持久化、附件存储、空间扫描 | `MarrCore` |
| `MarrSettings` | 推理设置与凭据存储 | `MarrCore` |

`MarrText` 返回数据与布局结果，不创建窗口或执行绘制。`MarkdownLineLayout` 通过宽度测量闭包接收外部排版度量，因此不需要知道应用字体或 SwiftUI 布局。

```sh
swift test --package-path Packages/MarrModules
swift test --package-path Packages/MarrModules --filter MarrTextTests
```

新增功能的归属原则：

- 不依赖应用生命周期、有明确输入输出且可独立测试的逻辑，放入对应包模块。
- 依赖窗口、焦点、系统截图、权限或具体界面状态的代码，留在 `Marr/` 的功能目录。
- 通用逻辑不通过导入应用模块复用类型；先明确模块拥有的数据与 API。
- 模块扩展已有职责时增加源文件。只有职责与依赖边界确实独立时，才新增 target。

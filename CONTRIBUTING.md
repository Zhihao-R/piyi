# 参与开发

## 从源码编译

要求：macOS 26 以上，Xcode 26（带 Swift 6 工具链），Node.js（编译浏览器扩展）。

```sh
./scripts/build_app.sh   # 正式版，生成 build/拼贴.app
swift run Collage        # 调试版
swift test               # 自动测试
```

调试版要先 `swift build`（不只是 `swift run Collage`），扩展的中转程序才会编译出来。

资料库在 `~/Library/Application Support/Collage/`。启动时设环境变量 `COLLAGE_ROOT=<目录>` 可以换一个资料库目录，试「新装用户第一次打开」时用。

## 代码分块

| 块 | 负责 | 可以调用 |
|---|---|---|
| `Library` | 资料库、内容抽取 | 无 |
| `Intelligence` | 模型接入、理解、搜索、灵感、分拣、讨论 | `Library` |
| `Canvas` | 画布、卡片呈现 | `Library`、`Tokens` |
| `Collage` | App：界面外壳、收集入口、放大查看 | 以上全部 |
| `Tokens` | 设计数值：间距、动效时长、颜色、字号，只有数字 | 无 |
| `Wire` | App、扩展中转程序、扩展之间的消息格式和连接 | 无 |

另有两个独立的程序：扩展的中转程序 `CollageRelay`（由浏览器启动，只用 `Wire`），浏览器扩展本身 `Extension/`（TypeScript，`npm run build` 打包，正式版打包脚本会自动做）。

`Package.swift` 按上表写明依赖，编译器会挡住反方向的调用。三处特意的安排：

- **画布和智能互相看不见。** 搜索给出一串卡片编号，由 App 交给画布去聚拢。
- **抽取要用模型，但 `Library` 不能调 `Intelligence`。** `Library` 只写明它需要的能力（判断抓回来的是不是登录页、抓不到时让模型兜底、转录音视频），App 启动时把 `Intelligence` 的实现交给它。需要反方向的能力时都这样做：在下层写协议，由 App 注入实现。
- **设计数值单独成块，只放数字。** 画布用 Core Animation 画卡片，其余界面用 SwiftUI，两边用同一套数值。

**收集流程**由 App 里的收集协调者（`Collector`）按这个顺序调各块：

1. 收的是网址，先按网址查重。
2. 画布按落点给占位卡找空位，`Library` 写入占位卡，卡片马上出现。
3. `Library` 抽取内容，按内容指纹查重，存文件。
4. 按抽到的内容定最终尺寸，一次写入这批摆放。
5. 卡片进入理解队列。

## 写代码的规矩

- **画布上不给每张卡配真控件。** 卡片平时是一张画好的图层，只有正在编辑文字的那一张临时盖一个文本框；悬停、选中只改那一张的边框。
- **主线程只做界面。** 解码图片、画卡片位图、读写数据库、算向量、调模型都在后台。视野内马上要显示的用 `.userInitiated`，算向量、调模型、生成缩略图用 `.utility`。
- **所有模型调用只走模型接入一个出口**（`Intelligence/Models/Gateway.swift`）。
- **测试写在逻辑容易错、又不靠肉眼判断的地方**：数据库操作、查重、网格吸附、查询解析、抽取器的输出。用 Swift Testing。

## 联网和真实模型的检查

平时的 `swift test` 不联网、不调模型。下面几项要手动打开：

```sh
OPENROUTER_API_KEY=… swift test --filter RealCloud   # 用真实云端理解一张图，确认请求格式没坏
SUBTITLE_CHECK=1 swift test --filter SubtitleCheck    # 取一条 YouTube 视频的字幕，平台改版时它先失败
```

## 示例画板

新装时放进「示例」画板的素材在 `Sources/Collage/Resources/Seed/`，清单是 `manifest.json`，每项可以带位置、宽高和旋转。想重新摆：在 App 里把示例画板摆好，再运行

```sh
python3 scripts/seed_export.py "画板名"
```

把位置写回清单。素材的许可见 `THIRD_PARTY_NOTICES.md`，新加的素材必须能随 App 自由分发。

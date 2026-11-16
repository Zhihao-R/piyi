// swift-tools-version: 6.0
import PackageDescription

// 分块和依赖方向见 CONTRIBUTING.md：编译器只允许按下面写明的方向调用
let package = Package(
    name: "Piyi",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.9.0"),
    ],
    targets: [
        // 设计数值：只有数字
        .target(name: "Tokens"),
        // App 和扩展中转程序之间的消息格式
        .target(name: "Wire"),
        // 资料：资料库、内容抽取
        .target(
            name: "Library",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("Resources/Readability.js"), .copy("Resources/Readability-LICENSE.md")]
        ),
        // 智能：模型接入、理解、搜索、灵感
        .target(name: "Intelligence", dependencies: ["Library", "llama"]),
        // llama.cpp 官方预编译包，本机向量模型用它跑
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11191/llama-b11191-xcframework.zip",
            checksum: "c8f9af07555a15b00a87334e13a21320596178c58bbafa2d7c4915c574e7086e"),
        // 画布：画布、卡片呈现
        .target(name: "Canvas", dependencies: ["Library", "Tokens"]),
        // App：界面外壳、收集入口、放大查看
        .executableTarget(
            name: "Piyi",
            dependencies: ["Library", "Intelligence", "Canvas", "Tokens", "Wire"],
            resources: [.copy("Resources/Seed")]
        ),
        // 扩展的中转程序：由浏览器启动，在扩展和 App 之间转发消息
        .executableTarget(name: "PiyiRelay", dependencies: ["Wire"]),
        .testTarget(name: "LibraryTests", dependencies: ["Library"]),
        .testTarget(name: "CanvasTests", dependencies: ["Canvas", "Library"]),
        .testTarget(name: "IntelligenceTests", dependencies: ["Intelligence", "Library"]),
        // 依赖中转程序只为让 swift test 先把它编译出来：测试像浏览器一样启动它
        // 资料块：扩展收的东西从中转程序一路走到资料库的测试要用
        .testTarget(name: "WireTests", dependencies: ["Wire", "PiyiRelay", "Library"]),
    ]
)

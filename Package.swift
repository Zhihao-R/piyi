// swift-tools-version: 6.0
import PackageDescription

// See CONTRIBUTING.md for the modules and dependency directions: the compiler only allows calls in the directions written below
let package = Package(
    name: "Piyi",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.9.0"),
    ],
    targets: [
        // Design values: numbers only
        .target(name: "Tokens"),
        // Message format between the App and the extension relay
        .target(name: "Wire"),
        // Library: the library, content extraction
        .target(
            name: "Library",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("Resources/Readability.js"), .copy("Resources/Readability-LICENSE.md")]
        ),
        // Intelligence: model access, understanding, search, inspiration
        .target(name: "Intelligence", dependencies: ["Library", "llama"]),
        // Official llama.cpp prebuilt package, used to run the on-device embedding model
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11191/llama-b11191-xcframework.zip",
            checksum: "c8f9af07555a15b00a87334e13a21320596178c58bbafa2d7c4915c574e7086e"),
        // Canvas: the canvas, card rendering
        .target(name: "Canvas", dependencies: ["Library", "Tokens"]),
        // App: interface shell, collect entry points, detail view
        .executableTarget(
            name: "Piyi",
            dependencies: ["Library", "Intelligence", "Canvas", "Tokens", "Wire"],
            resources: [.copy("Resources/Seed")]
        ),
        // The extension relay: launched by the browser, forwards messages between the extension and the App
        .executableTarget(name: "PiyiRelay", dependencies: ["Wire"]),
        .testTarget(name: "LibraryTests", dependencies: ["Library"]),
        .testTarget(name: "CanvasTests", dependencies: ["Canvas", "Library"]),
        .testTarget(name: "IntelligenceTests", dependencies: ["Intelligence", "Library"]),
        // Depends on the relay only so swift test builds it first: the tests launch it the way a browser does
        // Library module: needed by the tests that follow what the extension collects from the relay all the way into the library
        .testTarget(name: "WireTests", dependencies: ["Wire", "PiyiRelay", "Library"]),
    ]
)

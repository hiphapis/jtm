// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "jtm",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "JTMCore", targets: ["JTMCore"]),
        .executable(name: "jtm", targets: ["jtm"]),
        .executable(name: "JTMApp", targets: ["JTMApp"]),
        // 개발용 진단 도구. 앱 번들(build-app.sh)에는 들어가지 않는다.
        .executable(name: "JTMSnapshot", targets: ["JTMSnapshot"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "JTMCore"),
        .executableTarget(
            name: "jtm",
            dependencies: [
                "JTMCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // 메뉴바 앱의 테스트 가능한 부분(뷰모델, DB 감시, 동기화 게이트). AppKit/SwiftUI 뷰는 JTMApp에만 둔다.
        .target(name: "JTMAppCore", dependencies: ["JTMCore"], path: "Sources/JTMApp/Core"),
        // 팝오버/패널 본문(SwiftUI). 앱과 진단 도구가 함께 쓴다(실행 타깃끼리는 import할 수 없어서 라이브러리로 뺐다).
        .target(name: "JTMAppUI", dependencies: ["JTMAppCore", "JTMCore"], path: "Sources/JTMApp/UI"),
        .executableTarget(name: "JTMApp", dependencies: ["JTMAppUI", "JTMAppCore", "JTMCore"], path: "Sources/JTMApp/App"),
        .executableTarget(name: "JTMSnapshot", dependencies: ["JTMAppUI", "JTMAppCore"], path: "Sources/JTMSnapshot"),
        .testTarget(name: "JTMCoreTests", dependencies: ["JTMCore"]),
        .testTarget(name: "JTMAppCoreTests", dependencies: ["JTMAppCore", "JTMCore"]),
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "where-was-i",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WWICore", targets: ["WWICore"]),
        .executable(name: "wwi", targets: ["wwi"]),
        .executable(name: "WhereWasI", targets: ["WhereWasI"]),
        // 개발용 진단 도구. 앱 번들(build-app.sh)에는 들어가지 않는다.
        .executable(name: "WWISnapshot", targets: ["WWISnapshot"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "WWICore"),
        .executableTarget(
            name: "wwi",
            dependencies: [
                "WWICore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // 메뉴바 앱의 테스트 가능한 부분(뷰모델, DB 감시, 동기화 게이트). AppKit/SwiftUI 뷰는 WhereWasI에만 둔다.
        // 화면 문구(영어 기본, 한국어)는 Resources/{en,ko}.lproj에 있고 Bundle.module로 읽는다. build-app.sh가 이 리소스 번들을 앱에 복사한다.
        .target(name: "WWIAppCore", dependencies: ["WWICore"], path: "Sources/WhereWasI/Core", resources: [.process("Resources")]),
        // 팝오버/패널 본문(SwiftUI). 앱과 진단 도구가 함께 쓴다(실행 타깃끼리는 import할 수 없어서 라이브러리로 뺐다).
        .target(name: "WWIAppUI", dependencies: ["WWIAppCore", "WWICore"], path: "Sources/WhereWasI/UI"),
        .executableTarget(name: "WhereWasI", dependencies: ["WWIAppUI", "WWIAppCore", "WWICore"], path: "Sources/WhereWasI/App"),
        .executableTarget(name: "WWISnapshot", dependencies: ["WWIAppUI", "WWIAppCore"], path: "Sources/WWISnapshot"),
        .testTarget(name: "WWICoreTests", dependencies: ["WWICore"]),
        .testTarget(name: "WWIAppCoreTests", dependencies: ["WWIAppCore", "WWICore"]),
    ]
)

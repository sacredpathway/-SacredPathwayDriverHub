// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SacredPathway",
    platforms: [
        .iOS(.v17)
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.0.0"),
        .package(url: "https://github.com/techprimate/TPPDF.git", from: "2.0.0")
    ],
    targets: [
        .target(
            name: "SacredPathway",
            dependencies: [
                .product(name: "Supabase", package: "supabase-swift"),
                .product(name: "TPPDF", package: "TPPDF")
            ]
        )
    ]
)

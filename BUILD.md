# Build Instructions

## Android APK
```bash
flutter build apk --release --target-platform android-arm64
# Output: build/app/outputs/flutter-apk/app-release.apk
```

## Android App Bundle
```bash
flutter build appbundle --release
# Output: build/app/outputs/bundle/release/app-release.aab
```

## Linux Desktop
```bash
# Prerequisites: sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev
flutter build linux --release
# Output: build/linux/x64/release/bundle/
```

## Windows Desktop
```bash
# Prerequisites: Visual Studio with C++ desktop development workload
flutter build windows --release
# Output: build/windows/x64/runner/Release/
```

## macOS Desktop
```bash
# Prerequisites: Xcode 14+
flutter build macos --release
# Output: build/macos/Build/Products/Release/LocalVault.app
```

## Run Tests
```bash
flutter test
```

## Static Analysis
```bash
flutter analyze
```

## Clean Build
```bash
flutter clean
flutter pub get
```
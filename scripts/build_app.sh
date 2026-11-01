#!/bin/bash
# Builds build/SiliconMeter.app (Apple Silicon, ad-hoc signed), with the desktop widget
# extension inside it (Contents/PlugIns/SiliconMeterWidget.appex).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/SiliconMeter"

APP="build/SiliconMeter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SiliconMeter"
cp scripts/Info.plist "$APP/Contents/Info.plist"
# The icon is packed by Apple's iconutil from the iconset (the widget gallery misread the
# small sizes of the hand-packed icns as raw pixels).
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns" \
    || cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Widget extension (macOS 14+). SwiftPM can't build app extensions, so it is compiled here
# from the drawing code it shares with the app plus Widget/. The widget is optional: if it
# fails to build, the app is still built without it.
# Like Xcode, the extension starts in Foundation's NSExtensionMain, which records the launch
# arguments the extension runtime needs and then calls the widget bundle's @main; started
# straight in @main, the runtime finds them missing and the widget crashes on launch.
WIDGET="$APP/Contents/PlugIns/SiliconMeterWidget.appex"
mkdir -p "$WIDGET/Contents/MacOS"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
if xcrun swiftc -O -parse-as-library -application-extension \
        -target arm64-apple-macos14.0 -sdk "$SDK" -module-name SiliconMeterWidget \
        Sources/SiliconMeter/Model.swift \
        Sources/SiliconMeter/Topology.swift \
        Sources/SiliconMeter/ChipCatalog.swift \
        Sources/SiliconMeter/ChipLayout.swift \
        Sources/SiliconMeter/DieRenderer.swift \
        Sources/SiliconMeter/WidgetArt.swift \
        Widget/SiliconMeterWidget.swift \
        -framework WidgetKit -framework SwiftUI -framework IOKit \
        -Xlinker -e -Xlinker _NSExtensionMain \
        -o "$WIDGET/Contents/MacOS/SiliconMeterWidget"; then
    cp Widget/Info.plist "$WIDGET/Contents/Info.plist"
    # The keys Xcode adds when it processes an Info.plist (platform and SDK the bundle was
    # built for); the extension runtime reads them when it starts the widget.
    WP="$WIDGET/Contents/Info.plist"
    SDKVER="$(xcrun --sdk macosx --show-sdk-version)"
    SDKBUILD="$(xcrun --sdk macosx --show-sdk-build-version 2>/dev/null || sw_vers -buildVersion)"
    plutil -insert CFBundleSupportedPlatforms -json '["MacOSX"]' "$WP"
    plutil -insert CFBundleDevelopmentRegion -string en "$WP"
    plutil -insert DTPlatformName -string macosx "$WP"
    plutil -insert DTPlatformVersion -string "$SDKVER" "$WP"
    plutil -insert DTPlatformBuild -string "$SDKBUILD" "$WP"
    plutil -insert DTSDKName -string "macosx$SDKVER" "$WP"
    plutil -insert DTSDKBuild -string "$SDKBUILD" "$WP"
    plutil -insert BuildMachineOSBuild -string "$(sw_vers -buildVersion)" "$WP"
    codesign --force --sign - --entitlements Widget/Widget.entitlements "$WIDGET" >/dev/null
    echo "Built widget extension"
else
    echo "warning: widget extension failed to build; the app is built without it" >&2
    rm -rf "$APP/Contents/PlugIns"
fi

codesign --force --sign - "$APP" >/dev/null

echo "Built $APP"
echo "Run:  open $APP"
echo "Install:  cp -R $APP /Applications/"

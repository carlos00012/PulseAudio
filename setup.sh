#!/usr/bin/env bash
# Genera el proyecto Flutter y compila el APK. Requiere Flutter instalado.
set -e
flutter create --org com.pulse --project-name pulseaudio --platforms android app
cp src/pubspec.yaml app/pubspec.yaml
cp src/main.dart app/lib/main.dart
rm -rf app/test
cp overrides/AndroidManifest.xml app/android/app/src/main/AndroidManifest.xml
mkdir -p app/android/app/src/main/kotlin/com/pulse/pulseaudio
cp overrides/MainActivity.kt app/android/app/src/main/kotlin/com/pulse/pulseaudio/MainActivity.kt
cd app && flutter pub get && flutter build apk --release
echo "APK listo: app/build/app/outputs/flutter-apk/app-release.apk"

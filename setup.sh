#!/usr/bin/env bash
# Genera el proyecto Flutter y compila el APK. Requiere Flutter instalado.
set -e
flutter create --org com.pulse --project-name pulseaudio --platforms android app
cp src/pubspec.yaml app/pubspec.yaml
cp src/main.dart app/lib/main.dart
rm -rf app/test
cp overrides/AndroidManifest.xml app/android/app/src/main/AndroidManifest.xml
mkdir -p app/android/app/src/main/kotlin/com/pulse/pulseaudio app/android/app/src/main/res/layout app/android/app/src/main/res/xml app/android/app/src/main/res/drawable
cp overrides/MainActivity.kt app/android/app/src/main/kotlin/com/pulse/pulseaudio/MainActivity.kt
cp overrides/PulseAudioWidgetProvider.kt app/android/app/src/main/kotlin/com/pulse/pulseaudio/PulseAudioWidgetProvider.kt
cp overrides/pulseaudio_widget.xml app/android/app/src/main/res/layout/pulseaudio_widget.xml
cp overrides/pulseaudio_widget_info.xml app/android/app/src/main/res/xml/pulseaudio_widget_info.xml
cp overrides/widget_music_note.xml app/android/app/src/main/res/drawable/widget_music_note.xml
cp overrides/widget_shuffle.xml app/android/app/src/main/res/drawable/widget_shuffle.xml
cd app
flutter pub get

pub_cache="${PUB_CACHE:-}"
if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]] && command -v cygpath >/dev/null 2>&1; then
  if [[ -n "$pub_cache" ]]; then
    pub_cache="$(cygpath -u "$pub_cache")"
  elif [[ -n "${LOCALAPPDATA:-}" ]]; then
    pub_cache="$(cygpath -u "$LOCALAPPDATA")/Pub/Cache"
  fi
fi
if [[ -z "$pub_cache" ]]; then
  pub_cache="$HOME/.pub-cache"
fi

plugin_gradle="$(find "$pub_cache" -type f -path '*/on_audio_query_android-*/android/build.gradle' -print -quit)"
if [[ -z "$plugin_gradle" ]]; then
  echo "No se encontró el build.gradle de on_audio_query_android en $pub_cache" >&2
  exit 1
fi

# Patch legacy settings required by the current Android Gradle toolchain.
if ! grep -q '^[[:space:]]*namespace[[:space:]]' "$plugin_gradle"; then
  sed -i '/^android[[:space:]]*{/a\    namespace "com.lucasjosino.on_audio_query"' "$plugin_gradle"
fi
if ! grep -q 'jvmTarget' "$plugin_gradle"; then
  sed -i '/^android[[:space:]]*{/a\    kotlinOptions { jvmTarget = "11" }' "$plugin_gradle"
fi
sed -i 's/compileSdkVersion 33/compileSdkVersion 34/' "$plugin_gradle"

flutter build apk --release
echo "APK listo: app/build/app/outputs/flutter-apk/app-release.apk"

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

if ! grep -q '^[[:space:]]*namespace[[:space:]]' "$plugin_gradle"; then
  sed -i '/^android[[:space:]]*{/a\    namespace "com.lucasjosino.on_audio_query"' "$plugin_gradle"
fi

flutter build apk --release
echo "APK listo: app/build/app/outputs/flutter-apk/app-release.apk"

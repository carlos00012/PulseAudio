# PulseAudio (Flutter)
Reproductor de música local estilo Spotify. Android 8+.

## Biblioteca y controles
- En el botón de filtros puedes elegir una carpeta para la biblioteca y fijar una duración mínima. El valor inicial es 30 segundos; puedes cambiarlo o seleccionar «Sin mínimo». La selección se guarda en el dispositivo.
- Añade el widget PulseAudio desde la lista de widgets de Android para ver la portada, canción, artista y progreso, y controlar aleatorio, anterior, reproducir/pausar y siguiente. Los botones anteriores/siguiente reanudan la reproducción; si el reproductor no tiene cola, inicia desde la canción guardada o la primera disponible.
- Al iniciar una canción, permite las notificaciones para mostrar los controles multimedia en la barra de notificaciones y la pantalla bloqueada. Android también permite ocultarlas desde los ajustes de pantalla de bloqueo.

## Opción A: compilar en tu PC (tienes Flutter)
    ./setup.sh
El APK queda en app/build/app/outputs/flutter-apk/app-release.apk

## Opción B: sin instalar nada (GitHub)
1. Crea un repositorio en github.com y sube el contenido de esta carpeta.
2. Pestaña Actions > "Build APK" > Run workflow.
3. Al terminar, descarga el artefacto "PulseAudio-apk" (contiene el .apk).

## Instalar
Pasa el .apk al móvil y ábrelo (permite «instalar apps desconocidas»).

## Estructura
src/main.dart (app), src/pubspec.yaml (dependencias), overrides/ (permisos y servicio de audio en segundo plano).
Para iOS: añade NSAppleMusicUsageDescription y UIBackgroundModes=audio en Info.plist.

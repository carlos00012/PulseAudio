import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:shared_preferences/shared_preferences.dart';

const accent = Color(0xFF1DB954), bg = Color(0xFF121212);
final player = AudioPlayer();
final query = OnAudioQuery();
ConcatenatingAudioSource? queueSrc;
final favs = ValueNotifier<Set<String>>({});
final lists = ValueNotifier<Map<String, List<String>>>({});
List<SongModel> librarySongs = [];
bool _libraryLoaded = false;
late SharedPreferences prefs;
const _widgetChannel = MethodChannel('com.pulse.audio/widget');
final _widgetBridge = _WidgetBridge();

void save() {
  prefs.setStringList('favs', favs.value.toList());
  prefs.setString('lists', jsonEncode(lists.value));
}

void toggleFav(String id) {
  final s = {...favs.value};
  s.contains(id) ? s.remove(id) : s.add(id);
  favs.value = s;
  save();
}

void setLists(Map<String, List<String>> m) {
  lists.value = m;
  save();
}

AudioSource _src(SongModel s) => AudioSource.uri(Uri.parse(s.uri!),
    tag: MediaItem(id: '${s.id}', title: s.title, artist: s.artist ?? 'Desconocido',
        album: s.album,
        duration: Duration(milliseconds: s.duration ?? 0),
        artUri: s.albumId == null
            ? null
            : Uri.parse('content://media/external/audio/albumart/${s.albumId}'),
        extras: s.albumId == null ? null : {'albumId': s.albumId}));

Future<void> playList(List<SongModel> l, int i) async {
  queueSrc = ConcatenatingAudioSource(children: l.map(_src).toList());
  await player.setAudioSource(queueSrc!, initialIndex: i);
  player.play();
}

String fmt(Duration d) =>
    '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

class _WidgetBridge {
  String? _trackId;
  Uint8List? _artwork;
  int _lastPositionSecond = -1;
  bool _updating = false, _updatePending = false;
  bool _firstUpdate = true;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final List<String> _pendingCommands = [];
  Future<void> _commandQueue = Future<void>.value();

  Future<void> start() async {
    _widgetChannel.setMethodCallHandler((call) async {
      if (call.method != 'remoteCommand' || call.arguments is! String) {
        throw MissingPluginException(
            'Método del widget no reconocido: ${call.method}');
      }
      await _enqueueCommand(call.arguments as String);
    });
    await _widgetChannel.invokeMethod<void>('widgetReady');
    _subscriptions.add(player.sequenceStateStream.listen((_) {
      _lastPositionSecond = -1;
      _scheduleUpdate();
    }));
    _subscriptions.add(player.playingStream.listen((_) => _scheduleUpdate()));
    _subscriptions.add(
        player.shuffleModeEnabledStream.listen((_) => _scheduleUpdate()));
    _subscriptions.add(player.positionStream.listen((position) {
      if (position.inSeconds != _lastPositionSecond) {
        _lastPositionSecond = position.inSeconds;
        _scheduleUpdate();
      }
    }));
    _scheduleUpdate();
  }

  void setLibraryReady() {
    _libraryLoaded = true;
    for (final command in _pendingCommands) {
      unawaited(_enqueueCommand(command));
    }
    _pendingCommands.clear();
  }

  Future<void> _enqueueCommand(String command) {
    _commandQueue = _commandQueue.then((_) => _handleCommand(command));
    return _commandQueue;
  }

  Future<void> _handleCommand(String command) async {
    final hasQueue =
        player.sequenceState?.currentSource?.tag is MediaItem;
    if (!hasQueue && !_libraryLoaded) {
      _pendingCommands.add(command);
      return;
    }
    if (command == 'toggleShuffle') {
      final enabled = !player.shuffleModeEnabled;
      await player.setShuffleModeEnabled(enabled);
      if (enabled) await player.shuffle();
      return;
    }
    if (command == 'togglePlayback' && player.playing) {
      await player.pause();
      return;
    }
    if (!hasQueue) {
      if (librarySongs.isEmpty) return;
      final savedId = prefs.getString('widgetCurrentSongId');
      final savedIndex =
          librarySongs.indexWhere((song) => '${song.id}' == savedId);
      final startIndex = switch (command) {
        'previous' => savedIndex < 0
            ? librarySongs.length - 1
            : (savedIndex - 1 + librarySongs.length) % librarySongs.length,
        'next' => savedIndex < 0 ? 0 : (savedIndex + 1) % librarySongs.length,
        _ => savedIndex < 0 ? 0 : savedIndex,
      };
      await playList(librarySongs, startIndex);
      return;
    }
    if (command == 'play' || command == 'togglePlayback') {
      player.play();
      return;
    }
    final sequence = player.sequenceState!.sequence;
    if (sequence.isEmpty) return;
    final currentIndex = player.sequenceState?.currentIndex ?? 0;
    final nextIndex = command == 'next'
        ? (currentIndex + 1) % sequence.length
        : (currentIndex - 1 + sequence.length) % sequence.length;
    await player.seek(Duration.zero, index: nextIndex);
    player.play();
  }

  void _scheduleUpdate() {
    _updatePending = true;
    if (!_updating) unawaited(_drainUpdates());
  }

  Future<void> _drainUpdates() async {
    _updating = true;
    try {
      while (_updatePending) {
        _updatePending = false;
        await _sendUpdate();
      }
    } finally {
      _updating = false;
      if (_updatePending) _scheduleUpdate();
    }
  }

  Future<void> _sendUpdate() async {
    final tag = player.sequenceState?.currentSource?.tag;
    final item = tag is MediaItem ? tag : null;
    final artworkChanged = _firstUpdate || item?.id != _trackId;
    if (artworkChanged) {
      Uint8List? artwork;
      final id = int.tryParse(item?.id ?? '');
      if (id != null) {
        artwork = await query.queryArtwork(
          id,
          ArtworkType.AUDIO,
          format: ArtworkFormat.JPEG,
          size: 240,
          quality: 80,
        );
      }
      _trackId = item?.id;
      _artwork = artwork;
      _firstUpdate = false;
      if (item != null) await prefs.setString('widgetCurrentSongId', item.id);
    }
    final duration = player.duration ?? item?.duration ?? Duration.zero;
    await _widgetChannel.invokeMethod<void>('updateWidget', {
      'hasTrack': item != null,
      'title': item?.title ?? '',
      'artist': item?.artist ?? '',
      'durationMs': duration.inMilliseconds,
      'positionMs': player.position.inMilliseconds,
      'playing': player.playing,
      'shuffle': player.shuffleModeEnabled,
      'albumId': item?.extras?['albumId'],
      'artworkChanged': artworkChanged,
      'artwork': _artwork,
    });
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(
      androidNotificationChannelId: 'com.pulse.audio.playback.v2',
      androidNotificationChannelName: 'PulseAudio',
      androidNotificationChannelDescription: 'Controles de reproducción',
      androidNotificationIcon: 'drawable/ic_notification',
      androidNotificationOngoing: true);
  prefs = await SharedPreferences.getInstance();
  favs.value = (prefs.getStringList('favs') ?? []).toSet();
  final minDurationSeconds = prefs.getInt('minDurationSeconds');
  if (minDurationSeconds == null) {
    await prefs.setInt('minDurationSeconds', 30);
  }
  final raw = prefs.getString('lists');
  if (raw != null) {
    lists.value = (jsonDecode(raw) as Map)
        .map((k, v) => MapEntry(k as String, List<String>.from(v)));
  }
  await _widgetBridge.start();
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'PulseAudio',
    theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: bg,
        colorScheme: const ColorScheme.dark(primary: accent, surface: bg),
        appBarTheme: const AppBarTheme(backgroundColor: bg)),
    home: const Home(),
  ));
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  List<SongModel> songs = [];
  bool loading = true, denied = false;
  bool notificationsEnabled = true;
  String q = '';
  String? selectedFolder;
  int minDurationSeconds = 30;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final savedFolder = prefs.getString('selectedFolder');
    selectedFolder = savedFolder == null || savedFolder.isEmpty ? null : savedFolder;
    minDurationSeconds = prefs.getInt('minDurationSeconds') ?? 30;
    var ok = await query.permissionsStatus();
    if (!ok) ok = await query.permissionsRequest();
    if (ok) {
      final all = await query.querySongs(
          sortType: SongSortType.TITLE,
          orderType: OrderType.ASC_OR_SMALLER,
          uriType: UriType.EXTERNAL,
          ignoreCase: true);
      songs = all.where((s) => s.isMusic == true && s.uri != null).toList();
      if (selectedFolder != null &&
          !songs.any((s) => _songFolder(s) == selectedFolder)) {
        selectedFolder = null;
        await prefs.remove('selectedFolder');
      }
    }
    notificationsEnabled =
        await _widgetChannel.invokeMethod<bool>('requestNotifications') ?? false;
    librarySongs = songs;
    _widgetBridge.setLibraryReady();
    if (mounted) setState(() { loading = false; denied = !ok; });
    if (mounted && !notificationsEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
                'Activa las notificaciones de PulseAudio para ver los controles de reproducción y bloqueo.'),
            action: SnackBarAction(
              label: 'Ajustes',
              onPressed: () =>
                  _widgetChannel.invokeMethod<void>('openNotificationSettings'),
            ),
          ),
        );
      });
    }
  }

  List<SongModel> _visibleSongs() => songs.where((s) {
        final matchesSearch =
            q.isEmpty || '${s.title} ${s.artist} ${s.album}'.toLowerCase().contains(q);
        final matchesFolder =
            selectedFolder == null || _songFolder(s) == selectedFolder;
        final matchesDuration = (s.duration ?? 0) >= minDurationSeconds * 1000;
        return matchesSearch && matchesFolder && matchesDuration;
      }).toList();

  Future<void> _showFilters() async {
    final folders = songs.map(_songFolder).toSet().toList()..sort();
    var folder = selectedFolder;
    var duration = minDurationSeconds;
    final result = await showDialog<(String?, int)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Filtros de biblioteca'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Carpeta'),
              DropdownButton<String?>(
                isExpanded: true,
                value: folder,
                items: [
                  const DropdownMenuItem<String?>(
                      value: null, child: Text('Todas las carpetas')),
                  for (final path in folders)
                    DropdownMenuItem<String?>(
                      value: path,
                      child: Text(path, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (value) => setDialogState(() => folder = value),
              ),
              const SizedBox(height: 16),
              const Text('Duración mínima'),
              DropdownButton<int>(
                isExpanded: true,
                value: duration,
                items: const [
                  DropdownMenuItem(value: 0, child: Text('Sin mínimo')),
                  DropdownMenuItem(value: 30, child: Text('30 segundos')),
                  DropdownMenuItem(value: 60, child: Text('1 minuto')),
                  DropdownMenuItem(value: 120, child: Text('2 minutos')),
                  DropdownMenuItem(value: 300, child: Text('5 minutos')),
                ],
                onChanged: (value) {
                  if (value != null) setDialogState(() => duration = value);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, (folder, duration)),
              child: const Text('Aplicar'),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      selectedFolder = result.$1;
      minDurationSeconds = result.$2;
    });
    await prefs.setString('selectedFolder', result.$1 ?? '');
    await prefs.setInt('minDurationSeconds', result.$2);
  }

  @override
  Widget build(BuildContext context) {
    final f = _visibleSongs();
    final filtersActive = selectedFolder != null || minDurationSeconds > 0;
    return DefaultTabController(
      length: 6,
      child: Scaffold(
        appBar: AppBar(
          title: TextField(
            onChanged: (v) => setState(() => q = v.toLowerCase()),
            decoration: InputDecoration(
                hintText: 'Buscar…', filled: true, fillColor: const Color(0xFF1E1E1E),
                prefixIcon: const Icon(Icons.search), isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none)),
          ),
          actions: [
            IconButton(
              tooltip: 'Filtrar carpeta y duración',
              onPressed: _showFilters,
              icon: Icon(
                filtersActive ? Icons.filter_alt : Icons.filter_alt_outlined,
                color: filtersActive ? accent : null,
              ),
            ),
          ],
          bottom: const TabBar(isScrollable: true, indicatorColor: accent, tabs: [
            Tab(text: 'Canciones'), Tab(text: 'Listas'), Tab(text: 'Artistas'),
            Tab(text: 'Álbumes'), Tab(text: 'Carpetas'), Tab(text: 'Favoritos')]),
        ),
        body: loading
            ? const Center(child: CircularProgressIndicator(color: accent))
            : denied
                ? Center(child: TextButton(onPressed: _init, child: const Text('Permite el acceso a tu música (toca para reintentar)')))
                : Column(children: [
                    Expanded(
                      child: TabBarView(children: [
                        SongList(f),
                        PlaylistsTab(songs),
                        GroupTab(f, (s) => s.artist ?? 'Desconocido', Icons.person),
                        GroupTab(f, (s) => s.album ?? 'Desconocido', Icons.album),
                        GroupTab(f, (s) {
                          final p = s.data.substring(0, s.data.lastIndexOf('/'));
                          return p.substring(p.lastIndexOf('/') + 1);
                        }, Icons.folder),
                        ValueListenableBuilder(
                            valueListenable: favs,
                            builder: (_, fv, __) => SongList(f.where((s) => fv.contains('${s.id}')).toList())),
                      ]),
                    ),
                    const MiniPlayer(),
                  ]),
      ),
    );
  }
}

String _songFolder(SongModel song) {
  final path = song.data.replaceAll('\\', '/');
  final separator = path.lastIndexOf('/');
  return separator <= 0 ? 'Desconocida' : path.substring(0, separator);
}

Widget art(int id, double size) => QueryArtworkWidget(
    id: id, type: ArtworkType.AUDIO, artworkWidth: size, artworkHeight: size, size: 600,
    artworkBorder: BorderRadius.circular(6),
    nullArtworkWidget: Container(width: size, height: size,
        decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(6)),
        child: const Icon(Icons.music_note, color: Colors.white54)));

Future<String?> askName(BuildContext c, String init) {
  final t = TextEditingController(text: init);
  return showDialog<String>(
      context: c,
      builder: (_) => AlertDialog(
            title: const Text('Nombre de la lista'),
            content: TextField(controller: t, autofocus: true),
            actions: [TextButton(onPressed: () => Navigator.pop(c, t.text.trim()), child: const Text('Aceptar'))],
          ));
}

Future<void> addToList(BuildContext c, SongModel s) async {
  final pick = await showDialog<String>(
      context: c,
      builder: (_) => SimpleDialog(title: const Text('Añadir a lista'), children: [
            SimpleDialogOption(onPressed: () => Navigator.pop(c, '\u0000new'), child: const Text('+ Nueva lista')),
            for (final n in lists.value.keys)
              SimpleDialogOption(onPressed: () => Navigator.pop(c, n), child: Text(n)),
          ]));
  if (pick == null) return;
  var name = pick;
  if (pick == '\u0000new') {
    if (!c.mounted) return;
    name = await askName(c, '') ?? '';
    if (name.isEmpty) return;
  }
  final m = {...lists.value};
  final l = [...(m[name] ?? <String>[])];
  if (!l.contains('${s.id}')) l.add('${s.id}');
  m[name] = l;
  setLists(m);
}

class SongList extends StatelessWidget {
  final List<SongModel> songs;
  const SongList(this.songs, {super.key});
  @override
  Widget build(BuildContext context) {
    if (songs.isEmpty) return const Center(child: Text('Nada por aquí', style: TextStyle(color: Colors.white54)));
    return ListView.builder(
      itemCount: songs.length,
      itemExtent: 64,
      itemBuilder: (c, i) {
        final s = songs[i];
        return ListTile(
          leading: art(s.id, 44),
          title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${s.artist ?? ''} · ${s.album ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: () => playList(songs, i),
          trailing: PopupMenuButton<int>(
            onSelected: (v) => v == 0 ? toggleFav('${s.id}') : addToList(c, s),
            itemBuilder: (_) => [
              PopupMenuItem(value: 0, child: Text(favs.value.contains('${s.id}') ? 'Quitar de favoritos' : 'Me gusta')),
              const PopupMenuItem(value: 1, child: Text('Añadir a lista')),
            ],
          ),
        );
      },
    );
  }
}

class GroupTab extends StatelessWidget {
  final List<SongModel> songs;
  final String Function(SongModel) keyFn;
  final IconData icon;
  const GroupTab(this.songs, this.keyFn, this.icon, {super.key});
  @override
  Widget build(BuildContext context) {
    final m = <String, List<SongModel>>{};
    for (final s in songs) { (m[keyFn(s)] ??= []).add(s); }
    final names = m.keys.toList()..sort();
    return ListView.builder(
      itemCount: names.length,
      itemBuilder: (c, i) => ListTile(
        leading: Icon(icon, color: accent),
        title: Text(names[i]),
        subtitle: Text('${m[names[i]]!.length} canciones'),
        onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => Scaffold(
            appBar: AppBar(title: Text(names[i])),
            body: Column(children: [Expanded(child: SongList(m[names[i]]!)), const MiniPlayer()])))),
      ),
    );
  }
}

class PlaylistsTab extends StatelessWidget {
  final List<SongModel> all;
  const PlaylistsTab(this.all, {super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: lists,
        builder: (c, m, _) => ListView(children: [
          ListTile(
            leading: const Icon(Icons.add, color: accent),
            title: const Text('Nueva lista'),
            onTap: () async {
              final n = await askName(c, '');
              if (n != null && n.isNotEmpty && !m.containsKey(n)) setLists({...m, n: []});
            },
          ),
          for (final n in m.keys)
            ListTile(
              leading: const Icon(Icons.queue_music, color: accent),
              title: Text(n),
              subtitle: Text('${m[n]!.length} canciones'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(icon: const Icon(Icons.edit), onPressed: () async {
                  final r = await askName(c, n);
                  if (r != null && r.isNotEmpty && r != n) {
                    final x = {...m}; x[r] = x.remove(n)!; setLists(x);
                  }
                }),
                IconButton(icon: const Icon(Icons.delete), onPressed: () { final x = {...m}..remove(n); setLists(x); }),
              ]),
              onTap: () {
                final l = m[n]!.map((id) => all.where((s) => '${s.id}' == id)).expand((e) => e).toList();
                Navigator.push(c, MaterialPageRoute(builder: (_) => Scaffold(
                    appBar: AppBar(title: Text(n)),
                    body: Column(children: [Expanded(child: SongList(l)), const MiniPlayer()]))));
              },
            ),
        ]),
      );
}

class PlayBtn extends StatelessWidget {
  final double size;
  const PlayBtn(this.size, {super.key});
  @override
  Widget build(BuildContext context) => StreamBuilder<bool>(
      stream: player.playingStream,
      builder: (_, s) => IconButton(
          iconSize: size,
          icon: Icon(s.data == true ? Icons.pause_circle_filled : Icons.play_circle_fill),
          onPressed: () => s.data == true ? player.pause() : player.play()));
}

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});
  @override
  Widget build(BuildContext context) => StreamBuilder<SequenceState?>(
      stream: player.sequenceStateStream,
      builder: (c, snap) {
        final item = snap.data?.currentSource?.tag;
        if (item is! MediaItem) return const SizedBox.shrink();
        return GestureDetector(
          onTap: () => showModalBottomSheet(context: c, isScrollControlled: true, useSafeArea: true,
              backgroundColor: const Color(0xFF1B2B22), builder: (_) => const NowPlaying()),
          onHorizontalDragEnd: (d) =>
              (d.primaryVelocity ?? 0) < 0 ? player.seekToNext() : player.seekToPrevious(),
          child: Container(
            margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            decoration: BoxDecoration(color: const Color(0xFF2A2A2A), borderRadius: BorderRadius.circular(10)),
            child: Column(children: [
              ListTile(
                dense: true,
                leading: art(int.parse(item.id), 40),
                title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(item.artist ?? '', maxLines: 1),
                trailing: const PlayBtn(36),
              ),
              StreamBuilder<Duration>(
                  stream: player.positionStream,
                  builder: (_, p) {
                    final d = player.duration?.inMilliseconds ?? 1;
                    return LinearProgressIndicator(
                        value: ((p.data?.inMilliseconds ?? 0) / d).clamp(0.0, 1.0),
                        minHeight: 2, color: accent, backgroundColor: Colors.white24);
                  }),
            ]),
          ),
        );
      });
}

class NowPlaying extends StatelessWidget {
  const NowPlaying({super.key});
  @override
  Widget build(BuildContext context) => StreamBuilder<SequenceState?>(
      stream: player.sequenceStateStream,
      builder: (c, snap) {
        final item = snap.data?.currentSource?.tag;
        if (item is! MediaItem) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(children: [
            Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white38, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 16),
            Expanded(
              child: GestureDetector(
                onHorizontalDragEnd: (d) =>
                    (d.primaryVelocity ?? 0) < 0 ? player.seekToNext() : player.seekToPrevious(),
                child: LayoutBuilder(builder: (_, b) => Center(child: art(int.parse(item.id), b.maxWidth.clamp(100, 340).toDouble()))),
              ),
            ),
            Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                Text(item.artist ?? '', style: const TextStyle(color: Colors.white70)),
              ])),
              ValueListenableBuilder(
                  valueListenable: favs,
                  builder: (_, f, __) => IconButton(
                      icon: Icon(f.contains(item.id) ? Icons.favorite : Icons.favorite_border,
                          color: f.contains(item.id) ? accent : null),
                      onPressed: () => toggleFav(item.id))),
            ]),
            StreamBuilder<Duration>(
                stream: player.positionStream,
                builder: (_, p) {
                  final d = player.duration ?? Duration.zero;
                  final pos = p.data ?? Duration.zero;
                  return Column(children: [
                    Slider(
                        activeColor: accent,
                        value: pos.inMilliseconds.clamp(0, d.inMilliseconds).toDouble(),
                        max: d.inMilliseconds.toDouble().clamp(1, double.infinity),
                        onChanged: (v) => player.seek(Duration(milliseconds: v.toInt()))),
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [Text(fmt(pos)), Text(fmt(d))]),
                  ]);
                }),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              StreamBuilder<bool>(
                  stream: player.shuffleModeEnabledStream,
                  builder: (_, s) => IconButton(
                      icon: Icon(Icons.shuffle, color: s.data == true ? accent : null),
                      onPressed: () async {
                        final on = !(s.data ?? false);
                        await player.setShuffleModeEnabled(on);
                        if (on) await player.shuffle();
                      })),
              IconButton(iconSize: 40, icon: const Icon(Icons.skip_previous), onPressed: player.seekToPrevious),
              const PlayBtn(64),
              IconButton(iconSize: 40, icon: const Icon(Icons.skip_next), onPressed: player.seekToNext),
              StreamBuilder<LoopMode>(
                  stream: player.loopModeStream,
                  builder: (_, s) {
                    final m = s.data ?? LoopMode.off;
                    return IconButton(
                        icon: Icon(m == LoopMode.one ? Icons.repeat_one : Icons.repeat,
                            color: m == LoopMode.off ? null : accent),
                        onPressed: () => player.setLoopMode(LoopMode.values[(m.index + 1) % 3]));
                  }),
            ]),
            TextButton.icon(
                icon: const Icon(Icons.queue_music),
                label: const Text('Cola'),
                onPressed: () => showModalBottomSheet(context: c, builder: (_) => const QueueSheet())),
          ]),
        );
      });
}

class QueueSheet extends StatelessWidget {
  const QueueSheet({super.key});
  @override
  Widget build(BuildContext context) => StreamBuilder<SequenceState?>(
      stream: player.sequenceStateStream,
      builder: (c, snap) {
        final seq = snap.data?.sequence ?? [];
        return ReorderableListView.builder(
          itemCount: seq.length,
          onReorder: (o, n) { if (n > o) n--; queueSrc?.move(o, n); },
          itemBuilder: (c, i) {
            final item = seq[i].tag as MediaItem;
            return ListTile(
              key: ValueKey('$i-${item.id}'),
              selected: i == snap.data?.currentIndex,
              selectedColor: accent,
              leading: art(int.parse(item.id), 40),
              title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(item.artist ?? ''),
              onTap: () => player.seek(Duration.zero, index: i),
              trailing: IconButton(icon: const Icon(Icons.close), onPressed: () => queueSrc?.removeAt(i)),
            );
          },
        );
      });
}

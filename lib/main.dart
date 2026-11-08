import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:on_audio_query_pluse/on_audio_query.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    const accent = Colors.deepPurpleAccent;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Music Player',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F0E17),
        primaryColor: accent,
        colorScheme: ThemeData.dark().colorScheme.copyWith(primary: accent),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1F1D2B),
          elevation: 0,
          centerTitle: true,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

/// A common song model used by both Android's device library and browser files.
class MusicTrack {
  const MusicTrack({
    required this.id,
    required this.title,
    required this.artist,
    this.path,
    this.bytes,
  });

  final String id;
  final String title;
  final String artist;
  final String? path;
  final Uint8List? bytes;

  bool get canPlay => (path != null && path!.isNotEmpty) || bytes != null;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  final AudioPlayer _audioPlayer = AudioPlayer();
  final OnAudioQuery _audioQuery = OnAudioQuery();

  final List<MusicTrack> playlist = [];
  final Set<String> favoriteSongs = {};

  int currentIndex = -1;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  double _volume = 1.0;

  bool isPlaying = false;
  bool isShuffle = false;
  bool isRepeat = false;
  bool isSearching = false;
  bool showOnlyFavorites = false;
  bool isLoadingSongs = false;
  bool _isPickingFiles = false; // Prevent opening the native picker twice.
  bool _hasStartedPlayback = false;
  String searchQuery = '';

  late final AnimationController _rotationController;

  @override
  void initState() {
    super.initState();

    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    );

    _audioPlayer.onPlayerStateChanged.listen((state) {
      if (!mounted) return;
      setState(() => isPlaying = state == PlayerState.playing);
      if (isPlaying) {
        _rotationController.repeat();
      } else {
        _rotationController.stop();
      }
    });

    _audioPlayer.onDurationChanged.listen((duration) {
      if (mounted) setState(() => _duration = duration);
    });

    _audioPlayer.onPositionChanged.listen((position) {
      if (mounted) setState(() => _position = position);
    });

    _audioPlayer.onPlayerComplete.listen((_) {
      if (!mounted || playlist.isEmpty || currentIndex < 0 ||
          currentIndex >= playlist.length) {
        return;
      }
      if (isRepeat) {
        _playAudio(playlist[currentIndex]);
      } else if (isShuffle) {
        _playRandomNext();
      } else {
        _playNext();
      }
    });

    // A browser cannot enumerate the device's complete music library.
    // Android can scan its indexed audio library.
    if (!kIsWeb) {
      _loadDeviceMusic();
    }
  }

  Future<void> _loadDeviceMusic() async {
    if (kIsWeb) {
      _showMessage('On Web, use "Choose Music Files" to add songs.');
      return;
    }
    if (!mounted || isLoadingSongs) return;

    setState(() => isLoadingSongs = true);

    try {
      // Let on_audio_query_pluse request/check its own Android permission.
      // Do not call Android permission APIs on Web.
      final permissionGranted = await _audioQuery.permissionsRequest();
      if (!permissionGranted) {
        if (!mounted) return;
        setState(() => isLoadingSongs = false);
        _showMessage(
          'Music permission was not granted. Allow Music and audio permission in Android Settings, then scan again.',
        );
        return;
      }

      final songs = await _audioQuery.querySongs(
        sortType: SongSortType.TITLE,
        orderType: OrderType.ASC_OR_SMALLER,
        uriType: UriType.EXTERNAL,
        ignoreCase: true,
      );

      if (!mounted) return;
      final scannedTracks = songs.map((song) {
        return MusicTrack(
          id: 'device_${song.id}',
          title: song.title,
          artist: (song.artist == null || song.artist == '<unknown>')
              ? 'Unknown Artist'
              : song.artist!,
          path: song.data,
        );
      }).toList();

      setState(() {
        // Keep files that the user manually selected; replace the old scan.
        final pickedTracks = playlist.where((track) =>
            !track.id.startsWith('device_')).toList();
        playlist
          ..clear()
          ..addAll(scannedTracks)
          ..addAll(pickedTracks);
        if (playlist.isEmpty) {
          currentIndex = -1;
        } else if (currentIndex < 0 || currentIndex >= playlist.length) {
          currentIndex = 0;
        }
        isLoadingSongs = false;
        _position = Duration.zero;
        _duration = Duration.zero;
        _hasStartedPlayback = false;
      });

      _showMessage(
        scannedTracks.isEmpty
            ? 'No music found. Add audio files to your phone and scan again.'
            : 'Found ${scannedTracks.length} songs!',
      );
    } catch (e, stack) {
      debugPrint('Music library error: $e');
      debugPrintStack(stackTrace: stack);
      if (!mounted) return;
      setState(() => isLoadingSongs = false);
      _showMessage('Could not scan music library: $e');
    }
  }

  Future<void> _pickMusicFiles() async {
    // FilePicker throws PlatformException(already_active) if a second picker
    // request starts before the first one has finished.
    if (_isPickingFiles || isLoadingSongs) return;

    setState(() => _isPickingFiles = true);

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        allowMultiple: true,
        // On Web, keep file bytes because browser file paths are inaccessible.
        withData: kIsWeb,
      );

      if (result == null || result.files.isEmpty) return;

      final addedTracks = <MusicTrack>[];
      for (final file in result.files) {
        final Uint8List? data = file.bytes;
        final String? path = file.path;

        if (kIsWeb && data == null) continue;
        if (!kIsWeb && (path == null || path.isEmpty) && data == null) {
          continue;
        }

        addedTracks.add(
          MusicTrack(
            id: 'picked_${file.name}_${file.size}_${addedTracks.length}',
            title: _titleFromFileName(file.name),
            artist: 'Selected file',
            path: path,
            bytes: data,
          ),
        );
      }

      if (!mounted) return;
      if (addedTracks.isEmpty) {
        _showMessage('No playable audio files were selected.');
        return;
      }

      setState(() {
        playlist.addAll(addedTracks);
        if (currentIndex == -1) currentIndex = 0;
      });
      _showMessage('Added ${addedTracks.length} song(s).');
    } catch (e) {
      debugPrint('File picker error: $e');
      if (mounted) {
        _showMessage('Could not choose music files: $e');
      }
    } finally {
      // Always release the lock, including cancel/error/early-return cases.
      _isPickingFiles = false;
      if (mounted) setState(() {});
    }
  }

  String _titleFromFileName(String name) {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  Future<void> _playAudio(MusicTrack song) async {
    if (!song.canPlay) {
      _showMessage('This song has no playable file data. Please add it again.');
      return;
    }
    try {
      await _audioPlayer.stop();
      if (kIsWeb) {
        if (song.bytes == null) {
          _showMessage('This browser song is no longer available. Add it again.');
          return;
        }
        await _audioPlayer.play(BytesSource(song.bytes!));
      } else if (song.bytes != null) {
        await _audioPlayer.play(BytesSource(song.bytes!));
      } else {
        await _audioPlayer.play(DeviceFileSource(song.path!));
      }
      await _audioPlayer.setVolume(_volume);
      if (mounted) {
        setState(() {
          _hasStartedPlayback = true;
          _position = Duration.zero;
        });
      }
    } catch (e) {
      debugPrint('Audio playback error: $e');
      if (mounted) _showMessage('Could not play this song: $e');
    }
  }

  Future<void> _togglePlayPause() async {
    if (currentIndex < 0 || currentIndex >= playlist.length) {
      _showMessage(
        kIsWeb
            ? 'Choose music files first.'
            : 'No song selected. Scan your music first.',
      );
      return;
    }

    if (isPlaying) {
      await _audioPlayer.pause();
    } else if (_hasStartedPlayback) {
      await _audioPlayer.resume();
    } else {
      await _playAudio(playlist[currentIndex]);
    }
  }

  Future<void> _playNext() async {
    if (playlist.isEmpty || currentIndex < 0) return;
    final next = (currentIndex + 1) % playlist.length;
    setState(() {
      currentIndex = next;
      _position = Duration.zero;
      _duration = Duration.zero;
      _hasStartedPlayback = false;
    });
    await _playAudio(playlist[next]);
  }

  Future<void> _playPrevious() async {
    if (playlist.isEmpty || currentIndex < 0) return;
    if (_position.inSeconds > 3) {
      await _audioPlayer.seek(Duration.zero);
      return;
    }
    final previous =
        currentIndex <= 0 ? playlist.length - 1 : currentIndex - 1;
    setState(() {
      currentIndex = previous;
      _position = Duration.zero;
      _duration = Duration.zero;
      _hasStartedPlayback = false;
    });
    await _playAudio(playlist[previous]);
  }

  Future<void> _playRandomNext() async {
    if (playlist.isEmpty) return;
    if (playlist.length == 1) {
      await _playAudio(playlist.first);
      return;
    }
    int next = currentIndex;
    while (next == currentIndex) {
      next = Random().nextInt(playlist.length);
    }
    setState(() {
      currentIndex = next;
      _position = Duration.zero;
      _duration = Duration.zero;
      _hasStartedPlayback = false;
    });
    await _playAudio(playlist[next]);
  }

  void _toggleFavorite(String songId) {
    setState(() {
      if (!favoriteSongs.add(songId)) favoriteSongs.remove(songId);
    });
  }

  Future<void> _removeFromPlaylist(int index) async {
    if (index < 0 || index >= playlist.length) return;
    final wasCurrent = index == currentIndex;

    setState(() {
      playlist.removeAt(index);
      if (playlist.isEmpty) {
        currentIndex = -1;
        _position = Duration.zero;
        _duration = Duration.zero;
        _hasStartedPlayback = false;
      } else if (wasCurrent) {
        if (currentIndex >= playlist.length) {
          currentIndex = playlist.length - 1;
        }
        _position = Duration.zero;
        _duration = Duration.zero;
        _hasStartedPlayback = false;
      } else if (index < currentIndex) {
        currentIndex--;
      }
    });

    if (wasCurrent) {
      await _audioPlayer.stop();
      if (playlist.isNotEmpty && currentIndex >= 0) {
        await _playAudio(playlist[currentIndex]);
      }
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final minutes =
        duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds =
        duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  void dispose() {
    _rotationController.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final validIndex = currentIndex >= 0 && currentIndex < playlist.length;
    final currentSong = validIndex ? playlist[currentIndex] : null;
    final currentTitle = currentSong?.title ?? 'No song selected';
    final currentArtist = currentSong?.artist ?? '';

    final filteredPlaylist = playlist.where((song) {
      final matchesSearch =
          song.title.toLowerCase().contains(searchQuery.toLowerCase()) ||
          song.artist.toLowerCase().contains(searchQuery.toLowerCase());
      final matchesFavorite =
          !showOnlyFavorites || favoriteSongs.contains(song.id);
      return matchesSearch && matchesFavorite;
    }).toList();

    final durationSeconds = _duration.inSeconds.toDouble();
    final positionSeconds = _position.inSeconds
        .toDouble()
        .clamp(0.0, durationSeconds > 0 ? durationSeconds : 0.0);

    return Scaffold(
      appBar: AppBar(
        title: isSearching
            ? TextField(
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: 'Search music...',
                  hintStyle: TextStyle(color: Colors.grey),
                  border: InputBorder.none,
                ),
                onChanged: (value) => setState(() => searchQuery = value),
              )
            : const Text(
                'My Music Library',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
        actions: [
          IconButton(
            icon: Icon(isSearching ? Icons.close : Icons.search),
            onPressed: () => setState(() {
              isSearching = !isSearching;
              if (!isSearching) searchQuery = '';
            }),
          ),
          IconButton(
            icon: Icon(
              showOnlyFavorites ? Icons.favorite : Icons.favorite_border,
              color: showOnlyFavorites ? Colors.redAccent : Colors.white,
            ),
            onPressed: () =>
                setState(() => showOnlyFavorites = !showOnlyFavorites),
          ),
          if (!kIsWeb)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Scan device music',
              onPressed: isLoadingSongs ? null : _loadDeviceMusic,
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    const SizedBox(height: 10),
                    RotationTransition(
                      turns: _rotationController,
                      child: Container(
                        padding: const EdgeInsets.all(25),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFF252336),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.deepPurpleAccent
                                  .withValues(alpha: 0.3),
                              blurRadius: 20,
                              spreadRadius: 5,
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.music_note_rounded,
                          size: 80,
                          color: Colors.deepPurpleAccent,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            children: [
                              Text(
                                currentTitle,
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                              if (currentArtist.isNotEmpty) ...[
                                const SizedBox(height: 5),
                                Text(
                                  currentArtist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: Colors.grey,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (validIndex)
                          IconButton(
                            icon: Icon(
                              favoriteSongs.contains(currentSong!.id)
                                  ? Icons.favorite
                                  : Icons.favorite_border,
                              color: favoriteSongs.contains(currentSong.id)
                                  ? Colors.redAccent
                                  : Colors.grey,
                            ),
                            onPressed: () =>
                                _toggleFavorite(currentSong.id),
                          ),
                      ],
                    ),
                    const SizedBox(height: 15),
                    Slider(
                      min: 0,
                      max: durationSeconds > 0 ? durationSeconds : 1,
                      value: durationSeconds > 0 ? positionSeconds : 0,
                      activeColor: Colors.deepPurpleAccent,
                      inactiveColor: Colors.grey.shade800,
                      onChanged: durationSeconds > 0
                          ? (value) => _audioPlayer.seek(
                                Duration(seconds: value.toInt()),
                              )
                          : null,
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            _formatDuration(_position),
                            style: const TextStyle(
                                color: Colors.grey, fontSize: 12),
                          ),
                          Text(
                            _formatDuration(_duration),
                            style: const TextStyle(
                                color: Colors.grey, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _volume == 0 ? Icons.volume_off : Icons.volume_up,
                          color: Colors.deepPurpleAccent,
                          size: 18,
                        ),
                        SizedBox(
                          width: 160,
                          child: Slider(
                            value: _volume,
                            min: 0,
                            max: 1,
                            activeColor: Colors.deepPurpleAccent,
                            inactiveColor: Colors.grey.shade800,
                            onChanged: (value) {
                              setState(() => _volume = value);
                              _audioPlayer.setVolume(value);
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          icon: Icon(
                            Icons.shuffle,
                            color: isShuffle
                                ? Colors.deepPurpleAccent
                                : Colors.grey,
                          ),
                          onPressed: () =>
                              setState(() => isShuffle = !isShuffle),
                        ),
                        IconButton(
                          iconSize: 32,
                          icon: const Icon(Icons.skip_previous),
                          onPressed:
                              playlist.isEmpty ? null : _playPrevious,
                        ),
                        CircleAvatar(
                          radius: 28,
                          backgroundColor: Colors.deepPurpleAccent,
                          child: IconButton(
                            iconSize: 28,
                            icon: Icon(
                              isPlaying ? Icons.pause : Icons.play_arrow,
                              color: Colors.white,
                            ),
                            onPressed:
                                validIndex ? _togglePlayPause : null,
                          ),
                        ),
                        IconButton(
                          iconSize: 32,
                          icon: const Icon(Icons.skip_next),
                          onPressed: playlist.isEmpty ? null : _playNext,
                        ),
                        IconButton(
                          icon: Icon(
                            Icons.repeat,
                            color: isRepeat
                                ? Colors.deepPurpleAccent
                                : Colors.grey,
                          ),
                          onPressed: () =>
                              setState(() => isRepeat = !isRepeat),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (kIsWeb)
                      ElevatedButton.icon(
                        onPressed: (isLoadingSongs || _isPickingFiles) ? null : _pickMusicFiles,
                        icon: const Icon(Icons.library_music),
                        label: Text(_isPickingFiles ? 'Opening Picker...' : 'Choose Music Files'),
                        style: _buttonStyle(),
                      )
                    else
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 10,
                        runSpacing: 8,
                        children: [
                          ElevatedButton.icon(
                            onPressed:
                                isLoadingSongs ? null : _loadDeviceMusic,
                            icon: isLoadingSongs
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Icon(Icons.refresh),
                            label: Text(isLoadingSongs
                                ? 'Scanning Music...'
                                : 'Scan Device Music'),
                            style: _buttonStyle(),
                          ),
                          ElevatedButton.icon(
                            onPressed: (isLoadingSongs || _isPickingFiles) ? null : _pickMusicFiles,
                            icon: const Icon(Icons.add),
                            label: Text(_isPickingFiles ? 'Opening Picker...' : 'Choose Files'),
                            style: _buttonStyle(),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
            const Divider(color: Colors.white24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  showOnlyFavorites ? 'Favorite Songs:' : 'Device Library:',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15),
                ),
                Text(
                  '${filteredPlaylist.length} songs',
                  style: const TextStyle(color: Colors.grey, fontSize: 13),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 160,
              child: isLoadingSongs
                  ? const Center(child: CircularProgressIndicator())
                  : filteredPlaylist.isEmpty
                      ? const Center(
                          child: Text(
                            'No music found',
                            style: TextStyle(color: Colors.grey),
                          ),
                        )
                      : ListView.builder(
                          itemCount: filteredPlaylist.length,
                          itemBuilder: (context, index) {
                            final song = filteredPlaylist[index];
                            final originalIndex = playlist.indexOf(song);
                            final selected = originalIndex == currentIndex;
                            final isFav = favoriteSongs.contains(song.id);

                            return ListTile(
                              dense: true,
                              leading: Icon(
                                selected
                                    ? Icons.graphic_eq
                                    : Icons.music_note,
                                color: selected
                                    ? Colors.deepPurpleAccent
                                    : Colors.grey,
                              ),
                              title: Text(
                                song.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: selected
                                      ? Colors.deepPurpleAccent
                                      : Colors.white,
                                  fontWeight: selected
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                              ),
                              subtitle: Text(
                                song.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.grey,
                                  fontSize: 12,
                                ),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: Icon(
                                      isFav
                                          ? Icons.favorite
                                          : Icons.favorite_border,
                                      size: 18,
                                      color: isFav
                                          ? Colors.redAccent
                                          : Colors.grey,
                                    ),
                                    onPressed: () => _toggleFavorite(song.id),
                                  ),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.remove_circle_outline,
                                      size: 18,
                                      color: Colors.grey,
                                    ),
                                    tooltip: 'Remove from this list',
                                    onPressed: () =>
                                        _removeFromPlaylist(originalIndex),
                                  ),
                                ],
                              ),
                              onTap: () {
                                setState(() {
                                  currentIndex = originalIndex;
                                  _position = Duration.zero;
                                  _duration = Duration.zero;
                                  _hasStartedPlayback = false;
                                });
                                _playAudio(playlist[originalIndex]);
                              },
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }

  ButtonStyle _buttonStyle() {
    return ElevatedButton.styleFrom(
      backgroundColor: Colors.deepPurpleAccent,
      foregroundColor: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
    );
  }
}
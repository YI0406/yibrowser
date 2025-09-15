import 'package:flutter/material.dart';
import 'browser.dart';
import 'home.dart';
import 'media.dart';
import 'setting.dart';
import 'soure.dart';
import 'package:video_player/video_player.dart';
import 'dart:io';
import 'dart:async';

/// Entry point of the application. Initializes WebView debugging and sets up
/// the root navigation with three tabs: browser, media, and settings.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Enable debugging for WebView content (useful during development).
  await Sniffer.initWebViewDebug();
  // Load any persisted downloads so media lists persist across restarts.
  await AppRepo.I.init();
  runApp(const MyApp());
}

/// Root widget of the app.
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sniffer Browser',
      // Follow system theme: use light/dark themes and rely on system setting.
      themeMode: ThemeMode.system,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.dark,
      ),
      home: const RootNav(),
    );
  }
}

/// Main navigation widget that holds the three core pages and a bottom
/// navigation bar to switch between them.
class RootNav extends StatefulWidget {
  const RootNav({super.key});

  @override
  State<RootNav> createState() => _RootNavState();
}

class _RootNavState extends State<RootNav> {
  // Index of the selected tab.
  // Start on home tab by default (index 1).
  int index = 1;
  // Pages for bottom navigation bar: media, home, browser, settings. Initialized in initState.
  late final List<Widget> pages;

  @override
  void initState() {
    super.initState();
    // Initialize pages with callbacks. Use lazy initialization so that
    // callbacks capture the correct context.
    pages = [
      const MediaPage(),
      HomePage(
        onOpen: (String url) {
          // When a shortcut is tapped, set the pending URL and switch to the browser tab.
          AppRepo.I.pendingOpenUrl.value = url;
          setState(() {
            index = 2;
          });
        },
      ),
      BrowserPage(
        onGoHome: () {
          // Navigate to the home tab.
          setState(() {
            index = 1;
          });
        },
      ),
      const SettingPage(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Use IndexedStack so the state of each page persists when switching tabs.
      body: Stack(
        children: [
          IndexedStack(index: index, children: pages),
          // Overlay the mini player when active. The mini player floats above
          // the content and bottom navigation bar. When null, nothing is
          // displayed.
          ValueListenableBuilder<MiniPlayerData?>(
            valueListenable: AppRepo.I.miniPlayer,
            builder: (context, mini, _) {
              if (mini == null) return const SizedBox.shrink();
              return Positioned(
                left: 8,
                right: 8,
                bottom: kBottomNavigationBarHeight + 8,
                child: MiniPlayerWidget(data: mini),
              );
            },
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        destinations: const [
          // order: Media, Home, Browser, Settings
          NavigationDestination(
            icon: Icon(Icons.video_library_outlined),
            label: '媒體',
          ),
          NavigationDestination(
            icon: Icon(Icons.home),
            label: '主頁',
          ),
          NavigationDestination(icon: Icon(Icons.public), label: '瀏覽器'),
          NavigationDestination(icon: Icon(Icons.settings), label: '設定'),
        ],
        onDestinationSelected: (i) => setState(() => index = i),
      ),
    );
  }
}

/// A floating mini player overlay shown above the root content. When active,
/// it plays a video in a small panel with play/pause, progress bar, expand
/// and close buttons. Tapping the expand icon reopens the full player page.
class MiniPlayerWidget extends StatefulWidget {
  final MiniPlayerData data;
  const MiniPlayerWidget({super.key, required this.data});

  @override
  State<MiniPlayerWidget> createState() => _MiniPlayerWidgetState();
}

class _MiniPlayerWidgetState extends State<MiniPlayerWidget> {
  late VideoPlayerController _vc;
  bool _ready = false;
  bool _showControls = true;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    // Support both local and remote videos. If the path looks like an HTTP(S)
    // URL then stream it directly rather than reading from disk. This
    // enables playing videos discovered in the browser via the mini player.
    if (widget.data.path.startsWith('http://') ||
        widget.data.path.startsWith('https://')) {
      _vc = VideoPlayerController.network(widget.data.path);
    } else {
      _vc = VideoPlayerController.file(File(widget.data.path));
    }
    _vc
      ..initialize().then((_) {
        if (!mounted) return;
        setState(() => _ready = true);
        // If a start position was provided (e.g. returning from fullscreen),
        // seek to that point before starting playback. This ensures the
        // mini player continues from where the user left off rather than
        // starting from the beginning.
        final start = widget.data.startAt;
        if (start != null && start > Duration.zero) {
          final dur = _vc.value.duration;
          if (dur == Duration.zero || start < dur) {
            _vc.seekTo(start);
          }
        }
        _vc.play();
        _startAutoHide();
      });
    _vc.addListener(() {
      if (mounted) setState(() {});
    });
  }

  void _startAutoHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _vc.value.isPlaying) {
        setState(() => _showControls = false);
      }
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _vc.dispose();
    super.dispose();
  }

  void _togglePlay() {
    if (!_ready) return;
    if (_vc.value.isPlaying) {
      _vc.pause();
    } else {
      _vc.play();
      _startAutoHide();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final aspect =
        (_ready && _vc.value.size != Size.zero)
            ? _vc.value.aspectRatio
            : (16 / 9);
    final Duration dur = _vc.value.duration;
    final Duration pos = _vc.value.position;
    final double totalMs =
        dur.inMilliseconds.toDouble().clamp(1.0, double.maxFinite) as double;
    final double currentMs =
        pos.inMilliseconds.toDouble().clamp(0.0, totalMs) as double;

    return GestureDetector(
      onTap: () {
        setState(() => _showControls = !_showControls);
        if (_showControls && _vc.value.isPlaying) _startAutoHide();
      },
      child: Material(
        color: Colors.black.withOpacity(0.8),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
              // Video preview area with fixed width maintaining aspect ratio
              Container(
                width: 120,
                height: 68,
                color: Colors.black,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child:
                      _ready
                          ? AspectRatio(
                            aspectRatio: aspect,
                            child: VideoPlayer(_vc),
                          )
                          : const Center(child: CircularProgressIndicator()),
                ),
              ),
              const SizedBox(width: 8),
              // Expanded area with controls
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.data.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white),
                    ),
                    // Progress bar
                    Slider(
                      min: 0.0,
                      max: totalMs,
                      value: currentMs,
                      onChanged: (v) async {
                        final target = Duration(milliseconds: v.round());
                        await _vc.seekTo(target);
                      },
                    ),
                    if (_showControls)
                      Row(
                        children: [
                          IconButton(
                            icon: Icon(
                              _vc.value.isPlaying
                                  ? Icons.pause
                                  : Icons.play_arrow,
                              color: Colors.white,
                            ),
                            onPressed: _togglePlay,
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.fullscreen,
                              color: Colors.white,
                            ),
                            tooltip: '放大',
                            onPressed: () {
                              // Capture the current playback position before closing
                              final pos = _vc.value.position;
                              // Close mini and reopen full page player with resume position.
                              AppRepo.I.closeMiniPlayer();
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => VideoPlayerPage(
                                    path: widget.data.path,
                                    title: widget.data.title,
                                    startAt: pos,
                                  ),
                                ),
                              );
                            },
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, color: Colors.white),
                            tooltip: '關閉',
                            onPressed: () {
                              AppRepo.I.closeMiniPlayer();
                            },
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'browser.dart';
import 'home.dart';
import 'media.dart';
import 'video_player_page.dart';
import 'setting.dart';
import 'soure.dart';
import 'package:flutter_in_app_pip/flutter_in_app_pip.dart';
import 'package:video_player/video_player.dart';
import 'dart:io';
import 'ads.dart';
import 'iap.dart';
import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_analytics/observer.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:app_tracking_transparency/app_tracking_transparency.dart';
import 'package:quick_actions/quick_actions.dart';

/// Entry point of the application. Initializes WebView debugging and sets up
/// the root navigation with three tabs: browser, media, and settings.
Future<void> _requestATTIfNeeded() async {
  if (!Platform.isIOS) return;
  try {
    final status = await AppTrackingTransparency.trackingAuthorizationStatus;
    if (status == TrackingStatus.notDetermined) {
      // Give iOS a brief moment to ensure the dialog can be presented cleanly.
      await Future.delayed(const Duration(milliseconds: 200));
      await AppTrackingTransparency.requestTrackingAuthorization();
    }
  } catch (e) {
    debugPrint('ATT request error: $e');
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase (uses GoogleService-Info.plist on iOS when no options provided).
  try {
    await Firebase.initializeApp();
    // Log cold start
    try {
      await FirebaseAnalytics.instance.logAppOpen();
    } catch (_) {}
  } catch (_) {
    // Keep app running even if Firebase is absent in non-Firebase builds.
  }
  // Enable debugging for WebView content (useful during development).
  await Sniffer.initWebViewDebug();
  // Load any persisted downloads so media lists persist across restarts.
  await AppRepo.I.init();
  final purchaseService = PurchaseService();
  purchaseService.onPurchaseUpdated = () {
    final unlocked = purchaseService.isPremiumUnlocked;
    AppRepo.I.setPremiumUnlocked(unlocked);
    AdService.instance.setPremiumUnlocked(unlocked);
  };
  purchaseService.onIapBusyChanged = (busy) {
    AdService.instance.setIapBusy(busy);
  };
  await purchaseService.initStoreInfo();
  AppRepo.I.setPremiumUnlocked(purchaseService.isPremiumUnlocked);

  await AdService.instance.init();
  // Request ATT prior to initializing ads (iOS only)
  await _requestATTIfNeeded();
  AdService.instance.setPremiumUnlocked(purchaseService.isPremiumUnlocked);
  runApp(const MyApp());
}

/// Root widget of the app.
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
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
      navigatorObservers: [
        // Report navigation as screen_view 到 Firebase Analytics
        FirebaseAnalyticsObserver(analytics: FirebaseAnalytics.instance),
      ],
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
  static const String _quickActionNewTab = 'quick_action_new_tab';
  static const String _quickActionMedia = 'quick_action_media';
  final QuickActions _quickActions = const QuickActions();
  bool _handledInitialQuickAction = false;
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
    _configureQuickActions();
  }

  void _configureQuickActions() {
    if (!(Platform.isIOS || Platform.isAndroid)) {
      return;
    }
    void dispatchQuickAction(String? type, {bool fromLaunchCheck = false}) {
      if (type == null) {
        return;
      }
      if (fromLaunchCheck && _handledInitialQuickAction) {
        return;
      }
      _handledInitialQuickAction = true;
      _handleQuickAction(type);
    }

    bool hasProcessedInitialCallback = false;

    _quickActions.initialize((String? type) {
      final bool fromLaunchCallback = !hasProcessedInitialCallback;
      hasProcessedInitialCallback = true;
      dispatchQuickAction(type, fromLaunchCheck: fromLaunchCallback);
    });

    Future<void> setupShortcuts() async {
      try {
        // Register dynamic shortcuts on BOTH Android and iOS.
        // iOS: this coexists with static UIApplicationShortcutItems in Info.plist.
        await _quickActions.setShortcutItems(const <ShortcutItem>[
          ShortcutItem(type: _quickActionNewTab, localizedTitle: '新分頁'),
          ShortcutItem(type: _quickActionMedia, localizedTitle: '媒體'),
        ]);
      } catch (_) {
        // Quick actions are optional enhancements; ignore platform errors.
      }
    }

    unawaited(setupShortcuts());
  }

  void _handleQuickAction(String type) {
    if (!mounted) {
      return;
    }
    switch (type) {
      case _quickActionNewTab:
        setState(() {
          index = 2;
        });
        AppRepo.I.requestNewTab();
        break;
      case _quickActionMedia:
        setState(() {
          index = 0;
        });
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Use IndexedStack so the state of each page persists when switching tabs.
      body: Stack(
        children: [
          IndexedStack(index: index, children: pages),
          // Overlay the mini player when active. Dock position can be top/
          // middle/bottom and updates in real‑time.
          ValueListenableBuilder<MiniPlayerData?>(
            valueListenable: AppRepo.I.miniPlayer,
            builder: (context, mini, _) {
              if (mini == null) return const SizedBox.shrink();
              return LayoutBuilder(
                builder: (ctx, box) {
                  final size = MediaQuery.of(ctx).size;
                  return ValueListenableBuilder<Offset>(
                    valueListenable: AppRepo.I.miniOffset,
                    builder: (context, off, __) {
                      // fallback to bottom-right if not yet positioned
                      double left = off.dx;
                      double top = off.dy;
                      if (left == 0 && top == 0) {
                        left = size.width - 280;
                        top = size.height - (kBottomNavigationBarHeight + 180);
                      }
                      // Clamp inside screen
                      left = left.clamp(8.0, size.width - 200.0);
                      top = top.clamp(
                        32.0,
                        size.height - (kBottomNavigationBarHeight + 140.0),
                      );
                      return Positioned(
                        left: left,
                        top: top,
                        child: MiniPlayerWidget(data: mini),
                      );
                    },
                  );
                },
              );
            },
          ),
        ],
      ),
      bottomNavigationBar: ValueListenableBuilder<BannerAd?>(
        valueListenable: AdService.instance.bannerAdNotifier,
        builder: (context, banner, _) {
          final navBar = NavigationBar(
            selectedIndex: index,
            destinations: const [
              // order: Media, Home, Browser, Settings
              NavigationDestination(
                icon: Icon(Icons.video_library_outlined),
                label: '媒體',
              ),
              NavigationDestination(icon: Icon(Icons.home), label: '主頁'),
              NavigationDestination(icon: Icon(Icons.public), label: '瀏覽器'),
              NavigationDestination(icon: Icon(Icons.settings), label: '設定'),
            ],
            onDestinationSelected: (i) => setState(() => index = i),
          );
          if (banner == null) {
            return SafeArea(top: false, child: navBar);
          }
          return SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  alignment: Alignment.center,
                  color: Theme.of(context).colorScheme.surface,
                  child: SizedBox(
                    width: banner.size.width.toDouble(),
                    height: banner.size.height.toDouble(),
                    child: AdWidget(ad: banner),
                  ),
                ),
                navBar,
              ],
            ),
          );
        },
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
  double _dragDy = 0.0; // accumulate vertical drag distance
  Offset? _dragStartPos;

  @override
  void initState() {
    super.initState();
    // Support both local and remote videos. If the path looks like an HTTP(S)
    // URL then stream it directly rather than reading from disk. This
    // enables playing videos discovered in the browser via the mini player.
    final bgOptions =
        Platform.isIOS
            ? VideoPlayerOptions(allowBackgroundPlayback: true)
            : null;
    if (widget.data.path.startsWith('http://') ||
        widget.data.path.startsWith('https://')) {
      _vc = VideoPlayerController.network(
        widget.data.path,
        videoPlayerOptions: bgOptions,
      );
    } else {
      _vc = VideoPlayerController.file(
        File(widget.data.path),
        videoPlayerOptions: bgOptions,
      );
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
      // Single tap toggles play/pause to mimic other apps' mini player
      onTap: _togglePlay,
      onLongPress: () {
        setState(() => _showControls = !_showControls);
        if (_showControls && _vc.value.isPlaying) _startAutoHide();
      },
      // Free drag anywhere to reposition like AssistiveTouch
      onPanStart: (d) {
        _dragStartPos = d.globalPosition;
        if (AppRepo.I.miniOffset.value == Offset.zero) {
          try {
            final box = context.findRenderObject() as RenderBox?;
            if (box != null) {
              final origin = box.localToGlobal(Offset.zero);
              AppRepo.I.miniOffset.value = origin;
            }
          } catch (_) {}
        }
      },
      onPanUpdate: (d) {
        final cur = AppRepo.I.miniOffset.value;
        // When offset is zero (not yet set), seed with current pointer
        Offset base = cur == Offset.zero ? const Offset(0, 0) : cur;
        AppRepo.I.miniOffset.value = Offset(
          base.dx + d.delta.dx,
          base.dy + d.delta.dy,
        );
      },
      onPanEnd: (_) {
        _dragStartPos = null;
      },
      child: Material(
        color: Colors.black.withOpacity(0.75),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Video preview area with fixed width maintaining aspect ratio
              Container(
                width: 160,
                height: 90,
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
              // Compact title + buttons (no slider/progress)
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.data.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white),
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
                                builder:
                                    (_) => VideoPlayerPage(
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
            ],
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'browser.dart';
import 'home.dart';
import 'media.dart';
import 'video_player_page.dart';
import 'setting.dart';
import 'soure.dart';
import 'share_review_page.dart';
import 'package:flutter_in_app_pip/flutter_in_app_pip.dart';
import 'package:video_player/video_player.dart';
import 'dart:io';
import 'ads.dart';
import 'iap.dart';
import 'dart:async';
import 'package:path/path.dart' as p;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_analytics/observer.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:app_tracking_transparency/app_tracking_transparency.dart';
import 'package:quick_actions/quick_actions.dart';
import 'package:flutter/services.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'app_localizations.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

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
  await LanguageService.instance.init();
  runApp(const MyApp());
}

/// Root widget of the app.
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppLanguage>(
      valueListenable: LanguageService.instance.languageListenable,
      builder: (context, language, _) {
        final languageService = LanguageService.instance;
        return MaterialApp(
          navigatorKey: navigatorKey,
          title: languageService.translate('app.title'),
          locale: languageService.currentLocale,
          supportedLocales: languageService.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
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
      },
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

class _RootNavState extends State<RootNav> with LanguageAwareState<RootNav> {
  // Index of the selected tab.
  // Start on home tab by default (index 1).
  int index = 1;
  // Pages for bottom navigation bar: media, home, browser, settings. Initialized in initState.
  late final List<Widget> pages;
  static const String _quickActionNewTab = 'quick_action_new_tab';
  static const String _quickActionMedia = 'quick_action_media';
  static const MethodChannel _iosQuickActionChannel = MethodChannel(
    'app.quick_actions_bridge',
  );
  static const MethodChannel _iosShareChannel = MethodChannel(
    'com.yibrowser/share',
  );
  final QuickActions _quickActions = const QuickActions();
  ReceiveSharingIntent get _receiveSharingIntent =>
      ReceiveSharingIntent.instance;
  bool _handledInitialQuickAction = false;
  DateTime? _lastQuickActionAt;
  String? _lastQuickActionType;
  StreamSubscription<List<SharedMediaFile>>? _sharedMediaSubscription;
  bool _iosShareHandlerRegistered = false;
  String? _lastShareEventKey;
  DateTime? _lastShareEventAt;
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
    _initShareHandling();
  }

  void _configureQuickActions() {
    if (!(Platform.isIOS || Platform.isAndroid)) {
      return;
    }
    void dispatchQuickAction(String? type, {bool fromLaunchCheck = false}) {
      if (type == null) {
        return;
      }
      if (fromLaunchCheck) {
        if (_handledInitialQuickAction) {
          return;
        }
        _handledInitialQuickAction = true;
      }
      final now = DateTime.now();
      if (_lastQuickActionType == type &&
          _lastQuickActionAt != null &&
          now.difference(_lastQuickActionAt!).inMilliseconds < 300) {
        return;
      }
      _lastQuickActionType = type;
      _lastQuickActionAt = now;
      _handleQuickAction(type);
    }

    Future<void> setupAndroidShortcuts() async {
      if (!Platform.isAndroid) {
        return;
      }
      try {
        // Register dynamic shortcuts on BOTH Android and iOS.
        // iOS: this coexists with static UIApplicationShortcutItems in Info.plist.
        final language = LanguageService.instance;
        await _quickActions.setShortcutItems(<ShortcutItem>[
          ShortcutItem(
            type: _quickActionNewTab,
            localizedTitle: language.translate('main.quickAction.newTab'),
          ),
          ShortcutItem(
            type: _quickActionMedia,
            localizedTitle: language.translate('main.quickAction.media'),
          ),
        ]);
      } catch (_) {
        // Quick actions are optional enhancements; ignore platform errors.
      }
    }

    if (Platform.isIOS) {
      _iosQuickActionChannel.setMethodCallHandler((call) async {
        if (call.method != 'launchShortcut') {
          return;
        }
        String? type;
        bool fromLaunch = false;
        final args = call.arguments;
        if (args is Map) {
          final dynamic rawType = args['type'];
          if (rawType is String) {
            type = rawType;
          }
          fromLaunch = args['from_launch'] == true;
        } else if (args is String?) {
          type = args;
        }
        dispatchQuickAction(type, fromLaunchCheck: fromLaunch);
      });

      Future<void> requestInitialShortcut() async {
        try {
          await _iosQuickActionChannel.invokeMethod('readyForQuickActions');
        } catch (_) {
          // Missing handler or other native errors can be ignored safely.
        }
      }

      unawaited(requestInitialShortcut());
      return;
    }

    bool hasProcessedInitialCallback = false;

    _quickActions.initialize((String? type) {
      final bool fromLaunchCallback = !hasProcessedInitialCallback;
      hasProcessedInitialCallback = true;
      dispatchQuickAction(type, fromLaunchCheck: fromLaunchCallback);
    });
    unawaited(setupAndroidShortcuts());
  }

  void _initShareHandling() {
    if (Platform.isIOS) {
      debugPrint('[Share] Initializing iOS share bridge');
      if (!_iosShareHandlerRegistered) {
        _iosShareChannel.setMethodCallHandler((call) async {
          if (call.method == 'onShareTriggered') {
            await _consumeIosSharedDownloads();
            return;
          }
          debugPrint('[Share] Unknown iOS share callback: ${call.method}');
        });
        _iosShareHandlerRegistered = true;
      }
      unawaited(_consumeIosSharedDownloads());
      return;
    }
    if (!Platform.isAndroid) {
      return;
    }
    debugPrint('[Share] Initializing share handling listeners');
    _sharedMediaSubscription = _receiveSharingIntent.getMediaStream().listen(
      (mediaFiles) {
        debugPrint(
          '[Share] Stream event received with ${mediaFiles.length} item(s)',
        );
        final incoming = mediaFiles
            .map(_incomingShareFromPlugin)
            .toList(growable: false);
        _importAndPresentSharedMedia(incoming);
      },
      onError: (Object err) {
        debugPrint('Share stream error: $err');
      },
    );

    _receiveSharingIntent
        .getInitialMedia()
        .then((mediaFiles) {
          debugPrint(
            '[Share] Initial media fetch returned ${mediaFiles.length} item(s)',
          );
          if (mediaFiles.isEmpty) {
            return;
          }
          final incoming = mediaFiles
              .map(_incomingShareFromPlugin)
              .toList(growable: false);
          _importAndPresentSharedMedia(incoming);
        })
        .catchError((Object err) {
          debugPrint('Initial media error: $err');
        });
  }

  Future<void> _consumeIosSharedDownloads() async {
    List<dynamic>? rawItems;
    try {
      rawItems = await _iosShareChannel.invokeMethod<List<dynamic>>(
        'consumeSharedDownloads',
      );
    } catch (err) {
      debugPrint('[Share] Failed to consume iOS shared downloads: $err');
      return;
    }
    if (rawItems == null || rawItems.isEmpty) {
      return;
    }
    final entries = rawItems
        .whereType<Map<dynamic, dynamic>>()
        .map(_incomingShareFromIosMap)
        .whereType<IncomingShare>()
        .toList(growable: false);
    if (entries.isEmpty) {
      debugPrint('[Share] consumeIosSharedDownloads yielded no valid items');
      return;
    }
    await _importAndPresentSharedMedia(entries);
  }

  IncomingShare? _incomingShareFromIosMap(Map<dynamic, dynamic> map) {
    final pathValue = map['path'];
    if (pathValue is! String || pathValue.isEmpty) {
      return null;
    }
    final typeValue = map['type'];
    String? type;
    if (typeValue is String && typeValue.isNotEmpty) {
      type = typeValue;
    }
    final relative = map['relativePath'];
    final relativePath =
        relative is String && relative.isNotEmpty ? relative : null;
    final displayValue = map['displayName'];
    String? displayName;
    if (displayValue is String) {
      final trimmed = displayValue.trim();
      if (trimmed.isNotEmpty) {
        displayName = trimmed;
      }
    }
    return IncomingShare(
      path: pathValue,
      typeHint: type,
      relativePath: relativePath,
      displayName: displayName,
    );
  }

  IncomingShare _incomingShareFromPlugin(SharedMediaFile file) {
    final baseName = p.basename(file.path);
    return IncomingShare(
      path: file.path,
      typeHint: _normalizedShareType(file.type),
      relativePath: null,
      displayName: baseName.isNotEmpty ? baseName : null,
    );
  }

  Future<void> _importAndPresentSharedMedia(
    List<IncomingShare> mediaFiles,
  ) async {
    if (mediaFiles.isEmpty) {
      debugPrint('[Share] Import requested with 0 items; ignoring');
      return;
    }
    debugPrint(
      '[Share] Incoming media files: '
      '${mediaFiles.map((f) => '${f.path} (type: ${f.typeHint})').join(', ')}',
    );
    final signature = mediaFiles.map((f) => f.path).join('|');
    final now = DateTime.now();
    if (_lastShareEventKey == signature &&
        _lastShareEventAt != null &&
        now.difference(_lastShareEventAt!) < const Duration(seconds: 2)) {
      debugPrint('[Share] Duplicate share event ignored for $signature');
      return;
    }
    _lastShareEventKey = signature;
    _lastShareEventAt = now;

    if (!mounted) {
      return;
    }

    setState(() {
      index = 0;
    });
    final items = List<IncomingShare>.unmodifiable(mediaFiles);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showShareReview(items);
    });
  }

  String? _normalizedShareType(dynamic rawType) {
    if (rawType == null) {
      return null;
    }
    if (rawType is SharedMediaType) {
      switch (rawType) {
        case SharedMediaType.video:
          return 'video';

        case SharedMediaType.image:
          return 'image';
        case SharedMediaType.file:
          return 'file';
        default:
          return null;
      }
    }
    if (rawType is String) {
      final lower = rawType.toLowerCase();
      if (lower.contains('video')) return 'video';
      if (lower.contains('audio')) return 'audio';
      if (lower.contains('image')) return 'image';
      if (lower.contains('file')) return 'file';
      return lower;
    }
    final description = rawType.toString().toLowerCase();
    if (description.contains('video')) return 'video';
    if (description.contains('audio')) return 'audio';
    if (description.contains('image')) return 'image';
    if (description.contains('file')) return 'file';
    return description.isEmpty ? null : description;
  }

  void _showShareReview(List<IncomingShare> items, {int attempt = 0}) {
    if (!mounted || items.isEmpty) {
      return;
    }
    final nav = navigatorKey.currentState;
    final ctx = navigatorKey.currentContext ?? context;
    if (nav == null || ctx == null) {
      if (attempt >= 5) {
        return;
      }
      Future.delayed(const Duration(milliseconds: 200), () {
        _showShareReview(items, attempt: attempt + 1);
      });
      return;
    }

    nav
        .push<ShareReviewResult>(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder:
                (_) => ShareReviewPage(
                  items: items,
                  onConfirm: _confirmSharedImports,
                  onDiscard: _discardSharedImports,
                ),
          ),
        )
        .then((result) {
          if (!mounted || result == null) {
            return;
          }
          final message = result.message;
          if (message != null && message.isNotEmpty) {
            ScaffoldMessenger.of(
              ctx,
            ).showSnackBar(SnackBar(content: Text(message)));
          }
        });
  }

  Future<ShareReviewResult> _confirmSharedImports(
    List<IncomingShare> items,
  ) async {
    final imported = <DownloadTask>[];
    int failureCount = 0;

    for (final media in items) {
      final originalPath = media.path;
      String resolvedPath = originalPath;
      final uri = Uri.tryParse(originalPath);
      if (uri != null && uri.hasScheme) {
        if (uri.scheme != 'file') {
          debugPrint('[Share] Non-file URI detected: $originalPath');
        }
        try {
          resolvedPath = uri.toFilePath();
        } catch (err) {
          debugPrint('[Share] Failed to convert URI $originalPath: $err');
        }
      }
      if (resolvedPath != originalPath) {
        debugPrint(
          '[Share] Resolved share path: $originalPath -> $resolvedPath',
        );
      }
      final exists = await File(resolvedPath).exists();
      debugPrint('[Share] Candidate path check: $resolvedPath exists=$exists');
      final task = await AppRepo.I.importSharedMediaFile(
        sourcePath: resolvedPath,
        displayName: media.displayName ?? p.basename(resolvedPath),
        typeHint: media.typeHint,
      );
      if (task != null) {
        imported.add(task);
      } else {
        failureCount += 1;
        debugPrint('[Share] Import returned null for $resolvedPath');
      }
    }

    if (Platform.isAndroid) {
      try {
        await _receiveSharingIntent.reset();
      } catch (err) {
        debugPrint('[Share] Failed to reset share intent: $err');
      }
    }

    await _cleanupIncomingShares(items);

    String? message;
    if (imported.isNotEmpty) {
      final first = imported.first;
      final firstName = first.name ?? p.basename(first.savePath);
      if (imported.length == 1) {
        message =
            failureCount > 0
                ? context.l10n(
                  'main.snack.import.singleSuccessWithFailures',
                  params: {'name': firstName, 'count': '$failureCount'},
                )
                : context.l10n(
                  'main.snack.import.singleSuccess',
                  params: {'name': firstName},
                );
      } else {
        if (failureCount > 0) {
          message = context.l10n(
            'main.snack.import.multiSuccessWithFailures',
            params: {
              'count': '${imported.length}',
              'failures': '$failureCount',
            },
          );
        } else {
          message = context.l10n(
            'main.snack.import.multiSuccess',
            params: {'count': '${imported.length}'},
          );
        }
      }
    } else if (failureCount > 0) {
      message = context.l10n(
        'main.snack.import.failure',
        params: {'count': '$failureCount'},
      );
    } else {
      message = context.l10n('main.snack.import.none');
    }

    return ShareReviewResult(
      imported: imported.isNotEmpty,
      message: message,
      successCount: imported.length,
      failureCount: failureCount,
    );
  }

  Future<ShareReviewResult> _discardSharedImports(
    List<IncomingShare> items,
  ) async {
    if (Platform.isAndroid) {
      try {
        await _receiveSharingIntent.reset();
      } catch (err) {
        debugPrint('[Share] Failed to reset share intent: $err');
      }
    }
    await _cleanupIncomingShares(items);
    final count = items.length;
    final message =
        count > 1
            ? context.l10n(
              'main.snack.discarded.multiple',
              params: {'count': '$count'},
            )
            : context.l10n('main.snack.discarded.single');
    return ShareReviewResult(
      imported: false,
      message: message,
      successCount: 0,
      failureCount: 0,
    );
  }

  Future<void> _cleanupIncomingShares(List<IncomingShare> items) async {
    if (!Platform.isIOS) {
      return;
    }
    final cleanupPaths = items
        .map((e) => e.relativePath)
        .whereType<String>()
        .map((path) => path.trim())
        .where((path) => path.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (cleanupPaths.isEmpty) {
      return;
    }
    try {
      await _iosShareChannel.invokeMethod(
        'cleanupSharedDownloads',
        cleanupPaths,
      );
    } catch (err) {
      debugPrint('[Share] Cleanup for iOS shared downloads failed: $err');
    }
  }

  @override
  void dispose() {
    _sharedMediaSubscription?.cancel();
    if (_iosShareHandlerRegistered) {
      _iosShareChannel.setMethodCallHandler(null);
      _iosShareHandlerRegistered = false;
    }
    super.dispose();
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
          final theme = Theme.of(context);
          final navBar = NavigationBar(
            height: 64,
            elevation: 6,
            backgroundColor: theme.colorScheme.surface.withOpacity(0.94),
            shadowColor: theme.shadowColor.withOpacity(0.08),
            surfaceTintColor: Colors.transparent,
            indicatorColor: theme.colorScheme.primary.withOpacity(0.12),
            indicatorShape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
            selectedIndex: index,
            destinations: [
              // order: Media, Home, Browser, Settings
              NavigationDestination(
                icon: Icon(Icons.video_library_outlined),
                selectedIcon: Icon(Icons.video_library_rounded),
                label: context.l10n('main.nav.media'),
              ),
              NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home_rounded),
                label: context.l10n('main.nav.home'),
              ),
              NavigationDestination(
                icon: Icon(Icons.public_outlined),
                selectedIcon: Icon(Icons.public),
                label: context.l10n('main.nav.browser'),
              ),
              NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: context.l10n('main.nav.settings'),
              ),
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
                          tooltip: context.l10n('miniPlayer.tooltip.expand'),
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
                          tooltip: context.l10n('miniPlayer.tooltip.close'),
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

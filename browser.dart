import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/log.dart';
import 'package:ffmpeg_kit_flutter_new/session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'iap.dart';
import 'soure.dart';
// Import the media page to allow launching the built‑in video player when
// playing remote videos from the browser. This also brings in the
// VideoPlayerPage class used in the play callbacks.
import 'media.dart';
import 'video_player_page.dart';
import 'image_preview_page.dart';
import 'package:share_plus/share_plus.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'app_localizations.dart';
import 'yt.dart';

// --- Top-level helper for measuring instantaneous rates (bytes per second)
class _RateSnapshot {
  final int bytes;
  final DateTime ts;
  const _RateSnapshot(this.bytes, this.ts);
}

// Represents one browser tab's state (URL text controller, progress, title, etc.)
class _TabData {
  final Key webviewKey;
  final TextEditingController urlCtrl;
  final ValueNotifier<double> progress;
  final ValueNotifier<bool> isLoading;
  String? pageTitle;
  String? currentUrl;
  InAppWebViewController? controller;
  Uint8List? cachedThumbnail;
  String? cachedThumbnailBase64;
  final Set<String> allowedAppLinkHosts = <String>{};
  final List<String> history = <String>[];
  int historyIndex = -1;
  int? pendingHistoryIndex;
  bool skipNextHistorySync = false;
  bool restoringInitialHistory = false;

  /// When true the first page load should not be recorded in history.
  bool skipInitialHistory = true;
  _TabData({String initialUrl = 'about:blank'})
    : webviewKey = UniqueKey(),
      urlCtrl = TextEditingController(
        text:
            initialUrl.toLowerCase().startsWith('about:blank')
                ? ''
                : initialUrl,
      ),
      progress = ValueNotifier<double>(0.0),
      isLoading = ValueNotifier<bool>(false);
}

class _BlockedExternalNavigation {
  final String rawUrl;
  final String? scheme;
  final WebUri? resolvedUri;
  final bool isAppLink;
  final bool canBypassInWebView;
  final String? fallbackUrl;

  const _BlockedExternalNavigation({
    required this.rawUrl,
    this.scheme,
    this.resolvedUri,
    this.isAppLink = false,
    this.canBypassInWebView = false,
    this.fallbackUrl,
  });
}

enum _BlockedNavigationFallbackResult {
  openedNewTab,
  openedInCurrentTab,
  suppressed,
  unavailable,
}

class _ExternalNavigationIntent {
  final bool shouldBlock;
  final bool isAppLink;

  const _ExternalNavigationIntent({
    required this.shouldBlock,
    this.isAppLink = false,
  });

  static const none = _ExternalNavigationIntent(
    shouldBlock: false,
    isAppLink: false,
  );

  _ExternalNavigationIntent merge(_ExternalNavigationIntent other) {
    return _ExternalNavigationIntent(
      shouldBlock: shouldBlock || other.shouldBlock,
      isAppLink: isAppLink || other.isAppLink,
    );
  }
}

enum _ToolbarMenuAction {
  openFavorites,
  openHistory,
  clearBrowsingData,
  toggleAdBlocker,
  toggleAutoDetectMedia,
  toggleBlockPopup,
  blockExternalApp,
  addHome,
  goHome,
  help,
}

/// BrowserPage encapsulates a WebView with URL entry, navigation, and a bar
/// showing detected media resources. It hooks into resource loading
/// callbacks and JavaScript injection to sniff media URLs (audio/video).
class BrowserPage extends StatefulWidget {
  /// Optional callback invoked when the user presses the home button in the toolbar.
  final VoidCallback? onGoHome;
  const BrowserPage({super.key, this.onGoHome});

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _AdBlockerDialogResult {
  final bool enabled;
  final Set<String> selectedProfiles;

  const _AdBlockerDialogResult({
    required this.enabled,
    required this.selectedProfiles,
  });
}

class _BrowserPageState extends State<BrowserPage>
    with LanguageAwareState<BrowserPage> {
  static final RegExp _kHttpUrlPattern = RegExp(
    r'''https?:\/\/[^\s'"<>]+''',
    caseSensitive: false,
  );
  static final RegExp _kDirectDownloadPattern = RegExp(
    r'\.(?:m3u8|mpd|mp4|mov|m4v|webm|mkv|avi|flv|ts|mp3|m4a|aac|ogg|wav|flac)(?:$|[\/?#&])',
    caseSensitive: false,
  );
  static const Set<String> _kImageExtensions = {
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.bmp',
    '.svg',
    '.avif',
  };
  static const Set<String> _kAudioExtensions = {
    '.mp3',
    '.wav',
    '.ogg',
    '.m4a',
    '.aac',
    '.flac',
    '.opus',
  };
  static const Set<String> _kVideoExtensions = {
    '.mp4',
    '.mkv',
    '.mov',
    '.webm',
    '.m4v',
    '.ts',
    '.avi',
    '.flv',
  };
  static const List<String> _kLegacyAdBlockHostPatterns = [
    'doubleclick.net',
    'googlesyndication.com',
    'googletagservices.com',
    'googletagmanager.com',
    'googleadservices.com',
    'googleads.g.doubleclick.net',
    'adservice.google.com',
    'adservice.google.com.tw',
    'ads.yahoo.com',
    'adnxs.com',
    'taboola.com',
    'outbrain.com',
    'scorecardresearch.com',
    'zedo.com',
    'rubiconproject.com',
    'criteo.net',
  ];
  static const Map<String, String> _kAdBlockerAssetPaths = {
    'lite': 'assets/adblocker/blockerslite.json',
    'plus': 'assets/adblocker/blockersplus.json',
    'privacy': 'assets/adblocker/blockersprivacy.json',
  };
  static const String _kPrefBrowserHelpSeen = 'browser_help_seen';

  static const List<String> _kAdBlockCssSelectors = [
    '.adsbygoogle',
    '.ad',
    '.ads',
    '.adsbox',
    '.ad-banner',
    '.adslot',
    '.advertisement',
    '.sponsored',
    '.promoted',
    // Match common ad containers without catching words like "thread" or
    // "download" that contain the substring "ad".
    '[class^="ad-"]',
    '[class^="ads-"]',
    r'[class$="-ad"]',
    r'[class$="-ads"]',
    '[class*=" ad-"]',
    '[class*=" ads-"]',
    '[class*=" ad_"]',
    '[class*=" ads_"]',
    '[id^="ad_"]',
    '[id^="ads_"]',
    r'[id$="_ad"]',
    r'[id$="_ads"]',
    '[data-ad-client]',
    '[data-ad-name]',
  ];
  String get _defaultFolderName =>
      context.l10n('browser.download.defaultFolder');
  static const String _kFolderSheetDefaultKey = '__default_media_folder__';

  List<ContentBlocker> _adBlockerRules = const <ContentBlocker>[];

  static ContentBlocker _buildCssDisplayNoneRule() {
    final selectors = _kAdBlockCssSelectors.join(', ');
    return ContentBlocker(
      trigger: ContentBlockerTrigger(urlFilter: '.*'),
      action: ContentBlockerAction(
        type: ContentBlockerActionType.CSS_DISPLAY_NONE,
        selector: selectors,
      ),
    );
  }

  Future<void> _showYoutubePreviewDialog(
    String url, {
    InAppWebViewController? releaseController,
  }) async {
    if (!mounted) return;
    if (_ytMenuOpen) return;
    if (_ytFetchInFlight) return;

    _suppressLinkLongPress = true;
    if (kDebugMode) {
      debugPrint(
        '[Debug][YouTube] Long press interactions suppressed while preview dialog is open.',
      );
    }

    try {
      _ytFetchInFlight = true;
      _insertYtFetchBarrier();

      YtVideoInfo? info;
      try {
        info = await AppRepo.I.prepareYoutubeOptions(url);
      } finally {
        _removeYtFetchBarrier();
        _ytFetchInFlight = false;
      }
      if (!mounted) {
        _suppressLinkLongPress = false;
        return;
      }
      if (info == null || info.options.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 2),
            content: Text(context.l10n('browser.youtube.error.noStreams')),
          ),
        );
        _suppressLinkLongPress = false;
        return;
      }

      final resolvedInfo = info!;
      _cachedYoutubeInfo = resolvedInfo;

      final durationLabel =
          resolvedInfo.duration != null
              ? context.l10n(
                'browser.media.durationLabel',
                params: {
                  'duration': _fmtDur(
                    resolvedInfo.duration!.inSeconds.toDouble(),
                  ),
                },
              )
              : context.l10n('browser.media.durationResolving');
      final thumbUrl =
          'https://img.youtube.com/vi/${resolvedInfo.videoId}/hqdefault.jpg';

      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          final theme = Theme.of(dialogContext);
          return AlertDialog(
            title: Text(
              resolvedInfo.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Image.network(
                      thumbUrl,
                      fit: BoxFit.cover,
                      errorBuilder:
                          (_, __, ___) => Container(
                            color: theme.colorScheme.surfaceVariant,
                            alignment: Alignment.center,
                            child: const Icon(Icons.image_not_supported),
                          ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(durationLabel, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 8),
                SelectableText(
                  url,
                  maxLines: 2,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withOpacity(0.7),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(context.l10n('common.cancel')),
              ),
              TextButton.icon(
                icon: const Icon(Icons.copy),
                label: Text(context.l10n('browser.context.copyLink')),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: url));
                  if (mounted) {
                    _showSnackBar(context.l10n('browser.snack.copiedLink'));
                  }
                  Navigator.of(dialogContext).pop();
                },
              ),
              FilledButton.icon(
                icon: const Icon(Icons.download),
                label: Text(context.l10n('common.download')),
                onPressed: () async {
                  Navigator.of(dialogContext).pop();
                  await _showYoutubeDownloadOptions(
                    url,
                    preloaded: resolvedInfo,
                  );
                },
              ),
            ],
          );
        },
      );

      if (!_ytMenuOpen) {
        _suppressLinkLongPress = false;
        if (kDebugMode) {
          debugPrint(
            '[Debug][YouTube] Long press interactions restored after preview dialog closed.',
          );
        }
      }
    } finally {
      if (releaseController != null) {
        await _restoreIosLinkInteractions(controller: releaseController);
      }
    }
  }

  static List<ContentBlocker> _buildLegacyAdBlockerRules() {
    final List<ContentBlocker> rules = [];
    for (final host in _kLegacyAdBlockHostPatterns) {
      rules.add(
        ContentBlocker(
          trigger: ContentBlockerTrigger(
            urlFilter: '.*${RegExp.escape(host)}.*',
            resourceType: const [
              ContentBlockerTriggerResourceType.SCRIPT,
              ContentBlockerTriggerResourceType.IMAGE,
              ContentBlockerTriggerResourceType.STYLE_SHEET,
              ContentBlockerTriggerResourceType.FONT,
            ],
          ),
          action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
        ),
      );
    }

    // NOTE: We intentionally avoid a "block all third-party resources" rule
    // because many modern sites load essential scripts and styles from CDNs.

    // Ad hosts are instead targeted explicitly above and the fallback CSS rule
    // below hides common ad containers without breaking the page layout.
    rules.add(_buildCssDisplayNoneRule());
    return rules;
  }

  static ContentBlockerActionType? _parseActionType(String? value) {
    switch (value) {
      case 'block':
        return ContentBlockerActionType.BLOCK;
      case 'css-display-none':
        return ContentBlockerActionType.CSS_DISPLAY_NONE;
      case 'ignore-previous-rules':
        return ContentBlockerActionType.IGNORE_PREVIOUS_RULES;
      case 'make-https':
        return ContentBlockerActionType.MAKE_HTTPS;
      default:
        return null;
    }
  }

  static ContentBlockerTriggerResourceType? _parseResourceType(dynamic value) {
    if (value is! String) return null;
    switch (value) {
      case 'document':
        return ContentBlockerTriggerResourceType.DOCUMENT;
      case 'image':
        return ContentBlockerTriggerResourceType.IMAGE;
      case 'style-sheet':
        return ContentBlockerTriggerResourceType.STYLE_SHEET;
      case 'script':
        return ContentBlockerTriggerResourceType.SCRIPT;
      case 'font':
        return ContentBlockerTriggerResourceType.FONT;
      case 'media':
        return ContentBlockerTriggerResourceType.MEDIA;
      case 'svg-document':
        return ContentBlockerTriggerResourceType.SVG_DOCUMENT;
      case 'raw':
        return ContentBlockerTriggerResourceType.RAW;
      default:
        return null;
    }
  }

  static ContentBlocker? _contentBlockerFromMap(Map<String, dynamic> map) {
    final triggerRaw = map['trigger'];
    final actionRaw = map['action'];
    if (triggerRaw is! Map || actionRaw is! Map) {
      return null;
    }
    final trigger = triggerRaw.cast<String, dynamic>();
    final action = actionRaw.cast<String, dynamic>();
    final urlFilter = trigger['url-filter'];
    if (urlFilter is! String || urlFilter.isEmpty) {
      return null;
    }
    final actionType = _parseActionType(action['type'] as String?);
    if (actionType == null) {
      return null;
    }

    List<ContentBlockerTriggerResourceType>? resourceTypes;
    final rawResources = trigger['resource-type'];
    if (rawResources is List) {
      final parsed = <ContentBlockerTriggerResourceType>[];
      for (final entry in rawResources) {
        final type = _parseResourceType(entry);
        if (type != null) {
          parsed.add(type);
        }
      }
      if (parsed.isNotEmpty) {
        resourceTypes = parsed;
      }
    }

    String? selector;
    if (actionType == ContentBlockerActionType.CSS_DISPLAY_NONE) {
      final rawSelector = action['selector'];
      if (rawSelector is! String || rawSelector.isEmpty) {
        return null;
      }
      selector = rawSelector;
    }

    return ContentBlocker(
      trigger: ContentBlockerTrigger(
        urlFilter: urlFilter,
        resourceType:
            resourceTypes ?? const <ContentBlockerTriggerResourceType>[],
      ),
      action: ContentBlockerAction(type: actionType, selector: selector),
    );
  }

  static Future<List<ContentBlocker>?> _loadContentBlockersFromAsset(
    String assetPath,
  ) async {
    try {
      final jsonString = await rootBundle.loadString(assetPath);
      final dynamic decoded = jsonDecode(jsonString);
      if (decoded is! List) {
        return null;
      }
      final result = <ContentBlocker>[];
      for (final entry in decoded) {
        if (entry is Map<String, dynamic>) {
          final blocker = _contentBlockerFromMap(entry);
          if (blocker != null) {
            result.add(blocker);
          }
        } else if (entry is Map) {
          final blocker = _contentBlockerFromMap(
            entry.map((key, value) => MapEntry(key.toString(), value)),
          );
          if (blocker != null) {
            result.add(blocker);
          }
        }
      }
      if (result.isEmpty) {
        return null;
      }
      return result;
    } catch (err, stack) {
      debugPrint('Failed to load ad blocker rules from $assetPath: $err');
      debugPrint('$stack');
      return null;
    }
  }

  Future<void> _initAdBlockerRules() async {
    final selected = repo.adBlockFilterSets.value;
    final combined = <ContentBlocker>[];
    for (final profile in selected) {
      final assetPath = _kAdBlockerAssetPaths[profile];
      if (assetPath == null) {
        continue;
      }
      final rules = await _loadContentBlockersFromAsset(assetPath);
      if (rules != null && rules.isNotEmpty) {
        combined.addAll(rules);
        debugPrint('[AdBlocker] Loaded ${rules.length} rules for $profile');
      }
    }
    if (combined.isEmpty) {
      combined
        ..clear()
        ..addAll(_buildLegacyAdBlockerRules());
      debugPrint(
        '[AdBlocker] Falling back to legacy rules (${combined.length})',
      );
    }
    combined.add(_buildCssDisplayNoneRule());
    if (!mounted) {
      _adBlockerRules = combined;
      return;
    }
    setState(() {
      _adBlockerRules = combined;
    });
    if (repo.adBlockEnabled.value) {
      unawaited(_applyAdBlockerSetting());
    }
  }

  // Global key used to control the Scaffold (e.g. open the end drawer) from
  // contexts where Scaffold.of(context) does not resolve correctly, such as
  // bottom sheets. This allows the side drawer to slide in from the right
  // when the menu button is pressed in the downloads sheet.
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  // Global key for the tab count button (for anchored popup menu)
  final GlobalKey _tabButtonKey = GlobalKey();
  // Global key for the toolbar menu button so we can reopen the menu at the
  // same location after toggling quick actions.
  final GlobalKey _menuButtonKey = GlobalKey();

  // List of open tabs. At least one tab is always present.
  final List<_TabData> _tabs = [];
  // Index of the currently active tab.
  int _currentTabIndex = 0;
  // --- Mini player state ---
  OverlayEntry? _miniEntry;
  VideoPlayerController? _miniCtrl;
  bool _miniVisible = false;
  Offset _miniPos = const Offset(20, 80); // 初始位置（相對螢幕左上）
  String? _miniUrl;

  void _syncRepoPageContext() {
    if (_currentTabIndex < 0 || _currentTabIndex >= _tabs.length) {
      AppRepo.I.currentPageUrl.value = null;
      AppRepo.I.currentPageTitle.value = null;
      return;
    }
    final tab = _tabs[_currentTabIndex];
    final url = tab.currentUrl?.trim();
    final title = tab.pageTitle?.trim();
    AppRepo.I.currentPageUrl.value =
        (url != null && url.isNotEmpty) ? url : null;
    AppRepo.I.currentPageTitle.value =
        (title != null && title.isNotEmpty) ? title : null;
  }

  // Focus node for the URL input. Used to determine whether to show the
  // clear button only when the field has focus and contains text.
  final FocusNode _urlFocus = FocusNode();
  // --- Paste button state ---
  bool _showPaste = false;
  String? _clipboardCache;

  // ---- UA Preference ----
  String? _uaMode; // 'iphone' | 'ipad' | 'android'
  String? _userAgent; // resolved UA string used by WebView
  bool _uaInitialized = false;

  bool _blockExternalApp = false; // 阻擋由網頁開啟第三方 App
  String? _lastBlockedExternalUrl;
  DateTime? _lastBlockedExternalAt;
  String? _lastBlockedExternalMessage;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>?
  _blockedExternalSnackBarController;
  static const Duration _kBlockedFallbackCooldown = Duration(seconds: 5);
  final Map<String, DateTime> _recentBlockedFallbacks = <String, DateTime>{};
  final Set<String> _appLinkBypassUrls = <String>{};
  static const Duration _kRecentAppLinkBypassHostTtl = Duration(seconds: 8);
  final Map<String, DateTime> _recentAppLinkBypassHosts = <String, DateTime>{};
  static const Set<String> _kDefaultIosUniversalLinkHosts = {
    'x.com',
    'www.x.com',
    'twitter.com',
    'www.twitter.com',
    'mobile.twitter.com',
    'm.twitter.com',
    'facebook.com',
    'www.facebook.com',
    'm.facebook.com',
    'l.facebook.com',
    'lm.facebook.com',
    'mbasic.facebook.com',
    'fb.com',
    'www.fb.com',
    'm.fb.com',
    'messenger.com',
    'www.messenger.com',
    'm.me',
    'instagram.com',
    'www.instagram.com',
    'm.instagram.com',
    'l.instagram.com',
    'business.instagram.com',
    'threads.net',
    'www.threads.net',
    'threads.com',
    'www.threads.com',
  };
  final Set<String> _learnedIosUniversalLinkHosts = <String>{};
  final Set<String> _allKnownIosUniversalLinkHosts = {
    ..._kDefaultIosUniversalLinkHosts,
  };

  static const Set<String> _kWebSchemes = {
    'http',
    'https',
    'about',
    'data',
    'blob',
    'file',
  };
  static const List<String> _kExternalAppFlagKeys = [
    'shouldPerformAppLink',
    'iosShouldPerformAppLink',
    'iosShouldOpenExternalApp',
    'shouldOpenExternalApp',
    'shouldOpenApp',
    'shouldOpenAppLink',
    'androidShouldOpenExternalApp',
    'androidShouldLeaveApplication',
    'iosShouldOpenApp',
    'iosWKNavigationActionShouldPerformAppLink',
    'iosWKNavigationActionShouldOpenApp',
    'shouldPerformAppLinkForCurrentRequest',
    'shouldAllowExternalApp',
    'shouldOpenExternalAppUrl',
    'shouldAllowOpenInExternalApp',
    'shouldOpenInExternalApp',
    'openExternalApp',
    'opensExternalApp',
    'openWithSystemBrowser',
  ];
  static const String _kPrefLearnedUniversalLinkHosts =
      'learned_universal_link_hosts';
  static const Set<String> _kIosUniversalLinkHostSuffixes = {
    'apps.apple.com',
    'itunes.apple.com',
    'appsto.re',
  };
  static const List<String> _kIosUniversalLinkRawMarkers = [
    '://apps.apple.com/',
    '://itunes.apple.com/',
    '://appsto.re/',
  ];

  static const double _edgeSwipeWidth = 32.0;
  static const double _edgeSwipeDistanceThreshold = 48.0;
  static const double _edgeSwipeVelocityThreshold = 700.0;

  bool _suppressLinkLongPress = false;
  YtVideoInfo? _cachedYoutubeInfo;

  static const String _kDebugTapLoggerJS = r'''
(function () {
  if (typeof window === 'undefined') {
    return false;
  }
  if (window.__flutterDebugTapLoggerInstalled) {
    return true;
  }
  if (!window.flutter_inappwebview || !window.flutter_inappwebview.callHandler) {
    return false;
  }

  window.__flutterDebugTapLoggerInstalled = true;

  const limit = (value) => {
    if (!value) return null;
    const text = ('' + value).trim();
    if (!text) return null;
    if (text.length <= 120) return text;
    return text.slice(0, 117) + '...';
  };

  const safeClosest = (element, selector) => {
    if (!element || typeof element.closest !== 'function') {
      return null;
    }
    try {
      return element.closest(selector);
    } catch (_) {
      return null;
    }
  };

  const describe = (target) => {
    if (!target) return {};
    const info = {
      tag: target.tagName || null,
      id: target.id || null,
      classes: typeof target.className === 'string' ? target.className : null,
    };

    const anchor = safeClosest(target, 'a,area');
    if (anchor) {
      info.linkHref = anchor.getAttribute('href') || anchor.href || null;
      info.linkText = limit(anchor.innerText || anchor.textContent);
    } else if (target.href) {
      info.linkHref = target.getAttribute('href') || target.href || null;
    }

    const button = safeClosest(target, 'button');
    if (button) {
      info.buttonText = limit(button.innerText || button.textContent);
    } else if (target.tagName === 'BUTTON') {
      info.buttonText = limit(target.innerText || target.textContent);
    }

    info.text = limit(target.innerText || target.textContent);
    return info;
  };

  const forward = (event) => {
    try {
      const payload = describe(event.target);
      payload.eventType = event.type;
      payload.timestamp = Date.now();
      window.flutter_inappwebview.callHandler('debugTapLogger', payload);
    } catch (err) {}
  };

  const install = () => {
    document.addEventListener('click', forward, true);
    document.addEventListener('touchend', forward, true);
  };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', install, { once: true });
  } else {
    install();
  }

  return true;
})();
''';

  String _uaForMode(String mode) {
    switch (mode) {
      case 'ipad':
        return 'Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
      case 'android':
        return 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';
      case 'windows':
        return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
      case 'iphone':
      default:
        return 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
    }
  }

  bool _hasRenderableFile(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) return false;
      return file.lengthSync() > 0;
    } catch (_) {
      return false;
    }
  }

  Widget _buildThumb(DownloadTask t) {
    final resolvedType = AppRepo.I.resolvedTaskType(t);
    final isDone = t.state.toLowerCase() == 'done';
    if (resolvedType == 'image') {
      if (isDone && _hasRenderableFile(t.savePath)) {
        final file = File(t.savePath);
        return ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Image.file(
            file,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const Icon(Icons.image),
          ),
        );
      }
      return Container(
        color: Colors.grey.shade300,
        alignment: Alignment.center,
        child: const Icon(Icons.image, color: Colors.black54),
      );
    }

    if (resolvedType == 'audio') {
      return Container(
        color: Colors.deepPurple.shade200,
        alignment: Alignment.center,
        child: const Icon(Icons.audiotrack, color: Colors.white),
      );
    }

    final thumbPath = t.thumbnailPath;
    if (thumbPath != null && File(thumbPath).existsSync()) {
      return Image.file(
        File(thumbPath),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const Icon(Icons.movie),
      );
    }

    // 如果影片檔還存在，但縮圖沒有 → 背景再抓一次縮圖
    final f = File(t.savePath);
    if (isDone && f.existsSync() && resolvedType == 'video') {
      _regenThumbAsync(t); // 非同步抽圖
    }

    // 預設顯示一個灰色方塊或 icon
    return Container(
      color: Colors.grey.shade800,
      child: const Icon(Icons.movie, color: Colors.white),
    );
  }

  Future<void> _regenThumbAsync(DownloadTask t) async {
    if (AppRepo.I.resolvedTaskType(t) != 'video') {
      return;
    }
    if (t.state.toLowerCase() != 'done') {
      return;
    }
    try {
      final outDir = path.join(
        (await getApplicationDocumentsDirectory()).path,
        'thumbnails',
      );
      await Directory(outDir).create(recursive: true);
      final outPath = path.join(
        outDir,
        '${path.basenameWithoutExtension(t.savePath)}.jpg',
      );

      // ffmpeg 抽取 1 秒處的畫面，縮成寬 320
      final cmd =
          "-i '${t.savePath}' -ss 00:00:01.000 -vframes 1 -vf scale=320:-1 '$outPath'";
      await FFmpegKit.execute(cmd);

      if (File(outPath).existsSync()) {
        setState(() {
          t.thumbnailPath = outPath;
        });
        AppRepo.I.updateDownload(t);
      }
    } catch (e) {
      debugPrint('縮圖生成失敗: $e');
    }
  }

  Future<void> _openMiniPlayer(String url) async {
    // 關掉舊的
    await _closeMiniPlayer();
    _miniUrl = url;

    try {
      final bgOptions =
          Platform.isIOS
              ? VideoPlayerOptions(allowBackgroundPlayback: true)
              : null;
      final ctrl = VideoPlayerController.networkUrl(
        Uri.parse(url),
        videoPlayerOptions: bgOptions,
      );
      _miniCtrl = ctrl;
      await ctrl.initialize();
      await ctrl.play();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 1),
            content: Text(context.l10n('browser.miniPlayer.error.openFailed')),
          ),
        );
      }
      return;
    }

    _miniEntry = OverlayEntry(
      builder: (_) {
        return StatefulBuilder(
          builder: (context, setSB) {
            final size = MediaQuery.of(context).size;
            final dx = _miniPos.dx.clamp(0.0, size.width - 220.0);
            final dy = _miniPos.dy.clamp(0.0, size.height - 140.0);
            return Positioned(
              left: dx,
              top: dy,
              child: Material(
                color: Colors.transparent,
                child: GestureDetector(
                  onPanUpdate: (d) {
                    setSB(
                      () =>
                          _miniPos = Offset(
                            _miniPos.dx + d.delta.dx,
                            _miniPos.dy + d.delta.dy,
                          ),
                    );
                  },
                  child: Container(
                    width: 220,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.surface.withOpacity(0.95),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.2),
                          blurRadius: 12,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 標題列 + 關閉鈕
                        Row(
                          children: [
                            const Icon(Icons.smart_display, size: 16),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                _prettyFileName(url),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                            InkWell(
                              onTap: () async => await _closeMiniPlayer(),
                              child: const Padding(
                                padding: EdgeInsets.all(4.0),
                                child: Icon(Icons.close, size: 16),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),

                        // 控制列：後退15、播放/暫停、快轉15
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.replay_10),
                              tooltip: context.l10n(
                                'browser.miniPlayer.tooltip.rewind15',
                              ),
                              onPressed: () async {
                                final v = _miniCtrl;
                                if (v == null) return;
                                final cur = await v.position ?? Duration.zero;
                                final targetMs = (cur.inMilliseconds - 15000)
                                    .clamp(0, 1 << 31);
                                await v.seekTo(
                                  Duration(milliseconds: targetMs),
                                );
                              },
                            ),
                            IconButton(
                              icon: Icon(
                                (_miniCtrl?.value.isPlaying ?? false)
                                    ? Icons.pause
                                    : Icons.play_arrow,
                              ),
                              tooltip: context.l10n(
                                'browser.miniPlayer.tooltip.playPause',
                              ),
                              onPressed: () async {
                                final v = _miniCtrl;
                                if (v == null) return;
                                if (v.value.isPlaying) {
                                  await v.pause();
                                } else {
                                  await v.play();
                                }
                                setSB(() {}); // 更新按鈕圖示
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.forward_10),
                              tooltip: context.l10n(
                                'browser.miniPlayer.tooltip.forward15',
                              ),
                              onPressed: () async {
                                final v = _miniCtrl;
                                if (v == null) return;
                                final dur = v.value.duration;
                                final cur = await v.position ?? Duration.zero;
                                var ms = cur.inMilliseconds + 15000;
                                if (dur != null) {
                                  ms = ms.clamp(0, dur.inMilliseconds);
                                }
                                await v.seekTo(Duration(milliseconds: ms));
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    Overlay.of(context).insert(_miniEntry!);
    setState(() => _miniVisible = true);
  }

  Future<void> _closeMiniPlayer() async {
    _miniEntry?.remove();
    _miniEntry = null;
    try {
      await _miniCtrl?.pause();
    } catch (_) {}
    await _miniCtrl?.dispose();
    _miniCtrl = null;
    if (mounted) setState(() => _miniVisible = false);
  }

  Future<void> _loadUaFromPrefs(BuildContext context) async {
    final sp = await SharedPreferences.getInstance();
    String? mode = sp.getString('ua_mode');
    if (mode == null) {
      // Decide a sensible default based on device type
      if (Platform.isIOS) {
        final shortest = MediaQuery.of(context).size.shortestSide;
        mode = shortest >= 600 ? 'ipad' : 'iphone';
      } else if (Platform.isAndroid) {
        mode = 'android';
      } else {
        mode = 'iphone';
      }
      await sp.setString('ua_mode', mode);
    }
    final ua = _uaForMode(mode);
    if (mounted) {
      setState(() {
        _uaMode = mode;
        _userAgent = ua;
        _uaInitialized = true;
      });
    }
    // Try to apply to existing controllers
    await _applyUserAgentToControllers();
  }

  Future<void> _applyUserAgentToControllers() async {
    if (_userAgent == null) return;
    for (final t in _tabs) {
      final c = t.controller;
      if (c != null) {
        try {
          await c.setSettings(
            settings: InAppWebViewSettings(userAgent: _userAgent),
          );
          await c.reload();
        } catch (_) {}
      }
    }
  }

  // --- YouTube Download Options Listener ---
  DateTime? _lastYtOptionsRequest;
  bool _ytFetchInFlight = false;
  OverlayEntry? _ytFetchBarrier;
  bool _ytMenuOpen = false;

  void _removeYtFetchBarrier() {
    _ytFetchBarrier?.remove();
    _ytFetchBarrier = null;
  }

  void _insertYtFetchBarrier() {
    if (_ytFetchBarrier != null) return;
    final overlay = Overlay.of(context);
    if (overlay == null) return;
    _ytFetchBarrier = OverlayEntry(
      builder: (_) {
        final theme = Theme.of(context);
        return Stack(
          children: [
            ModalBarrier(
              dismissible: false,
              color: theme.colorScheme.scrim.withOpacity(0.4),
            ),
            Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.18),
                      blurRadius: 20,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: const Padding(
                  padding: EdgeInsets.all(20),
                  child: CircularProgressIndicator.adaptive(),
                ),
              ),
            ),
          ],
        );
      },
    );
    overlay.insert(_ytFetchBarrier!);
  }

  void _onYtOptionsChanged() {
    final opts = repo.ytOptions.value;
    if (opts == null || _ytMenuOpen) return;
    _ytMenuOpen = true;
    final theme = Theme.of(context);
    final title =
        repo.ytTitle.value ??
        context.l10n('browser.dialog.downloadQuality.title');

    String? formatBitrate(int? bps) {
      if (bps == null || bps <= 0) return null;
      if (bps >= 1000000) {
        final mbps = bps / 1000000;
        return '${mbps.toStringAsFixed(mbps >= 10 ? 0 : 1)} Mbps';
      }
      final kbps = (bps / 1000).round();
      return '$kbps kbps';
    }

    String typeLabel(YtOptionType type) {
      switch (type) {
        case YtOptionType.muxed:
          return context.l10n('browser.youtube.option.type.muxed');
        case YtOptionType.videoAudio:
          return context.l10n('browser.youtube.option.type.videoAudio');
        case YtOptionType.videoOnly:
          return context.l10n('browser.youtube.option.type.videoOnly');
        case YtOptionType.audioOnly:
          return context.l10n('browser.youtube.option.type.audioOnly');
      }
    }

    IconData iconFor(YtStreamOption option) {
      switch (option.type) {
        case YtOptionType.audioOnly:
          return Icons.audiotrack;
        case YtOptionType.videoOnly:
          return Icons.video_camera_back;
        case YtOptionType.videoAudio:
        case YtOptionType.muxed:
          return Icons.ondemand_video;
      }
    }

    String titleFor(YtStreamOption option) {
      final quality =
          option.qualityLabel ??
          (option.height != null ? '${option.height}p' : '');
      final container = option.fileExtension.toUpperCase();
      final bitrate = formatBitrate(
        option.totalBitrate ?? option.videoBitrate ?? option.audioBitrate,
      );
      final segments = <String>[
        if (quality.isNotEmpty) quality,
        if (container.isNotEmpty) container,
        if (bitrate != null) bitrate,
      ];
      if (segments.isEmpty && option.type == YtOptionType.audioOnly) {
        final audioRate = formatBitrate(option.audioBitrate);
        if (audioRate != null) segments.add(audioRate);
        segments.add(container);
      }
      return segments.join(' · ');
    }

    String subtitleFor(YtStreamOption option) {
      final parts = <String>[typeLabel(option.type)];
      if (option.type == YtOptionType.videoAudio) {
        final audioRate = formatBitrate(option.audioBitrate);
        if (audioRate != null) parts.add(audioRate);
        parts.add(context.l10n('browser.youtube.option.mergeHint'));
      }
      return parts.join(' · ');
    }

    _suppressLinkLongPress = true;
    if (kDebugMode) {
      debugPrint(
        '[Debug][YouTube] Long press interactions suppressed while download options sheet is open.',
      );
    }
    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      enableDrag: true,
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) {
        final media = MediaQuery.of(sheetContext);
        final screenHeight = media.size.height;
        const double minSheetHeight = 180;
        const double headerHeight = 104;
        const double itemExtent = 64;
        final double maxSheetHeight = math.max(
          minSheetHeight,
          screenHeight * 0.7,
        );
        final double desiredHeight =
            headerHeight + itemExtent * opts.length.toDouble();
        final double sheetHeight = desiredHeight.clamp(
          minSheetHeight,
          maxSheetHeight,
        );

        return SizedBox(
          height: sheetHeight,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: theme.textTheme.titleMedium,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            context.l10n(
                              'browser.dialog.downloadQuality.subtitle',
                            ),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurface.withOpacity(
                                0.7,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: context.l10n('common.close'),
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.separated(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: opts.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final o = opts[i];
                    return ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 6,
                      ),
                      leading: Icon(iconFor(o)),
                      title: Text(
                        titleFor(o),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        subtitleFor(o),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.download),
                      onTap: () async {
                        Navigator.of(sheetContext).pop();
                        await AppRepo.I.enqueueYoutubeOption(
                          o,
                          sourceUrl: repo.currentPageUrl.value,
                          titleOverride: repo.ytTitle.value,
                        );
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              duration: const Duration(seconds: 1),
                              content: Text(
                                context.l10n('browser.snack.addedDownload'),
                              ),
                            ),
                          );
                        }
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    ).whenComplete(() {
      _ytMenuOpen = false;
      // 重置，不要重複彈出
      repo.ytOptions.value = null;
      repo.ytTitle.value = null;
      _suppressLinkLongPress = false;
      if (kDebugMode) {
        debugPrint(
          '[Debug][YouTube] Long press interactions restored after download options sheet closed.',
        );
      }
    });
  }

  void _onUaChanged() {
    final mode = uaNotifier.value;
    if (mode == null) return;
    final ua = _uaForMode(mode);
    setState(() {
      _uaMode = mode;
      _userAgent = ua;
    });
    _applyUserAgentToControllers(); // 對所有現有 WebView setSettings + reload
  }
  // ---- end of UA Preference ----

  String _fmtDur(double s) {
    final d = s.floor();
    final h = d ~/ 3600;
    final m = (d % 3600) ~/ 60;
    final sec = d % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(h)}:${two(m)}:${two(sec)}';
  }

  Uint8List? _decodeVideoSnapshot(String? dataUrl) {
    if (dataUrl == null) return null;
    final trimmed = dataUrl.trim();
    if (trimmed.isEmpty) return null;
    final comma = trimmed.indexOf(',');
    final payload = comma >= 0 ? trimmed.substring(comma + 1) : trimmed;
    try {
      return base64Decode(payload);
    } catch (_) {
      return null;
    }
  }

  double? _asDouble(dynamic value) {
    if (value is num) {
      final v = value.toDouble();
      return v.isFinite ? v : null;
    }
    if (value is String) {
      final parsed = double.tryParse(value);
      if (parsed == null || !parsed.isFinite) {
        return null;
      }
      return parsed;
    }
    return null;
  }

  int? _asInt(dynamic value) {
    if (value is num) {
      final v = value.toInt();
      return v > 0 ? v : null;
    }
    if (value is String) {
      final parsed = int.tryParse(value);
      if (parsed == null || parsed <= 0) {
        return null;
      }
      return parsed;
    }
    return null;
  }

  String _buildPlayingCandidateId(String url, String pageUrl) {
    final trimmedUrl = url.trim();
    final trimmedPage = pageUrl.trim();
    final base = trimmedUrl.isNotEmpty ? trimmedUrl : trimmedPage;
    if (base.isEmpty) {
      return 'candidate_${DateTime.now().microsecondsSinceEpoch}';
    }
    if (trimmedPage.isNotEmpty) {
      return '$trimmedPage|$base';
    }
    return base;
  }

  String _effectiveDisplayUrl(PlayingVideoCandidate candidate) {
    final page = candidate.pageUrl.trim();
    if (page.isNotEmpty) return page;
    return candidate.url.trim();
  }

  String? _truncateForDebugLog(String? value, {int maxLength = 80}) {
    if (value == null) {
      return null;
    }
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    if (trimmed.length <= maxLength) {
      return trimmed;
    }
    if (maxLength <= 1) {
      return trimmed.substring(0, 1);
    }
    return '${trimmed.substring(0, maxLength - 1)}…';
  }

  String? _stringFromPayload(dynamic value) {
    if (value == null) {
      return null;
    }
    if (value is String) {
      return value;
    }
    try {
      return value.toString();
    } catch (_) {
      return null;
    }
  }

  String _hostnameFromUrl(String url) {
    if (url.isEmpty) {
      return '';
    }
    try {
      final uri = Uri.parse(url);
      return uri.host;
    } catch (_) {
      return '';
    }
  }

  String _timelineLabel(BuildContext context, PlayingVideoCandidate candidate) {
    final duration = candidate.durationSeconds;
    final position = candidate.positionSeconds ?? 0;
    if (duration != null && duration.isFinite && duration > 0) {
      final clamped = math.max(0.0, math.min(duration, position));
      return '${_fmtDur(clamped)} / ${_fmtDur(duration)}';
    }
    return context.l10n('browser.playingNow.liveOrUnknown');
  }

  String _resolutionLabel(
    BuildContext context,
    PlayingVideoCandidate candidate,
  ) {
    final width = candidate.videoWidth;
    final height = candidate.videoHeight;
    if (width != null && width > 0 && height != null && height > 0) {
      return '${width}×${height}';
    }
    return context.l10n('common.unknown');
  }

  Widget _buildPlayingVideoPreview(PlayingVideoCandidate candidate) {
    final snapshot = candidate.snapshot;
    if (snapshot != null && snapshot.isNotEmpty) {
      return Image.memory(snapshot, fit: BoxFit.cover);
    }
    final poster = candidate.posterUrl;
    if (poster != null && poster.isNotEmpty) {
      return Image.network(
        poster,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _defaultVideoPreviewWidget(),
      );
    }
    return _defaultVideoPreviewWidget();
  }

  Widget _defaultVideoPreviewWidget() {
    return Container(
      color: Colors.black12,
      alignment: Alignment.center,
      child: const Icon(Icons.ondemand_video),
    );
  }

  /// Format bytes into a human friendly string.
  /// Examples: 532 -> 532 B, 1_234 -> 1.21 KB, 5_678_901 -> 5.42 MB
  String _fmtSize(int? bytes) {
    final b = bytes ?? 0;
    if (b < 1024) return '$b B';
    final kb = b / 1024.0;
    if (kb < 1024) return '${kb.toStringAsFixed(2)} KB';
    final mb = kb / 1024.0;
    if (mb < 1024) return '${mb.toStringAsFixed(2)} MB';
    final gb = mb / 1024.0;
    return '${gb.toStringAsFixed(2)} GB';
  }

  /// Returns the size of [path] in bytes if the file exists, otherwise null.
  int? _fileLengthIfExists(String path) {
    if (path.isEmpty) return null;
    try {
      final file = File(path);
      if (file.existsSync()) {
        return file.lengthSync();
      }
    } catch (_) {}
    return null;
  }

  /// Whether this task is a segmented/HLS style job where size doesn't update in real time.
  bool _isSegmentedTask(DownloadTask t) {
    final k = (t.kind).toString().toLowerCase();
    final ty = (t.type).toString().toLowerCase();
    return k.contains('hls') ||
        k.contains('m3u8') ||
        k.contains('segment') ||
        ty.contains('hls') ||
        ty.contains('m3u8');
  }

  /// Whether this entry represents a real download task (either ongoing or completed).
  /// Excludes local/imported/library items from the downloads UI entirely.
  bool _isDownloadTaskEntry(DownloadTask t) {
    if (t.hidden) {
      return false;
    }
    final rawUrl = (t.url).toString().trim();
    if (rawUrl.isEmpty) {
      return false;
    }

    if (rawUrl.startsWith('asset://')) {
      return false;
    }
    String _normalizeLocalUrl(String value) {
      if (value.startsWith('file://')) {
        final uri = Uri.tryParse(value);
        if (uri != null && uri.scheme == 'file') {
          try {
            return path.normalize(uri.toFilePath());
          } catch (_) {
            // Fall back to stripping the scheme if toFilePath fails.
            value = value.replaceFirst('file://', '');
          }
        }
      }
      return path.normalize(value);
    }

    final uri = Uri.tryParse(rawUrl);
    final scheme = uri?.scheme.toLowerCase() ?? '';
    final bool isBlob = rawUrl.startsWith('blob:');
    final bool isHttpLike =
        scheme == 'http' ||
        scheme == 'https' ||
        scheme == 'ftp' ||
        scheme == 'ftps';
    final bool isRemote = isBlob || isHttpLike;

    final bool isFileScheme = scheme == 'file';
    final bool isAbsolutePath = scheme.isEmpty && path.isAbsolute(rawUrl);
    final fromLibrary =
        (t.kind == 'library' || t.kind == 'local' || t.kind == 'import');
    if (fromLibrary) {
      return false;
    }

    if (isFileScheme || isAbsolutePath) {
      final normalizedSave = path.normalize(t.savePath);
      final normalizedUrl = _normalizeLocalUrl(rawUrl);
      if (normalizedSave == normalizedUrl) {
        // Imported/hand-added media: hide from download list.
        return false;
      }
    }

    if (isRemote) {
      return true;
    }

    if (isFileScheme || isAbsolutePath) {
      // Local paths that do not map to the current savePath are also treated as
      // manual entries (e.g. moved in from Files app), so hide them.
      return false;
    }

    // For uncommon schemes (custom download handlers) keep showing while active.
    final state = (t.state).toString().toLowerCase();
    return state != 'done';
  }

  /// Whether the download task should be counted as "active" for the badge.
  bool _isActiveDownloadTask(DownloadTask t) {
    final s = (t.state).toString().toLowerCase();
    const activeStates = <String>{'downloading', 'paused', 'queued', 'error'};
    return activeStates.contains(s);
  }

  /// Produce a compact progress text for a download entry.
  /// For HLS/segmented tasks we hide size until finished as requested.
  String _currentReceived(DownloadTask t) {
    // Hide size while still processing segmented downloads
    if (_isSegmentedTask(t) && (t.state.toLowerCase() != 'done')) {
      return context.l10n('browser.download.status.processing');
    }
    if (t.total != null && t.total! > 0) {
      return '${_fmtSize(t.received)} / ${_fmtSize(t.total)}';
    }
    return _fmtSize(t.received);
  }

  String _prettyFileName(String url) {
    try {
      final u = Uri.parse(url);
      String name = '';
      final segs = u.pathSegments.where((e) => e.isNotEmpty).toList();
      if (segs.isNotEmpty) {
        name = segs.last;
        // If it is an m3u8, prefer parent folder name + .m3u8
        if (name.toLowerCase().endsWith('.m3u8') && segs.length >= 2) {
          name = '${segs[segs.length - 2]}.m3u8';
        }
      }
      if (name.isEmpty) name = u.host;
      name = Uri.decodeComponent(name);
      name = name.split('?').first.split('#').first;
      // Use the active tab's title as a smarter fallback when name looks generic.
      final generic =
          name.isEmpty ||
          name == '/' ||
          name.toLowerCase() == 'index.m3u8' ||
          name.toLowerCase().startsWith('index.');
      if (generic) {
        String? tabTitle;
        if (_tabs.isNotEmpty && _currentTabIndex < _tabs.length) {
          tabTitle = _tabs[_currentTabIndex].pageTitle;
        }
        if (tabTitle != null && tabTitle.trim().isNotEmpty) {
          name = tabTitle.trim();
        }
      }
      if (name.isEmpty) return url;
      if (name.length > 60) {
        name = '${name.substring(0, 57)}…';
      }
      return name;
    } catch (_) {
      return url;
    }
  }

  void _onLongPressDetectionChanged() {
    if (!repo.longPressDetectionEnabled.value) {
      repo.clearPlayingVideos();
    }
  }

  // All tab‑specific controllers live on the individual [_TabData] instances.
  final repo = AppRepo.I;
  final Map<String, String> _thumbCache = {};

  /// Persist the list of open tabs into the AppRepo. This helper
  /// should be called whenever the tabs list changes (added, removed or
  /// navigated) so that the browser state can be restored on the next
  /// application launch. Each tab contributes its current URL (or
  /// pending URL if the page has not yet loaded).
  void _updateOpenTabs() {
    final urls = _tabs.map((t) => t.urlCtrl.text.trim()).toList();
    final sessions = _tabs.map(_buildSessionForTab).toList();
    repo.setOpenTabs(urls, sessions: sessions);
  }

  TabSessionState _buildSessionForTab(_TabData tab) {
    final urlText = tab.urlCtrl.text.trim();
    final history =
        tab.history
            .map((e) => e.trim())
            .where(
              (e) => e.isNotEmpty && !e.toLowerCase().startsWith('about:blank'),
            )
            .toList();
    int index = tab.historyIndex;
    if (history.isEmpty) {
      index = -1;
    } else {
      if (index < 0) {
        index = history.length - 1;
      } else if (index >= history.length) {
        index = history.length - 1;
      }
    }
    String? thumbBase64 = tab.cachedThumbnailBase64;
    final bytes = tab.cachedThumbnail;
    if (thumbBase64 == null && bytes != null && bytes.isNotEmpty) {
      thumbBase64 = base64Encode(bytes);
      tab.cachedThumbnailBase64 = thumbBase64;
    }
    return TabSessionState(
      history: history,
      currentIndex: index,
      urlText: urlText,
      thumbnailBase64: thumbBase64,
    );
  }

  bool _canNavigateHistory(_TabData tab, int delta) {
    if (tab.history.isEmpty) return false;
    if (tab.historyIndex < 0) return false;
    final target = tab.historyIndex + delta;
    return target >= 0 && target < tab.history.length;
  }

  void _navigateHistoryDelta(int delta) {
    if (_tabs.isEmpty) return;
    _navigateHistoryForTab(_currentTabIndex, delta);
  }

  void _navigateHistoryForTab(int tabIndex, int delta) {
    if (tabIndex < 0 || tabIndex >= _tabs.length) return;
    final tab = _tabs[tabIndex];
    if (!_canNavigateHistory(tab, delta)) {
      final controller = tab.controller;
      if (controller == null) return;
      if (delta < 0) {
        controller.goBack();
      } else {
        controller.goForward();
      }
      return;
    }
    final targetIndex = tab.historyIndex + delta;
    if (targetIndex < 0 || targetIndex >= tab.history.length) return;
    final targetUrl = tab.history[targetIndex];
    tab.pendingHistoryIndex = targetIndex;
    tab.skipNextHistorySync = true;
    tab.currentUrl = targetUrl;
    tab.urlCtrl.text = targetUrl;
    unawaited(
      tab.controller?.loadUrl(urlRequest: URLRequest(url: WebUri(targetUrl))),
    );
  }

  void _updateHistoryForUrl(_TabData tab, String url) {
    final normalized = url.trim();
    if (normalized.isEmpty) return;
    if (normalized.toLowerCase().startsWith('about:blank')) return;

    if (tab.pendingHistoryIndex != null) {
      final target = tab.pendingHistoryIndex!;
      tab.pendingHistoryIndex = null;
      if (target >= 0 && target < tab.history.length) {
        tab.historyIndex = target;
      } else if (target >= tab.history.length) {
        tab.history.add(normalized);
        tab.historyIndex = tab.history.length - 1;
      } else if (tab.history.isNotEmpty) {
        tab.historyIndex = 0;
      } else {
        tab.historyIndex = -1;
      }
      return;
    }

    final currentIndex = tab.historyIndex;
    if (currentIndex >= 0 && currentIndex < tab.history.length) {
      if (tab.history[currentIndex] == normalized) {
        return;
      }
      final prevIndex = currentIndex - 1;
      final nextIndex = currentIndex + 1;
      final prevMatch = prevIndex >= 0 && tab.history[prevIndex] == normalized;
      final nextMatch =
          nextIndex < tab.history.length &&
          tab.history[nextIndex] == normalized;
      if (prevMatch || nextMatch) {
        tab.historyIndex = prevMatch ? prevIndex : nextIndex;
        return;
      }
    }

    if (currentIndex >= 0 && currentIndex < tab.history.length - 1) {
      tab.history.removeRange(currentIndex + 1, tab.history.length);
    }
    if (tab.history.isEmpty || tab.history.last != normalized) {
      tab.history.add(normalized);
    }
    tab.historyIndex = tab.history.length - 1;
  }

  Future<void> _syncHistoryFromController(_TabData tab) async {
    final controller = tab.controller;
    if (controller == null) return;
    try {
      final history = await controller.getCopyBackForwardList();
      if (history == null) return;
      final dynamic dynHistory = history;
      List<dynamic>? rawItems;
      if (dynHistory.historyItemList is List) {
        rawItems = List<dynamic>.from(dynHistory.historyItemList as List);
      } else if (dynHistory.list is List) {
        rawItems = List<dynamic>.from(dynHistory.list as List);
      } else if (dynHistory.historyItems is List) {
        rawItems = List<dynamic>.from(dynHistory.historyItems as List);
      }
      if (rawItems == null) return;
      final sanitized = <String>[];
      for (final raw in rawItems) {
        final dynamic item = raw;
        final url =
            (item.url?.toString() ?? item.originalUrl?.toString() ?? '').trim();
        if (url.isEmpty) continue;
        if (url.toLowerCase().startsWith('about:blank')) continue;
        sanitized.add(url);
      }
      int idx = -1;
      final dynamic idxDyn = dynHistory.currentIndex;
      if (idxDyn is int) {
        idx = idxDyn;
      } else if (idxDyn is num) {
        idx = idxDyn.toInt();
      }
      if (idx >= sanitized.length) {
        idx = sanitized.length - 1;
      }
      if (idx < 0 && sanitized.isNotEmpty) {
        idx = sanitized.length - 1;
      }
      if (!listEquals(tab.history, sanitized) || tab.historyIndex != idx) {
        tab.history
          ..clear()
          ..addAll(sanitized);
        tab.historyIndex = sanitized.isEmpty ? -1 : idx;
      }
    } catch (_) {}
  }

  Future<String?> _resolveHitTestUrl(
    InAppWebViewController controller,
    String link,
  ) async {
    final trimmed = link.trim();
    if (trimmed.isEmpty) return null;
    final script =
        '(() => { try { return new URL(${jsonEncode(trimmed)}, window.location.href).href; } catch (e) { return ${jsonEncode(trimmed)}; } })();';
    try {
      final result = await controller.evaluateJavascript(source: script);
      if (result is String && result.isNotEmpty) {
        return result;
      }
    } catch (_) {}
    return trimmed;
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(duration: const Duration(seconds: 1), content: Text(message)),
    );
  }

  Future<void> _checkClipboardForPasteButton() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim();
      final hasText = text != null && text.isNotEmpty;
      // 若剪貼簿內容與欄位相同，也不顯示貼上
      final current =
          (_tabs.isNotEmpty ? _tabs[_currentTabIndex].urlCtrl.text.trim() : '');
      final shouldShow = _urlFocus.hasFocus && hasText && text != current;
      if (mounted && (_showPaste != shouldShow || _clipboardCache != text)) {
        setState(() {
          _showPaste = shouldShow;
          _clipboardCache = text;
        });
      }
    } catch (_) {
      if (mounted && _showPaste) {
        setState(() => _showPaste = false);
      }
    }
  }

  Future<void> _injectDebugTapLogger(InAppWebViewController controller) async {
    try {
      final result = await controller.evaluateJavascript(
        source: _kDebugTapLoggerJS,
      );
      if (kDebugMode && result != true) {
        debugPrint(
          '[Debug][WebTap] Tap logger injection reported result: $result',
        );
      }
    } catch (err, stack) {
      if (kDebugMode) {
        debugPrint('[Debug][WebTap] Failed to inject tap logger: $err');
        debugPrint('$stack');
      }
    }
  }

  bool _hasKnownExtension(String lowerUrl, Set<String> extensions) {
    for (final ext in extensions) {
      if (lowerUrl.endsWith(ext)) {
        return true;
      }
    }
    return false;
  }

  bool _isOnYoutubeWatchPage() {
    final current = repo.currentPageUrl.value ?? '';
    if (current.isEmpty) return false;
    final uri = Uri.tryParse(current);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();
    final isYoutubeHost =
        host.contains('youtube.com') || host.contains('youtu.be');
    if (!isYoutubeHost) return false;
    if (host.contains('youtu.be')) {
      return uri.pathSegments.isNotEmpty;
    }
    if (path == '/watch' || path.startsWith('/watch/')) return true;
    if (path.startsWith('/shorts/')) return true;
    return false;
  }

  Widget _buildPlayingVideoCard(
    BuildContext sheetContext,
    PlayingVideoCandidate candidate, {
    required bool isPrimary,
  }) {
    final theme = Theme.of(sheetContext);
    final preview = _buildPlayingVideoPreview(candidate);
    final displayUrl = _effectiveDisplayUrl(candidate);
    final host = _hostnameFromUrl(
      displayUrl.isNotEmpty ? displayUrl : candidate.url,
    );
    final timeline = _timelineLabel(sheetContext, candidate);
    final resolution = _resolutionLabel(sheetContext, candidate);

    final isYoutube =
        AppRepo.I.isYoutubeUrl(candidate.url) ||
        AppRepo.I.isYoutubeUrl(candidate.pageUrl);
    final directUrl = candidate.url.trim();
    final isBlob = directUrl.toLowerCase().startsWith('blob:');
    final hasDirectUrl = directUrl.isNotEmpty && !isBlob && !isYoutube;
    final youtubeSource =
        displayUrl.isNotEmpty ? displayUrl : (repo.currentPageUrl.value ?? '');
    final copyUrl =
        isYoutube
            ? (displayUrl.isNotEmpty ? displayUrl : youtubeSource)
            : (hasDirectUrl ? directUrl : displayUrl);
    final canDownload = isYoutube ? youtubeSource.isNotEmpty : hasDirectUrl;
    final openInNewTabUrl =
        isYoutube ? youtubeSource : (hasDirectUrl ? directUrl : '');
    String? _validHomeUrl(String source) {
      final trimmed = source.trim();
      if (trimmed.isEmpty) {
        return null;
      }
      final uri = Uri.tryParse(trimmed);
      if (uri == null) {
        return null;
      }
      if (uri.scheme != 'http' && uri.scheme != 'https') {
        return null;
      }
      return uri.toString();
    }

    final homeCandidateUrl =
        _validHomeUrl(displayUrl) ?? _validHomeUrl(candidate.url) ?? '';
    final canAddHome = homeCandidateUrl.isNotEmpty;
    final downloadLabel =
        isYoutube
            ? sheetContext.l10n('browser.playingNow.action.stream')
            : sheetContext.l10n('common.download');
    final navigator = Navigator.of(sheetContext);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(width: 120, height: 68, child: preview),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        candidate.title,
                        style: theme.textTheme.titleMedium,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      if (host.isNotEmpty)
                        Text(host, style: theme.textTheme.bodySmall),
                      Text(resolution, style: theme.textTheme.bodySmall),
                      Text(timeline, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SelectableText(
              displayUrl.isNotEmpty ? displayUrl : directUrl,
              maxLines: 2,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  icon: Icon(isYoutube ? Icons.stream : Icons.download),
                  label: Text(downloadLabel),
                  onPressed:
                      canDownload
                          ? () async {
                            navigator.pop();
                            if (isYoutube) {
                              final target =
                                  youtubeSource.isNotEmpty
                                      ? youtubeSource
                                      : displayUrl;
                              if (target.isNotEmpty) {
                                await _showYoutubePreviewDialog(target);
                              }
                            } else if (directUrl.isNotEmpty) {
                              await _confirmDownload(
                                directUrl,
                                skipPrompt: true,
                              );
                            }
                          }
                          : null,
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.copy),
                  label: Text(sheetContext.l10n('browser.context.copyLink')),
                  onPressed:
                      copyUrl.isNotEmpty
                          ? () async {
                            navigator.pop();
                            await Clipboard.setData(
                              ClipboardData(text: copyUrl),
                            );
                            _showSnackBar(
                              sheetContext.l10n('browser.snack.copiedLink'),
                            );
                          }
                          : null,
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.open_in_new),
                  label: Text(
                    sheetContext.l10n('browser.context.openInNewTab'),
                  ),
                  onPressed:
                      openInNewTabUrl.isNotEmpty
                          ? () async {
                            navigator.pop();
                            await _openLinkInNewTab(openInNewTabUrl);
                          }
                          : null,
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.home_outlined),
                  label: Text(sheetContext.l10n('browser.context.addHome')),
                  onPressed:
                      canAddHome
                          ? () async {
                            navigator.pop();
                            await _showAddToHomeDialog(
                              initialUrl: homeCandidateUrl,
                              initialName:
                                  candidate.title.isNotEmpty
                                      ? candidate.title
                                      : null,
                            );
                          }
                          : null,
                ),
                TextButton.icon(
                  icon: const Icon(Icons.close),
                  label: Text(sheetContext.l10n('common.cancel')),
                  onPressed: () {
                    AppRepo.I.removePlayingVideo(candidate.id);
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showPlayingVideosSheet() async {
    if (repo.playingVideos.value.isEmpty) {
      return;
    }
    debugPrint(
      '[Debug][NowPlaying] Opening playing videos sheet with '
      '${repo.playingVideos.value.length} candidate(s)',
    );
    _suppressLinkLongPress = true;
    if (kDebugMode) {
      debugPrint(
        '[Debug][NowPlaying] Long press interactions suppressed while sheet is visible.',
      );
    }
    try {
      await showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (sheetContext) {
          return FractionallySizedBox(
            heightFactor: 0.75,
            child: SafeArea(
              child: Column(
                children: [
                  ListTile(
                    title: Text(
                      sheetContext.l10n('browser.playingNow.sheetTitle'),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(sheetContext).pop(),
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ValueListenableBuilder<List<PlayingVideoCandidate>>(
                      valueListenable: repo.playingVideos,
                      builder: (context, candidates, _) {
                        if (candidates.isEmpty) {
                          return Center(
                            child: Text(
                              sheetContext.l10n(
                                'browser.mediaDetection.emptyState',
                              ),
                            ),
                          );
                        }
                        return ListView.builder(
                          itemCount: candidates.length,
                          itemBuilder: (context, index) {
                            final candidate = candidates[index];
                            return _buildPlayingVideoCard(
                              sheetContext,
                              candidate,
                              isPrimary: index == 0,
                            );
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    } finally {
      Future.delayed(const Duration(milliseconds: 250), () {
        _suppressLinkLongPress = false;
        if (kDebugMode) {
          debugPrint(
            '[Debug][NowPlaying] Long press interactions restored after sheet closed.',
          );
        }
        unawaited(_restoreIosLinkInteractions());
      });
    }
  }

  Future<void> _showYoutubeDownloadOptions(
    String url, {
    YtVideoInfo? preloaded,
  }) async {
    if (!mounted) return;
    if (_ytMenuOpen) {
      return;
    }

    YtVideoInfo? info = preloaded;
    if (info == null && _cachedYoutubeInfo != null) {
      final cached = _cachedYoutubeInfo!;
      final cachedWatch = cached.watchUrl;
      final requestedId = extractYoutubeVideoId(url);
      if (requestedId != null && requestedId == cached.videoId) {
        info = cached;
      } else if (cachedWatch != null && cachedWatch == url) {
        info = cached;
      }
    }
    if (info == null) {
      if (_ytFetchInFlight) {
        return;
      }
      final now = DateTime.now();
      if (_lastYtOptionsRequest != null &&
          now.difference(_lastYtOptionsRequest!) <
              const Duration(milliseconds: 800)) {
        return;
      }
      _lastYtOptionsRequest = now;
      _ytFetchInFlight = true;

      try {
        FocusScope.of(context).unfocus();
      } catch (_) {}

      _insertYtFetchBarrier();
      try {
        info = await AppRepo.I.prepareYoutubeOptions(url);
      } finally {
        _removeYtFetchBarrier();
        _ytFetchInFlight = false;
      }
    }

    if (!mounted) {
      return;
    }
    if (info == null || info.options.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 2),
          content: Text(context.l10n('browser.youtube.error.noStreams')),
        ),
      );
      if (!_ytMenuOpen) {
        _suppressLinkLongPress = false;
      }
      return;
    }

    _cachedYoutubeInfo = info;
    AppRepo.I.ytTitle.value = info.title;
    // Reset before assigning so listeners fire even if same list reference is reused.
    AppRepo.I.ytOptions.value = null;
    AppRepo.I.ytOptions.value = info.options;
  }

  Future<void> _openLinkInNewTab(
    String url, {
    bool makeActive = true,
    Set<String>? allowedAppLinkHosts,
  }) async {
    final target = url.trim();
    if (target.isEmpty) return;
    final tab = _createTab(
      initialUrl: target,
      allowedAppLinkHosts: allowedAppLinkHosts,
    );
    tab.currentUrl = target;
    final previousIndex =
        (_currentTabIndex >= 0 && _currentTabIndex < _tabs.length)
            ? _currentTabIndex
            : 0;
    _rememberCurrentTabThumbnail();
    setState(() {
      _tabs.add(tab);
      _currentTabIndex = makeActive ? _tabs.length - 1 : previousIndex;
    });
    _updateOpenTabs();
    _syncRepoPageContext();
    await _persistCurrentTabIndex();
  }

  void _addUrlToFavorites(String url) {
    final target = url.trim();
    if (target.isEmpty) return;
    if (repo.favorites.value.contains(target)) {
      _showSnackBar(context.l10n('browser.snack.alreadyFavorited'));
      return;
    }
    repo.addFavoriteUrl(target);
    _showSnackBar(context.l10n('browser.snack.addedFavorite'));
  }

  Future<void> _persistCurrentTabIndex() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt('current_tab_index', _currentTabIndex);
    } catch (_) {}
  }

  /// Build the horizontal scrollable tab bar used below the toolbar. Each
  /// tab displays its page title or URL and includes a close button when
  /// more than one tab is present. A plus button at the end allows users
  /// to open a new blank tab. The active tab is highlighted using a
  /// secondary container colour. Scrolling horizontally reveals all tabs
  /// when there are too many to fit on screen.
  Widget _buildTabBar() {
    return SizedBox(
      height: 36,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (int i = 0; i < _tabs.length; i++)
              Container(
                margin: const EdgeInsets.only(right: 4),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color:
                      (i == _currentTabIndex)
                          ? Theme.of(context).colorScheme.secondaryContainer
                          : Theme.of(context).colorScheme.surfaceVariant,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    InkWell(
                      onTap: () {
                        _rememberCurrentTabThumbnail();
                        setState(() {
                          _currentTabIndex = i;
                        });
                        _syncRepoPageContext();
                        _persistCurrentTabIndex();
                      },
                      child: Text(
                        _tabs[i].pageTitle?.isNotEmpty == true
                            ? _tabs[i].pageTitle!
                            : (_tabs[i].currentUrl ??
                                context.l10n('browser.tab.newTabTitle')),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    const SizedBox(width: 4),
                    if (_tabs.length > 1)
                      GestureDetector(
                        onTap: () {
                          _rememberCurrentTabThumbnail();
                          setState(() {
                            final removed = _tabs.removeAt(i);
                            removed.urlCtrl.dispose();
                            removed.progress.dispose();
                            removed.isLoading.dispose();
                            if (_currentTabIndex >= _tabs.length) {
                              _currentTabIndex = _tabs.length - 1;
                            } else if (_currentTabIndex > i) {
                              _currentTabIndex -= 1;
                            }
                          });
                          // Update persisted open tabs after removal
                          _syncRepoPageContext();
                          _updateOpenTabs();
                        },
                        child: const Icon(Icons.close, size: 14),
                      ),
                  ],
                ),
              ),
            GestureDetector(
              onTap: () {
                // Open the tab manager page instead of directly adding a tab. This
                // page displays all open tabs and allows the user to add,
                // select or close tabs. It is similar to Chrome's tab switcher.
                _openTabManager();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceVariant,
                  borderRadius: BorderRadius.circular(8),
                ),
                // Show number of tabs instead of a plus icon.
                child: Text(
                  '${_tabs.length}',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Launch the app’s built‑in media player for the given URL. The page
  /// title is derived from the URL to provide a reasonable default name.
  /// 直接啟動內建全螢幕播放器；如需背景瀏覽請使用 iOS 子母畫面（PiP）。
  void _playMedia(String url, {String? title, Duration? startAt}) {
    final resolvedTitle =
        (title != null && title.trim().isNotEmpty)
            ? title.trim()
            : _prettyFileName(url);
    // 直接啟動內建全螢幕播放器；如需背景瀏覽請使用 iOS 子母畫面（PiP）。
    Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => VideoPlayerPage(
              path: url,
              title: resolvedTitle,
              startAt: startAt,
            ),
      ),
    );
  }

  Future<String> _buildSearchUrl(String query) async {
    final sp = await SharedPreferences.getInstance();
    final engine = sp.getString('search_engine') ?? 'google';
    final q = Uri.encodeComponent(query);
    switch (engine) {
      case 'bing':
        return 'https://www.bing.com/search?q=$q';
      case 'yahoo':
        return 'https://search.yahoo.com/search?p=$q';
      case 'duckduckgo':
        return 'https://duckduckgo.com/?q=$q';
      case 'baidu':
        return 'https://www.baidu.com/s?wd=$q';
      case 'google':
      default:
        return 'https://www.google.com/search?q=$q';
    }
  }

  Future<Uint8List?> _captureTabThumbnail(
    _TabData tab, {
    bool force = false,
  }) async {
    if (!force &&
        tab.cachedThumbnail != null &&
        tab.cachedThumbnail!.isNotEmpty) {
      return tab.cachedThumbnail;
    }
    final controller = tab.controller;
    if (controller == null) {
      return tab.cachedThumbnail;
    }
    try {
      final shot = await controller.takeScreenshot();
      if (shot != null && shot.isNotEmpty) {
        final previous = tab.cachedThumbnailBase64;
        final encoded = base64Encode(shot);
        tab.cachedThumbnail = shot;
        tab.cachedThumbnailBase64 = encoded;
        if (previous != encoded) {
          _updateOpenTabs();
        }
      }
    } catch (err, stack) {
      if (kDebugMode) {
        debugPrint('Failed to capture tab thumbnail: $err\n$stack');
      }
    }
    return tab.cachedThumbnail;
  }

  void _rememberCurrentTabThumbnail() {
    if (_currentTabIndex < 0 || _currentTabIndex >= _tabs.length) {
      return;
    }
    final tab = _tabs[_currentTabIndex];
    unawaited(_captureTabThumbnail(tab, force: true));
  }

  /// Navigate to the tab management view. This view displays all open tabs
  /// in a grid and allows adding, selecting and closing tabs. When the
  /// manager is closed the browser state is updated accordingly.
  Future<void> _openTabManager() async {
    // 逐一蒐集每個分頁的資訊
    final infos = <_TabInfo>[];
    for (final t in _tabs) {
      final name = () {
        if (t.pageTitle != null && t.pageTitle!.trim().isNotEmpty) {
          return t.pageTitle!.trim();
        }
        final u = t.currentUrl?.trim();
        if (u != null &&
            u.isNotEmpty &&
            !u.toLowerCase().startsWith('about:blank')) {
          return u;
        }
        return context.l10n('browser.tab.newTabTitle');
      }();

      final shot = await _captureTabThumbnail(t);

      infos.add(_TabInfo(title: name, thumbnail: shot));
    }

    // 推分頁管理頁（保留你原本 onAdd/onSelect/onClose）
    Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => _TabManagerPage(
              tabs: List<_TabInfo>.from(infos),
              onAdd: () {
                _rememberCurrentTabThumbnail();
                setState(() {
                  _tabs.add(_createTab());
                  _currentTabIndex = _tabs.length - 1;
                });
                _updateOpenTabs();
                _syncRepoPageContext();
                _persistCurrentTabIndex();
              },
              onSelect: (int index) {
                _rememberCurrentTabThumbnail();
                setState(() {
                  _currentTabIndex = index;
                });
                _syncRepoPageContext();
                _persistCurrentTabIndex();
              },
              onClose: (int index) {
                setState(() {
                  final removed = _tabs.removeAt(index);
                  removed.urlCtrl.dispose();
                  removed.progress.dispose();
                  removed.isLoading.dispose();
                  if (_tabs.isEmpty) {
                    _tabs.add(_createTab());
                    _currentTabIndex = 0;
                  } else if (_currentTabIndex >= _tabs.length) {
                    _currentTabIndex = _tabs.length - 1;
                  } else if (_currentTabIndex > index) {
                    _currentTabIndex -= 1;
                  }
                });
                _updateOpenTabs();
                _syncRepoPageContext();
                _persistCurrentTabIndex();
              },
            ),
      ),
    );
  }

  // Removed the obsolete _showHome flag. Home navigation happens via RootNav.

  _TabData _createTab({
    String initialUrl = 'about:blank',
    Set<String>? allowedAppLinkHosts,
  }) {
    final tab = _TabData(initialUrl: initialUrl);
    if (allowedAppLinkHosts != null && allowedAppLinkHosts.isNotEmpty) {
      for (final host in allowedAppLinkHosts) {
        final normalized = _normalizeHostComponent(host);
        if (normalized != null) {
          tab.allowedAppLinkHosts.add(normalized);
        }
      }
    }
    tab.urlCtrl.addListener(() {
      if (mounted) setState(() {});
    });
    return tab;
  }

  void _onPendingNewTab() {
    final token = repo.pendingNewTab.value;
    if (token == null) {
      return;
    }
    // Clear the request before creating the new tab to avoid re-entrant
    // handling when the notifier updates.
    repo.pendingNewTab.value = null;
    final tab = _createTab();
    _rememberCurrentTabThumbnail();
    if (mounted) {
      setState(() {
        _tabs.add(tab);
        _currentTabIndex = _tabs.length - 1;
      });
    } else {
      _tabs.add(tab);
      _currentTabIndex = _tabs.length - 1;
    }
    _updateOpenTabs();
    _syncRepoPageContext();
    _persistCurrentTabIndex();
  }

  void _ensureActiveTab() {
    if (_tabs.isEmpty) {
      final tab = _createTab();
      if (mounted) {
        setState(() {
          _tabs.add(tab);
          _currentTabIndex = 0;
        });
      } else {
        _tabs.add(tab);
        _currentTabIndex = 0;
      }
      _updateOpenTabs();
      _syncRepoPageContext();
      _persistCurrentTabIndex();
    } else if (_currentTabIndex < 0 || _currentTabIndex >= _tabs.length) {
      final newIndex = _tabs.isEmpty ? 0 : (_tabs.length - 1);
      if (mounted) {
        setState(() {
          _currentTabIndex = newIndex;
        });
      } else {
        _currentTabIndex = newIndex;
      }
      _syncRepoPageContext();
      _persistCurrentTabIndex();
    }
  }

  /// Builds the custom home page widget. Displays a list of user saved
  /// shortcuts. Items can be reordered by dragging, tapped to open
  /// their corresponding URL, or long pressed to edit/delete. When no
  /// items are present a helpful message is shown.
  Widget _buildHomePage() {
    return ValueListenableBuilder<List<HomeItem>>(
      valueListenable: repo.homeItems,
      builder: (context, items, _) {
        if (items.isEmpty) {
          return Center(
            child: Text(
              context.l10n('browser.shortcuts.emptyHint'),
              textAlign: TextAlign.center,
            ),
          );
        }
        return ReorderableListView(
          padding: const EdgeInsets.symmetric(vertical: 8.0),
          onReorder: (oldIndex, newIndex) {
            repo.reorderHomeItems(oldIndex, newIndex);
          },
          children: [
            for (int i = 0; i < items.length; i++) _buildHomeItem(i, items[i]),
          ],
        );
      },
    );
  }

  /// Build a single shortcut tile for the home page. Includes the site's
  /// favicon (derived from the domain), the user defined name, and the
  /// URL as a subtitle. Tapping opens the URL in the browser. Long
  /// pressing opens a menu to edit or delete the entry.
  Widget _buildHomeItem(int index, HomeItem item) {
    final uri = Uri.tryParse(item.url);
    final host = uri?.host ?? '';
    final faviconUrl =
        host.isNotEmpty
            ? 'https://www.google.com/s2/favicons?domain=$host&sz=64'
            : null;
    return ListTile(
      key: ValueKey('home_$index'),
      leading:
          faviconUrl != null
              ? Image.network(
                faviconUrl,
                width: 32,
                height: 32,
                errorBuilder: (_, __, ___) => const Icon(Icons.public),
              )
              : const Icon(Icons.public),
      title: Text(item.name.isNotEmpty ? item.name : host),
      subtitle: Text(item.url, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () {
        // Navigate to the URL on the current tab.
        _ensureActiveTab();
        if (_tabs.isNotEmpty) {
          final tab = _tabs[_currentTabIndex];
          tab.urlCtrl.text = item.url;
          _go(item.url);
        }
      },
      onLongPress: () => _showHomeItemMenu(index),
    );
  }

  /// Present a bottom sheet for a specific home item allowing the user to
  /// edit or delete the entry. Editing pops up a dialog prefilled with
  /// the current name and URL. Deleting removes the entry immediately.
  void _showHomeItemMenu(int index) {
    final items = repo.homeItems.value;
    if (index < 0 || index >= items.length) return;
    final item = items[index];
    showModalBottomSheet(
      context: context,
      builder:
          (sheetContext) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: Text(item.name.isNotEmpty ? item.name : item.url),
                  subtitle: Text(item.url),
                ),
                ListTile(
                  leading: const Icon(Icons.edit),
                  title: Text(sheetContext.l10n('common.edit')),
                  onTap: () {
                    Navigator.pop(context);
                    _editHomeItem(index);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.delete),
                  title: Text(sheetContext.l10n('common.delete')),
                  onTap: () {
                    Navigator.pop(context);
                    repo.removeHomeItemAt(index);
                  },
                ),
              ],
            ),
          ),
    );
  }

  /// Show a dialog allowing the user to edit an existing home entry. The
  /// current values are prefilled. On confirmation the entry is updated.
  void _editHomeItem(int index) {
    final items = repo.homeItems.value;
    if (index < 0 || index >= items.length) return;
    final item = items[index];
    final nameCtrl = TextEditingController(text: item.name);
    final urlCtrlLocal = TextEditingController(text: item.url);
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(dialogContext.l10n('browser.shortcuts.editShortcut')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: InputDecoration(
                  labelText: dialogContext.l10n('common.name'),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: urlCtrlLocal,
                decoration: InputDecoration(
                  labelText: dialogContext.l10n('common.url'),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(dialogContext.l10n('common.cancel')),
            ),
            TextButton(
              onPressed: () {
                final newName = nameCtrl.text.trim();
                final newUrl = urlCtrlLocal.text.trim();
                if (newName.isNotEmpty && newUrl.isNotEmpty) {
                  repo.updateHomeItem(index, url: newUrl, name: newName);
                }
                Navigator.pop(context);
              },
              child: Text(dialogContext.l10n('common.confirm')),
            ),
          ],
        );
      },
    );
  }

  /// Prompt the user to add a page to the home screen. When [initialUrl]
  /// or [initialName] are provided they are used to prefill the dialog,
  /// otherwise the current tab's information is used.
  Future<void> _showAddToHomeDialog({
    String? initialUrl,
    String? initialName,
  }) async {
    if (AppRepo.I.hasReachedFreeHomeShortcutLimit) {
      await PurchaseService().showPurchasePrompt(
        context,
        featureName: context.l10n('feature.addHomeShortcut'),
      );
      return;
    }
    String? tabTitle =
        (initialName != null && initialName.trim().isNotEmpty)
            ? initialName.trim()
            : null;
    String? tabUrl =
        (initialUrl != null && initialUrl.trim().isNotEmpty)
            ? initialUrl.trim()
            : null;
    if ((tabTitle == null || tabTitle.isEmpty) ||
        (tabUrl == null || tabUrl.isEmpty)) {
      if (_tabs.isNotEmpty) {
        final tab = _tabs[_currentTabIndex];
        tabTitle = tabTitle ?? tab.pageTitle;
        tabUrl = tabUrl ?? tab.currentUrl;
      }
    }
    final defaultUrl = tabUrl ?? '';
    final defaultName =
        (tabTitle != null && tabTitle.trim().isNotEmpty)
            ? tabTitle.trim()
            : (defaultUrl.isNotEmpty ? _prettyFileName(defaultUrl) : '');
    final nameCtrl = TextEditingController(text: defaultName);
    final urlCtrlLocal = TextEditingController(text: defaultUrl);
    await showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(dialogContext.l10n('browser.shortcuts.addShortcutTitle')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: InputDecoration(
                  labelText: dialogContext.l10n('common.name'),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: urlCtrlLocal,
                decoration: InputDecoration(
                  labelText: dialogContext.l10n('common.url'),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(dialogContext.l10n('common.cancel')),
            ),
            TextButton(
              onPressed: () {
                final name = nameCtrl.text.trim();
                final url = urlCtrlLocal.text.trim();
                if (name.isNotEmpty && url.isNotEmpty) {
                  repo.addHomeItem(url, name);
                  setState(() {});
                }
                Navigator.pop(context);
              },
              child: Text(dialogContext.l10n('common.add')),
            ),
          ],
        );
      },
    );
  }

  @override
  void initState() {
    super.initState();
    unawaited(_initAdBlockerRules());
    uaNotifier.addListener(_onUaChanged);
    repo.ytOptions.addListener(_onYtOptionsChanged);
    repo.pendingNewTab.addListener(_onPendingNewTab);
    repo.adBlockFilterSets.addListener(_onAdBlockFilterSetsChanged);
    repo.longPressDetectionEnabled.addListener(_onLongPressDetectionChanged);
    // Listen to focus changes to handle paste button
    _urlFocus.addListener(() {
      if (_urlFocus.hasFocus) {
        _checkClipboardForPasteButton();
      } else {
        if (mounted && _showPaste) setState(() => _showPaste = false);
      }
    });
    // Restore any previously open tabs (with history) from the repository.
    // If none exist, start with a single blank tab.
    final savedSessions = repo.tabSessions.value;
    if (savedSessions.isNotEmpty) {
      for (final session in savedSessions) {
        final current = session.currentUrl;
        final initial =
            (current != null && current.isNotEmpty) ? current : 'about:blank';
        final tab = _createTab(initialUrl: initial);
        final text = session.urlText;
        tab.urlCtrl.text = text;
        tab.currentUrl = current;
        tab.history
          ..clear()
          ..addAll(session.history);
        final rawIndex = session.currentIndex;
        if (tab.history.isEmpty) {
          tab.historyIndex = -1;
          tab.pendingHistoryIndex = null;
        } else {
          final clamped = rawIndex.clamp(0, tab.history.length - 1).toInt();
          tab.historyIndex = clamped;
          tab.pendingHistoryIndex = clamped;
        }
        tab.skipNextHistorySync = true;
        tab.restoringInitialHistory = true;
        final thumb = session.thumbnailBase64;
        if (thumb != null && thumb.isNotEmpty) {
          try {
            final bytes = base64Decode(thumb);
            tab.cachedThumbnail = bytes;
            tab.cachedThumbnailBase64 = thumb;
          } catch (_) {
            tab.cachedThumbnail = null;
            tab.cachedThumbnailBase64 = null;
          }
        }
        _tabs.add(tab);
      }
      if (_tabs.isEmpty) {
        _tabs.add(_createTab());
      }
      _currentTabIndex = 0;
    } else {
      final savedTabs = repo.openTabs.value;
      if (savedTabs.isNotEmpty) {
        for (final url in savedTabs) {
          final tab = _createTab(initialUrl: url);
          final trimmed = url.trim();
          if (trimmed.isNotEmpty &&
              !trimmed.toLowerCase().startsWith('about:blank')) {
            tab.history
              ..clear()
              ..add(trimmed);
            tab.historyIndex = 0;
            tab.currentUrl = trimmed;
            tab.pendingHistoryIndex = 0;
          }
          _tabs.add(tab);
        }
        _currentTabIndex = 0;
      } else {
        _tabs.add(_createTab());
      }
    }
    // Save the restored tabs back into the repo in case they were just
    // created from saved state. This ensures that any default blank tab
    // also gets persisted.
    _updateOpenTabs();
    // Handle any pending new-tab request issued before the browser was ready.
    _onPendingNewTab();
    // Restore last active tab index (default 0), clamp to valid range.
    () async {
      final sp = await SharedPreferences.getInstance();
      int idx = sp.getInt('current_tab_index') ?? 0;
      if (_tabs.isNotEmpty) {
        if (idx < 0) idx = 0;
        if (idx >= _tabs.length) idx = _tabs.length - 1;
        if (mounted) {
          setState(() {
            _currentTabIndex = idx;
          });
        } else {
          _currentTabIndex = idx;
        }
      }
    }();
    // When a pending URL is set via the home page, load it automatically in
    // the current browser tab.
    repo.pendingOpenUrl.addListener(() {
      final pending = repo.pendingOpenUrl.value;
      if (pending != null && pending.isNotEmpty) {
        _ensureActiveTab();
        if (_tabs.isNotEmpty) {
          final tab = _tabs[_currentTabIndex];
          tab.urlCtrl.text = pending;
        }
        _go(pending);
        // Clear the notifier so the URL isn't loaded repeatedly.
        repo.pendingOpenUrl.value = null;
      }
    });

    // Load saved snifferEnabled preference, default to false if not set.
    () async {
      final sp = await SharedPreferences.getInstance();
      if (!sp.containsKey('sniffer_enabled')) {
        repo.setSnifferEnabled(false);
        await sp.setBool('sniffer_enabled', false);
      } else {
        final saved = sp.getBool('sniffer_enabled') ?? false;
        repo.setSnifferEnabled(saved);
      }
    }();
    // Load saved long-press detection preference, default to true if not set.
    () async {
      final sp = await SharedPreferences.getInstance();
      if (!sp.containsKey('detect_media_long_press')) {
        repo.setLongPressDetectionEnabled(true);
        await sp.setBool('detect_media_long_press', true);
      } else {
        final saved = sp.getBool('detect_media_long_press') ?? true;
        repo.setLongPressDetectionEnabled(saved);
      }
    }();
    // Load saved blockExternalApp preference, default to false if not set.
    () async {
      final sp = await SharedPreferences.getInstance();
      _blockExternalApp = sp.getBool('block_external_app') ?? false;
      if (mounted) setState(() {});
    }();
    _maybeShowBrowserHelp();
    // Load cached universal-link hosts so iOS can automatically keep pages in-web.
    () async {
      final sp = await SharedPreferences.getInstance();
      final saved =
          sp.getStringList(_kPrefLearnedUniversalLinkHosts) ?? const <String>[];
      final normalized =
          saved
              .map((e) => e.trim().toLowerCase())
              .where(
                (element) =>
                    element.isNotEmpty &&
                    !_kDefaultIosUniversalLinkHosts.contains(element),
              )
              .toSet();
      if (_learnedIosUniversalLinkHosts.isNotEmpty) {
        normalized.addAll(_learnedIosUniversalLinkHosts);
      }
      _learnedIosUniversalLinkHosts
        ..clear()
        ..addAll(normalized);
      _allKnownIosUniversalLinkHosts
        ..clear()
        ..addAll(_kDefaultIosUniversalLinkHosts)
        ..addAll(_learnedIosUniversalLinkHosts);
    }();
  }

  void _toggleBlockExternalAppSetting() async {
    final next = !_blockExternalApp;
    _blockExternalApp = next;
    final sp = await SharedPreferences.getInstance();
    await sp.setBool('block_external_app', next);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 1),
        content: Text(
          next
              ? context.l10n('browser.snack.blockExternalApp.enabled')
              : context.l10n('browser.snack.blockExternalApp.disabled'),
        ),
      ),
    );
    setState(() {});
  }

  _TabData? _tabForController(InAppWebViewController controller) {
    for (final tab in _tabs) {
      if (tab.controller == controller) {
        return tab;
      }
    }
    return null;
  }

  String _describeExternalAppTarget(_BlockedExternalNavigation blocked) {
    if (blocked.scheme != null && blocked.scheme!.isNotEmpty) {
      return blocked.scheme!;
    }
    final parsed = Uri.tryParse(blocked.rawUrl);
    final fallbackScheme = parsed?.scheme;
    if (fallbackScheme != null && fallbackScheme.isNotEmpty) {
      return fallbackScheme;
    }
    return blocked.rawUrl.isEmpty
        ? LanguageService.instance.translate('common.unknown')
        : blocked.rawUrl;
  }

  void _showExternalAppBlockedSnackBar(
    _BlockedExternalNavigation blocked, {
    bool openedInNewTab = false,
    bool bypassedInWebView = false,
  }) {
    if (!mounted) return;
    final now = DateTime.now();
    if (_lastBlockedExternalUrl == blocked.rawUrl &&
        _lastBlockedExternalAt != null &&
        now.difference(_lastBlockedExternalAt!).inMilliseconds < 500) {
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    final label = _describeExternalAppTarget(blocked);
    final bool fallbackToWeb = bypassedInWebView;
    final messageText =
        openedInNewTab
            ? context.l10n(
              'browser.snack.blockExternal.openedNewTab',
              params: {'app': label},
            )
            : fallbackToWeb
            ? context.l10n(
              'browser.snack.blockExternal.webFallback',
              params: {'app': label},
            )
            : context.l10n(
              'browser.snack.blockExternal.blocked',
              params: {'app': label},
            );
    final bool canLaunch = blocked.rawUrl.isNotEmpty;
    final bool isDuplicateMessage =
        _blockedExternalSnackBarController != null &&
        _lastBlockedExternalUrl == blocked.rawUrl &&
        _lastBlockedExternalMessage == messageText;
    if (isDuplicateMessage) {
      return;
    }

    final previousController = _blockedExternalSnackBarController;
    if (previousController != null) {
      previousController.close();
      _blockedExternalSnackBarController = null;
    }

    _lastBlockedExternalUrl = blocked.rawUrl;
    _lastBlockedExternalAt = now;
    _lastBlockedExternalMessage = messageText;

    final controller = messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
        content: Row(
          children: [
            Icon(
              Icons.close,
              size: 18,
              color: Theme.of(context).colorScheme.onInverseSurface,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(messageText)),
          ],
        ),
        action:
            canLaunch
                ? SnackBarAction(
                  label: context.l10n('common.open'),
                  onPressed: () {
                    messenger.hideCurrentSnackBar();
                    unawaited(_launchExternalApp(blocked.rawUrl));
                  },
                )
                : null,
      ),
    );
    _blockedExternalSnackBarController = controller;
    controller.closed.then((_) {
      if (identical(_blockedExternalSnackBarController, controller)) {
        _blockedExternalSnackBarController = null;
        _lastBlockedExternalMessage = null;
      }
    });
  }

  Future<void> _launchExternalApp(String rawUrl) async {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null) {
      _showExternalAppLaunchError();
      return;
    }
    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        _showExternalAppLaunchError();
      }
    } catch (_) {
      _showExternalAppLaunchError();
    }
  }

  void _showExternalAppLaunchError() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 1),
        content: Text(context.l10n('browser.error.openExternalApp')),
      ),
    );
  }

  void _handleBlockedExternalNavigation(
    _BlockedExternalNavigation blocked, {
    InAppWebViewController? controller,
  }) {
    _TabData? requestingTab;
    String? previousUrl;
    if (controller != null) {
      try {
        unawaited(controller.stopLoading());
      } catch (_) {}
      requestingTab = _tabForController(controller);
      if (requestingTab != null) {
        final current = requestingTab.currentUrl?.trim();
        final text = requestingTab.urlCtrl.text.trim();
        if (current != null && current.isNotEmpty) {
          previousUrl = current;
        } else if (text.isNotEmpty) {
          previousUrl = text;
        }
        requestingTab.isLoading.value = false;
        requestingTab.progress.value = 0.0;
        if (current != null && current.isNotEmpty) {
          requestingTab.urlCtrl.text = current;
        } else if (requestingTab.urlCtrl.text.isNotEmpty) {
          requestingTab.urlCtrl.clear();
        }
      }
    }
    final fallbackResult = _openBlockedNavigationInNewTab(
      blocked,
      requestingTab: requestingTab,
    );
    final openedInNewTab =
        fallbackResult == _BlockedNavigationFallbackResult.openedNewTab;
    final openedInCurrentTab =
        fallbackResult == _BlockedNavigationFallbackResult.openedInCurrentTab;
    final shouldAttemptBypass =
        controller != null &&
        fallbackResult == _BlockedNavigationFallbackResult.unavailable &&
        blocked.canBypassInWebView;
    _showExternalAppBlockedSnackBar(
      blocked,
      openedInNewTab: openedInNewTab,
      bypassedInWebView: shouldAttemptBypass || openedInCurrentTab,
    );
    final needsRestore =
        fallbackResult == _BlockedNavigationFallbackResult.suppressed ||
        fallbackResult == _BlockedNavigationFallbackResult.unavailable;
    if (shouldAttemptBypass) {
      _attemptAppLinkBypass(controller!, blocked);
    } else if (needsRestore && requestingTab != null) {
      final normalizedPrevious = _normalizeHttpUrl(previousUrl) ?? previousUrl;
      if (normalizedPrevious != null && normalizedPrevious.isNotEmpty) {
        requestingTab.urlCtrl.text = normalizedPrevious;
        requestingTab.currentUrl = normalizedPrevious;
        requestingTab.isLoading.value = true;
        try {
          unawaited(
            requestingTab.controller?.loadUrl(
              urlRequest: URLRequest(url: WebUri(normalizedPrevious)),
            ),
          );
        } catch (_) {}
      } else {
        requestingTab.currentUrl = null;
        requestingTab.urlCtrl.clear();
      }
      _updateOpenTabs();
      if (mounted) setState(() {});
    }
  }

  _BlockedNavigationFallbackResult _openBlockedNavigationInNewTab(
    _BlockedExternalNavigation blocked, {
    _TabData? requestingTab,
  }) {
    final normalizedFallback = _normalizeHttpUrl(blocked.fallbackUrl);
    if (normalizedFallback == null) {
      return _BlockedNavigationFallbackResult.unavailable;
    }
    final fallbackVariants = _normalizedBypassCandidates(normalizedFallback)
      ..add(normalizedFallback);
    String? normalizedRequestingCurrent;
    if (requestingTab != null) {
      normalizedRequestingCurrent = _normalizeHttpUrl(
        requestingTab.currentUrl ?? requestingTab.urlCtrl.text,
      );
    }
    final bool sameAsRequestingTab =
        normalizedRequestingCurrent != null &&
        normalizedRequestingCurrent == normalizedFallback;
    final now = DateTime.now();
    _recentBlockedFallbacks.removeWhere(
      (_, ts) => now.difference(ts) > _kBlockedFallbackCooldown,
    );
    for (final variant in fallbackVariants) {
      final ts = _recentBlockedFallbacks[variant];
      if (!sameAsRequestingTab &&
          ts != null &&
          now.difference(ts) <= _kBlockedFallbackCooldown) {
        return _BlockedNavigationFallbackResult.suppressed;
      }
    }
    for (final tab in _tabs) {
      if (identical(tab, requestingTab)) {
        continue;
      }
      final normalizedTabUrl = _normalizeHttpUrl(tab.currentUrl);
      if (normalizedTabUrl == null) {
        continue;
      }
      final tabVariants = _normalizedBypassCandidates(normalizedTabUrl)
        ..add(normalizedTabUrl);
      final intersects = tabVariants.any(fallbackVariants.contains);
      if (intersects) {
        for (final variant in fallbackVariants) {
          _recentBlockedFallbacks[variant] = now;
        }
        return _BlockedNavigationFallbackResult.suppressed;
      }
    }
    for (final variant in fallbackVariants) {
      _recentBlockedFallbacks[variant] = now;
    }
    _rememberTemporaryHostBypassFromUrl(normalizedFallback);
    for (final variant in fallbackVariants) {
      _appLinkBypassUrls.add(variant);
    }
    final allowedHosts = <String>{};
    void addHostCandidate(String? host) {
      final normalized = _normalizeHostComponent(host);
      if (normalized != null) {
        allowedHosts.add(normalized);
      }
    }

    addHostCandidate(_extractHostFromString(normalizedFallback));
    addHostCandidate(_extractHostFromString(blocked.rawUrl));
    addHostCandidate(_extractHostFromWebUri(blocked.resolvedUri));

    bool handledByRequestingTab() {
      if (requestingTab == null) {
        return false;
      }
      if (!sameAsRequestingTab) {
        return false;
      }
      if (allowedHosts.isNotEmpty) {
        requestingTab.allowedAppLinkHosts.addAll(allowedHosts);
      }
      requestingTab.urlCtrl.text = normalizedFallback;
      requestingTab.currentUrl = normalizedFallback;
      unawaited(
        requestingTab.controller?.loadUrl(
          urlRequest: URLRequest(url: WebUri(normalizedFallback)),
        ),
      );
      _updateOpenTabs();
      if (mounted) setState(() {});
      return true;
    }

    if (handledByRequestingTab()) {
      return _BlockedNavigationFallbackResult.openedInCurrentTab;
    }

    _TabData? reusableTab;
    if (requestingTab != null) {
      final current = requestingTab.currentUrl?.trim() ?? '';
      if (current.isEmpty) {
        reusableTab = requestingTab;
      }
    }
    if (reusableTab == null &&
        _currentTabIndex >= 0 &&
        _currentTabIndex < _tabs.length) {
      final candidate = _tabs[_currentTabIndex];
      final current = candidate.currentUrl?.trim() ?? '';
      if (current.isEmpty) {
        reusableTab = candidate;
      }
    }

    if (reusableTab != null) {
      if (allowedHosts.isNotEmpty) {
        reusableTab.allowedAppLinkHosts.addAll(allowedHosts);
      }
      reusableTab.urlCtrl.text = normalizedFallback;
      reusableTab.currentUrl = normalizedFallback;
      unawaited(
        reusableTab.controller?.loadUrl(
          urlRequest: URLRequest(url: WebUri(normalizedFallback)),
        ),
      );
      _updateOpenTabs();
      if (mounted) setState(() {});
      return _BlockedNavigationFallbackResult.openedInCurrentTab;
    }

    unawaited(
      _openLinkInNewTab(normalizedFallback, allowedAppLinkHosts: allowedHosts),
    );
    return _BlockedNavigationFallbackResult.openedNewTab;
  }

  Future<void> _releaseWebViewAfterContextMenu(
    InAppWebViewController controller,
  ) async {
    const script = r'''
      (function() {
        try {
          const active = document.activeElement;
          if (active && typeof active.blur === 'function') {
            active.blur();
          }
        } catch (_) {}
        try {
       const selection =
              typeof window.getSelection === 'function'
                  ? window.getSelection()
                  : null;
          if (selection && typeof selection.removeAllRanges === 'function') {
            selection.removeAllRanges();
          }
        } catch (_) {}
  
      })();
    ''';
    try {
      await controller.evaluateJavascript(source: script);
    } catch (_) {}
  }

  Future<void> _resetAndReleaseWebViewAfterContextMenu(
    InAppWebViewController controller,
  ) async {
    if (kDebugMode) {
      debugPrint('[Debug][LinkMenu] Resetting web view after context menu.');
    }

    await _releaseWebViewAfterContextMenu(controller);
  }

  Future<void> _restoreIosLinkInteractions({
    InAppWebViewController? controller,
  }) async {
    if (!Platform.isIOS) {
      return;
    }

    InAppWebViewController? target = controller;
    if (target == null) {
      if (_tabs.isEmpty || _currentTabIndex < 0) {
        return;
      }
      if (_currentTabIndex >= _tabs.length) {
        return;
      }
      target = _tabs[_currentTabIndex].controller;
    }
    if (target == null) {
      return;
    }

    try {
      await _resetAndReleaseWebViewAfterContextMenu(target);
    } catch (_) {}
  }

  bool _flagTruthy(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      return normalized == 'true' ||
          normalized == '1' ||
          normalized == 'yes' ||
          normalized == 'y';
    }
    return false;
  }

  bool _flagNameIndicatesAppLink(String key) {
    final lower = key.toLowerCase();
    return lower.contains('applink') ||
        lower.contains('externalapp') ||
        lower.contains('systembrowser') ||
        lower.contains('openinbrowser') ||
        lower.contains('openapp') ||
        lower.contains('leaveapplication');
  }

  void _rememberIosUniversalLinkHost(String? host) {
    final normalized = host?.trim().toLowerCase();
    if (normalized == null || normalized.isEmpty) {
      return;
    }
    if (_learnedIosUniversalLinkHosts.add(normalized)) {
      _persistLearnedIosUniversalLinkHosts();
    }
  }

  void _persistLearnedIosUniversalLinkHosts() {
    final snapshot = _learnedIosUniversalLinkHosts.toList()..sort();
    unawaited(() async {
      try {
        final sp = await SharedPreferences.getInstance();
        await sp.setStringList(_kPrefLearnedUniversalLinkHosts, snapshot);
      } catch (_) {}
    }());
  }

  bool _matchesIosUniversalLinkHost(String host) {
    final normalizedHost = host.toLowerCase();
    if (_allKnownIosUniversalLinkHosts.contains(normalizedHost)) {
      return true;
    }
    for (final suffix in _kIosUniversalLinkHostSuffixes) {
      final normalizedSuffix = suffix.toLowerCase();
      if (normalizedHost == normalizedSuffix ||
          normalizedHost.endsWith('.$normalizedSuffix')) {
        return true;
      }
    }
    return false;
  }

  bool _isLikelyIosUniversalLink({WebUri? uri, String? rawUrl}) {
    if (!Platform.isIOS) {
      return false;
    }
    final fallbackRaw = rawUrl ?? uri?.toString();
    final normalizedRaw = (fallbackRaw ?? '').toLowerCase();

    WebUri? candidateUri = uri;
    if (candidateUri == null && fallbackRaw != null && fallbackRaw.isNotEmpty) {
      candidateUri = _tryParseWebUri(fallbackRaw);
    }
    String? host;
    try {
      host = candidateUri?.host;
    } catch (_) {}
    if (host != null && host.isNotEmpty) {
      if (_matchesIosUniversalLinkHost(host)) {
        return true;
      }
    }
    if (normalizedRaw.isNotEmpty) {
      for (final marker in _kIosUniversalLinkRawMarkers) {
        if (normalizedRaw.contains(marker)) {
          return true;
        }
      }
    }
    return false;
  }

  _ExternalNavigationIntent _mapContainsExternalAppHint(
    Map<dynamic, dynamic>? map,
  ) {
    if (map == null) {
      return _ExternalNavigationIntent.none;
    }
    bool shouldBlock = false;
    bool isAppLink = false;
    void inspectKey(String key, dynamic value) {
      if (!_flagTruthy(value)) {
        return;
      }
      shouldBlock = true;
      if (_flagNameIndicatesAppLink(key)) {
        isAppLink = true;
      }
    }

    for (final key in _kExternalAppFlagKeys) {
      if (!map.containsKey(key)) {
        continue;
      }
      inspectKey(key.toString(), map[key]);
    }
    map.forEach((rawKey, rawValue) {
      if (rawKey is! String) {
        return;
      }
      if (_kExternalAppFlagKeys.contains(rawKey)) {
        return;
      }
      if (_flagNameIndicatesAppLink(rawKey)) {
        inspectKey(rawKey, rawValue);
      }
    });
    if (!shouldBlock) {
      return _ExternalNavigationIntent.none;
    }
    return _ExternalNavigationIntent(shouldBlock: true, isAppLink: isAppLink);
  }

  _ExternalNavigationIntent _navigationActionRequestsExternalApp(
    NavigationAction action,
  ) {
    bool shouldBlock = false;
    bool isAppLink = false;

    void inspectFlag(dynamic value, String debugName) {
      if (_flagTruthy(value)) {
        shouldBlock = true;
        if (_flagNameIndicatesAppLink(debugName)) {
          isAppLink = true;
        }
      }
    }

    try {
      final dynamic dynAction = action;
      inspectFlag(dynAction.shouldPerformAppLink, 'shouldPerformAppLink');
      inspectFlag(dynAction.iosShouldPerformAppLink, 'iosShouldPerformAppLink');
      inspectFlag(
        dynAction.androidShouldOpenExternalApp,
        'androidShouldOpenExternalApp',
      );
      inspectFlag(
        dynAction.androidShouldLeaveApplication,
        'androidShouldLeaveApplication',
      );
      inspectFlag(
        dynAction.iosShouldOpenExternalApp,
        'iosShouldOpenExternalApp',
      );
      inspectFlag(dynAction.iosShouldOpenApp, 'iosShouldOpenApp');
      inspectFlag(dynAction.shouldOpenAppLink, 'shouldOpenAppLink');
      inspectFlag(dynAction.shouldOpenExternalApp, 'shouldOpenExternalApp');
    } catch (_) {}

    try {
      final dynamic rawMap = action.toMap();
      if (rawMap is Map) {
        final intent = _mapContainsExternalAppHint(rawMap);
        if (intent.shouldBlock) {
          shouldBlock = true;
          if (intent.isAppLink) {
            isAppLink = true;
          }
        }
        if (!intent.shouldBlock) {
          final dynamic requestMap = rawMap['request'];
          if (requestMap is Map) {
            final nested = _mapContainsExternalAppHint(requestMap);
            if (nested.shouldBlock) {
              shouldBlock = true;
              if (nested.isAppLink) {
                isAppLink = true;
              }
            }
          }
          final dynamic optionsMap = rawMap['options'];
          if (optionsMap is Map) {
            final nested = _mapContainsExternalAppHint(optionsMap);
            if (nested.shouldBlock) {
              shouldBlock = true;
              if (nested.isAppLink) {
                isAppLink = true;
              }
            }
          }
        }
      }
    } catch (_) {}

    if (!shouldBlock) {
      return _ExternalNavigationIntent.none;
    }
    return _ExternalNavigationIntent(shouldBlock: true, isAppLink: isAppLink);
  }

  _ExternalNavigationIntent _createWindowRequestRequestsExternalApp(
    dynamic createWindowRequest,
  ) {
    if (createWindowRequest == null) {
      return _ExternalNavigationIntent.none;
    }
    bool shouldBlock = false;
    bool isAppLink = false;
    try {
      final dynamic rawMap = createWindowRequest.toMap();
      if (rawMap is Map) {
        final intent = _mapContainsExternalAppHint(rawMap);
        if (intent.shouldBlock) {
          shouldBlock = true;
          if (intent.isAppLink) {
            isAppLink = true;
          }
        }
        final dynamic requestMap = rawMap['request'];
        if (requestMap is Map) {
          final nested = _mapContainsExternalAppHint(requestMap);
          if (nested.shouldBlock) {
            shouldBlock = true;
            if (nested.isAppLink) {
              isAppLink = true;
            }
          }
        }
        final dynamic optionsMap =
            rawMap['options'] ?? rawMap['windowFeatures'];
        if (optionsMap is Map) {
          final nested = _mapContainsExternalAppHint(optionsMap);
          if (nested.shouldBlock) {
            shouldBlock = true;
            if (nested.isAppLink) {
              isAppLink = true;
            }
          }
        }
      }
    } catch (_) {}
    if (!shouldBlock) {
      return _ExternalNavigationIntent.none;
    }
    return _ExternalNavigationIntent(shouldBlock: true, isAppLink: isAppLink);
  }

  _BlockedExternalNavigation? _shouldPreventExternalNavigation(
    WebUri? uri, {
    NavigationAction? action,
    URLRequest? request,
    dynamic createWindowRequest,
    InAppWebViewController? controller,
  }) {
    if (!_blockExternalApp) return null;
    final now = DateTime.now();
    _purgeExpiredAppLinkBypassHosts(now);
    final _TabData? requestingTab =
        controller != null ? _tabForController(controller) : null;

    String? scheme = uri?.scheme;
    String? rawUrl = uri?.toString();
    WebUri? resolvedUri = uri;
    bool shouldBlock = false;
    bool dueToAppLink = false;
    String? normalizedHost;

    void ingestUrlRequest(URLRequest? req) {
      if (req == null) {
        return;
      }
      try {
        if (rawUrl == null || rawUrl!.isEmpty) {
          rawUrl = req.url?.toString();
        }
        if ((scheme == null || scheme!.isEmpty) && req.url != null) {
          scheme = req.url!.scheme;
          resolvedUri ??= req.url;
        }
        if (rawUrl == null || rawUrl!.isEmpty) {
          try {
            final mapped = req.toMap();
            final dynamic urlValue = mapped['url'];
            if (urlValue is String && urlValue.isNotEmpty) {
              rawUrl = urlValue;
            }
            final dynamic schemeValue = mapped['scheme'];
            if (schemeValue is String && schemeValue.isNotEmpty) {
              scheme ??= schemeValue;
            }
          } catch (_) {}
        }
      } catch (_) {}
    }

    if (action != null) {
      try {
        ingestUrlRequest(action.request);
      } catch (_) {}
    }
    ingestUrlRequest(request);
    if (createWindowRequest != null) {
      ingestUrlRequest(createWindowRequest.request);
    }
    if ((rawUrl == null || rawUrl!.isEmpty) && action != null) {
      try {
        final dynamic rawMap = action.toMap();
        if (rawMap is Map) {
          final dynamic requestMap = rawMap['request'];
          if (requestMap is Map) {
            final dynamic mappedUrl = requestMap['url'];
            if (mappedUrl is String && mappedUrl.isNotEmpty) {
              rawUrl = mappedUrl;
            }
            final dynamic mappedScheme = requestMap['scheme'];
            if (mappedScheme is String && mappedScheme.isNotEmpty) {
              scheme ??= mappedScheme;
            }
          }
        }
      } catch (_) {}
    }
    if ((rawUrl == null || rawUrl!.isEmpty) && createWindowRequest != null) {
      try {
        final dynamic rawMap = createWindowRequest.toMap();
        if (rawMap is Map) {
          final dynamic requestMap = rawMap['request'];
          if (requestMap is Map) {
            final dynamic mappedUrl = requestMap['url'];
            if (mappedUrl is String && mappedUrl.isNotEmpty) {
              rawUrl = mappedUrl;
            }
            final dynamic mappedScheme = requestMap['scheme'];
            if (mappedScheme is String && mappedScheme.isNotEmpty) {
              scheme ??= mappedScheme;
            }
          }
        }
      } catch (_) {}
    }
    if ((scheme == null || scheme!.isEmpty) && rawUrl != null) {
      try {
        final parsed = WebUri(rawUrl!);
        scheme = parsed.scheme;
        resolvedUri ??= parsed;
      } catch (_) {
        try {
          scheme = Uri.tryParse(rawUrl!)?.scheme;
        } catch (_) {}
      }
    }
    try {
      final host = resolvedUri?.host;
      if (host != null && host.isNotEmpty) {
        normalizedHost = host.toLowerCase();
      }
    } catch (_) {}
    if ((normalizedHost == null || normalizedHost!.isEmpty) &&
        rawUrl != null &&
        rawUrl!.isNotEmpty) {
      try {
        final parsed = WebUri(rawUrl!);
        final host = parsed.host;
        if (host != null && host.isNotEmpty) {
          normalizedHost = host.toLowerCase();
        }
      } catch (_) {
        final host = Uri.tryParse(rawUrl!)?.host;
        if (host != null && host.isNotEmpty) {
          normalizedHost = host.toLowerCase();
        }
      }
    }
    final normalizedScheme = (scheme ?? '').toLowerCase();
    final normalizedRaw = (rawUrl ?? '').toLowerCase();
    final bool schemeLooksHttp = _isHttpScheme(scheme);
    final bool rawLooksHttp =
        normalizedRaw.startsWith('http://') ||
        normalizedRaw.startsWith('https://');

    final bool hostLearned =
        normalizedHost != null &&
        _learnedIosUniversalLinkHosts.contains(normalizedHost);
    if (hostLearned) {
      shouldBlock = true;
      if (schemeLooksHttp || rawLooksHttp) {
        dueToAppLink = true;
      }
    }
    if (normalizedScheme.isNotEmpty &&
        !_kWebSchemes.contains(normalizedScheme)) {
      shouldBlock = true;
    }

    if (!shouldBlock && normalizedScheme.isEmpty && normalizedRaw.isNotEmpty) {
      const suspiciousPrefixes = [
        'intent:',
        'intent://',
        'line://',
        'line:',
        'whatsapp://',
        'whatsapp:',
        'tg://',
        'twitter://',
        'fb://',
        'instagram://',
        'weixin://',
        'weibo://',
        'alipay://',
        'alipays://',
        'taobao://',
        'pinduoduo://',
        'mqq://',
        'mailto:',
        'tel:',
        'sms:',
      ];
      for (final prefix in suspiciousPrefixes) {
        if (normalizedRaw.startsWith(prefix)) {
          shouldBlock = true;
          break;
        }
      }
    }

    if (action != null) {
      final intent = _navigationActionRequestsExternalApp(action);
      if (intent.shouldBlock) {
        shouldBlock = true;
        if (intent.isAppLink) {
          dueToAppLink = true;
        }
      }
    }
    if (createWindowRequest != null) {
      final intent = _createWindowRequestRequestsExternalApp(
        createWindowRequest,
      );
      if (intent.shouldBlock) {
        shouldBlock = true;
        if (intent.isAppLink) {
          dueToAppLink = true;
        }
      }
    }
    if (_isLikelyIosUniversalLink(uri: resolvedUri, rawUrl: rawUrl)) {
      shouldBlock = true;
      dueToAppLink = true;
    }
    if (shouldBlock && !dueToAppLink && (schemeLooksHttp || rawLooksHttp)) {
      dueToAppLink = true;
    }
    if (!shouldBlock) {
      return null;
    }

    final effectiveRaw =
        (rawUrl != null && rawUrl!.isNotEmpty)
            ? rawUrl
            : (resolvedUri?.toString() ?? '');
    final effectiveScheme =
        (scheme != null && scheme!.isNotEmpty)
            ? scheme
            : Uri.tryParse(effectiveRaw!)?.scheme;
    final fallbackUrl = _determineBlockedNavigationFallback(
      effectiveRaw: effectiveRaw,
      rawUrl: rawUrl,
      resolvedUri: resolvedUri,
    );
    if (shouldBlock &&
        requestingTab != null &&
        requestingTab.allowedAppLinkHosts.isNotEmpty) {
      final candidateHosts = <String>{};
      void addCandidate(String? host) {
        final normalized = _normalizeHostComponent(host);
        if (normalized != null) {
          candidateHosts.add(normalized);
        }
      }

      addCandidate(normalizedHost);
      addCandidate(_extractHostFromString(effectiveRaw));
      addCandidate(_extractHostFromString(rawUrl));
      addCandidate(_extractHostFromWebUri(resolvedUri));
      addCandidate(_extractHostFromString(fallbackUrl));

      if (candidateHosts.any(requestingTab.allowedAppLinkHosts.contains)) {
        return null;
      }
    }
    if (shouldBlock && dueToAppLink) {
      String? hostForBypass = normalizedHost;
      String? schemeForBypass = effectiveScheme ?? scheme;
      if ((hostForBypass == null || hostForBypass.isEmpty) &&
          effectiveRaw != null &&
          effectiveRaw.isNotEmpty) {
        final parsedEffective = Uri.tryParse(effectiveRaw);
        if (parsedEffective != null) {
          hostForBypass = parsedEffective.host;
          schemeForBypass ??= parsedEffective.scheme;
        }
      }
      if (_shouldBypassHostDueToRecentAllowance(
        scheme: schemeForBypass,
        host: hostForBypass,
        now: now,
      )) {
        return null;
      }
    }

    if (_consumePendingAppLinkBypass(
      effectiveRaw: effectiveRaw,
      rawUrl: rawUrl,
      resolvedUri: resolvedUri,
    )) {
      return null;
    }

    final normalizedEffectiveScheme = effectiveScheme?.toLowerCase();
    final canBypassInWebView =
        dueToAppLink && _isHttpScheme(normalizedEffectiveScheme);
    if (Platform.isIOS && dueToAppLink && canBypassInWebView) {
      String? hostToRemember = normalizedHost;
      if (hostToRemember == null || hostToRemember.isEmpty) {
        final fallback = effectiveRaw ?? rawUrl ?? '';
        if (fallback.isNotEmpty) {
          final parsed = Uri.tryParse(fallback);
          final fallbackHost = parsed?.host;
          if (fallbackHost != null && fallbackHost.isNotEmpty) {
            hostToRemember = fallbackHost.toLowerCase();
          }
        }
      }
      _rememberIosUniversalLinkHost(hostToRemember);
    }
    return _BlockedExternalNavigation(
      rawUrl: effectiveRaw ?? '',
      scheme: effectiveScheme,
      resolvedUri: resolvedUri,
      isAppLink: dueToAppLink,
      canBypassInWebView: canBypassInWebView,
      fallbackUrl: fallbackUrl,
    );
  }

  bool _isHttpScheme(String? scheme) {
    if (scheme == null || scheme.isEmpty) {
      return false;
    }
    final normalized = scheme.toLowerCase();
    return normalized == 'http' || normalized == 'https';
  }

  String? _normalizeHttpUrl(String? value) {
    if (value == null) {
      return null;
    }
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final parsed = Uri.tryParse(trimmed);
    if (parsed == null || !_isHttpScheme(parsed.scheme)) {
      return null;
    }
    return parsed.toString();
  }

  String? _normalizeHostComponent(String? host) {
    final normalized = host?.trim().toLowerCase();
    if (normalized == null || normalized.isEmpty) {
      return null;
    }
    return normalized;
  }

  String? _extractHostFromString(String? value) {
    if (value == null) {
      return null;
    }
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    try {
      final parsed = Uri.tryParse(trimmed);
      final host = parsed?.host;
      if (host != null && host.isNotEmpty) {
        return host.toLowerCase();
      }
    } catch (_) {}
    return null;
  }

  String? _extractHostFromWebUri(WebUri? uri) {
    if (uri == null) {
      return null;
    }
    try {
      final host = uri.host;
      if (host != null && host.isNotEmpty) {
        return host.toLowerCase();
      }
    } catch (_) {}
    return _extractHostFromString(uri.toString());
  }

  bool _isHttpUrlString(String? value) {
    return _normalizeHttpUrl(value) != null;
  }

  String? _extractFallbackFromIntentUri(String? rawUrl) {
    if (rawUrl == null) {
      return null;
    }
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    if (!trimmed.toLowerCase().startsWith('intent://')) {
      return null;
    }
    final intentIndex = trimmed.indexOf('#Intent;');
    if (intentIndex <= 0) {
      return null;
    }
    final metadata = trimmed.substring(intentIndex + '#Intent;'.length);
    final parts = metadata.split(';');
    String? fallback;
    String? scheme;
    for (final part in parts) {
      if (part.startsWith('S.browser_fallback_url=')) {
        final encoded = part.substring('S.browser_fallback_url='.length);
        try {
          fallback = Uri.decodeComponent(encoded);
        } catch (_) {
          fallback = encoded;
        }
      } else if (part.startsWith('scheme=')) {
        scheme = part.substring('scheme='.length);
      }
    }
    final normalizedFallback = _normalizeHttpUrl(fallback);
    if (normalizedFallback != null) {
      return normalizedFallback;
    }
    final normalizedScheme = scheme?.trim();
    if (normalizedScheme != null &&
        normalizedScheme.isNotEmpty &&
        _isHttpScheme(normalizedScheme)) {
      final remainder = trimmed.substring('intent://'.length, intentIndex);
      if (remainder.isNotEmpty) {
        return '$normalizedScheme://$remainder';
      }
    }
    return null;
  }

  String? _extractHttpUrlFromString(String? value) {
    if (value == null) {
      return null;
    }
    String? search(String input) {
      final match = _kHttpUrlPattern.firstMatch(input);
      if (match == null) {
        return null;
      }
      final candidate = match.group(0);
      return _normalizeHttpUrl(candidate);
    }

    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    String? candidate = search(trimmed);
    if (candidate != null) {
      return candidate;
    }
    final decoders = <String Function(String)>[
      (v) => Uri.decodeComponent(v),
      (v) => Uri.decodeFull(v),
    ];
    for (final decode in decoders) {
      try {
        final decoded = decode(trimmed);
        if (decoded != trimmed) {
          candidate = search(decoded);
          if (candidate != null) {
            return candidate;
          }
        }
      } catch (_) {}
    }
    return null;
  }

  String? _determineBlockedNavigationFallback({
    String? effectiveRaw,
    String? rawUrl,
    WebUri? resolvedUri,
  }) {
    String? candidate = _normalizeHttpUrl(effectiveRaw);
    candidate ??= _normalizeHttpUrl(resolvedUri?.toString());
    candidate ??= _normalizeHttpUrl(rawUrl);
    candidate ??= _extractFallbackFromIntentUri(rawUrl);
    candidate ??= _extractHttpUrlFromString(rawUrl);
    return candidate;
  }

  String _normalizeUrlForBypass(String? url) {
    if (url == null) {
      return '';
    }
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    final parsed = Uri.tryParse(trimmed);
    if (parsed == null) {
      return trimmed;
    }
    if (parsed.scheme.isEmpty && parsed.host.isEmpty) {
      return trimmed;
    }
    final normalized = parsed.replace(
      scheme:
          parsed.scheme.isNotEmpty
              ? parsed.scheme.toLowerCase()
              : parsed.scheme,
      host: parsed.host.isNotEmpty ? parsed.host.toLowerCase() : parsed.host,
    );
    return normalized.toString();
  }

  Set<String> _normalizedBypassCandidates(String? url) {
    final normalized = _normalizeUrlForBypass(url);
    if (normalized.isEmpty) {
      return <String>{};
    }

    final variants = <String>{normalized};
    final parsed = Uri.tryParse(normalized);
    if (parsed != null &&
        _isHttpScheme(parsed.scheme) &&
        (parsed.path.isEmpty || parsed.path == '/') &&
        !parsed.hasQuery &&
        !parsed.hasFragment) {
      final base =
          '${parsed.scheme.toLowerCase()}://${parsed.host.toLowerCase()}';
      variants
        ..add(base)
        ..add('$base/');
    }

    return variants;
  }

  bool _consumePendingAppLinkBypass({
    String? effectiveRaw,
    String? rawUrl,
    WebUri? resolvedUri,
  }) {
    final candidates = <String>{};
    void addCandidate(String? value) {
      candidates.addAll(_normalizedBypassCandidates(value));
    }

    addCandidate(effectiveRaw);
    addCandidate(rawUrl);
    addCandidate(resolvedUri?.toString());

    if (candidates.isEmpty) {
      return false;
    }

    bool matched = false;
    for (final candidate in candidates) {
      if (_appLinkBypassUrls.remove(candidate)) {
        matched = true;
      }
    }
    if (matched) {
      for (final candidate in candidates) {
        _appLinkBypassUrls.remove(candidate);
      }
    }
    return matched;
  }

  void _purgeExpiredAppLinkBypassHosts(DateTime now) {
    _recentAppLinkBypassHosts.removeWhere(
      (_, ts) => now.difference(ts) > _kRecentAppLinkBypassHostTtl,
    );
  }

  void _rememberTemporaryHostBypass({String? scheme, String? host}) {
    final normalizedHost = host?.trim().toLowerCase();
    if (normalizedHost == null || normalizedHost.isEmpty) {
      return;
    }
    final normalizedScheme = scheme?.trim().toLowerCase();
    if (normalizedScheme != null &&
        normalizedScheme.isNotEmpty &&
        !_isHttpScheme(normalizedScheme)) {
      return;
    }
    final now = DateTime.now();
    _purgeExpiredAppLinkBypassHosts(now);
    _recentAppLinkBypassHosts[normalizedHost] = now;
    if (normalizedScheme != null && normalizedScheme.isNotEmpty) {
      _recentAppLinkBypassHosts['$normalizedScheme://$normalizedHost'] = now;
    }
  }

  void _rememberTemporaryHostBypassFromUrl(String? url) {
    if (url == null) {
      return;
    }
    final parsed = Uri.tryParse(url);
    if (parsed == null) {
      return;
    }
    _rememberTemporaryHostBypass(scheme: parsed.scheme, host: parsed.host);
  }

  bool _shouldBypassHostDueToRecentAllowance({
    required DateTime now,
    String? scheme,
    String? host,
  }) {
    final normalizedHost = host?.trim().toLowerCase();
    if (normalizedHost == null || normalizedHost.isEmpty) {
      return false;
    }
    final normalizedScheme = scheme?.trim().toLowerCase();
    if (normalizedScheme != null &&
        normalizedScheme.isNotEmpty &&
        !_isHttpScheme(normalizedScheme)) {
      return false;
    }
    final keys = <String>{normalizedHost};
    if (normalizedScheme != null && normalizedScheme.isNotEmpty) {
      keys.add('$normalizedScheme://$normalizedHost');
    }
    bool allowed = false;
    for (final key in keys) {
      final ts = _recentAppLinkBypassHosts[key];
      if (ts == null) {
        continue;
      }
      if (now.difference(ts) <= _kRecentAppLinkBypassHostTtl) {
        allowed = true;
        _recentAppLinkBypassHosts[key] = now;
      } else {
        _recentAppLinkBypassHosts.remove(key);
      }
    }
    return allowed;
  }

  WebUri? _tryParseWebUri(String value) {
    try {
      return WebUri(value);
    } catch (_) {
      return null;
    }
  }

  void _attemptAppLinkBypass(
    InAppWebViewController controller,
    _BlockedExternalNavigation blocked,
  ) {
    if (!blocked.canBypassInWebView) {
      return;
    }
    WebUri? target = blocked.resolvedUri;
    target ??= _tryParseWebUri(blocked.rawUrl);
    if (target == null) {
      return;
    }
    final targetString = target.toString();
    if (targetString.trim().isEmpty) {
      return;
    }
    final candidateKeys =
        <String>{}
          ..addAll(_normalizedBypassCandidates(targetString))
          ..addAll(_normalizedBypassCandidates(blocked.rawUrl))
          ..addAll(
            _normalizedBypassCandidates(blocked.resolvedUri?.toString()),
          );
    if (candidateKeys.isEmpty) {
      return;
    }
    _rememberTemporaryHostBypassFromUrl(targetString);
    _rememberTemporaryHostBypassFromUrl(blocked.rawUrl);
    _rememberTemporaryHostBypassFromUrl(blocked.resolvedUri?.toString());
    if (candidateKeys.any(_appLinkBypassUrls.contains)) {
      return;
    }
    for (final key in candidateKeys) {
      _appLinkBypassUrls.add(key);
    }
    Future.microtask(() async {
      try {
        await controller.loadUrl(urlRequest: URLRequest(url: target));
      } catch (_) {
        for (final key in candidateKeys) {
          _appLinkBypassUrls.remove(key);
        }
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_uaInitialized) {
      _loadUaFromPrefs(context);
    }
  }

  @override
  void dispose() {
    // Dispose each tab's controllers and progress notifiers. Also dispose
    // the focus node when the page is destroyed to free resources.
    for (final tab in _tabs) {
      tab.urlCtrl.dispose();
      tab.progress.dispose();
      tab.isLoading.dispose();
      _closeMiniPlayer();
    }
    uaNotifier.removeListener(_onUaChanged);
    repo.ytOptions.removeListener(_onYtOptionsChanged);
    repo.pendingNewTab.removeListener(_onPendingNewTab);
    repo.adBlockFilterSets.removeListener(_onAdBlockFilterSetsChanged);
    repo.longPressDetectionEnabled.removeListener(_onLongPressDetectionChanged);
    _urlFocus.dispose();
    _removeYtFetchBarrier();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    focusNode: _urlFocus,
                    // Bind the text controller to the current tab's URL controller.
                    controller:
                        (_tabs.isNotEmpty
                            ? _tabs[_currentTabIndex].urlCtrl
                            : TextEditingController()),
                    onTap: () {
                      final ctrl =
                          (_tabs.isNotEmpty
                              ? _tabs[_currentTabIndex].urlCtrl
                              : null);
                      if (ctrl != null) {
                        ctrl.selection = TextSelection(
                          baseOffset: 0,
                          extentOffset: ctrl.text.length,
                        );
                      }
                      _checkClipboardForPasteButton();
                    },
                    onChanged: (_) {
                      if (_urlFocus.hasFocus) _checkClipboardForPasteButton();
                    },
                    textInputAction: TextInputAction.go,
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      hintText: context.l10n('browser.urlField.hint'),
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_showPaste)
                            IconButton(
                              tooltip: context.l10n('browser.urlField.paste'),
                              icon: const Icon(Icons.content_paste),
                              onPressed: () async {
                                try {
                                  final data = await Clipboard.getData(
                                    Clipboard.kTextPlain,
                                  );
                                  final clip = data?.text ?? '';
                                  if (_tabs.isNotEmpty) {
                                    final c = _tabs[_currentTabIndex].urlCtrl;
                                    c.text = clip;
                                    c.selection = TextSelection.collapsed(
                                      offset: c.text.length,
                                    );
                                  }
                                  setState(() => _showPaste = false);
                                } catch (_) {}
                              },
                            ),
                          if (_tabs.isNotEmpty &&
                              _tabs[_currentTabIndex].urlCtrl.text.isNotEmpty &&
                              _urlFocus.hasFocus)
                            IconButton(
                              tooltip: context.l10n('browser.urlField.clear'),
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                if (_tabs.isNotEmpty) {
                                  _tabs[_currentTabIndex].urlCtrl.clear();
                                }
                                _urlFocus.unfocus();
                                setState(() {});
                              },
                            ),
                        ],
                      ),
                      suffixIconConstraints: const BoxConstraints(
                        minWidth: 0,
                        minHeight: 0,
                      ),
                    ),
                    onSubmitted: (v) => _go(v),
                  ),
                ),
                ValueListenableBuilder<List<String>>(
                  valueListenable: repo.favorites,
                  builder: (context, favs, _) {
                    String? curUrl;
                    if (_tabs.isNotEmpty) {
                      curUrl = _tabs[_currentTabIndex].currentUrl;
                    }
                    final isFav = curUrl != null && favs.contains(curUrl);
                    final currentUrl = curUrl;
                    return IconButton(
                      icon: Icon(
                        isFav ? Icons.favorite : Icons.favorite_border,
                      ),
                      color: isFav ? Colors.redAccent : null,
                      tooltip:
                          isFav
                              ? context.l10n('browser.toolbar.favorite.remove')
                              : context.l10n('browser.toolbar.favorite.add'),
                      visualDensity: VisualDensity.compact,
                      onPressed:
                          currentUrl == null
                              ? null
                              : () {
                                repo.toggleFavoriteUrl(currentUrl);
                                setState(() {});
                              },
                    );
                  },
                ),
                if (_tabs.isEmpty ||
                    _currentTabIndex < 0 ||
                    _currentTabIndex >= _tabs.length)
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: context.l10n('browser.toolbar.reload'),
                    visualDensity: VisualDensity.compact,
                    onPressed: null,
                  )
                else
                  ValueListenableBuilder<bool>(
                    valueListenable: _tabs[_currentTabIndex].isLoading,
                    builder: (context, loading, _) {
                      final tab = _tabs[_currentTabIndex];
                      return IconButton(
                        icon: Icon(loading ? Icons.close : Icons.refresh),
                        tooltip:
                            loading
                                ? context.l10n('browser.toolbar.stop')
                                : context.l10n('browser.toolbar.reload'),
                        visualDensity: VisualDensity.compact,
                        onPressed: () {
                          final controller = tab.controller;
                          if (controller == null) return;
                          if (loading) {
                            try {
                              unawaited(controller.stopLoading());
                            } catch (_) {}
                            tab.isLoading.value = false;
                            tab.progress.value = 0.0;
                          } else {
                            controller.reload();
                          }
                        },
                      );
                    },
                  ),
                const SizedBox(width: 4),
                _buildToolbarMenuButton(),
              ],
            ),
            // Loading progress bar for the current tab
            ValueListenableBuilder<double>(
              valueListenable:
                  (_tabs.isNotEmpty
                      ? _tabs[_currentTabIndex].progress
                      : ValueNotifier<double>(0.0)),
              builder: (context, p, _) {
                if (p <= 0.0 || p >= 1.0) {
                  return const SizedBox(height: 0);
                }
                return LinearProgressIndicator(value: p, minHeight: 2);
              },
            ),
          ],
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: ValueListenableBuilder<List<PlayingVideoCandidate>>(
        valueListenable: repo.playingVideos,
        builder: (context, candidates, _) {
          if (candidates.isEmpty) {
            return const SizedBox.shrink();
          }
          final label = context.l10n(
            'browser.playingNow.button',
            params: {'count': '${candidates.length}'},
          );
          return FloatingActionButton.extended(
            onPressed: _showPlayingVideosSheet,
            icon: const Icon(Icons.playlist_play),
            label: Text(label),
          );
        },
      ),
      body: Column(
        children: [
          _toolbar(),
          Expanded(
            child: IndexedStack(
              index: _currentTabIndex,
              children: [
                for (int tabIndex = 0; tabIndex < _tabs.length; tabIndex++)
                  Stack(
                    children: [
                      InAppWebView(
                        key: _tabs[tabIndex].webviewKey,
                        contextMenu: ContextMenu(
                          // ignore: deprecated_member_use
                          options: ContextMenuOptions(
                            hideDefaultSystemContextMenuItems: false,
                          ),
                        ),
                        initialSettings: InAppWebViewSettings(
                          userAgent: _userAgent,
                          allowsInlineMediaPlayback: true,
                          allowsPictureInPictureMediaPlayback: true,
                          allowsAirPlayForMediaPlayback: true,
                          mediaPlaybackRequiresUserGesture: false,
                          useOnLoadResource: true,
                          useShouldOverrideUrlLoading: true,
                          javaScriptEnabled: true,
                          javaScriptCanOpenWindowsAutomatically: true,

                          supportMultipleWindows: true,

                          allowsBackForwardNavigationGestures: true,
                          allowsLinkPreview: false,
                          contentBlockers:
                              repo.adBlockEnabled.value
                                  ? _adBlockerRules
                                  : const [],
                        ),
                        initialUrlRequest: URLRequest(
                          url: WebUri(
                            (() {
                              final s = _tabs[tabIndex].urlCtrl.text.trim();
                              return s.isEmpty ? 'about:blank' : s;
                            })(),
                          ),
                        ),
                        onWebViewCreated: (c) {
                          final tab = _tabs[tabIndex];
                          tab.controller = c;
                          // Register the JavaScript handler that receives sniffed media info.
                          c.addJavaScriptHandler(
                            handlerName: 'sniffer',
                            callback: (args) {
                              if (!repo.snifferEnabled.value) {
                                return {'ok': false, 'ignored': true};
                              }
                              final map = Map<String, dynamic>.from(args.first);
                              final url = (map['url'] ?? '').toString();
                              final type = (map['type'] ?? 'video').toString();
                              final contentType =
                                  (map['contentType'] ?? '').toString();
                              final poster = map['poster'] as String? ?? '';
                              double? dur;
                              final d = map['duration'];
                              if (d is num) {
                                dur = d.toDouble();
                              }
                              repo.addHit(
                                MediaHit(
                                  url: url,
                                  type: type,
                                  contentType: contentType,
                                  poster: poster,
                                  durationSeconds: dur,
                                ),
                              );
                              return {'ok': true};
                            },
                          );

                          c.addJavaScriptHandler(
                            handlerName: 'debugTapLogger',
                            callback: (args) {
                              if (args.isEmpty) {
                                return {'logged': false};
                              }
                              final dynamic raw = args.first;
                              if (raw is! Map) {
                                return {'logged': false};
                              }
                              final data = Map<String, dynamic>.from(
                                raw as Map,
                              );
                              if (kDebugMode) {
                                final eventType =
                                    _stringFromPayload(data['eventType']) ??
                                    'unknown';
                                final tag = _stringFromPayload(data['tag']);
                                final elementId = _stringFromPayload(
                                  data['id'],
                                );
                                final classes = _stringFromPayload(
                                  data['classes'],
                                );
                                final href = _stringFromPayload(
                                  data['linkHref'],
                                );
                                final linkText = _truncateForDebugLog(
                                  _stringFromPayload(data['linkText']),
                                );
                                final buttonText = _truncateForDebugLog(
                                  _stringFromPayload(data['buttonText']),
                                );
                                final elementText = _truncateForDebugLog(
                                  _stringFromPayload(data['text']),
                                );
                                final buffer = StringBuffer(
                                  '[Debug][WebTap] $eventType on',
                                );
                                if (tag != null && tag.isNotEmpty) {
                                  buffer.write(' <$tag>');
                                } else {
                                  buffer.write(' <unknown>');
                                }
                                if (elementId != null && elementId.isNotEmpty) {
                                  buffer.write(' #$elementId');
                                }
                                if (classes != null && classes.isNotEmpty) {
                                  buffer.write(' .$classes');
                                }
                                if (href != null && href.isNotEmpty) {
                                  buffer.write(' href=$href');
                                }
                                if (linkText != null && linkText.isNotEmpty) {
                                  buffer.write(' linkText="$linkText"');
                                }
                                if (buttonText != null &&
                                    buttonText.isNotEmpty) {
                                  buffer.write(' buttonText="$buttonText"');
                                }
                                if (elementText != null &&
                                    elementText.isNotEmpty &&
                                    (buttonText == null ||
                                        buttonText.isEmpty) &&
                                    (linkText == null || linkText.isEmpty)) {
                                  buffer.write(' text="$elementText"');
                                }
                                buffer.write(
                                  ' (longPressSuppressed=$_suppressLinkLongPress)',
                                );
                                debugPrint(buffer.toString());
                              }
                              return {'logged': true};
                            },
                          );

                          unawaited(_injectDebugTapLogger(c));
                        },
                        onLoadStart: (c, u) async {
                          _cachedYoutubeInfo = null;
                          // 雙保險：硬攔非 Web scheme（極少數情況仍可能觸發）
                          final blocked = _shouldPreventExternalNavigation(
                            u,
                            controller: c,
                          );
                          if (blocked != null) {
                            _handleBlockedExternalNavigation(
                              blocked,
                              controller: c,
                            );
                            return;
                          }

                          await _injectDebugTapLogger(c);
                          repo.clearPlayingVideos();
                          final tab = _tabs[tabIndex];
                          tab.isLoading.value = true;
                          tab.progress.value = 0.0;
                          if (u != null) {
                            final s = u.toString();
                            final isBlank = s.trim().toLowerCase().startsWith(
                              'about:blank',
                            );
                            tab.urlCtrl.text = isBlank ? '' : s;
                            tab.currentUrl = isBlank ? null : s;
                            if (!isBlank) {
                              AppRepo.I.currentPageUrl.value = s;
                              if (tabIndex == _currentTabIndex) {
                                AppRepo.I.currentPageTitle.value = null;
                              }
                            }
                            if (mounted) setState(() {});
                          }
                        },
                        onUpdateVisitedHistory: (
                          c,
                          url,
                          androidIsReload,
                        ) async {
                          if (url != null) {
                            final tab = _tabs[tabIndex];
                            final s = url.toString();
                            final isBlank = s.trim().toLowerCase().startsWith(
                              'about:blank',
                            );
                            tab.urlCtrl.text = isBlank ? '' : s;
                            tab.currentUrl = isBlank ? null : s;
                            if (!isBlank) {
                              AppRepo.I.currentPageUrl.value = s;
                              if (tabIndex == _currentTabIndex) {
                                AppRepo.I.currentPageTitle.value = null;
                              }
                            }
                            if (mounted) setState(() {});
                          }
                        },
                        onLoadStop: (c, u) async {
                          await _injectDebugTapLogger(c);
                          // 注入嗅探腳本並同步開關
                          await c.evaluateJavascript(source: Sniffer.jsHook);
                          await c.evaluateJavascript(
                            source: Sniffer.jsSetEnabled(
                              repo.snifferEnabled.value,
                            ),
                          );

                          final curUrl = await c.getUrl();
                          final title = await c.getTitle();
                          if (curUrl != null) {
                            final tab = _tabs[tabIndex];
                            tab.isLoading.value = false;
                            tab.progress.value = 1.0;
                            final s = curUrl.toString();
                            final isBlank = s.trim().toLowerCase().startsWith(
                              'about:blank',
                            );

                            tab.urlCtrl.text = isBlank ? '' : s;
                            tab.currentUrl = isBlank ? null : s;
                            if (!isBlank) {
                              AppRepo.I.currentPageUrl.value = s;
                            }
                            tab.pageTitle = title;
                            if (!isBlank && tabIndex == _currentTabIndex) {
                              final trimmed = title?.trim();
                              AppRepo.I.currentPageTitle.value =
                                  (trimmed != null && trimmed.isNotEmpty)
                                      ? trimmed
                                      : null;
                            }

                            // about:blank 不寫入歷史；復原的第一筆載入也跳過
                            if (!isBlank) {
                              unawaited(_captureTabThumbnail(tab, force: true));
                              if (tab.restoringInitialHistory) {
                                tab.restoringInitialHistory = false;
                              }
                              _updateHistoryForUrl(tab, s);
                              if (!tab.skipInitialHistory) {
                                repo.addHistory(s, title ?? '');
                              } else {
                                tab.skipInitialHistory = false;
                              }
                            } else {
                              tab.skipInitialHistory = false;
                              tab.restoringInitialHistory = false;
                            }
                            if (tab.skipNextHistorySync) {
                              tab.skipNextHistorySync = false;
                            } else {
                              unawaited(_syncHistoryFromController(tab));
                            }
                            _updateOpenTabs();
                            if (tabIndex == _currentTabIndex) {
                              _syncRepoPageContext();
                            }
                            if (mounted) setState(() {});
                          }
                        },
                        onTitleChanged: (c, title) {
                          final tab = _tabs[tabIndex];
                          tab.pageTitle = title;
                          if (tabIndex == _currentTabIndex) {
                            final trimmed = title?.trim();
                            AppRepo.I.currentPageTitle.value =
                                (trimmed != null && trimmed.isNotEmpty)
                                    ? trimmed
                                    : null;
                          }
                          if (mounted) setState(() {});
                        },
                        onProgressChanged: (c, progress) {
                          final tab = _tabs[tabIndex];
                          final fraction = progress / 100.0;
                          tab.progress.value = fraction;
                          if (progress >= 100) {
                            tab.isLoading.value = false;
                          } else if (progress > 0) {
                            tab.isLoading.value = true;
                          }
                        },
                        onReceivedError: (controller, request, error) {
                          final tab = _tabs[tabIndex];
                          tab.isLoading.value = false;
                          tab.progress.value = 0.0;
                        },
                        onCreateWindow: (ctl, createWindowRequest) async {
                          final req = createWindowRequest.request;
                          final uri = req?.url;
                          final blocked = _shouldPreventExternalNavigation(
                            uri,
                            controller: ctl,
                            request: req,
                            createWindowRequest: createWindowRequest,
                          );
                          if (blocked != null) {
                            _handleBlockedExternalNavigation(
                              blocked,
                              controller: ctl,
                            );
                            // 消化這次開窗要求（不交給系統），避免跳去外部 App
                            return true;
                          }
                          if (uri != null && repo.blockPopup.value) {
                            debugPrint(
                              '[Popup] Blocked window.open for ${uri.toString()}',
                            );
                            _showSnackBar(
                              context.l10n('browser.snack.blockedPopup'),
                            );
                            return true;
                          }
                          if (req != null) {
                            await ctl.loadUrl(urlRequest: req);
                            return true;
                          }
                          return true;
                        },
                        onLoadResource: (c, r) async {
                          if (!repo.snifferEnabled.value) {
                            return;
                          }
                          final url = r.url.toString();
                          final ct = '';
                          if (Sniffer.looksLikeMedia(url, contentType: ct)) {
                            repo.addHit(
                              MediaHit(
                                url: url,
                                type:
                                    ct.startsWith('audio/') ? 'audio' : 'video',
                                contentType: ct,
                              ),
                            );
                          }
                        },
                        shouldInterceptRequest: (c, r) async {
                          if (!repo.snifferEnabled.value) {
                            return null;
                          }
                          final url = r.url.toString();
                          final ct = r.headers?['content-type'] ?? '';
                          if (Sniffer.looksLikeMedia(url, contentType: ct)) {
                            repo.addHit(
                              MediaHit(
                                url: url,
                                type:
                                    ct.toString().startsWith('audio/')
                                        ? 'audio'
                                        : 'video',
                                contentType: ct,
                              ),
                            );
                          }
                          return null;
                        },
                        shouldOverrideUrlLoading: (
                          controller,
                          navigationAction,
                        ) async {
                          final requestUrl = navigationAction.request.url;
                          final navType = navigationAction.navigationType;
                          final navTypeDescription =
                              navType != null
                                  ? describeEnum(navType)
                                  : 'unknown';
                          final requestDescription =
                              requestUrl?.rawValue ??
                              requestUrl?.toString() ??
                              'unknown';
                          debugPrint(
                            '[Debug][WebView] shouldOverrideUrlLoading triggered '
                            'for $requestDescription '
                            '(type: $navTypeDescription)',
                          );
                          final blocked = _shouldPreventExternalNavigation(
                            navigationAction.request.url,
                            controller: controller,
                            action: navigationAction,
                          );
                          if (blocked != null) {
                            _handleBlockedExternalNavigation(
                              blocked,
                              controller: controller,
                            );
                            return NavigationActionPolicy.CANCEL;
                          }
                          return NavigationActionPolicy.ALLOW;
                        },
                        onLongPressHitTestResult: (c, res) async {
                          await _resetAndReleaseWebViewAfterContextMenu(c);
                        },
                      ),
                      Positioned.fill(
                        child: Row(
                          children: [
                            _buildEdgeSwipeArea(
                              isLeft: true,
                              tabIndex: tabIndex,
                            ),
                            const Expanded(
                              child: IgnorePointer(child: SizedBox.expand()),
                            ),
                            _buildEdgeSwipeArea(
                              isLeft: false,
                              tabIndex: tabIndex,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // 清空所有分頁（保留一個空白分頁）
  void _clearAllTabs() {
    for (final t in _tabs) {
      t.urlCtrl.dispose();
      t.progress.dispose();
      t.isLoading.dispose();
    }
    setState(() {
      _tabs.clear();
      _tabs.add(_createTab());
      _currentTabIndex = 0;
      _persistCurrentTabIndex();
    });
    _updateOpenTabs();
  }

  /// Renders an icon with a numeric badge (if count > 0).
  Widget _iconWithBadge({
    required Widget icon,
    required int count,
    EdgeInsetsGeometry iconPadding = const EdgeInsets.all(8.0),
  }) {
    if (count <= 0) return Padding(padding: iconPadding, child: icon);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Padding(padding: iconPadding, child: icon),
        Positioned(
          right: -2,
          top: -2,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.error,
              borderRadius: BorderRadius.circular(10),
            ),
            constraints: const BoxConstraints(minWidth: 18),
            child: Text(
              count > 99 ? '99+' : '$count',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ],
    );
  }

  /// Toolbar with back/forward/refresh and a button to load the current URL into the address bar.
  Widget _toolbar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4.0),
      child: LayoutBuilder(
        builder: (context, box) {
          final shortest = MediaQuery.of(context).size.shortestSide;
          final bool tablet = shortest >= 600;
          Widget pad(Widget child) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2.0),
            child: child,
          );

          final navItems = <Widget>[
            pad(
              IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: context.l10n('browser.toolbar.back'),
                onPressed: () => _navigateHistoryDelta(-1),
              ),
            ),
            pad(
              IconButton(
                icon: const Icon(Icons.arrow_forward),
                tooltip: context.l10n('browser.toolbar.forward'),
                onPressed: () => _navigateHistoryDelta(1),
              ),
            ),
          ];

          // Right side controls (all aligned right): Sniffer, Resources, Downloads
          final rightSideButtons = <Widget>[
            // Sniffer toggle (eye icon)
            pad(
              ValueListenableBuilder<bool>(
                valueListenable: AppRepo.I.premiumUnlocked,
                builder: (context, premium, _) {
                  return ValueListenableBuilder<bool>(
                    valueListenable: repo.snifferEnabled,
                    builder: (context, on, __) {
                      final active = premium && on;
                      return IconButton(
                        tooltip:
                            premium
                                ? context.l10n(
                                  'browser.sniffer.tooltip.enabled',
                                )
                                : context.l10n(
                                  'browser.sniffer.tooltip.premiumLocked',
                                ),
                        onPressed: () async {
                          if (!premium) {
                            await PurchaseService().showPurchasePrompt(
                              context,
                              featureName: context.l10n('feature.sniffing'),
                            );
                            return;
                          }
                          await _toggleSniffer();
                        },
                        icon: Icon(
                          active ? Icons.visibility : Icons.visibility_off,
                        ),
                        color: active ? Colors.green : null,
                        visualDensity: VisualDensity.compact,
                      );
                    },
                  );
                },
              ),
            ),
            // Resources (detected hits) with live badge
            pad(
              ValueListenableBuilder<bool>(
                valueListenable: AppRepo.I.premiumUnlocked,
                builder: (context, premium, _) {
                  return ValueListenableBuilder<List<MediaHit>>(
                    valueListenable: repo.hits,
                    builder: (context, hits, __) {
                      final detected = hits.length;
                      final tooltip =
                          premium
                              ? (detected > 0
                                  ? context.l10n(
                                    'browser.resources.tooltip.count',
                                    params: {'count': detected.toString()},
                                  )
                                  : context.l10n('browser.resources.tooltip'))
                              : context.l10n(
                                'browser.resources.tooltip.premiumLocked',
                              );
                      return IconButton(
                        tooltip: tooltip,
                        onPressed: () async {
                          if (!premium) {
                            await PurchaseService().showPurchasePrompt(
                              context,
                              featureName: context.l10n(
                                'feature.sniffingResources',
                              ),
                            );
                            return;
                          }
                          await _openDetectedSheet();
                        },
                        visualDensity: VisualDensity.compact,
                        icon: _iconWithBadge(
                          icon: const Icon(Icons.search),
                          count: detected,
                          iconPadding: const EdgeInsets.all(8.0),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            // Add to home shortcut
            pad(
              IconButton(
                tooltip: context.l10n('browser.context.addHome'),
                onPressed: () {
                  unawaited(_showAddToHomeDialog());
                },
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.add),
              ),
            ),
            // Downloads with live badge (only count real download tasks)
            pad(
              ValueListenableBuilder<List<DownloadTask>>(
                valueListenable: repo.downloads,
                builder: (context, list, _) {
                  final downloadCount =
                      list
                          .where(_isDownloadTaskEntry)
                          .where(_isActiveDownloadTask)
                          .length;
                  return IconButton(
                    tooltip:
                        downloadCount > 0
                            ? context.l10n(
                              'browser.downloadList.titleWithCount',
                              params: {'count': downloadCount.toString()},
                            )
                            : context.l10n('browser.downloadList.title'),
                    onPressed: _openDownloadsSheet,
                    visualDensity: VisualDensity.compact,
                    icon: _iconWithBadge(
                      icon: const Icon(Icons.file_download),
                      count: downloadCount,
                      iconPadding: const EdgeInsets.all(8.0),
                    ),
                  );
                },
              ),
            ),
          ];

          final tabButton = pad(
            GestureDetector(
              onTap: _openTabManager,
              onLongPress: () async {
                await HapticFeedback.mediumImpact();
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (context) {
                    return AlertDialog(
                      title: Text(context.l10n('browser.tabs.closeAll.title')),
                      content: Text(
                        context.l10n('browser.tabs.closeAll.message'),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: Text(context.l10n('common.cancel')),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.of(context).pop(true),
                          child: Text(context.l10n('common.close')),
                        ),
                      ],
                    );
                  },
                );
                if (confirm == true) {
                  _clearAllTabs();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        duration: const Duration(seconds: 1),
                        content: Text(
                          context.l10n('browser.snack.tabs.cleared'),
                        ),
                      ),
                    );
                  }
                }
              },
              child: Container(
                key: _tabButtonKey,
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceVariant,
                  border: Border.all(
                    color: Theme.of(
                      context,
                    ).colorScheme.outline.withOpacity(0.8),
                    width: 1.2,
                  ),
                  borderRadius: BorderRadius.circular(6),
                ),
                alignment: Alignment.center,
                child: Text(
                  '${_tabs.length}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
            ),
          );

          if (tablet) {
            return Row(
              children: [
                ...navItems,
                const Spacer(),
                ...rightSideButtons,
                tabButton,
              ],
            );
          }

          return Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  alignment: WrapAlignment.start,
                  children: navItems,
                ),
              ),
              ...rightSideButtons,
              tabButton,
            ],
          );
        },
      ),
    );
  }

  Widget _buildToolbarMenuButton() {
    return AnimatedBuilder(
      animation: Listenable.merge([
        repo.snifferEnabled,
        repo.hits,
        repo.downloads,
        repo.favorites,
        repo.history,
        repo.blockPopup,
        repo.longPressDetectionEnabled,
        repo.adBlockEnabled,
        repo.adBlockFilterSets,
      ]),
      builder: (context, _) {
        return IconButton(
          key: _menuButtonKey,
          tooltip: context.l10n('browser.toolbar.menu'),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
          onPressed: _showToolbarMenu,
          icon: Icon(
            Icons.more_horiz,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        );
      },
    );
  }

  Future<void> _showToolbarMenu() async {
    final keyContext = _menuButtonKey.currentContext;
    if (keyContext == null) return;
    final renderObject = keyContext.findRenderObject();
    if (renderObject is! RenderBox) return;
    final overlay = Overlay.of(context);
    if (overlay == null) return;
    final overlayBox = overlay.context.findRenderObject();
    if (overlayBox is! RenderBox) return;

    final repo = AppRepo.I;

    final favoriteCount = repo.favorites.value.length;
    final historyCount = repo.history.value.length;
    final blockPopupOn = repo.blockPopup.value;
    final autoDetectOn = repo.longPressDetectionEnabled.value;
    final adBlockOn = repo.adBlockEnabled.value;
    final selectedProfiles = repo.adBlockFilterSets.value;

    PopupMenuItem<_ToolbarMenuAction> buildItem(
      _ToolbarMenuAction action,
      IconData icon,
      String label, {
      Color? iconColor,
    }) {
      return PopupMenuItem<_ToolbarMenuAction>(
        value: action,
        child: Row(
          children: [
            Icon(icon, color: iconColor),
            const SizedBox(width: 12),
            Expanded(child: Text(label)),
          ],
        ),
      );
    }

    final colorScheme = Theme.of(context).colorScheme;
    final topLeft = renderObject.localToGlobal(
      Offset.zero,
      ancestor: overlayBox,
    );
    final bottomRight = renderObject.localToGlobal(
      renderObject.size.bottomRight(Offset.zero),
      ancestor: overlayBox,
    );
    final position = RelativeRect.fromRect(
      Rect.fromPoints(topLeft, bottomRight),
      Offset.zero & overlayBox.size,
    ).shift(const Offset(0, 8));

    final entries = <PopupMenuEntry<_ToolbarMenuAction>>[
      buildItem(
        _ToolbarMenuAction.openFavorites,
        Icons.favorite,
        favoriteCount > 0
            ? context.l10n(
              'browser.menu.favoritesWithCount',
              params: {'count': favoriteCount.toString()},
            )
            : context.l10n('browser.menu.favorites'),
        iconColor: favoriteCount > 0 ? Colors.redAccent : null,
      ),
      buildItem(
        _ToolbarMenuAction.openHistory,
        Icons.history,
        historyCount > 0
            ? context.l10n(
              'browser.menu.historyWithCount',
              params: {'count': historyCount.toString()},
            )
            : context.l10n('browser.menu.history'),
        iconColor: historyCount > 0 ? colorScheme.primary : null,
      ),
      buildItem(
        _ToolbarMenuAction.clearBrowsingData,
        Icons.cleaning_services,
        context.l10n('browser.menu.clearBrowsingData'),
        iconColor: colorScheme.error,
      ),
      const PopupMenuDivider(),
      buildItem(
        _ToolbarMenuAction.toggleAdBlocker,
        adBlockOn ? Icons.toggle_on : Icons.toggle_off,

        _adBlockerMenuLabel(adBlockOn, selectedProfiles),
        iconColor: adBlockOn ? colorScheme.primary : null,
      ),
      buildItem(
        _ToolbarMenuAction.toggleAutoDetectMedia,
        autoDetectOn ? Icons.toggle_on : Icons.toggle_off,
        context.l10n('settings.detectMediaLongPress.title'),
        iconColor: autoDetectOn ? colorScheme.primary : null,
      ),
      buildItem(
        _ToolbarMenuAction.toggleBlockPopup,
        blockPopupOn ? Icons.toggle_on : Icons.toggle_off,
        context.l10n('browser.menu.blockPopups'),
        iconColor: blockPopupOn ? Colors.redAccent : null,
      ),
      buildItem(
        _ToolbarMenuAction.blockExternalApp,
        _blockExternalApp ? Icons.toggle_on : Icons.toggle_off,
        context.l10n('browser.menu.blockExternalApps'),
        iconColor:
            _blockExternalApp ? Theme.of(context).colorScheme.primary : null,
      ),
      const PopupMenuDivider(),
      buildItem(
        _ToolbarMenuAction.addHome,
        Icons.add,
        context.l10n('browser.context.addHome'),
      ),
      buildItem(
        _ToolbarMenuAction.goHome,
        Icons.home,
        context.l10n('browser.menu.home'),
      ),
      buildItem(
        _ToolbarMenuAction.help,
        Icons.help_outline,
        context.l10n('browser.menu.help'),
      ),
    ];

    final selected = await showMenu<_ToolbarMenuAction>(
      context: context,
      position: position,
      items: entries,
    );
    if (!mounted || selected == null) {
      return;
    }

    final keepOpen =
        selected == _ToolbarMenuAction.toggleAutoDetectMedia ||
        selected == _ToolbarMenuAction.toggleBlockPopup ||
        selected == _ToolbarMenuAction.blockExternalApp;

    switch (selected) {
      case _ToolbarMenuAction.openFavorites:
        await _openFavoritesPage();
        break;
      case _ToolbarMenuAction.openHistory:
        await _openHistoryPage();
        break;
      case _ToolbarMenuAction.clearBrowsingData:
        await _clearBrowsingData();
        break;
      case _ToolbarMenuAction.toggleAdBlocker:
        await _showAdBlockerSettings();
        break;
      case _ToolbarMenuAction.toggleAutoDetectMedia:
        {
          final next = !repo.longPressDetectionEnabled.value;
          repo.setLongPressDetectionEnabled(next);
          final sp = await SharedPreferences.getInstance();
          await sp.setBool('detect_media_long_press', next);
          if (!mounted) {
            break;
          }
          final snackKey =
              next
                  ? 'settings.detectMediaLongPress.snack.enabled'
                  : 'settings.detectMediaLongPress.snack.disabled';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              duration: const Duration(seconds: 1),
              content: Text(context.l10n(snackKey)),
            ),
          );
        }
        break;
      case _ToolbarMenuAction.toggleBlockPopup:
        _toggleBlockPopupSetting();
        break;
      case _ToolbarMenuAction.blockExternalApp:
        _toggleBlockExternalAppSetting();
        break;
      case _ToolbarMenuAction.addHome:
        await _showAddToHomeDialog();
        break;
      case _ToolbarMenuAction.goHome:
        if (widget.onGoHome != null) {
          widget.onGoHome!();
        }
        break;
      case _ToolbarMenuAction.help:
        await _showBrowserHelpDialog(requireAcknowledgement: false);
        break;
    }

    if (keepOpen && mounted) {
      await Future.delayed(const Duration(milliseconds: 120));
      if (mounted) {
        _showToolbarMenu();
      }
    }
  }

  Widget _buildEdgeSwipeArea({required bool isLeft, required int tabIndex}) {
    double drag = 0;
    return SizedBox(
      width: _edgeSwipeWidth,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: (_) {
          drag = 0;
        },
        onHorizontalDragUpdate: (details) {
          final delta = details.delta.dx;
          if (isLeft) {
            drag += delta;
            if (drag < 0) drag = 0;
          } else {
            drag -= delta;
            if (drag < 0) drag = 0;
          }
        },
        onHorizontalDragCancel: () {
          drag = 0;
        },
        onHorizontalDragEnd: (details) {
          final tab = tabIndex < _tabs.length ? _tabs[tabIndex] : null;
          final controller = tab?.controller;
          if (controller == null) {
            drag = 0;
            return;
          }
          final velocity = details.primaryVelocity ?? 0.0;
          final directionalVelocity = isLeft ? velocity : -velocity;
          final exceededDistance = drag > _edgeSwipeDistanceThreshold;
          final exceededVelocity =
              directionalVelocity > _edgeSwipeVelocityThreshold;
          if (exceededDistance || exceededVelocity) {
            if (isLeft) {
              if (tab != null && _canNavigateHistory(tab, -1)) {
                _navigateHistoryForTab(tabIndex, -1);
              } else {
                controller.canGoBack().then((can) {
                  if (can) controller.goBack();
                });
              }
            } else {
              if (tab != null && _canNavigateHistory(tab, 1)) {
                _navigateHistoryForTab(tabIndex, 1);
              } else {
                controller.canGoForward().then((can) {
                  if (can) controller.goForward();
                });
              }
            }
          }
          drag = 0;
        },
      ),
    );
  }

  /// Navigates to a new URL entered by the user.
  Future<void> _go(String v) async {
    final text = v.trim();
    if (text.isEmpty) return;

    // 若像網址就直連；否則依設定的搜尋引擎產生查詢 URL
    final isUrl = text.startsWith('http') || text.contains('.');
    final dest =
        isUrl
            ? (text.startsWith('http') ? text : 'https://$text')
            : await _buildSearchUrl(text);

    _ensureActiveTab();
    if (_tabs.isEmpty) return;
    final tab = _tabs[_currentTabIndex];
    if (_blockExternalApp) {
      _rememberTemporaryHostBypassFromUrl(dest);
    }
    if (_looksLikeDirectDownloadUrl(dest)) {
      final handled = await _offerDownloadForDirectUrl(dest);
      if (handled) {
        _updateOpenTabs();
        return;
      }
    }
    tab.urlCtrl.text = dest;
    tab.currentUrl = dest;
    await tab.controller?.loadUrl(urlRequest: URLRequest(url: WebUri(dest)));
    _updateOpenTabs();
  }

  /// Adds the current page URL to favorites.
  Future<void> _addCurrentToFav() async {
    if (_tabs.isEmpty) return;
    final tab = _tabs[_currentTabIndex];
    final u = await tab.controller?.getUrl();
    final url = u?.toString();
    if (url == null) return;
    repo.toggleFavoriteUrl(url);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 1),
        content: Text(context.l10n('browser.snack.favorites.updated')),
      ),
    );
  }

  Future<void> _toggleSniffer() async {
    final ok = await PurchaseService().ensurePremium(
      context: context,
      featureName: context.l10n('feature.sniffing'),
    );
    if (!ok) {
      return;
    }
    final next = !repo.snifferEnabled.value;
    repo.setSnifferEnabled(next);
    final sp = await SharedPreferences.getInstance();
    await sp.setBool('sniffer_enabled', next);
    if (_tabs.isNotEmpty) {
      final tab = _tabs[_currentTabIndex];
      final controller = tab.controller;
      if (controller != null) {
        await controller.evaluateJavascript(source: Sniffer.jsSetEnabled(next));
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 1),
        content: Text(
          next
              ? context.l10n('browser.snack.sniffer.enabled')
              : context.l10n('browser.snack.sniffer.disabled'),
        ),
      ),
    );
  }

  Future<void> _openFavoritesPage() async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => FavoritesPage(
              onOpen: (String url) {
                if (_tabs.isEmpty) return;
                final tab = _tabs[_currentTabIndex];
                tab.controller?.loadUrl(
                  urlRequest: URLRequest(url: WebUri(url)),
                );
              },
              prettyName: _prettyFileName,
            ),
      ),
    );
  }

  Future<void> _openHistoryPage() async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => HistoryPage(
              onOpen: (String url) {
                if (_tabs.isNotEmpty) {
                  final tab = _tabs[_currentTabIndex];
                  tab.controller?.loadUrl(
                    urlRequest: URLRequest(url: WebUri(url)),
                  );
                }
              },
            ),
      ),
    );
  }

  Future<void> _clearBrowsingData() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder:
          (_) => AlertDialog(
            title: Text(context.l10n('browser.dialog.clearBrowsingData.title')),
            content: Text(
              context.l10n('browser.dialog.clearBrowsingData.message'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(context.l10n('common.cancel')),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(context.l10n('common.clear')),
              ),
            ],
          ),
    );

    if (confirm != true) {
      return;
    }

    repo.clearHistory();

    try {
      await CookieManager.instance().deleteAllCookies();
    } catch (_) {}

    try {
      await WebStorageManager.instance().deleteAllData();
    } catch (_) {}

    for (final tab in _tabs) {
      final controller = tab.controller;
      if (controller == null) continue;
      try {
        await InAppWebViewController.clearAllCache();
      } catch (_) {}
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 1),
        content: Text(context.l10n('browser.snack.browsingDataCleared')),
      ),
    );
  }

  Future<void> _applyAdBlockerSetting() async {
    final enabled = repo.adBlockEnabled.value;
    final blockers = enabled ? _adBlockerRules : const <ContentBlocker>[];
    for (int i = 0; i < _tabs.length; i++) {
      final controller = _tabs[i].controller;
      if (controller == null) continue;
      try {
        await controller.setSettings(
          settings: InAppWebViewSettings(contentBlockers: blockers),
        );
        if (i == _currentTabIndex) {
          await controller.reload();
        }
      } catch (_) {}
    }
  }

  void _onAdBlockFilterSetsChanged() {
    unawaited(_initAdBlockerRules());
  }

  Future<void> _showAdBlockerSettings() async {
    final initialEnabled = repo.adBlockEnabled.value;
    final initialSelection = repo.adBlockFilterSets.value;
    final result = await showDialog<_AdBlockerDialogResult>(
      context: context,
      builder: (context) {
        bool enabled = initialEnabled;
        final tempSelection = {...initialSelection};

        return StatefulBuilder(
          builder: (context, setState) {
            Widget checkbox(String profile) {
              final checked = tempSelection.contains(profile);
              return CheckboxListTile(
                value: checked,
                onChanged:
                    enabled
                        ? (_) {
                          setState(() {
                            if (checked) {
                              tempSelection.remove(profile);
                            } else {
                              tempSelection.add(profile);
                            }
                          });
                        }
                        : null,
                title: Text(
                  context.l10n('browser.dialog.adblocker.checkbox.$profile'),
                ),
              );
            }

            final canConfirm = !enabled || tempSelection.isNotEmpty;
            return AlertDialog(
              title: Text(context.l10n('browser.dialog.adblocker.title')),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SwitchListTile(
                      value: enabled,
                      onChanged: (value) {
                        setState(() {
                          enabled = value;
                        });
                      },
                      title: Text(
                        context.l10n('browser.dialog.adblocker.enableTitle'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      context.l10n('browser.dialog.adblocker.enableSubtitle'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    checkbox('lite'),
                    checkbox('plus'),
                    checkbox('privacy'),
                    if (enabled && tempSelection.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          context.l10n(
                            'browser.dialog.adblocker.selectAtLeastOne',
                          ),
                          style: Theme.of(
                            context,
                          ).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(context.l10n('common.cancel')),
                ),
                FilledButton(
                  onPressed:
                      canConfirm
                          ? () {
                            Navigator.of(context).pop(
                              _AdBlockerDialogResult(
                                enabled: enabled,
                                selectedProfiles: tempSelection.toSet(),
                              ),
                            );
                          }
                          : null,
                  child: Text(context.l10n('common.apply')),
                ),
              ],
            );
          },
        );
      },
    );
    if (result == null) return;
    repo.setAdBlockFilterSets(result.selectedProfiles);
    repo.setAdBlockEnabled(
      result.enabled && result.selectedProfiles.isNotEmpty,
    );
    await _applyAdBlockerSetting();
    if (!mounted) return;
    final enabled = repo.adBlockEnabled.value;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 1),
        content: Text(
          enabled
              ? context.l10n('browser.snack.adblocker.enabled')
              : context.l10n('browser.snack.adblocker.disabled'),
        ),
      ),
    );
  }

  void _toggleBlockPopupSetting() {
    final next = !repo.blockPopup.value;
    repo.setBlockPopup(next);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 1),
        content: Text(
          next
              ? context.l10n('browser.snack.blockPopups.enabled')
              : context.l10n('browser.snack.blockPopups.disabled'),
        ),
      ),
    );
  }

  Future<void> _recordHelpAcknowledged() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kPrefBrowserHelpSeen, true);
  }

  Future<void> _maybeShowBrowserHelp() async {
    final sp = await SharedPreferences.getInstance();
    final seen = sp.getBool(_kPrefBrowserHelpSeen) ?? false;
    if (seen) return;
    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    final acknowledged = await _showBrowserHelpDialog(
      requireAcknowledgement: true,
    );
    if (acknowledged) return;
  }

  Widget _buildHelpDialogContent(
    BuildContext context,
    TextTheme textTheme,
    Color bulletColor,
  ) {
    Widget bullet(String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(top: 6),
            decoration: BoxDecoration(
              color: bulletColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: textTheme.bodyMedium)),
        ],
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        bullet(context.l10n('browser.dialog.adblocker.bullet1')),
        bullet(context.l10n('browser.dialog.adblocker.bullet2')),
        bullet(context.l10n('browser.dialog.adblocker.bullet3')),
        bullet(context.l10n('browser.dialog.adblocker.bullet4')),
        bullet(context.l10n('browser.dialog.adblocker.bullet5')),
        bullet(context.l10n('browser.dialog.adblocker.bullet6')),
      ],
    );
  }

  Future<bool> _showBrowserHelpDialog({
    required bool requireAcknowledgement,
  }) async {
    if (!mounted) return false;
    final theme = Theme.of(context);
    final acknowledged = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        final textTheme = theme.textTheme;
        final colorScheme = theme.colorScheme;
        final accent = colorScheme.primary;
        final surface =
            theme.brightness == Brightness.dark
                ? colorScheme.surfaceVariant.withOpacity(0.95)
                : colorScheme.surfaceVariant;
        return PopScope(
          canPop: !requireAcknowledgement,
          child: Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 24,
              vertical: 24,
            ),
            child: Container(
              decoration: BoxDecoration(
                color: surface,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.18),
                    blurRadius: 20,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline, color: accent, size: 28),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              context.l10n('common.help'),
                              style: textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              context.l10n(
                                'browser.dialog.adblocker.helpSubtitle',
                              ),
                              style: textTheme.bodySmall?.copyWith(
                                color:
                                    textTheme.bodySmall?.color?.withOpacity(
                                      0.75,
                                    ) ??
                                    Colors.black54,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: colorScheme.surface.withOpacity(0.6),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: _buildHelpDialogContent(context, textTheme, accent),
                  ),
                  const SizedBox(height: 20),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      child: Text(context.l10n('common.gotIt')),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (acknowledged == true) {
      await _recordHelpAcknowledged();
      return true;
    }
    return false;
  }

  String _adBlockerMenuLabel(bool enabled, Set<String> profiles) {
    if (!enabled) {
      return context.l10n('browser.menu.adblockerDisabled');
    }
    String displayName(String key) {
      switch (key) {
        case 'lite':
          return 'Lite';
        case 'privacy':
          return 'Privacy';
        case 'plus':
        default:
          return 'Plus';
      }
    }

    final names = profiles.map(displayName).toList()..sort();
    final joined = names.join('、');
    return context.l10n(
      'browser.menu.adblockerEnabled',
      params: {'status': joined},
    );
  }

  /// Prompts the user to confirm downloading the given URL. If confirmed, enqueues the download.
  Future<void> _confirmDownload(String url, {bool skipPrompt = false}) async {
    bool ok = true;
    if (!skipPrompt) {
      ok =
          await showDialog<bool>(
            context: context,
            builder:
                (_) => AlertDialog(
                  title: Text(
                    context.l10n('browser.dialog.downloadMedia.title'),
                  ),
                  content: Text(
                    url,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text(context.l10n('common.cancel')),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(context.l10n('common.download')),
                    ),
                  ],
                ),
          ) ??
          false;
    }
    if (!ok) return;
    await AppRepo.I.enqueueDownload(url, skipYoutubeHandling: true);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 1),
        content: Text(context.l10n('browser.snack.addedToQueue')),
      ),
    );
  }

  bool _looksLikeDirectDownloadUrl(String url) {
    final normalized = _normalizeHttpUrl(url) ?? url.trim();
    if (normalized.isEmpty) {
      return false;
    }
    final lower = normalized.toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      return false;
    }
    final uri = Uri.tryParse(lower);
    if (uri == null) {
      return false;
    }

    String buildSearchTarget(Uri u) {
      final buffer = StringBuffer();
      buffer.write(u.path.toLowerCase());
      if (u.query.isNotEmpty) {
        buffer.write('?');
        buffer.write(u.query.toLowerCase());
      }
      return buffer.toString();
    }

    final primary = buildSearchTarget(uri);
    if (_kDirectDownloadPattern.hasMatch(primary)) {
      return true;
    }
    try {
      final decoded = Uri.decodeFull(primary);
      if (decoded != primary && _kDirectDownloadPattern.hasMatch(decoded)) {
        return true;
      }
    } catch (_) {
      // ignore decode errors
    }
    return false;
  }

  Future<bool> _offerDownloadForDirectUrl(String url) async {
    if (!mounted) {
      return false;
    }
    final shouldDownload = await showDialog<bool>(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: Text(context.l10n('browser.dialog.detectDownloadable.title')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(context.l10n('browser.dialog.detectDownloadable.message')),
              const SizedBox(height: 12),
              Text(
                url,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.l10n('common.cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.l10n('common.download')),
            ),
          ],
        );
      },
    );
    if (shouldDownload == true) {
      await _confirmDownload(url, skipPrompt: true);
      return true;
    }
    return false;
  }

  Future<String?> _ensureVideoThumb(String url) async {
    if (_thumbCache.containsKey(url)) return _thumbCache[url];
    try {
      final dir = await getTemporaryDirectory();
      final out = '${dir.path}/thumb_${url.hashCode}.jpg';
      // 從 1 秒抽一張影格；m3u8 有時也能成功
      final cmd = "-y -ss 1 -i \"$url\" -frames:v 1 -q:v 3 \"$out\"";
      final session = await FFmpegKit.execute(cmd);
      final rc = await session.getReturnCode();
      if (rc != null && rc.isValueSuccess() && File(out).existsSync()) {
        _thumbCache[url] = out;
        return out;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _previewHit(MediaHit h) async {
    Widget content;
    if (h.type == 'image') {
      content = InteractiveViewer(
        child: Image.network(
          h.url,
          fit: BoxFit.contain,
          errorBuilder:
              (_, __, ___) => const SizedBox(
                height: 160,
                child: Center(child: Icon(Icons.broken_image)),
              ),
        ),
      );
    } else if (h.type == 'video') {
      final thumb = await _ensureVideoThumb(h.url);
      content =
          thumb != null
              ? Image.file(File(thumb), fit: BoxFit.contain)
              : const SizedBox(
                height: 160,
                child: Center(child: Icon(Icons.ondemand_video, size: 48)),
              );
    } else {
      content = const SizedBox(
        height: 120,
        child: Center(child: Icon(Icons.audiotrack, size: 48)),
      );
    }

    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder:
          (_) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Text(
                    h.url,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Flexible(child: Center(child: content)),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      icon: const Icon(Icons.play_arrow),
                      label: Text(context.l10n('common.play')),
                      onPressed: () {
                        Navigator.pop(context);
                        // 使用內建播放器播放（支援 iOS 子母畫面 PiP）。
                        _playMedia(h.url);
                      },
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      icon: const Icon(Icons.download),
                      label: Text(context.l10n('common.download')),
                      onPressed: () {
                        Navigator.pop(context);
                        _confirmDownload(h.url);
                      },
                    ),
                    const SizedBox(width: 12),
                  ],
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
    );
  }

  /// Shows a bottom sheet listing all detected media resources with download buttons.
  Future<void> _openDetectedSheet() async {
    final ok = await PurchaseService().ensurePremium(
      context: context,
      featureName: context.l10n('feature.sniffingResources'),
    );
    if (!ok) {
      return;
    }
    await showModalBottomSheet(
      context: context,
      builder: (_) {
        return SafeArea(
          child: ValueListenableBuilder(
            valueListenable: repo.hits,
            builder: (_, list, __) {
              if (list.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    context.l10n('browser.mediaDetection.emptyState'),
                  ),
                );
              }
              return Column(
                children: [
                  ListTile(
                    title: Text(
                      context.l10n(
                        'browser.mediaDetection.titleWithCount',
                        params: {'count': list.length.toString()},
                      ),
                    ),
                    trailing: TextButton.icon(
                      icon: const Icon(Icons.delete_sweep),
                      label: Text(context.l10n('common.clearAll')),
                      onPressed: () {
                        repo.hits.value = [];
                        Navigator.pop(context);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              duration: const Duration(seconds: 1),
                              content: Text(
                                context.l10n('browser.snack.mediaCleared'),
                              ),
                            ),
                          );
                        }
                      },
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.separated(
                      itemCount: list.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final h = list[i];
                        return ListTile(
                          leading: SizedBox(
                            width: 56,
                            height: 56,
                            child: () {
                              if (h.type == 'image') {
                                return ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: Image.network(
                                    h.url,
                                    fit: BoxFit.cover,
                                    errorBuilder:
                                        (_, __, ___) => const Icon(Icons.image),
                                  ),
                                );
                              } else if (h.type == 'video') {
                                return FutureBuilder<String?>(
                                  future: _ensureVideoThumb(h.url),
                                  builder: (_, snap) {
                                    Widget base;
                                    if (snap.connectionState ==
                                        ConnectionState.waiting) {
                                      base = Container(
                                        decoration: BoxDecoration(
                                          color: Colors.black12,
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                        ),
                                        alignment: Alignment.center,
                                        child: const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        ),
                                      );
                                    } else if (snap.hasData &&
                                        snap.data != null) {
                                      base = ClipRRect(
                                        borderRadius: BorderRadius.circular(6),
                                        child: Image.file(
                                          File(snap.data!),
                                          fit: BoxFit.cover,
                                        ),
                                      );
                                    } else {
                                      base = Container(
                                        decoration: BoxDecoration(
                                          color: Colors.black12,
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                        ),
                                        alignment: Alignment.center,
                                        child: const Icon(Icons.ondemand_video),
                                      );
                                    }
                                    // overlay duration if available
                                    return Stack(
                                      children: [
                                        Positioned.fill(child: base),
                                        if (h.durationSeconds != null)
                                          Positioned(
                                            right: 4,
                                            bottom: 4,
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 4,
                                                    vertical: 2,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: Colors.black.withOpacity(
                                                  0.6,
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                              ),
                                              child: Text(
                                                _fmtDur(h.durationSeconds!),
                                                style: const TextStyle(
                                                  fontSize: 10,
                                                  color: Colors.white,
                                                ),
                                              ),
                                            ),
                                          ),
                                        if (h.durationSeconds == null &&
                                            snap.connectionState ==
                                                ConnectionState.waiting)
                                          Positioned(
                                            right: 4,
                                            bottom: 4,
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 4,
                                                    vertical: 2,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: Colors.black.withOpacity(
                                                  0.4,
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                              ),
                                              child: Text(
                                                context.l10n(
                                                  'browser.media.statusResolving',
                                                ),
                                                style: const TextStyle(
                                                  fontSize: 10,
                                                  color: Colors.white,
                                                ),
                                              ),
                                            ),
                                          ),
                                      ],
                                    );
                                  },
                                );
                              } else {
                                return Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(6),
                                    color: Colors.black12,
                                  ),
                                  alignment: Alignment.center,
                                  child: const Icon(Icons.audiotrack),
                                );
                              }
                            }(),
                          ),
                          title: Text(
                            _prettyFileName(h.url),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: (h.type == 'image'
                                              ? Colors.blueGrey
                                              : (h.type == 'audio'
                                                  ? Colors.teal
                                                  : Colors.deepPurple))
                                          .withOpacity(0.15),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      h.type.isNotEmpty
                                          ? h.type
                                          : (h.contentType.isNotEmpty
                                              ? h.contentType.split('/').first
                                              : ''),
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ),
                                  if (h.contentType.isNotEmpty) ...[
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        h.contentType,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                h.url,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
                              if (h.type != 'image')
                                Text(
                                  h.durationSeconds != null
                                      ? context.l10n(
                                        'browser.media.durationLabel',
                                        params: {
                                          'duration': _fmtDur(
                                            h.durationSeconds!,
                                          ),
                                        },
                                      )
                                      : context.l10n(
                                        'browser.media.durationResolving',
                                      ),
                                  style: const TextStyle(fontSize: 12),
                                ),
                            ],
                          ),
                          onLongPress: () async {
                            await _previewHit(h);
                          },
                          trailing: Wrap(
                            spacing: 4,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.link),
                                tooltip: context.l10n(
                                  'browser.context.copyLink',
                                ),
                                onPressed: () async {
                                  await Clipboard.setData(
                                    ClipboardData(text: h.url),
                                  );
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        duration: const Duration(seconds: 1),
                                        content: Text(
                                          context.l10n(
                                            'browser.snack.copiedLink',
                                          ),
                                        ),
                                      ),
                                    );
                                  }
                                },
                              ),
                              IconButton(
                                icon: const Icon(Icons.download),
                                tooltip: context.l10n('common.download'),
                                onPressed: () {
                                  Navigator.pop(context);
                                  _confirmDownload(h.url);
                                },
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  /// --- Download speed helpers ---

  /// key => snapshot (key can be url or savePath+phase)
  final Map<String, _RateSnapshot> _rateSnaps = {};

  /// Cache the most recent non-null speed so the UI can keep showing a value
  /// while the next sample is still being gathered.
  final Map<String, double> _lastSpeeds = {};
  void _clearSpeedSnapshotsForTask(String savePath) {
    final prefix = '$savePath|';
    _rateSnaps.removeWhere((key, _) => key.startsWith(prefix));
    _lastSpeeds.removeWhere((key, _) => key.startsWith(prefix));
  }

  void _resetAllSpeedTracking({bool clearCachedSpeeds = true}) {
    _rateSnaps.clear();
    if (clearCachedSpeeds) {
      _lastSpeeds.clear();
    }
  }

  String _fmtSpeed(num bps) {
    // bytes per second to human friendly string without specifying colors
    const units = ['B/s', 'KB/s', 'MB/s', 'GB/s', 'TB/s'];
    double v = bps.toDouble();
    int i = 0;
    while (v >= 1024.0 && i < units.length - 1) {
      v /= 1024.0;
      i++;
    }
    return '${v.toStringAsFixed(v >= 100 ? 0 : (v >= 10 ? 1 : 2))} ${units[i]}';
  }

  _RateSnapshot _snapNow(int bytes) => _RateSnapshot(bytes, DateTime.now());

  /// Computes speed in B/s based on previous snapshot.
  /// Returns null if not enough data yet.
  double? _computeSpeed(String key, int bytesNow) {
    final prev = _rateSnaps[key];
    final now = DateTime.now();
    _rateSnaps[key] = _snapNow(bytesNow);
    if (prev == null) return null;
    final elapsedMs = now.difference(prev.ts).inMilliseconds;
    if (elapsedMs <= 0) {
      return null;
    }
    final db = bytesNow - prev.bytes;
    if (db <= 0) {
      if (elapsedMs > 1200) {
        _lastSpeeds.remove(key);
      }
      return null;
    }
    return db / (elapsedMs / 1000.0);
  }

  /// --- end helpers ---

  /// Shows a bottom sheet listing all current download tasks. Each entry
  /// displays its name (or URL), status, timestamp, and progress. This
  /// provides quick visibility into ongoing and completed downloads without
  /// navigating away from the browser tab.
  void _openDownloadsSheet() {
    _suppressLinkLongPress = true;
    _resetAllSpeedTracking(clearCachedSpeeds: false);
    showModalBottomSheet(
      context: context,
      builder: (_) {
        return SafeArea(
          child: AnimatedBuilder(
            animation: AppRepo.I,
            builder: (_, __) {
              final list = repo.downloads.value;

              // 只顯示真實的下載任務（排除匯入/本機項目），完成項目仍會保留在清單中。
              final tasks =
                  list.where(_isDownloadTaskEntry).toList()
                    ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
              // 檢查並補齊缺失縮圖（重啟後快取丟失時自動重建）
              for (final t in tasks) {
                if (AppRepo.I.resolvedTaskType(t) != 'video') continue;
                final p = t.thumbnailPath;
                if (p == null || p.isEmpty || !File(p).existsSync()) {
                  _regenThumbAsync(t); // 背景抽圖，完成會 setState + 持久化
                }
              }

              if (tasks.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(context.l10n('browser.downloadList.empty')),
                );
              }
              return Column(
                children: [
                  ListTile(
                    title: Text(
                      context.l10n(
                        'browser.downloadList.titleWithCount',
                        params: {'count': tasks.length.toString()},
                      ),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.delete_sweep),
                          tooltip: context.l10n(
                            'browser.downloadList.clearTooltip',
                          ),
                          onPressed: () async {
                            final cleared =
                                await AppRepo.I.retainOnlyCompletedDownloads();
                            if (!mounted) return;
                            Navigator.pop(context);
                            if (!cleared) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  duration: const Duration(seconds: 1),
                                  content: Text(
                                    context.l10n(
                                      'browser.snack.noTasksToClear',
                                    ),
                                  ),
                                ),
                              );
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  duration: const Duration(seconds: 1),
                                  content: Text(
                                    context.l10n('browser.snack.tasksCleared'),
                                  ),
                                ),
                              );
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.separated(
                      itemCount: tasks.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final t = tasks[i];
                        return _buildDownloadTile(t);
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    ).whenComplete(() {
      _suppressLinkLongPress = false;
      if (kDebugMode) {
        debugPrint(
          '[Debug][YouTube] Long press interactions restored after download options sheet closed.',
        );
      }
    });
  }

  /// Build a ListTile for a given download task. This encapsulates all the logic
  /// for displaying progress, size, segment counts and conversion status for
  /// both HLS (m3u8) and direct file downloads. It ensures that the UI
  /// reflects real-time updates via [_currentReceived] and by observing
  /// AppRepo notifications.
  String _folderNameForId(String? folderId) {
    if (folderId == null) return _defaultFolderName;
    for (final folder in repo.mediaFolders.value) {
      if (folder.id == folderId) {
        return folder.name;
      }
    }
    return _defaultFolderName;
  }

  Future<String?> _pickFolderForTask({
    required BuildContext context,
    required String? currentId,
  }) async {
    final folders = repo.mediaFolders.value;
    final counts = <String?, int>{};
    for (final task in repo.downloads.value) {
      final key = task.folderId;
      counts[key] = (counts[key] ?? 0) + 1;
    }
    counts.putIfAbsent(null, () => 0);
    String formatName(String? id, String name) => '$name（${counts[id] ?? 0}）';
    final ids = <String?>[null, ...folders.map((f) => f.id)];
    final names = <String>[
      formatName(null, _defaultFolderName),
      ...folders.map((f) => formatName(f.id, f.name)),
    ];
    final currentKey = currentId ?? _kFolderSheetDefaultKey;

    final result = await showModalBottomSheet<String>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: Text(context.l10n('browser.dialog.selectFolder')),
                ),
                for (var i = 0; i < ids.length; i++)
                  ListTile(
                    leading: const Icon(Icons.folder),
                    title: Text(names[i]),
                    trailing:
                        (ids[i] ?? _kFolderSheetDefaultKey) == currentKey
                            ? const Icon(Icons.check, color: Colors.green)
                            : null,
                    onTap: () {
                      final key = ids[i] ?? _kFolderSheetDefaultKey;
                      Navigator.of(context).pop(key);
                    },
                  ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        );
      },
    );
    return result;
  }

  Future<void> _moveTaskToFolder(DownloadTask task) async {
    final key = await _pickFolderForTask(
      context: context,
      currentId: task.folderId,
    );
    if (key == null) return;
    final String? folderId = key == _kFolderSheetDefaultKey ? null : key;
    repo.setTasksFolder([task], folderId);
    if (!mounted) return;
    final targetName = _folderNameForId(folderId);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 1),
        content: Text(
          context.l10n(
            'browser.snack.movedToFolder',
            params: {'folder': targetName},
          ),
        ),
      ),
    );
  }

  Widget _buildDownloadTile(DownloadTask t) {
    // Determine if this task is an HLS playlist. HLS tasks use the segment
    // count to track progress rather than bytes until conversion begins.
    final bool isHls = t.kind == 'hls';
    // A HLS task is considered converting when all segments have been
    // downloaded but the state is still downloading. During this phase the
    // output file grows in size but total segment count does not change.
    final bool isConverting =
        isHls &&
        t.state == 'downloading' &&
        ((t.total != null && t.received >= t.total!) ||
            t.progressUnit == 'hls-converting');
    // HLS tasks actively downloading segments have received fewer segments
    // than the total and are still marked as downloading.
    final bool isDownloadingSegments =
        isHls &&
        t.state == 'downloading' &&
        (t.total != null && t.received < t.total!);
    final repo = AppRepo.I;
    final resolvedType = repo.resolvedTaskType(t);
    if (t.state != 'downloading' || t.paused) {
      _clearSpeedSnapshotsForTask(t.savePath);
    }
    final activeHlsPath = repo.activeHlsOutputFor(t) ?? t.savePath;
    final int? activeHlsBytes =
        isHls
            ? (_fileLengthIfExists(activeHlsPath) ??
                _fileLengthIfExists(t.savePath))
            : null;

    // --- Speed calculation setup ---

    String speedKeyPhase = 'dl';
    int? speedBytesNow;

    // Compute progress percentage. For HLS segment downloads, this is the
    // fraction of segments downloaded. For file downloads, it is the
    // fraction of bytes downloaded. When progress cannot be determined, it
    // remains null and the UI will show an indeterminate progress bar.
    double? progressPercent;
    if (isDownloadingSegments) {
      final int totalSegs = t.total ?? 0;
      if (totalSegs > 0) {
        progressPercent = t.received / totalSegs;
      }
    } else if (isHls &&
        t.progressUnit == 'time-ms' &&
        t.total != null &&
        t.total! > 0) {
      progressPercent = t.received / (t.total!.toDouble());
    } else if (!isHls &&
        t.state == 'downloading' &&
        t.total != null &&
        t.total! > 0) {
      progressPercent = t.received / (t.total!.toDouble());
    }

    // Decide which byte counter to use for speed:
    // - 非 HLS：使用 t.received（bytes）
    // - HLS：使用目前輸出檔案大小（無論片段下載或轉檔階段）
    if (!isHls && t.state == 'downloading') {
      speedBytesNow = t.received;
      speedKeyPhase = 'dl';
    } else if (isHls && t.state == 'downloading' && activeHlsBytes != null) {
      speedBytesNow = activeHlsBytes;
      speedKeyPhase = isConverting ? 'conv' : 'hls';
    }

    List<Widget> buildSubtitleWidgets() {
      // Build the subtitle lines dynamically. Use a list to collect lines and
      // later spread them into the Column.
      final List<Widget> subtitleWidgets = [];
      bool addedSize = false;

      // First line: the URL (truncated)
      subtitleWidgets.add(
        Text(
          t.url,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
      );
      // Second line: status (show '轉換中' during conversion)
      final String statusText =
          isConverting
              ? context.l10n('browser.download.status.converting')
              : t.state;
      subtitleWidgets.add(
        Text(
          context.l10n(
            'browser.download.statusLabel',
            params: {'status': statusText},
          ),
          style: const TextStyle(fontSize: 12),
        ),
      );
      // For non-HLS tasks, display the timestamp when the download was added. HLS
      // tasks omit this to reduce clutter.
      if (!isHls) {
        subtitleWidgets.add(
          Text(
            context.l10n(
              'browser.download.timeLabel',
              params: {
                'time': t.timestamp.toLocal().toString().split('.').first,
              },
            ),
            style: const TextStyle(fontSize: 12),
          ),
        );
      }
      // If downloading HLS segments, show the segment count and progress.
      if (isDownloadingSegments) {
        subtitleWidgets.add(
          Text(
            context.l10n(
              'browser.download.segmentLabel',
              params: {'progress': '${t.received}/${t.total}'},
            ),
            style: const TextStyle(fontSize: 12),
          ),
        );
        final int totalSegs = t.total ?? 0;
        if (totalSegs > 0) {
          final double pct = t.received / totalSegs * 100.0;
          subtitleWidgets.add(
            Text(
              context.l10n(
                'browser.download.progressLabel',
                params: {
                  'progress':
                      '${t.received}/${t.total} (${pct.toStringAsFixed(1)}%)',
                },
              ),
              style: const TextStyle(fontSize: 12),
            ),
          );
        }
        // 以「片段/秒」顯示近似速度（HLS 片段階段無可靠 byte 計數）
        final segKey = '${t.savePath}|seg';
        final segRate = _computeSpeed(
          segKey,
          t.received,
        ); // delta segments per second
        if (segRate != null) {
          subtitleWidgets.add(
            Text(
              context.l10n(
                'browser.download.speedLabel',
                params: {
                  'speed':
                      '${segRate.toStringAsFixed(2)} ${context.l10n('browser.download.segmentsPerSecond')}',
                },
              ),
              style: const TextStyle(fontSize: 12),
            ),
          );
        } else {
          _rateSnaps[segKey] = _snapNow(t.received);
          subtitleWidgets.add(
            Text(
              context.l10n('browser.download.speedMeasuring'),
              style: const TextStyle(fontSize: 12),
            ),
          );
        }
      } else if (isHls &&
          t.progressUnit == 'time-ms' &&
          t.total != null &&
          t.total! > 0) {
        final cur = Duration(milliseconds: t.received);
        final tot = Duration(milliseconds: t.total!);
        final percent = progressPercent ?? 0.0;
        final percentText = (percent * 100).toStringAsFixed(1);
        String progressText;
        final bytes = activeHlsBytes;
        if (bytes != null && bytes > 0) {
          int? estimatedTotalBytes;
          if (percent >= 0.01) {
            estimatedTotalBytes = (bytes / percent).round();
          }
          final timePart =
              '${_fmtDur(cur.inSeconds.toDouble())}/${_fmtDur(tot.inSeconds.toDouble())}';
          final sizePart =
              (estimatedTotalBytes != null && estimatedTotalBytes > 0)
                  ? '${_fmtSize(bytes)} / ${_fmtSize(estimatedTotalBytes)} ($percentText%)'
                  : '${_fmtSize(bytes)} ($percentText%)';
          progressText = '$sizePart • $timePart';
          addedSize = true;
        } else {
          progressText =
              '${_fmtDur(cur.inSeconds.toDouble())}/${_fmtDur(tot.inSeconds.toDouble())} ($percentText%)';
        }
        subtitleWidgets.add(
          Text(
            context.l10n(
              'browser.download.progressLabel',
              params: {'progress': progressText},
            ),
            style: const TextStyle(fontSize: 12),
          ),
        );
        if (bytes == null) {
          try {
            final f = File(t.savePath);
            if (f.existsSync() && !addedSize) {
              subtitleWidgets.add(
                Text(
                  context.l10n(
                    'browser.download.sizeLabel',
                    params: {'size': _fmtSize(f.lengthSync())},
                  ),
                  style: const TextStyle(fontSize: 12),
                ),
              );
              addedSize = true;
            }
          } catch (_) {}
        }
      }
      // During conversion of an HLS task, show the current output file size to
      // provide some sense of progress. Since FFmpeg does not expose a
      // percentage, we rely on the file growing over time.
      if (isConverting) {
        try {
          final f = File(t.savePath);
          if (f.existsSync() && !addedSize) {
            subtitleWidgets.add(
              Text(
                context.l10n(
                  'browser.download.sizeLabel',
                  params: {'size': _fmtSize(f.lengthSync())},
                ),
                style: const TextStyle(fontSize: 12),
              ),
            );
            addedSize = true;
          } else if (!f.existsSync()) {
            subtitleWidgets.add(
              Text(
                context.l10n('browser.download.sizeConverting'),
                style: const TextStyle(fontSize: 12),
              ),
            );
          }
        } catch (_) {
          subtitleWidgets.add(
            Text(
              context.l10n('browser.download.sizeConverting'),
              style: const TextStyle(fontSize: 12),
            ),
          );
        }
      }
      // For non-HLS downloads: show the downloaded size while downloading and the
      // final size when finished or errored.
      if (!isHls) {
        if (t.state == 'downloading') {
          final hasTotal = t.total != null && t.total! > 0;
          final sizeValue =
              hasTotal
                  ? '${_fmtSize(t.received)} / ${_fmtSize(t.total!)}'
                  : _fmtSize(t.received);
          subtitleWidgets.add(
            Text(
              context.l10n(
                'browser.download.sizeLabel',
                params: {'size': sizeValue},
              ),
              style: const TextStyle(fontSize: 12),
            ),
          );
          if (progressPercent != null) {
            subtitleWidgets.add(
              Text(
                context.l10n(
                  'browser.download.progressLabel',
                  params: {
                    'progress':
                        '${(progressPercent * 100).toStringAsFixed(1)}%',
                  },
                ),
                style: const TextStyle(fontSize: 12),
              ),
            );
          }
        } else if (t.state == 'done' || t.state == 'error') {
          try {
            final f = File(t.savePath);
            if (f.existsSync() && !addedSize) {
              subtitleWidgets.add(
                Text(
                  context.l10n(
                    'browser.download.sizeLabel',
                    params: {'size': _fmtSize(f.lengthSync())},
                  ),
                  style: const TextStyle(fontSize: 12),
                ),
              );
              addedSize = true;
            }
          } catch (_) {}
        }
      } else if (isHls && t.state == 'done') {
        // HLS tasks that have completed conversion: show final size.
        try {
          final f = File(t.savePath);
          if (f.existsSync() && !addedSize) {
            subtitleWidgets.add(
              Text(
                context.l10n(
                  'browser.download.sizeLabel',
                  params: {'size': _fmtSize(f.lengthSync())},
                ),
                style: const TextStyle(fontSize: 12),
              ),
            );
            addedSize = true;
          }
        } catch (_) {}
      }
      // 任何 downloading 狀態下的通用「目前檔案大小」顯示（若前面尚未加入大小）
      if (t.state == 'downloading' && !addedSize) {
        final bytes =
            isHls ? activeHlsBytes : _fileLengthIfExists(activeHlsPath);
        if (bytes != null) {
          subtitleWidgets.add(
            Text(
              context.l10n(
                'browser.download.sizeLabel',
                params: {'size': _fmtSize(bytes)},
              ),
              style: const TextStyle(fontSize: 12),
            ),
          );
          addedSize = true;
        }
      }
      // 顯示即時下載/轉換速度
      if (speedBytesNow != null) {
        final key = '${t.savePath}|$speedKeyPhase';
        final sp = _computeSpeed(key, speedBytesNow!);
        if (sp != null) {
          _lastSpeeds[key] = sp;
          subtitleWidgets.add(
            Text(
              context.l10n(
                'browser.download.speedLabel',
                params: {'speed': _fmtSpeed(sp)},
              ),
              style: const TextStyle(fontSize: 12),
            ),
          );
        } else {
          // 首次建立快照時先不顯示數值（避免顯示 0）
          _rateSnaps.putIfAbsent(key, () => _snapNow(speedBytesNow!));
          final cached = _lastSpeeds[key];
          subtitleWidgets.add(
            Text(
              cached != null
                  ? context.l10n(
                    'browser.download.speedLabel',
                    params: {'speed': _fmtSpeed(cached)},
                  )
                  : context.l10n('browser.download.speedMeasuring'),
              style: const TextStyle(fontSize: 12),
            ),
          );
        }
      }

      // Append duration information when available. If unavailable and the
      // media is audio/video, show a placeholder.
      if (t.duration != null) {
        subtitleWidgets.add(
          Text(
            context.l10n(
              'browser.media.durationLabel',
              params: {'duration': _fmtDur(t.duration!.inSeconds.toDouble())},
            ),
            style: const TextStyle(fontSize: 12),
          ),
        );
      } else if (resolvedType == 'video' || resolvedType == 'audio') {
        subtitleWidgets.add(
          Text(
            context.l10n('browser.media.durationResolving'),
            style: const TextStyle(fontSize: 12),
          ),
        );
      }
      return subtitleWidgets;
    }

    // 對於 HLS 轉換中或下載中，使用小型 ticker 讓速度/大小文字即時刷新
    final needsTicker = isConverting || t.state == 'downloading';

    Widget buildTile() {
      final subtitleWidgets = buildSubtitleWidgets();
      // Build and return the ListTile. Action buttons for pause/resume/delete
      // remain unchanged. Progress indicators adapt based on the computed
      // progressPercent.
      return ListTile(
        isThreeLine: true,
        dense: false,
        minVerticalPadding: 8,
        leading: SizedBox(width: 64, height: 64, child: _buildThumb(t)),
        title: Text(
          t.name ?? path.basename(t.savePath),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ...subtitleWidgets,
            if (t.state == 'downloading')
              (progressPercent == null)
                  ? const LinearProgressIndicator()
                  : LinearProgressIndicator(value: progressPercent),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (t.state == 'downloading' && !t.paused && !isConverting)
              IconButton(
                icon: const Icon(Icons.pause),
                tooltip: context.l10n('common.pause'),
                onPressed: () {
                  AppRepo.I.pauseTask(t);
                },
              ),
            if (t.state == 'paused' || t.paused)
              IconButton(
                icon: const Icon(Icons.play_arrow),
                tooltip: context.l10n('common.resume'),
                onPressed: () {
                  AppRepo.I.resumeTask(t);
                },
              ),
            IconButton(
              icon: const Icon(Icons.folder_open),
              tooltip: context.l10n('browser.download.moveToFolder'),
              onPressed: () {
                _moveTaskToFolder(t);
              },
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: context.l10n('common.delete'),
              onPressed: () async {
                final state = t.state.toLowerCase();
                final isCompleted = state == 'done';
                final shouldDeleteFile = !isCompleted;
                if (!isCompleted && state == 'downloading') {
                  await AppRepo.I.pauseTask(t);
                }
                await AppRepo.I.removeTasks([t], deleteFiles: shouldDeleteFile);
                await AppRepo.I.rescanDownloadsFolder();
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    duration: const Duration(seconds: 1),
                    content: Text(
                      context.l10n(
                        shouldDeleteFile
                            ? 'browser.snack.downloadRemovedDeletedFile'
                            : 'browser.snack.downloadRemovedKeepFile',
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
        onTap: () async {
          if ((t.state).toString().toLowerCase() != 'done') return;
          String? filePath = t.savePath.isNotEmpty ? t.savePath : null;
          if (filePath != null && !File(filePath).existsSync()) {
            filePath = null;
          }
          if (resolvedType == 'video' || resolvedType == 'audio') {
            final target = filePath ?? t.url;
            _playMedia(target);
            return;
          }
          if (resolvedType == 'image') {
            if (filePath != null) {
              final ok = await PurchaseService().ensurePremium(
                context: context,
                featureName: context.l10n('feature.export'),
              );
              if (!ok) return;
              final imagePath = filePath;
              if (!mounted) return;
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder:
                      (_) => ImagePreviewPage(
                        filePath: imagePath,
                        title: t.name ?? path.basename(imagePath),
                      ),
                ),
              );
            } else if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  duration: const Duration(seconds: 1),
                  content: Text(context.l10n('browser.snack.fileMissing')),
                ),
              );
            }
            return;
          }
          if (filePath != null) {
            try {
              await AppRepo.I.sharePaths([filePath]);
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    duration: const Duration(seconds: 1),
                    content: Text(
                      context.l10n(
                        'browser.snack.exportFailed',
                        params: {'error': '$e'},
                      ),
                    ),
                  ),
                );
              }
            }
          } else if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                duration: const Duration(seconds: 1),
                content: Text(context.l10n('browser.snack.fileMissing')),
              ),
            );
          }
        },
      );
    }

    if (!needsTicker) {
      return buildTile();
    }
    return StreamBuilder<int>(
      stream: Stream.periodic(const Duration(milliseconds: 800), (i) => i),
      builder: (_, __) => buildTile(),
    );
  }
}

class FavoritesPage extends StatelessWidget {
  const FavoritesPage({
    super.key,
    required this.onOpen,
    required this.prettyName,
  });

  final void Function(String url) onOpen;
  final String Function(String url) prettyName;

  @override
  Widget build(BuildContext context) {
    final repo = AppRepo.I;
    return ValueListenableBuilder<List<String>>(
      valueListenable: repo.favorites,
      builder: (context, favs, _) {
        return Scaffold(
          appBar: AppBar(
            title: Text(
              context.l10n(
                'browser.favorites.titleWithCount',
                params: {'count': favs.length.toString()},
              ),
            ),
            actions: [
              if (favs.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.delete_sweep),
                  tooltip: context.l10n('common.clearAll'),
                  onPressed: () => repo.clearFavorites(),
                ),
            ],
          ),
          body: SafeArea(
            child:
                favs.isEmpty
                    ? Center(
                      child: Text(context.l10n('browser.favorites.empty')),
                    )
                    : ListView.separated(
                      itemCount: favs.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final url = favs[index];
                        final display = prettyName(url);
                        return ListTile(
                          leading: const Icon(Icons.bookmark_outline),
                          title: Text(
                            display,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            url,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete),
                            tooltip: context.l10n(
                              'browser.favorites.removeTooltip',
                            ),
                            onPressed: () => repo.removeFavoriteUrl(url),
                          ),
                          onTap: () {
                            Navigator.of(context).pop();
                            onOpen(url);
                          },
                        );
                      },
                    ),
          ),
        );
      },
    );
  }
}

/// A dedicated page that shows the browsing history in a scrollable list with
/// a search field and friendly time grouping. Each entry displays its title
/// (or URL if no title), timestamp and URL. Tapping an entry invokes [onOpen]
/// to load the URL in the caller's context. Individual entries can be removed
/// and the entire list can be cleared from the app bar.
class HistoryPage extends StatefulWidget {
  final void Function(String url) onOpen;
  const HistoryPage({super.key, required this.onOpen});
  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage>
    with LanguageAwareState<HistoryPage> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    setState(() {
      _query = _searchController.text.trim();
    });
  }

  @override
  Widget build(BuildContext context) {
    final repo = AppRepo.I;
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n('browser.history.title')),
        actions: [
          ValueListenableBuilder<List<HistoryEntry>>(
            valueListenable: repo.history,
            builder: (context, hist, _) {
              if (hist.isEmpty) return const SizedBox.shrink();
              return IconButton(
                icon: const Icon(Icons.delete_sweep),
                tooltip: context.l10n('common.clearAll'),
                onPressed: repo.clearHistory,
              );
            },
          ),
        ],
      ),
      body: ValueListenableBuilder<List<HistoryEntry>>(
        valueListenable: repo.history,
        builder: (context, hist, _) {
          final items = [...hist]
            ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
          final filtered = items.where(_matchesQuery).toList();
          final hasHistory = items.isNotEmpty;

          return Column(
            children: [
              _buildSearchField(context),
              Expanded(
                child:
                    !hasHistory
                        ? _HistoryEmptyState(
                          message: context.l10n('browser.history.empty'),
                        )
                        : filtered.isEmpty
                        ? _HistoryEmptyState(
                          message: context.l10n('browser.history.noResults'),
                        )
                        : _buildHistoryList(filtered, repo),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSearchField(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: TextField(
        controller: _searchController,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search),
          suffixIcon:
              _query.isEmpty
                  ? null
                  : IconButton(
                    tooltip: context.l10n('common.clear'),
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      _searchController.clear();
                      FocusScope.of(context).unfocus();
                    },
                  ),
          hintText: context.l10n('browser.history.searchHint'),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(32)),
          isDense: true,
        ),
      ),
    );
  }

  Widget _buildHistoryList(List<HistoryEntry> entries, AppRepo repo) {
    final now = DateTime.now();
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: entries.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final entry = entries[index];
        final entryDate = entry.timestamp.toLocal();
        final showHeader =
            index == 0 ||
            !_isSameDay(entryDate, entries[index - 1].timestamp.toLocal());
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showHeader) _buildSectionHeader(context, entryDate, now),
            _buildHistoryTile(context, entry, repo),
          ],
        );
      },
    );
  }

  Widget _buildSectionHeader(
    BuildContext context,
    DateTime date,
    DateTime now,
  ) {
    final theme = Theme.of(context);
    final relative = _relativeLabel(date, now);
    final calendar = _formatCalendarLabel(date);

    Widget buildTag(Color background, Color foreground, String text) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          text,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: foreground,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          buildTag(
            theme.colorScheme.primaryContainer,
            theme.colorScheme.onPrimaryContainer,
            relative,
          ),
          buildTag(
            theme.colorScheme.surfaceVariant,
            theme.colorScheme.onSurfaceVariant,
            calendar,
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryTile(
    BuildContext context,
    HistoryEntry entry,
    AppRepo repo,
  ) {
    final theme = Theme.of(context);
    final localTs = entry.timestamp.toLocal();
    final title = entry.title.isNotEmpty ? entry.title : entry.url;
    String hostKey = '';
    try {
      final uri = Uri.parse(entry.url);
      hostKey = uri.host.toLowerCase();
    } catch (_) {
      hostKey = '';
    }
    if (hostKey.isNotEmpty) {
      unawaited(repo.ensureFaviconForUrl(entry.url));
    }
    Widget defaultAvatar() {
      return CircleAvatar(
        radius: 18,
        backgroundColor: theme.colorScheme.primaryContainer,
        child: Icon(Icons.public, color: theme.colorScheme.onPrimaryContainer),
      );
    }

    Widget leadingIcon;
    if (hostKey.isEmpty) {
      leadingIcon = defaultAvatar();
    } else {
      leadingIcon = ValueListenableBuilder<Map<String, String?>>(
        valueListenable: repo.faviconCache,
        builder: (context, cache, _) {
          final path = cache[hostKey];
          if (path != null && path.isNotEmpty) {
            final file = File(path);
            if (file.existsSync()) {
              return SizedBox(
                width: 36,
                height: 36,
                child: ClipOval(
                  child: Image.file(
                    file,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => defaultAvatar(),
                  ),
                ),
              );
            }
          }
          return defaultAvatar();
        },
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        color: theme.colorScheme.surfaceVariant,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            FocusScope.of(context).unfocus();
            Navigator.of(context).pop();
            widget.onOpen(entry.url);
          },
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    leadingIcon,
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            entry.url,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: context.l10n('common.delete'),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => repo.removeHistoryEntry(entry),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  context.l10n(
                    'browser.history.browsedAt',
                    params: {'time': _formatTime(localTs)},
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool _matchesQuery(HistoryEntry entry) {
    if (_query.isEmpty) return true;
    final needle = _query.toLowerCase();
    return entry.title.toLowerCase().contains(needle) ||
        entry.url.toLowerCase().contains(needle);
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  String _relativeLabel(DateTime date, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final entryDay = DateTime(date.year, date.month, date.day);
    final diff = today.difference(entryDay).inDays;
    if (diff <= 0) {
      return context.l10n('browser.history.relative.today');
    }
    if (diff == 1) {
      return context.l10n('browser.history.relative.yesterday');
    }
    if (diff == 2) {
      return context.l10n('browser.history.relative.twoDaysAgo');
    }
    return context.l10n(
      'browser.history.relative.daysAgo',
      params: {'days': diff.toString()},
    );
  }

  String _formatCalendarLabel(DateTime date) {
    final weekdayKeys = [
      'browser.history.weekday.mon',
      'browser.history.weekday.tue',
      'browser.history.weekday.wed',
      'browser.history.weekday.thu',
      'browser.history.weekday.fri',
      'browser.history.weekday.sat',
      'browser.history.weekday.sun',
    ];
    final weekday = context.l10n(
      weekdayKeys[(date.weekday - 1) % weekdayKeys.length],
    );
    return '${date.year}-${_twoDigits(date.month)}-${_twoDigits(date.day)} $weekday';
  }

  String _formatTime(DateTime date) {
    return '${_twoDigits(date.hour)}:${_twoDigits(date.minute)}';
  }

  String _twoDigits(int value) => value.toString().padLeft(2, '0');
}

class _HistoryEmptyState extends StatelessWidget {
  final String message;
  const _HistoryEmptyState({required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Text(
        message,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Simple data class describing a tab for the tab manager. Only contains a
/// title to display. The actual URL is managed by [BrowserPage].
class _TabInfo {
  final String title;
  final Uint8List? thumbnail; // 新增：縮圖
  _TabInfo({required this.title, this.thumbnail});
}

/// A page that displays all open browser tabs in a grid. Users can tap a
/// tab to switch to it, close tabs via the close icon, or create a new
/// blank tab. When done, the page is popped and the browser returns to
/// the previous view. This page does not directly modify the browser
/// tabs; instead it invokes the callbacks provided by [BrowserPage] to
/// update the tab list and current index.
class _TabManagerPage extends StatefulWidget {
  final List<_TabInfo> tabs;
  final VoidCallback onAdd;
  final void Function(int index) onSelect;
  final void Function(int index) onClose;
  const _TabManagerPage({
    super.key,
    required this.tabs,
    required this.onAdd,
    required this.onSelect,
    required this.onClose,
  });

  @override
  State<_TabManagerPage> createState() => _TabManagerPageState();
}

class _TabManagerPageState extends State<_TabManagerPage>
    with LanguageAwareState<_TabManagerPage> {
  late List<_TabInfo> _localTabs;
  bool _selectMode = false; // 是否進入選擇模式
  final Set<int> _selected = {}; // 已選索引集合
  @override
  void initState() {
    super.initState();
    _localTabs = List<_TabInfo>.from(widget.tabs);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          context.l10n(
            'browser.tabs.titleWithCount',
            params: {'count': _localTabs.length.toString()},
          ),
        ),
        actions: [
          // 切換選擇模式
          IconButton(
            tooltip:
                _selectMode
                    ? context.l10n('browser.tabs.exitSelection')
                    : context.l10n('browser.tabs.selectTabs'),
            icon: Icon(_selectMode ? Icons.close : Icons.checklist),
            onPressed: () {
              setState(() {
                _selectMode = !_selectMode;
                _selected.clear();
              });
            },
          ),
          if (_selectMode) ...[
            // 全選/取消全選
            IconButton(
              tooltip:
                  _selected.length == _localTabs.length && _localTabs.isNotEmpty
                      ? context.l10n('common.deselectAll')
                      : context.l10n('common.selectAll'),
              icon: const Icon(Icons.select_all),
              onPressed: () {
                setState(() {
                  if (_selected.length == _localTabs.length &&
                      _localTabs.isNotEmpty) {
                    _selected.clear();
                  } else {
                    _selected
                      ..clear()
                      ..addAll(List<int>.generate(_localTabs.length, (i) => i));
                  }
                });
              },
            ),
            // 刪除已選
            IconButton(
              tooltip:
                  _selected.isEmpty
                      ? context.l10n('common.delete')
                      : context.l10n(
                        'browser.tabs.deleteWithCount',
                        params: {'count': _selected.length.toString()},
                      ),
              icon: const Icon(Icons.delete_sweep),
              onPressed:
                  _selected.isEmpty
                      ? null
                      : () {
                        final toRemove =
                            _selected.toList()
                              ..sort((a, b) => b.compareTo(a)); // 由大到小避免位移
                        setState(() {
                          for (final idx in toRemove) {
                            if (idx >= 0 && idx < _localTabs.length) {
                              _localTabs.removeAt(idx);
                              widget.onClose(idx);
                            }
                          }
                          _selected.clear();
                        });
                      },
            ),
          ],
          // 右上的新增分頁（保留）
          IconButton(
            tooltip: context.l10n('browser.tabManager.addTab'),
            iconSize: 30,
            icon: const Icon(Icons.add_box_outlined),
            onPressed: () {
              // Create a real tab in the BrowserPage first
              widget.onAdd();
              // Determine new index (= current local list length before append)
              final int newIndex = _localTabs.length;
              setState(() {
                _localTabs.add(
                  _TabInfo(title: context.l10n('browser.tab.newTabTitle')),
                );
              });
              // Switch to the newly created tab and close this manager
              widget.onSelect(newIndex);
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          _localTabs.isEmpty
              ? Center(
                child: ElevatedButton(
                  onPressed: () {
                    widget.onAdd();
                    Navigator.of(context).pop();
                  },
                  child: Text(context.l10n('browser.tabManager.addTab')),
                ),
              )
              : GridView.builder(
                padding: const EdgeInsets.all(12),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: 0.8,
                ),
                itemCount: _localTabs.length + 1,
                itemBuilder: (context, index) {
                  if (index == _localTabs.length) {
                    return GestureDetector(
                      onTap: () {
                        widget.onAdd();
                        final int newIndex = _localTabs.length;
                        setState(() {
                          _localTabs.add(
                            _TabInfo(
                              title: context.l10n('browser.tab.newTabTitle'),
                            ),
                          );
                        });
                        widget.onSelect(newIndex);
                        Navigator.of(context).pop();
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surfaceVariant,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.add, size: 32),
                              const SizedBox(height: 8),
                              Text(context.l10n('browser.tabManager.addTab')),
                            ],
                          ),
                        ),
                      ),
                    );
                  }
                  final tab = _localTabs[index];
                  return GestureDetector(
                    onTap: () {
                      if (_selectMode) {
                        setState(() {
                          if (_selected.contains(index)) {
                            _selected.remove(index);
                          } else {
                            _selected.add(index);
                          }
                        });
                      } else {
                        widget.onSelect(index);
                        Navigator.of(context).pop();
                      }
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceVariant,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            // Preview image (if any)
                            if (tab.thumbnail != null)
                              Image.memory(tab.thumbnail!, fit: BoxFit.cover)
                            else
                              Container(
                                color:
                                    Theme.of(
                                      context,
                                    ).colorScheme.surfaceVariant,
                              ),
                            // Title overlay at bottom
                            Positioned(
                              left: 8,
                              right: 8,
                              bottom: 8,
                              child: Text(
                                tab.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  shadows: [
                                    Shadow(blurRadius: 3, color: Colors.black),
                                  ],
                                ),
                              ),
                            ),
                            // Close button at top‑right
                            Positioned(
                              top: 4,
                              right: 4,
                              child: Container(
                                decoration: const BoxDecoration(
                                  color: Colors.black54,
                                  shape: BoxShape.circle,
                                ),
                                child: IconButton(
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                    minWidth: 10,
                                    minHeight: 10,
                                  ),
                                  icon: const Icon(
                                    Icons.close,
                                    size: 20,
                                    color: Colors.white,
                                  ),
                                  onPressed: () {
                                    setState(() {
                                      _localTabs.removeAt(index);
                                    });
                                    widget.onClose(index);
                                  },
                                ),
                              ),
                            ),
                            if (_selectMode)
                              Positioned(
                                top: 6,
                                left: 6,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.black45,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Checkbox(
                                    value: _selected.contains(index),
                                    onChanged: (v) {
                                      setState(() {
                                        if (v == true) {
                                          _selected.add(index);
                                        } else {
                                          _selected.remove(index);
                                        }
                                      });
                                    },
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
          if (_selectMode)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  color: Theme.of(context).colorScheme.surface,
                  child: Row(
                    children: [
                      Text(
                        context.l10n(
                          'browser.tabs.selectedCount',
                          params: {'count': _selected.length.toString()},
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            if (_selected.length == _localTabs.length &&
                                _localTabs.isNotEmpty) {
                              _selected.clear();
                            } else {
                              _selected
                                ..clear()
                                ..addAll(
                                  List<int>.generate(
                                    _localTabs.length,
                                    (i) => i,
                                  ),
                                );
                            }
                          });
                        },
                        child: Text(
                          _selected.length == _localTabs.length &&
                                  _localTabs.isNotEmpty
                              ? context.l10n('common.deselectAll')
                              : context.l10n('common.selectAll'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        icon: const Icon(Icons.delete),
                        label: Text(context.l10n('common.delete')),
                        onPressed:
                            _selected.isEmpty
                                ? null
                                : () {
                                  final toRemove =
                                      _selected.toList()
                                        ..sort((a, b) => b.compareTo(a));
                                  setState(() {
                                    for (final idx in toRemove) {
                                      if (idx >= 0 && idx < _localTabs.length) {
                                        _localTabs.removeAt(idx);
                                        widget.onClose(idx);
                                      }
                                    }
                                    _selected.clear();
                                  });
                                },
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

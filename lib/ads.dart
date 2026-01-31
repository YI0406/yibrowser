import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart' show kReleaseMode, debugPrint;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:app_tracking_transparency/app_tracking_transparency.dart';

class AdService with WidgetsBindingObserver {
  AdService._();
  static final AdService instance = AdService._();

  /// Your AdMob **App ID** (iOS)
  /// Note: The App ID is configured in Info.plist; we keep it here for reference.
  static const String admobAppId = 'ca-app-pub-1219775982243471~1725741402';

  /// 插頁廣告單元 IDs
  static const String _prodInterstitialId =
      'ca-app-pub-1219775982243471/4619653589'; // 發布用（正式）
  static const String _testInterstitialId =
      'ca-app-pub-3940256099942544/4411468910'; // Google 官方測試（iOS）
  /// 橫幅廣告單元 IDs
  static const String _prodBannerId = 'ca-app-pub-1219775982243471/8917835715';
  static const String _testBannerId = 'ca-app-pub-3940256099942544/2934735716';

  /// Pick the right Unit ID based on build mode
  static String get _currentInterstitialId =>
      kReleaseMode ? _prodInterstitialId : _testInterstitialId;

  static bool get isRelease => kReleaseMode;

  InterstitialAd? _interstitial;
  BannerAd? _bannerAd;
  bool _adsDisabled = false; // VIP: true -> 關閉廣告
  DateTime? _lastShowTime;
  bool _hasShownThisResume = false;
  static const Duration _minInterval = Duration(minutes: 3); // 防止過於頻繁
  static const Duration _launchCooldown = Duration(minutes: 1);
  DateTime? _appLaunchTime;
  bool _iapBusy = false;

  final ValueNotifier<BannerAd?> bannerAdNotifier = ValueNotifier<BannerAd?>(
    null,
  );

  bool _observerAttached = false;
  void _attachObserver() {
    if (_observerAttached) return;
    WidgetsBinding.instance.addObserver(this);
    _observerAttached = true;
    debugPrint("🧩 AdService 已附加前景偵測。");
  }

  void _detachObserver() {
    if (!_observerAttached) return;
    WidgetsBinding.instance.removeObserver(this);
    _observerAttached = false;
    debugPrint("🧯 AdService 已釋放並取消前景偵測。");
  }

  static String get _currentBannerId =>
      kReleaseMode ? _prodBannerId : _testBannerId;

  void setIapBusy(bool busy) {
    _iapBusy = busy;
    if (busy) {
      debugPrint('⏸️ 內購流程進行中，暫停插頁廣告顯示。');
    }
  }

  /// Initialize the SDK and preload the first interstitial.
  ///
  /// [testDeviceIds]: add your device id here to force test ads while developing.
  Future<void> init({List<String> testDeviceIds = const []}) async {
    _appLaunchTime ??= DateTime.now();
    await MobileAds.instance.initialize();
    await _logAdvertisingId();

    // In debug/profile, always request test ads (safe for development).
    if (!kReleaseMode) {
      await MobileAds.instance.updateRequestConfiguration(
        RequestConfiguration(testDeviceIds: testDeviceIds),
      );
    } else if (testDeviceIds.isNotEmpty) {
      await MobileAds.instance.updateRequestConfiguration(
        RequestConfiguration(testDeviceIds: testDeviceIds),
      );
    }

    // 在初始化時優先讀取偏好中的 VIP 狀態，避免啟動階段誤載入/顯示廣告
    try {
      final prefs = await SharedPreferences.getInstance();
      final vipPref = prefs.getBool('isPremiumUnlocked') ?? false;
      if (vipPref && !_adsDisabled) {
        _adsDisabled = true;
        debugPrint("🔕 VIP 偏好為 true（啟動），AdService 將跳過預載與前景偵測。");
      }
    } catch (e) {
      debugPrint("⚠️ 讀取 VIP 偏好失敗（將以非 VIP 繼續）：$e");
    }

    if (!_adsDisabled) {
      await preloadInterstitial();
      await _loadBannerAd();
      _attachObserver();
    } else {
      debugPrint("🔕 VIP 已解鎖（啟動時），跳過預載與前景偵測。");
    }
  }

  Future<void> _logAdvertisingId() async {
    if (!kReleaseMode) {
      debugPrint('🧪 AdService: debug/profile 模式將嘗試讀取 IDFA。');
    }
    if (!WidgetsBinding.instance.isRootWidgetAttached) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    try {
      final status = await AppTrackingTransparency.trackingAuthorizationStatus;
      debugPrint('🆔 IDFA 授權狀態: $status');
      final idfa = await AppTrackingTransparency.getAdvertisingIdentifier();
      if (idfa.isEmpty || idfa == '00000000-0000-0000-0000-000000000000') {
        debugPrint('🆔 IDFA 取得結果為空或未授權');
      } else {
        debugPrint('🆔 IDFA: $idfa');
      }
    } catch (e) {
      debugPrint('🆔 IDFA 取得失敗: $e');
    }
  }

  /// Ensure interstitial is preloaded and foreground watcher is active.
  Future<void> ensureReady() async {
    if (_adsDisabled) {
      debugPrint("🔕 ensureReady(): VIP 狀態，跳過預載。");
      return;
    }
    if (_interstitial == null) {
      debugPrint("🔄 ensureReady(): 目前無快取廣告，開始預載…");
      await preloadInterstitial();
    }
    await _loadBannerAd();
    _attachObserver();
  }

  /// Whether an interstitial is ready to be shown.
  bool get isReady => _interstitial != null;

  /// Load an interstitial in the background.
  Future<void> preloadInterstitial() async {
    if (_adsDisabled) {
      debugPrint("🔕 preloadInterstitial(): VIP 狀態，略過載入。");
      return;
    }
    await InterstitialAd.load(
      adUnitId: _currentInterstitialId,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) {
          debugPrint("📥 Interstitial 已載入，就緒可播。");
          _interstitial = ad;
          ad.fullScreenContentCallback = FullScreenContentCallback(
            onAdShowedFullScreenContent: (ad) {},
            onAdImpression: (ad) {},
            onAdDismissedFullScreenContent: (ad) {
              debugPrint("🧹 使用者關閉插頁廣告，釋放並預載下一則。");
              ad.dispose();
              _interstitial = null;
              // Auto Prepare next one
              preloadInterstitial();
            },
            onAdFailedToShowFullScreenContent: (ad, error) {
              debugPrint("❌ 插頁廣告顯示失敗：$error，釋放並嘗試重新載入。");
              ad.dispose();
              _interstitial = null;
              // Try to load a fresh one
              preloadInterstitial();
            },
          );
        },
        onAdFailedToLoad: (error) {
          debugPrint("⚠️ 插頁廣告載入失敗：$error");
          _interstitial = null;
          // You may add retry/backoff here if needed.
        },
      ),
    );
  }

  /// Show the interstitial if loaded. Returns true if shown.
  Future<bool> showInterstitial() async {
    if (_adsDisabled) {
      debugPrint("🔕 showInterstitial(): VIP 狀態，禁止顯示。");
      return false;
    }
    if (_iapBusy) {
      debugPrint("⏸️ showInterstitial(): 內購流程進行中，暫停顯示。");
      return false;
    }
    if (_appLaunchTime != null &&
        DateTime.now().difference(_appLaunchTime!) < _launchCooldown) {
      debugPrint("⏳ showInterstitial(): 啟動冷卻中，略過此次顯示。");
      return false;
    }
    final ad = _interstitial;
    if (ad == null) {
      debugPrint("🚫 showInterstitial(): 目前沒有可用的插頁廣告。");
      // 嘗試預載，避免長期沒有可播廣告
      preloadInterstitial();
      return false;
    }
    await ad.show();
    return true;
  }

  /// Dispose any cached ad.
  void dispose() {
    _detachObserver();
    _interstitial?.dispose();
    _interstitial = null;
    _bannerAd?.dispose();
    _bannerAd = null;
    bannerAdNotifier.value = null;
  }

  /// 設定是否為 VIP（解鎖版）。VIP 會停用廣告與前景偵測並清掉快取。
  void setPremiumUnlocked(bool isVip) {
    _adsDisabled = isVip;
    if (_adsDisabled) {
      debugPrint("🔕 VIP 已解鎖，停用廣告與前景偵測。");
      _detachObserver();
      _interstitial?.dispose();
      _interstitial = null;
      _bannerAd?.dispose();
      _bannerAd = null;
      bannerAdNotifier.value = null;
    } else {
      debugPrint("🔔 非 VIP，啟用廣告。");
      ensureReady();
    }
  }

  /// Compatibility helper for callers expecting a banner hide API.
  /// This app currently serves interstitials only; to respect the intent of
  /// "no ads" after restore/purchase, we switch to VIP mode here.
  void hideBannerAd() {
    debugPrint(
      "🙈 hideBannerAd(): No banner in GPS app; disabling ads via VIP mode.",
    );
    setPremiumUnlocked(true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_adsDisabled) return;
    if (_iapBusy) return;
    if (state == AppLifecycleState.resumed) {
      _hasShownThisResume = false;
      // 小延遲，避免與頁面轉場/路由動畫衝突
      Future.delayed(const Duration(milliseconds: 500), () async {
        // 節流：距上次顯示間隔太短就跳過
        final now = DateTime.now();
        if (_lastShowTime != null &&
            now.difference(_lastShowTime!) < _minInterval) {
          debugPrint("⏱️ 回前景偵測到，但距離上次顯示 < ${_minInterval.inSeconds}s，跳過。");
          return;
        }
        if (_hasShownThisResume) return;
        debugPrint("📣 已從背景回前景 即將播放廣告…");
        final shown = await showInterstitial();
        if (shown) {
          _lastShowTime = DateTime.now();
          _hasShownThisResume = true;
          debugPrint("✅ 插頁廣告已顯示（回前景）。");
        } else {
          debugPrint("⌛ 廣告尚未就緒，嘗試預載中…");
          await preloadInterstitial();
        }
      });
    }
  }

  Future<void> _loadBannerAd() async {
    if (_adsDisabled) {
      debugPrint('🔕 _loadBannerAd(): VIP 狀態，略過載入。');
      return;
    }
    if (_bannerAd != null) {
      debugPrint('ℹ️ _loadBannerAd(): 已有橫幅快取，略過重複載入。');
      return;
    }
    final banner = BannerAd(
      adUnitId: _currentBannerId,
      size: AdSize.banner,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (ad) {
          debugPrint('🪧 橫幅廣告已載入。');
          _bannerAd = ad as BannerAd;
          bannerAdNotifier.value = _bannerAd;
        },
        onAdFailedToLoad: (ad, error) {
          debugPrint('⚠️ 橫幅載入失敗：$error');
          ad.dispose();
          if (identical(_bannerAd, ad)) {
            _bannerAd = null;
            bannerAdNotifier.value = null;
          }
        },
      ),
    );
    try {
      await banner.load();
    } catch (e) {
      debugPrint('⚠️ 橫幅 load() 例外：$e');
      banner.dispose();
    }
  }
}

import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Supported application languages.
enum AppLanguage { zhHant, zhHans, en }

/// Storage key for persisting language overrides.
const _languagePrefKey = 'selected_language_code';

/// Mapping between language and its locale.
const Map<AppLanguage, Locale> _kLanguageLocales = {
  AppLanguage.zhHant: Locale('zh', 'TW'),
  AppLanguage.zhHans: Locale('zh', 'CN'),
  AppLanguage.en: Locale('en'),
};

/// Internal translation table.
final Map<String, Map<AppLanguage, String>> _translations = {
  'app.title': {
    AppLanguage.zhHant: 'Sniffer Browser',
    AppLanguage.zhHans: 'Sniffer Browser',
    AppLanguage.en: 'Sniffer Browser',
  },
  'language.name.zhHant': {
    AppLanguage.zhHant: '繁體中文',
    AppLanguage.zhHans: '繁体中文',
    AppLanguage.en: 'Traditional Chinese',
  },
  'language.name.zhHans': {
    AppLanguage.zhHant: '簡體中文',
    AppLanguage.zhHans: '简体中文',
    AppLanguage.en: 'Simplified Chinese',
  },
  'language.name.en': {
    AppLanguage.zhHant: '英文',
    AppLanguage.zhHans: '英文',
    AppLanguage.en: 'English',
  },
  'settings.title': {
    AppLanguage.zhHant: '設定',
    AppLanguage.zhHans: '设置',
    AppLanguage.en: 'Settings',
  },
  'settings.language.title': {
    AppLanguage.zhHant: '語言',
    AppLanguage.zhHans: '语言',
    AppLanguage.en: 'Language',
  },
  'settings.language.snack': {
    AppLanguage.zhHant: '已設定語言：{language}',
    AppLanguage.zhHans: '已设置语言：{language}',
    AppLanguage.en: 'Language set to {language}',
  },
  'settings.premium.statusUnlocked': {
    AppLanguage.zhHant: '高級功能已啟用，廣告已移除。',
    AppLanguage.zhHans: '高级功能已启用，广告已移除。',
    AppLanguage.en: 'Premium is active and ads are removed.',
  },
  'settings.premium.statusLocked': {
    AppLanguage.zhHant: '升級後可使用編輯導出、嗅探、匯出等進階功能並去除廣告。',
    AppLanguage.zhHans: '升级后可使用编辑导出、嗅探、导出等进阶功能并去除广告。',
    AppLanguage.en:
        'Upgrade to unlock editor export, sniffing, exporting and remove ads.',
  },
  'settings.premium.purchaseSuccess': {
    AppLanguage.zhHant: '購買成功，已解鎖高級功能。',
    AppLanguage.zhHans: '购买成功，已解锁高级功能。',
    AppLanguage.en: 'Purchase successful. Premium features unlocked.',
  },
  'settings.premium.purchaseIncomplete': {
    AppLanguage.zhHant: '購買未完成',
    AppLanguage.zhHans: '购买未完成',
    AppLanguage.en: 'Purchase incomplete',
  },
  'settings.premium.button.unlocked': {
    AppLanguage.zhHant: '已解鎖高級功能',
    AppLanguage.zhHans: '已解锁高级功能',
    AppLanguage.en: 'Premium unlocked',
  },
  'settings.premium.button.upgrade': {
    AppLanguage.zhHant: '解鎖高級功能＆去廣告',
    AppLanguage.zhHans: '解锁高级功能＆去广告',
    AppLanguage.en: 'Unlock premium & remove ads',
  },
  'settings.premium.restoreSuccess': {
    AppLanguage.zhHant: '已還原購買。',
    AppLanguage.zhHans: '已还原购买。',
    AppLanguage.en: 'Purchases restored.',
  },
  'settings.premium.restoreFailed': {
    AppLanguage.zhHant: '未找到可還原的購買紀錄。',
    AppLanguage.zhHans: '未找到可还原的购买记录。',
    AppLanguage.en: 'No purchases available to restore.',
  },
  'settings.premium.restoreButton': {
    AppLanguage.zhHant: '還原購買',
    AppLanguage.zhHans: '还原购买',
    AppLanguage.en: 'Restore purchases',
  },
  'settings.section.general': {
    AppLanguage.zhHant: '一般',
    AppLanguage.zhHans: '常规',
    AppLanguage.en: 'General',
  },
  'settings.ua.title': {
    AppLanguage.zhHant: 'User-Agent (UA)',
    AppLanguage.zhHans: 'User-Agent (UA)',
    AppLanguage.en: 'User-Agent (UA)',
  },
  'common.notSet': {
    AppLanguage.zhHant: '未設定',
    AppLanguage.zhHans: '未设置',
    AppLanguage.en: 'Not set',
  },
  'settings.requiresPremiumSuffix': {
    AppLanguage.zhHant: '（需高級版）',
    AppLanguage.zhHans: '（需高级版）',
    AppLanguage.en: ' (Premium required)',
  },
  'settings.action.select': {
    AppLanguage.zhHant: '選擇',
    AppLanguage.zhHans: '选择',
    AppLanguage.en: 'Select',
  },
  'settings.ua.option.iphone': {
    AppLanguage.zhHant: 'iPhone',
    AppLanguage.zhHans: 'iPhone',
    AppLanguage.en: 'iPhone',
  },
  'settings.ua.option.ipad': {
    AppLanguage.zhHant: 'iPad',
    AppLanguage.zhHans: 'iPad',
    AppLanguage.en: 'iPad',
  },
  'settings.ua.option.android': {
    AppLanguage.zhHant: 'Android',
    AppLanguage.zhHans: 'Android',
    AppLanguage.en: 'Android',
  },
  'settings.ua.option.windows': {
    AppLanguage.zhHant: 'Windows',
    AppLanguage.zhHans: 'Windows',
    AppLanguage.en: 'Windows',
  },
  'settings.ua.snack': {
    AppLanguage.zhHant: '已設定 UA：{ua}（重啟後保留）',
    AppLanguage.zhHans: '已设定 UA：{ua}（重启后保留）',
    AppLanguage.en: 'UA set to {ua} (persists after restart)',
  },
  'settings.ua.featureName': {
    AppLanguage.zhHant: '更改 User-Agent',
    AppLanguage.zhHans: '更改 User-Agent',
    AppLanguage.en: 'Change User-Agent',
  },
  'settings.searchEngine.title': {
    AppLanguage.zhHant: '搜尋引擎',
    AppLanguage.zhHans: '搜索引擎',
    AppLanguage.en: 'Search engine',
  },
  'settings.searchEngine.option.google': {
    AppLanguage.zhHant: 'Google',
    AppLanguage.zhHans: 'Google',
    AppLanguage.en: 'Google',
  },
  'settings.searchEngine.option.bing': {
    AppLanguage.zhHant: 'Bing',
    AppLanguage.zhHans: 'Bing',
    AppLanguage.en: 'Bing',
  },
  'settings.searchEngine.option.yahoo': {
    AppLanguage.zhHant: 'Yahoo',
    AppLanguage.zhHans: 'Yahoo',
    AppLanguage.en: 'Yahoo',
  },
  'settings.searchEngine.option.duckduckgo': {
    AppLanguage.zhHant: 'DuckDuckGo',
    AppLanguage.zhHans: 'DuckDuckGo',
    AppLanguage.en: 'DuckDuckGo',
  },
  'settings.searchEngine.option.baidu': {
    AppLanguage.zhHant: 'Baidu',
    AppLanguage.zhHans: 'Baidu',
    AppLanguage.en: 'Baidu',
  },
  'settings.searchEngine.snack': {
    AppLanguage.zhHant: '已設定搜尋引擎：{engine}',
    AppLanguage.zhHans: '已设置搜索引擎：{engine}',
    AppLanguage.en: 'Search engine set to {engine}',
  },
  'settings.autoSave.title': {
    AppLanguage.zhHant: '自動儲存到相簿',
    AppLanguage.zhHans: '自动保存到相册',
    AppLanguage.en: 'Auto-save to gallery',
  },
  'settings.autoSave.premiumHint': {
    AppLanguage.zhHant: '升級高級版後才可啟用。',
    AppLanguage.zhHans: '升级到高级版后才能启用。',
    AppLanguage.en: 'Upgrade to premium to enable this feature.',
  },
  'settings.autoSave.permissionRequired': {
    AppLanguage.zhHant: '自動儲存需要相簿權限，請前往設定開啟。',
    AppLanguage.zhHans: '自动保存需要相册权限，请前往设置开启。',
    AppLanguage.en:
        'Auto-save requires photo access. Please enable it in settings.',
  },
  'settings.autoSave.permissionUnknown': {
    AppLanguage.zhHant: '無法確認相簿權限，請手動檢查設定。',
    AppLanguage.zhHans: '无法确认相册权限，请手动检查设置。',
    AppLanguage.en:
        'Unable to verify photo permission. Please check system settings.',
  },
  'settings.autoSave.snack.enabled': {
    AppLanguage.zhHant: '下載完成後將自動存入相簿',
    AppLanguage.zhHans: '下载完成后将自动保存到相册',
    AppLanguage.en: 'Downloads will be saved to the gallery automatically.',
  },
  'settings.autoSave.snack.disabled': {
    AppLanguage.zhHant: '已關閉自動存相簿',
    AppLanguage.zhHans: '已关闭自动保存到相册',
    AppLanguage.en: 'Auto-save to gallery disabled.',
  },
  'settings.cache.title': {
    AppLanguage.zhHant: '清理快取',
    AppLanguage.zhHans: '清理缓存',
    AppLanguage.en: 'Clear cache',
  },
  'settings.cache.subtitle': {
    AppLanguage.zhHant: '目前快取大小：{size}',
    AppLanguage.zhHans: '当前缓存大小：{size}',
    AppLanguage.en: 'Current cache size: {size}',
  },
  'settings.cache.cleared': {
    AppLanguage.zhHant: '已清理快取',
    AppLanguage.zhHans: '已清理缓存',
    AppLanguage.en: 'Cache cleared',
  },
  'settings.legal.title': {
    AppLanguage.zhHant: '版權與使用聲明',
    AppLanguage.zhHans: '版权与使用声明',
    AppLanguage.en: 'Copyright & disclaimer',
  },
  'settings.legal.description': {
    AppLanguage.zhHant:
        '本應用程式僅提供技術工具，用戶的所有使用行為均與作者無關。請尊重智慧財產權，僅下載您擁有或已獲授權的內容；加密 DRM 流可能無法下載',
    AppLanguage.zhHans:
        '本应用程序仅提供技术工具，用户的所有使用行为均与作者无关。请尊重知识产权，仅下载您拥有或已获授权的内容；加密 DRM 流可能无法下载',
    AppLanguage.en:
        'This app only provides technical tools. All user actions are unrelated to the author. Please respect intellectual property and download only content you own or are authorized to access. Encrypted DRM streams may not be downloadable.',
  },
  'settings.about.title': {
    AppLanguage.zhHant: '關於',
    AppLanguage.zhHans: '关于',
    AppLanguage.en: 'About',
  },
  'settings.about.description': {
    AppLanguage.zhHant:
        'Yi Apps Copyright © Yi Browser \n聯絡我們: tzuyichan0406@gmail.com',
    AppLanguage.zhHans:
        'Yi Apps Copyright © Yi Browser \n联系我们: tzuyichan0406@gmail.com',
    AppLanguage.en:
        'Yi Apps Copyright © Yi Browser\nContact: tzuyichan0406@gmail.com',
  },
  'settings.about.email.subject': {
    AppLanguage.zhHant: 'App 聯絡',
    AppLanguage.zhHans: 'App 联系',
    AppLanguage.en: 'App contact',
  },
  'settings.about.email.body': {
    AppLanguage.zhHant: '您好，',
    AppLanguage.zhHans: '您好，',
    AppLanguage.en: 'Hello,',
  },
  'settings.photoPermission.reminder': {
    AppLanguage.zhHant: '尚未取得相簿存取權限，啟用「自動儲存到相簿」前請先到系統設定開啟。',
    AppLanguage.zhHans: '尚未获得相册访问权限，启用“自动保存到相册”前请先到系统设置开启。',
    AppLanguage.en:
        'Photo access is not granted. Please enable it in system settings before using "Auto-save to gallery".',
  },
  'settings.photoPermission.unableCheck': {
    AppLanguage.zhHant: '無法檢查相簿權限，請至系統設定確認。',
    AppLanguage.zhHans: '无法检查相册权限，请至系统设置确认。',
    AppLanguage.en:
        'Unable to verify photo permission. Please confirm in system settings.',
  },
  'common.goToSettings': {
    AppLanguage.zhHant: '前往設定',
    AppLanguage.zhHans: '前往设置',
    AppLanguage.en: 'Open settings',
  },
  'settings.autoSave.featureName': {
    AppLanguage.zhHant: '自動儲存到相簿',
    AppLanguage.zhHans: '自动保存到相册',
    AppLanguage.en: 'Auto-save to gallery',
  },
  'iap.prompt.title': {
    AppLanguage.zhHant: '升級至高級版',
    AppLanguage.zhHans: '升级至高级版',
    AppLanguage.en: 'Upgrade to premium',
  },
  'iap.prompt.description.generic': {
    AppLanguage.zhHant: '解鎖高級功能可去除廣告並開啟所有進階功能。',
    AppLanguage.zhHans: '解锁高级功能可去除广告并开启所有进阶功能。',
    AppLanguage.en:
        'Unlock premium to remove ads and enable all advanced features.',
  },
  'iap.prompt.description.feature': {
    AppLanguage.zhHant: '使用{feature}需要先解鎖高級功能並去除廣告。',
    AppLanguage.zhHans: '使用{feature}需要先解锁高级功能并去除广告。',
    AppLanguage.en:
        '{feature} requires premium to unlock and remove ads first.',
  },
  'iap.prompt.action.buy': {
    AppLanguage.zhHant: '解鎖高級功能＆去廣告',
    AppLanguage.zhHans: '解锁高级功能＆去广告',
    AppLanguage.en: 'Unlock premium & remove ads',
  },
  'iap.prompt.action.restore': {
    AppLanguage.zhHant: '還原購買',
    AppLanguage.zhHans: '还原购买',
    AppLanguage.en: 'Restore purchases',
  },
  'iap.prompt.action.later': {
    AppLanguage.zhHant: '稍後再說',
    AppLanguage.zhHans: '稍后再说',
    AppLanguage.en: 'Maybe later',
  },
  'iap.prompt.snack.buySuccess': {
    AppLanguage.zhHant: '感謝購買，高級功能已解鎖。',
    AppLanguage.zhHans: '感谢购买，高级功能已解锁。',
    AppLanguage.en: 'Thanks for the purchase. Premium is unlocked.',
  },
  'iap.prompt.snack.buyIncomplete': {
    AppLanguage.zhHant: '購買未完成，請稍後再試。',
    AppLanguage.zhHans: '购买未完成，请稍后再试。',
    AppLanguage.en: 'Purchase incomplete. Please try again later.',
  },
  'iap.prompt.snack.restoreSuccess': {
    AppLanguage.zhHant: '已還原購買。',
    AppLanguage.zhHans: '已还原购买。',
    AppLanguage.en: 'Purchases restored.',
  },
  'iap.prompt.snack.restoreFailed': {
    AppLanguage.zhHant: '未找到可還原的購買紀錄。',
    AppLanguage.zhHans: '未找到可还原的购买记录。',
    AppLanguage.en: 'No purchases available to restore.',
  },
  'feature.addHomeShortcut': {
    AppLanguage.zhHant: '新增更多主頁捷徑',
    AppLanguage.zhHans: '新增更多主页捷径',
    AppLanguage.en: 'Add more home shortcuts',
  },
  'feature.sniffing': {
    AppLanguage.zhHant: '嗅探功能',
    AppLanguage.zhHans: '嗅探功能',
    AppLanguage.en: 'Sniffing feature',
  },
  'feature.sniffingResources': {
    AppLanguage.zhHant: '嗅探資源',
    AppLanguage.zhHans: '嗅探资源',
    AppLanguage.en: 'Sniff media resources',
  },
  'feature.export': {
    AppLanguage.zhHant: '匯出',
    AppLanguage.zhHans: '导出',
    AppLanguage.en: 'Export',
  },
  'feature.editExport': {
    AppLanguage.zhHant: '編輯導出',
    AppLanguage.zhHans: '编辑导出',
    AppLanguage.en: 'Edit & export',
  },
  'feature.hidden': {
    AppLanguage.zhHant: '隱藏功能',
    AppLanguage.zhHans: '隐藏功能',
    AppLanguage.en: 'Hidden feature',
  },
  'browser.sniffer.tooltip.enabled': {
    AppLanguage.zhHant: '嗅探',
    AppLanguage.zhHans: '嗅探',
    AppLanguage.en: 'Sniff',
  },
  'browser.sniffer.tooltip.premiumLocked': {
    AppLanguage.zhHant: '嗅探（需高級版）',
    AppLanguage.zhHans: '嗅探（需高级版）',
    AppLanguage.en: 'Sniff (Premium required)',
  },
  'browser.resources.tooltip': {
    AppLanguage.zhHant: '資源',
    AppLanguage.zhHans: '资源',
    AppLanguage.en: 'Resources',
  },
  'browser.resources.tooltip.count': {
    AppLanguage.zhHant: '資源（{count}）',
    AppLanguage.zhHans: '资源（{count}）',
    AppLanguage.en: 'Resources ({count})',
  },
  'browser.resources.tooltip.premiumLocked': {
    AppLanguage.zhHant: '資源（需高級版）',
    AppLanguage.zhHans: '资源（需高级版）',
    AppLanguage.en: 'Resources (Premium required)',
  },
};

/// Service that manages the current language and translation lookup.
class LanguageService {
  LanguageService._();

  static final LanguageService instance = LanguageService._();

  final ValueNotifier<AppLanguage> _currentLanguage =
      ValueNotifier<AppLanguage>(AppLanguage.en);

  bool _userOverride = false;

  ValueListenable<AppLanguage> get languageListenable => _currentLanguage;

  AppLanguage get currentLanguage => _currentLanguage.value;

  Locale get currentLocale => _kLanguageLocales[currentLanguage]!;

  List<Locale> get supportedLocales =>
      AppLanguage.values.map((e) => _kLanguageLocales[e]!).toList();

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_languagePrefKey);
    if (stored != null) {
      final match = AppLanguage.values.firstWhere(
        (element) => element.name == stored,
        orElse: () => AppLanguage.en,
      );
      _userOverride = true;
      _currentLanguage.value = match;
      return;
    }

    final locale = PlatformDispatcher.instance.locale;
    final detected = _detectLanguage(locale);
    _currentLanguage.value = detected;
  }

  Future<void> setLanguage(AppLanguage language) async {
    if (_currentLanguage.value == language) return;
    _currentLanguage.value = language;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_languagePrefKey, language.name);
    _userOverride = true;
  }

  /// Detect language from a device locale.
  AppLanguage _detectLanguage(Locale locale) {
    final langCode = locale.languageCode.toLowerCase();
    final scriptCode = locale.scriptCode?.toLowerCase();
    final countryCode = locale.countryCode?.toLowerCase();

    if (langCode == 'zh') {
      if (scriptCode == 'hant') {
        return AppLanguage.zhHant;
      }
      if (scriptCode == 'hans') {
        return AppLanguage.zhHans;
      }
      if (countryCode == 'tw' || countryCode == 'hk' || countryCode == 'mo') {
        return AppLanguage.zhHant;
      }
      if (countryCode == 'cn' || countryCode == 'sg' || countryCode == 'my') {
        return AppLanguage.zhHans;
      }
      return AppLanguage.zhHant;
    }

    if (langCode == 'en') {
      return AppLanguage.en;
    }

    return AppLanguage.en;
  }

  /// Translate [key] into the current language.
  String translate(String key, {Map<String, String>? params}) {
    final values = _translations[key];
    final fallback = values?[AppLanguage.en] ?? key;
    String value = values?[currentLanguage] ?? fallback;
    if (params != null) {
      params.forEach((name, v) {
        value = value.replaceAll('{$name}', v);
      });
    }
    return value;
  }

  /// Returns the translation key for the name of [language].
  String languageNameKey(AppLanguage language) {
    switch (language) {
      case AppLanguage.zhHant:
        return 'language.name.zhHant';
      case AppLanguage.zhHans:
        return 'language.name.zhHans';
      case AppLanguage.en:
        return 'language.name.en';
    }
  }

  bool get hasUserOverride => _userOverride;
}

extension LocalizationBuildContext on BuildContext {
  String l10n(String key, {Map<String, String>? params}) {
    return LanguageService.instance.translate(key, params: params);
  }
}

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
  'common.edit': {
    AppLanguage.zhHant: '編輯',
    AppLanguage.zhHans: '编辑',
    AppLanguage.en: 'Edit',
  },
  'common.delete': {
    AppLanguage.zhHant: '刪除',
    AppLanguage.zhHans: '删除',
    AppLanguage.en: 'Delete',
  },
  'common.done': {
    AppLanguage.zhHant: '完成',
    AppLanguage.zhHans: '完成',
    AppLanguage.en: 'Done',
  },
  'common.cancel': {
    AppLanguage.zhHant: '取消',
    AppLanguage.zhHans: '取消',
    AppLanguage.en: 'Cancel',
  },
  'common.canceling': {
    AppLanguage.zhHant: '取消中…',
    AppLanguage.zhHans: '取消中…',
    AppLanguage.en: 'Canceling…',
  },
  'common.add': {
    AppLanguage.zhHant: '新增',
    AppLanguage.zhHans: '新增',
    AppLanguage.en: 'Add',
  },
  'common.confirm': {
    AppLanguage.zhHant: '確定',
    AppLanguage.zhHans: '确定',
    AppLanguage.en: 'Confirm',
  },
  'common.name': {
    AppLanguage.zhHant: '名稱',
    AppLanguage.zhHans: '名称',
    AppLanguage.en: 'Name',
  },
  'common.url': {
    AppLanguage.zhHant: '網址',
    AppLanguage.zhHans: '网址',
    AppLanguage.en: 'URL',
  },
  'common.play': {
    AppLanguage.zhHant: '播放',
    AppLanguage.zhHans: '播放',
    AppLanguage.en: 'Play',
  },
  'common.pause': {
    AppLanguage.zhHant: '暫停',
    AppLanguage.zhHans: '暂停',
    AppLanguage.en: 'Pause',
  },
  'common.open': {
    AppLanguage.zhHant: '打開',
    AppLanguage.zhHans: '打开',
    AppLanguage.en: 'Open',
  },
  'common.unknown': {
    AppLanguage.zhHant: '未知',
    AppLanguage.zhHans: '未知',
    AppLanguage.en: 'Unknown',
  },
  'common.unknownError': {
    AppLanguage.zhHant: '未知錯誤',
    AppLanguage.zhHans: '未知错误',
    AppLanguage.en: 'Unknown error',
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
  'home.title': {
    AppLanguage.zhHant: '主頁',
    AppLanguage.zhHans: '主页',
    AppLanguage.en: 'Home',
  },
  'home.emptyState': {
    AppLanguage.zhHant: '尚未添加任何捷徑\n使用 + 按鈕新增網址到主頁',
    AppLanguage.zhHans: '尚未添加任何捷径\n使用 + 按钮新增网址到主页',
    AppLanguage.en:
        'No shortcuts yet.\nUse the + button to add one to the home page.',
  },
  'home.action.addShortcut': {
    AppLanguage.zhHant: '新增捷徑',
    AppLanguage.zhHans: '新增捷径',
    AppLanguage.en: 'Add shortcut',
  },
  'home.dialog.addTitle': {
    AppLanguage.zhHant: '新增捷徑',
    AppLanguage.zhHans: '新增捷径',
    AppLanguage.en: 'Add shortcut',
  },
  'home.dialog.editTitle': {
    AppLanguage.zhHant: '編輯捷徑',
    AppLanguage.zhHans: '编辑捷径',
    AppLanguage.en: 'Edit shortcut',
  },
  'shareReview.snack.importFailed': {
    AppLanguage.zhHant: '匯入失敗：{error}',
    AppLanguage.zhHans: '导入失败：{error}',
    AppLanguage.en: 'Import failed: {error}',
  },
  'shareReview.snack.cancelFailed': {
    AppLanguage.zhHant: '取消匯入失敗：{error}',
    AppLanguage.zhHans: '取消导入失败：{error}',
    AppLanguage.en: 'Failed to cancel import: {error}',
  },
  'shareReview.snack.allDiscarded': {
    AppLanguage.zhHant: '所有項目已丟棄',
    AppLanguage.zhHans: '所有项目已丢弃',
    AppLanguage.en: 'All items discarded',
  },
  'shareReview.snack.itemDiscarded': {
    AppLanguage.zhHant: '已丟棄 {name}',
    AppLanguage.zhHans: '已丢弃 {name}',
    AppLanguage.en: 'Discarded {name}',
  },
  'shareReview.dialog.title': {
    AppLanguage.zhHant: '匯入預覽',
    AppLanguage.zhHans: '导入预览',
    AppLanguage.en: 'Import preview',
  },
  'shareReview.dialog.confirm': {
    AppLanguage.zhHant: '匯入',
    AppLanguage.zhHans: '导入',
    AppLanguage.en: 'Import',
  },
  'shareReview.carousel.hintMultiple': {
    AppLanguage.zhHant: '左右滑動以檢視所有項目',
    AppLanguage.zhHans: '左右滑动以检视所有项目',
    AppLanguage.en: 'Swipe sideways to view all items',
  },
  'shareReview.carousel.hintSingle': {
    AppLanguage.zhHant: '預覽內容',
    AppLanguage.zhHans: '预览内容',
    AppLanguage.en: 'Preview',
  },
  'shareReview.tooltip.discardItem': {
    AppLanguage.zhHant: '丟棄此項目',
    AppLanguage.zhHans: '丢弃此项目',
    AppLanguage.en: 'Discard this item',
  },
  'shareReview.status.saving': {
    AppLanguage.zhHant: '保存中…',
    AppLanguage.zhHans: '保存中…',
    AppLanguage.en: 'Saving…',
  },
  'shareReview.empty.title': {
    AppLanguage.zhHant: '沒有可匯入的項目',
    AppLanguage.zhHans: '没有可导入的项目',
    AppLanguage.en: 'No items to import',
  },
  'shareReview.empty.subtitle': {
    AppLanguage.zhHant: '請返回並重新選擇分享的內容。',
    AppLanguage.zhHans: '请返回并重新选择分享的内容。',
    AppLanguage.en: 'Go back and choose the content to share again.',
  },
  'shareReview.error.audioLoad': {
    AppLanguage.zhHant: '音訊載入失敗',
    AppLanguage.zhHans: '音频载入失败',
    AppLanguage.en: 'Failed to load audio',
  },
  'shareReview.error.videoLoad': {
    AppLanguage.zhHant: '影片載入失敗',
    AppLanguage.zhHans: '视频载入失败',
    AppLanguage.en: 'Failed to load video',
  },
  'shareReview.error.fileNotFound': {
    AppLanguage.zhHant: '找不到檔案',
    AppLanguage.zhHans: '找不到文件',
    AppLanguage.en: 'File not found',
  },
  'shareReview.error.openFile': {
    AppLanguage.zhHant: '無法開啟檔案：{error}',
    AppLanguage.zhHans: '无法打开文件：{error}',
    AppLanguage.en: 'Unable to open file: {error}',
  },
  'main.quickAction.newTab': {
    AppLanguage.zhHant: '新分頁',
    AppLanguage.zhHans: '新标签页',
    AppLanguage.en: 'New tab',
  },
  'main.quickAction.media': {
    AppLanguage.zhHant: '媒體',
    AppLanguage.zhHans: '媒体',
    AppLanguage.en: 'Media',
  },
  'main.nav.media': {
    AppLanguage.zhHant: '媒體',
    AppLanguage.zhHans: '媒体',
    AppLanguage.en: 'Media',
  },
  'main.nav.home': {
    AppLanguage.zhHant: '主頁',
    AppLanguage.zhHans: '主页',
    AppLanguage.en: 'Home',
  },
  'main.nav.browser': {
    AppLanguage.zhHant: '瀏覽器',
    AppLanguage.zhHans: '浏览器',
    AppLanguage.en: 'Browser',
  },
  'main.nav.settings': {
    AppLanguage.zhHant: '設定',
    AppLanguage.zhHans: '设置',
    AppLanguage.en: 'Settings',
  },
  'main.snack.import.singleSuccess': {
    AppLanguage.zhHant: '已匯入：{name}',
    AppLanguage.zhHans: '已导入：{name}',
    AppLanguage.en: 'Imported: {name}',
  },
  'main.snack.import.singleSuccessWithFailures': {
    AppLanguage.zhHant: '已匯入：{name}（另有 {count} 個失敗）',
    AppLanguage.zhHans: '已导入：{name}（另有 {count} 个失败）',
    AppLanguage.en: 'Imported: {name} ({count} failed)',
  },
  'main.snack.import.multiSuccess': {
    AppLanguage.zhHant: '已匯入 {count} 個項目',
    AppLanguage.zhHans: '已导入 {count} 个项目',
    AppLanguage.en: 'Imported {count} items',
  },
  'main.snack.import.multiSuccessWithFailures': {
    AppLanguage.zhHant: '已匯入 {count} 個項目，{failures} 個失敗',
    AppLanguage.zhHans: '已导入 {count} 个项目，{failures} 个失败',
    AppLanguage.en: 'Imported {count} items, {failures} failed',
  },
  'main.snack.import.failure': {
    AppLanguage.zhHant: '匯入失敗：{count} 個項目未能存入',
    AppLanguage.zhHans: '导入失败：{count} 个项目未能存入',
    AppLanguage.en: 'Import failed: {count} items could not be saved',
  },
  'main.snack.import.none': {
    AppLanguage.zhHant: '沒有可匯入的項目',
    AppLanguage.zhHans: '没有可导入的项目',
    AppLanguage.en: 'No items to import',
  },
  'main.snack.discarded.single': {
    AppLanguage.zhHant: '已丟棄分享的項目',
    AppLanguage.zhHans: '已丢弃分享的项目',
    AppLanguage.en: 'Shared item discarded',
  },
  'main.snack.discarded.multiple': {
    AppLanguage.zhHant: '已丟棄 {count} 個分享的項目',
    AppLanguage.zhHans: '已丢弃 {count} 个分享的项目',
    AppLanguage.en: 'Discarded {count} shared items',
  },
  'miniPlayer.tooltip.expand': {
    AppLanguage.zhHant: '放大',
    AppLanguage.zhHans: '放大',
    AppLanguage.en: 'Expand',
  },
  'miniPlayer.tooltip.close': {
    AppLanguage.zhHant: '關閉',
    AppLanguage.zhHans: '关闭',
    AppLanguage.en: 'Close',
  },
  'videoPlayer.defaultTitle': {
    AppLanguage.zhHant: '播放器',
    AppLanguage.zhHans: '播放器',
    AppLanguage.en: 'Player',
  },
  'videoPlayer.action.playbackSpeed': {
    AppLanguage.zhHant: '播放速度',
    AppLanguage.zhHans: '播放速度',
    AppLanguage.en: 'Playback speed',
  },
  'converter.format.mp3': {
    AppLanguage.zhHant: 'MP3 (音訊)',
    AppLanguage.zhHans: 'MP3 (音频)',
    AppLanguage.en: 'MP3 (audio)',
  },
  'converter.format.m4a': {
    AppLanguage.zhHant: 'M4A (AAC 音訊)',
    AppLanguage.zhHans: 'M4A (AAC 音频)',
    AppLanguage.en: 'M4A (AAC audio)',
  },
  'converter.format.aac': {
    AppLanguage.zhHant: 'AAC',
    AppLanguage.zhHans: 'AAC',
    AppLanguage.en: 'AAC',
  },
  'converter.format.wav': {
    AppLanguage.zhHant: 'WAV (PCM)',
    AppLanguage.zhHans: 'WAV (PCM)',
    AppLanguage.en: 'WAV (PCM)',
  },
  'converter.format.jpg': {
    AppLanguage.zhHant: 'JPG (圖片)',
    AppLanguage.zhHans: 'JPG (图片)',
    AppLanguage.en: 'JPG (image)',
  },
  'converter.format.png': {
    AppLanguage.zhHant: 'PNG (圖片)',
    AppLanguage.zhHans: 'PNG (图片)',
    AppLanguage.en: 'PNG (image)',
  },
  'converter.format.gif': {
    AppLanguage.zhHant: 'GIF (圖片)',
    AppLanguage.zhHans: 'GIF (图片)',
    AppLanguage.en: 'GIF (image)',
  },
  'converter.format.bmp': {
    AppLanguage.zhHant: 'BMP (圖片)',
    AppLanguage.zhHans: 'BMP (图片)',
    AppLanguage.en: 'BMP (image)',
  },
  'converter.format.svg': {
    AppLanguage.zhHant: 'SVG (圖片)',
    AppLanguage.zhHans: 'SVG (图片)',
    AppLanguage.en: 'SVG (image)',
  },
  'converter.format.tiff': {
    AppLanguage.zhHant: 'TIFF (圖片)',
    AppLanguage.zhHans: 'TIFF (图片)',
    AppLanguage.en: 'TIFF (image)',
  },
  'converter.format.pdf': {
    AppLanguage.zhHant: 'PDF (圖片)',
    AppLanguage.zhHans: 'PDF (图片)',
    AppLanguage.en: 'PDF (image)',
  },
  'converter.format.mp4H264': {
    AppLanguage.zhHant: 'MP4 (H.264 + AAC)',
    AppLanguage.zhHans: 'MP4 (H.264 + AAC)',
    AppLanguage.en: 'MP4 (H.264 + AAC)',
  },
  'converter.format.movH264': {
    AppLanguage.zhHant: 'MOV (H.264 + AAC)',
    AppLanguage.zhHans: 'MOV (H.264 + AAC)',
    AppLanguage.en: 'MOV (H.264 + AAC)',
  },
  'converter.format.mkvH264': {
    AppLanguage.zhHant: 'MKV (H.264 + AAC)',
    AppLanguage.zhHans: 'MKV (H.264 + AAC)',
    AppLanguage.en: 'MKV (H.264 + AAC)',
  },
  'converter.format.webmVp9': {
    AppLanguage.zhHant: 'WebM (VP9 + Opus)',
    AppLanguage.zhHans: 'WebM (VP9 + Opus)',
    AppLanguage.en: 'WebM (VP9 + Opus)',
  },
  'converter.error.missingSourceFile': {
    AppLanguage.zhHant: '找不到來源檔案',
    AppLanguage.zhHans: '找不到来源文件',
    AppLanguage.en: 'Source file not found',
  },
  'converter.error.previewLoad': {
    AppLanguage.zhHant: '預覽無法載入：{error}',
    AppLanguage.zhHans: '预览无法载入：{error}',
    AppLanguage.en: 'Preview failed to load: {error}',
  },
  'converter.info.mediaTypeImage': {
    AppLanguage.zhHant: '媒體類型: 圖片',
    AppLanguage.zhHans: '媒体类型: 图片',
    AppLanguage.en: 'Media type: Image',
  },
  'converter.info.sourceDuration': {
    AppLanguage.zhHant: '來源長度: {duration}',
    AppLanguage.zhHans: '来源长度: {duration}',
    AppLanguage.en: 'Source length: {duration}',
  },
  'converter.info.sourcePath': {
    AppLanguage.zhHant: '來源路徑: {path}',
    AppLanguage.zhHans: '来源路径: {path}',
    AppLanguage.en: 'Source path: {path}',
  },
  'converter.action.exporting': {
    AppLanguage.zhHant: '匯出中…',
    AppLanguage.zhHans: '导出中…',
    AppLanguage.en: 'Exporting…',
  },
  'converter.error.imagePreviewUnavailable': {
    AppLanguage.zhHant: '無法顯示圖片預覽',
    AppLanguage.zhHans: '无法显示图片预览',
    AppLanguage.en: 'Unable to display image preview',
  },
  'converter.error.previewUnavailable': {
    AppLanguage.zhHant: '無法預覽，仍可進行匯出',
    AppLanguage.zhHans: '无法预览，仍可进行导出',
    AppLanguage.en: 'Preview unavailable, export still possible',
  },
  'converter.tooltip.rewind10': {
    AppLanguage.zhHant: '倒退 10 秒',
    AppLanguage.zhHans: '倒退 10 秒',
    AppLanguage.en: 'Rewind 10 seconds',
  },
  'converter.tooltip.forward10': {
    AppLanguage.zhHant: '快轉 10 秒',
    AppLanguage.zhHans: '快进 10 秒',
    AppLanguage.en: 'Forward 10 seconds',
  },
  'converter.hint.waveformLongPress': {
    AppLanguage.zhHant: '提示：長按波形並拖曳可預覽時間（顯示毫秒）',
    AppLanguage.zhHans: '提示：长按波形并拖曳可预览时间（显示毫秒）',
    AppLanguage.en:
        'Tip: long-press the waveform and drag to preview (shows milliseconds)',
  },
  'converter.waveform.notReady': {
    AppLanguage.zhHant: '波形圖尚未就緒',
    AppLanguage.zhHans: '波形图尚未就绪',
    AppLanguage.en: 'Waveform not ready yet',
  },
  'converter.waveform.regenerate': {
    AppLanguage.zhHant: '重新產生波形',
    AppLanguage.zhHans: '重新产生波形',
    AppLanguage.en: 'Regenerate waveform',
  },
  'converter.waveform.error.generic': {
    AppLanguage.zhHant: '波形圖產生失敗，請重試。',
    AppLanguage.zhHans: '波形图产生失败，请重试。',
    AppLanguage.en: 'Failed to generate waveform. Please try again.',
  },
  'converter.waveform.error.withReason': {
    AppLanguage.zhHant: '波形圖產生失敗：{error}',
    AppLanguage.zhHans: '波形图产生失败：{error}',
    AppLanguage.en: 'Waveform generation failed: {error}',
  },
  'converter.info.imageConversionNote': {
    AppLanguage.zhHant: '此圖片會完整轉換為選擇的輸出格式。',
    AppLanguage.zhHans: '此图片会完整转换为选择的输出格式。',
    AppLanguage.en:
        'This image will be fully converted to the selected output format.',
  },
  'converter.info.noDuration': {
    AppLanguage.zhHant: '無法取得媒體長度，請直接匯出整段。',
    AppLanguage.zhHans: '无法取得媒体长度，请直接导出整段。',
    AppLanguage.en:
        'Unable to determine media length. Export the full range instead.',
  },
  'converter.section.selection': {
    AppLanguage.zhHant: '選取範圍',
    AppLanguage.zhHans: '选取范围',
    AppLanguage.en: 'Selection',
  },
  'converter.selection.start': {
    AppLanguage.zhHant: '起點：{time}',
    AppLanguage.zhHans: '起点：{time}',
    AppLanguage.en: 'Start: {time}',
  },
  'converter.selection.end': {
    AppLanguage.zhHant: '終點：{time}',
    AppLanguage.zhHans: '终点：{time}',
    AppLanguage.en: 'End: {time}',
  },
  'converter.selection.length': {
    AppLanguage.zhHant: '長度：{time}（{seconds} 秒）',
    AppLanguage.zhHans: '长度：{time}（{seconds} 秒）',
    AppLanguage.en: 'Length: {time} ({seconds} s)',
  },
  'converter.selection.useCurrentAsStart': {
    AppLanguage.zhHant: '以目前時間為起點',
    AppLanguage.zhHans: '以目前时间为起点',
    AppLanguage.en: 'Use current time as start',
  },
  'converter.selection.useCurrentAsEnd': {
    AppLanguage.zhHant: '以目前時間為終點',
    AppLanguage.zhHans: '以目前时间为终点',
    AppLanguage.en: 'Use current time as end',
  },
  'converter.selection.preview': {
    AppLanguage.zhHant: '預覽選取範圍',
    AppLanguage.zhHans: '预览选取范围',
    AppLanguage.en: 'Preview selection',
  },
  'converter.section.output': {
    AppLanguage.zhHant: '輸出設定',
    AppLanguage.zhHans: '输出设定',
    AppLanguage.en: 'Output settings',
  },
  'converter.field.outputFormat': {
    AppLanguage.zhHant: '輸出格式',
    AppLanguage.zhHans: '输出格式',
    AppLanguage.en: 'Output format',
  },
  'converter.field.outputFileName': {
    AppLanguage.zhHant: '輸出檔名',
    AppLanguage.zhHans: '输出档名',
    AppLanguage.en: 'Output file name',
  },
  'converter.hint.outputLocation': {
    AppLanguage.zhHant: '檔案將儲存到與原始檔案相同的資料夾（副檔名會使用 .{extension}）',
    AppLanguage.zhHans: '文件将存到与原始文件相同的文件夹（扩展名会使用 .{extension}）',
    AppLanguage.en:
        'The file will be saved in the same folder as the original (with .{extension}).',
  },
  'converter.error.missingSourceImage': {
    AppLanguage.zhHant: '找不到來源圖片',
    AppLanguage.zhHans: '找不到来源图片',
    AppLanguage.en: 'Source image not found',
  },
  'converter.error.decodeImageFailed': {
    AppLanguage.zhHant: '無法解析來源圖片',
    AppLanguage.zhHans: '无法解析来源图片',
    AppLanguage.en: 'Unable to decode source image',
  },
  'converter.error.unsupportedOutputFormat': {
    AppLanguage.zhHant: '不支援的輸出格式',
    AppLanguage.zhHans: '不支持的输出格式',
    AppLanguage.en: 'Unsupported output format',
  },
  'converter.dialog.exportCompleted': {
    AppLanguage.zhHant: '匯出完成：{file}',
    AppLanguage.zhHans: '导出完成：{file}',
    AppLanguage.en: 'Export complete: {file}',
  },
  'converter.error.noDuration': {
    AppLanguage.zhHant: '無法取得媒體長度',
    AppLanguage.zhHans: '无法取得媒体长度',
    AppLanguage.en: 'Unable to determine media length',
  },
  'converter.error.invalidRange': {
    AppLanguage.zhHant: '請選擇有效的時間範圍',
    AppLanguage.zhHans: '请选择有效的时间范围',
    AppLanguage.en: 'Please select a valid time range',
  },
  'converter.error.imageConversionFailed': {
    AppLanguage.zhHant: '圖片轉檔失敗：{error}',
    AppLanguage.zhHans: '图片转档失败：{error}',
    AppLanguage.en: 'Image conversion failed: {error}',
  },
  'converter.status.exportCancelled': {
    AppLanguage.zhHant: '已取消匯出',
    AppLanguage.zhHans: '已取消导出',
    AppLanguage.en: 'Export canceled',
  },
  'converter.error.exportFailed': {
    AppLanguage.zhHant: '匯出失敗，請稍後再試',
    AppLanguage.zhHans: '导出失败，请稍后再试',
    AppLanguage.en: 'Export failed. Please try again later.',
  },
  'converter.error.startExportFailed': {
    AppLanguage.zhHant: '啟動轉檔失敗：{error}',
    AppLanguage.zhHans: '启动转档失败：{error}',
    AppLanguage.en: 'Failed to start conversion: {error}',
  },
  'converter.error.cancelFailed': {
    AppLanguage.zhHant: '取消失敗，請稍後再試',
    AppLanguage.zhHans: '取消失败，请稍后再试',
    AppLanguage.en: 'Cancel failed. Please try again later.',
  },
  'converter.action.exportImage': {
    AppLanguage.zhHant: '匯出轉檔圖片',
    AppLanguage.zhHans: '导出转换图片',
    AppLanguage.en: 'Export converted image',
  },
  'converter.action.exportSelected': {
    AppLanguage.zhHant: '匯出選取的{type}',
    AppLanguage.zhHans: '导出选取的{type}',
    AppLanguage.en: 'Export selected {type}',
  },
  'converter.mediaType.video': {
    AppLanguage.zhHant: '視訊',
    AppLanguage.zhHans: '视频',
    AppLanguage.en: 'video',
  },
  'converter.mediaType.audio': {
    AppLanguage.zhHant: '音訊',
    AppLanguage.zhHans: '音频',
    AppLanguage.en: 'audio',
  },
  'converter.snack.exportSaved': {
    AppLanguage.zhHant: '已匯出到：{path}',
    AppLanguage.zhHans: '已导出到：{path}',
    AppLanguage.en: 'Exported to: {path}',
  },
  'converter.error.openFileWithReason': {
    AppLanguage.zhHant: '無法開啟檔案（{error}）',
    AppLanguage.zhHans: '无法打开文件（{error}）',
    AppLanguage.en: 'Unable to open file ({error})',
  },
  'converter.error.openFileFailed': {
    AppLanguage.zhHant: '開啟檔案失敗：{error}',
    AppLanguage.zhHans: '打开文件失败：{error}',
    AppLanguage.en: 'Failed to open file: {error}',
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
  'common.cancel': {
    AppLanguage.zhHant: '取消',
    AppLanguage.zhHans: '取消',
    AppLanguage.en: 'Cancel',
  },
  'common.done': {
    AppLanguage.zhHant: '完成',
    AppLanguage.zhHans: '完成',
    AppLanguage.en: 'Done',
  },
  'common.edit': {
    AppLanguage.zhHant: '編輯',
    AppLanguage.zhHans: '编辑',
    AppLanguage.en: 'Edit',
  },
  'common.delete': {
    AppLanguage.zhHant: '刪除',
    AppLanguage.zhHans: '删除',
    AppLanguage.en: 'Delete',
  },
  'common.save': {
    AppLanguage.zhHant: '儲存',
    AppLanguage.zhHans: '保存',
    AppLanguage.en: 'Save',
  },
  'common.create': {
    AppLanguage.zhHant: '建立',
    AppLanguage.zhHans: '创建',
    AppLanguage.en: 'Create',
  },
  'common.rename': {
    AppLanguage.zhHant: '重新命名',
    AppLanguage.zhHans: '重新命名',
    AppLanguage.en: 'Rename',
  },
  'common.later': {
    AppLanguage.zhHant: '稍後',
    AppLanguage.zhHans: '稍后',
    AppLanguage.en: 'Later',
  },
  'common.unlock': {
    AppLanguage.zhHant: '解鎖',
    AppLanguage.zhHans: '解锁',
    AppLanguage.en: 'Unlock',
  },
  'common.play': {
    AppLanguage.zhHant: '播放',
    AppLanguage.zhHans: '播放',
    AppLanguage.en: 'Play',
  },
  'common.pause': {
    AppLanguage.zhHant: '暫停',
    AppLanguage.zhHans: '暂停',
    AppLanguage.en: 'Pause',
  },
  'common.open': {
    AppLanguage.zhHant: '打開',
    AppLanguage.zhHans: '打开',
    AppLanguage.en: 'Open',
  },
  'common.unknownError': {
    AppLanguage.zhHant: '未知錯誤',
    AppLanguage.zhHans: '未知错误',
    AppLanguage.en: 'Unknown error',
  },
  'media.folder.defaultName': {
    AppLanguage.zhHant: '我的下載',
    AppLanguage.zhHans: '我的下载',
    AppLanguage.en: 'My downloads',
  },
  'media.folder.unnamed': {
    AppLanguage.zhHant: '未命名資料夾',
    AppLanguage.zhHans: '未命名文件夹',
    AppLanguage.en: 'Untitled folder',
  },
  'media.folder.newDefault': {
    AppLanguage.zhHant: '新資料夾',
    AppLanguage.zhHans: '新文件夹',
    AppLanguage.en: 'New folder',
  },
  'media.folder.select': {
    AppLanguage.zhHant: '選擇資料夾',
    AppLanguage.zhHans: '选择文件夹',
    AppLanguage.en: 'Choose folder',
  },
  'media.unlock.reasonHidden': {
    AppLanguage.zhHant: '解鎖以查看隱藏媒體',
    AppLanguage.zhHans: '解锁以查看隐藏媒体',
    AppLanguage.en: 'Unlock to view hidden media',
  },
  'media.unlock.permissionTitle': {
    AppLanguage.zhHant: '需要 Face ID / Touch ID 權限',
    AppLanguage.zhHans: '需要 Face ID / Touch ID 权限',
    AppLanguage.en: 'Face ID / Touch ID permission required',
  },
  'media.unlock.permissionDescription': {
    AppLanguage.zhHant: '請在系統設定中允許 Face ID 或 Touch ID 權限，以解鎖隱藏媒體。',
    AppLanguage.zhHans: '请在系统设置中允许 Face ID 或 Touch ID 权限，以解锁隐藏媒体。',
    AppLanguage.en:
        'Please allow Face ID or Touch ID in system settings to unlock hidden media.',
  },
  'media.tab.media': {
    AppLanguage.zhHant: '媒體',
    AppLanguage.zhHans: '媒体',
    AppLanguage.en: 'Media',
  },
  'media.tab.favorites': {
    AppLanguage.zhHant: '收藏',
    AppLanguage.zhHans: '收藏',
    AppLanguage.en: 'Favorites',
  },
  'media.hidden.badge': {
    AppLanguage.zhHant: '已隱藏',
    AppLanguage.zhHans: '已隐藏',
    AppLanguage.en: 'Hidden',
  },
  'media.hidden.unlockPrompt': {
    AppLanguage.zhHant: '請使用 Face ID 或 Touch ID 解鎖',
    AppLanguage.zhHans: '请使用 Face ID 或 Touch ID 解锁',
    AppLanguage.en: 'Use Face ID or Touch ID to unlock',
  },
  'media.hidden.empty': {
    AppLanguage.zhHant: '尚無隱藏媒體',
    AppLanguage.zhHans: '尚无隐藏媒体',
    AppLanguage.en: 'No hidden media yet',
  },
  'media.empty.folder': {
    AppLanguage.zhHant: '此資料夾尚無媒體',
    AppLanguage.zhHans: '此文件夹尚无媒体',
    AppLanguage.en: 'This folder has no media yet',
  },
  'media.empty.search': {
    AppLanguage.zhHant: '沒有符合搜尋的媒體',
    AppLanguage.zhHans: '没有符合搜索的媒体',
    AppLanguage.en: 'No media matches your search',
  },
  'media.empty.favorites': {
    AppLanguage.zhHant: '尚無收藏',
    AppLanguage.zhHans: '尚无收藏',
    AppLanguage.en: 'No favorites yet',
  },
  'media.action.addFolder': {
    AppLanguage.zhHant: '新增收納',
    AppLanguage.zhHans: '新增文件夹',
    AppLanguage.en: 'Add folder',
  },
  'media.action.rescan': {
    AppLanguage.zhHant: '重新掃描',
    AppLanguage.zhHans: '重新扫描',
    AppLanguage.en: 'Rescan',
  },
  'media.action.selectAll': {
    AppLanguage.zhHant: '全選',
    AppLanguage.zhHans: '全选',
    AppLanguage.en: 'Select all',
  },
  'media.action.editName': {
    AppLanguage.zhHant: '編輯名稱',
    AppLanguage.zhHans: '编辑名称',
    AppLanguage.en: 'Edit name',
  },
  'media.action.moveTo': {
    AppLanguage.zhHant: '移動到...',
    AppLanguage.zhHans: '移动到...',
    AppLanguage.en: 'Move to...',
  },
  'media.action.editExport': {
    AppLanguage.zhHant: '編輯導出...',
    AppLanguage.zhHans: '编辑导出...',
    AppLanguage.en: 'Edit export...',
  },
  'media.action.export': {
    AppLanguage.zhHant: '匯出...',
    AppLanguage.zhHans: '导出...',
    AppLanguage.en: 'Export...',
  },
  'media.action.hide': {
    AppLanguage.zhHant: '隱藏',
    AppLanguage.zhHans: '隐藏',
    AppLanguage.en: 'Hide',
  },
  'media.action.unhide': {
    AppLanguage.zhHant: '取消隱藏',
    AppLanguage.zhHans: '取消隐藏',
    AppLanguage.en: 'Unhide',
  },
  'media.action.favorite': {
    AppLanguage.zhHant: '加入收藏',
    AppLanguage.zhHans: '加入收藏',
    AppLanguage.en: 'Add to favorites',
  },
  'media.action.unfavorite': {
    AppLanguage.zhHant: '取消收藏',
    AppLanguage.zhHans: '取消收藏',
    AppLanguage.en: 'Remove favorite',
  },
  'media.selection.count': {
    AppLanguage.zhHant: '已選取 {count} 項',
    AppLanguage.zhHans: '已选取 {count} 项',
    AppLanguage.en: 'Selected {count} item(s)',
  },
  'media.search.placeholder': {
    AppLanguage.zhHant: '搜尋名稱/檔名',
    AppLanguage.zhHans: '搜索名称/文件名',
    AppLanguage.en: 'Search name / filename',
  },
  'media.details.size': {
    AppLanguage.zhHant: '大小: {size}',
    AppLanguage.zhHans: '大小: {size}',
    AppLanguage.en: 'Size: {size}',
  },
  'media.details.duration': {
    AppLanguage.zhHant: '時長: {duration}',
    AppLanguage.zhHans: '时长: {duration}',
    AppLanguage.en: 'Duration: {duration}',
  },
  'media.reorder.up': {
    AppLanguage.zhHant: '上移',
    AppLanguage.zhHans: '上移',
    AppLanguage.en: 'Move up',
  },
  'media.reorder.down': {
    AppLanguage.zhHant: '下移',
    AppLanguage.zhHans: '下移',
    AppLanguage.en: 'Move down',
  },
  'media.state.paused': {
    AppLanguage.zhHant: '已暫停',
    AppLanguage.zhHans: '已暂停',
    AppLanguage.en: 'Paused',
  },
  'media.state.error': {
    AppLanguage.zhHant: '失敗',
    AppLanguage.zhHans: '失败',
    AppLanguage.en: 'Failed',
  },
  'media.state.done': {
    AppLanguage.zhHant: '已完成',
    AppLanguage.zhHans: '已完成',
    AppLanguage.en: 'Completed',
  },
  'media.state.converting': {
    AppLanguage.zhHant: '轉換中',
    AppLanguage.zhHans: '转换中',
    AppLanguage.en: 'Converting',
  },
  'media.state.downloading': {
    AppLanguage.zhHant: '下載中',
    AppLanguage.zhHans: '下载中',
    AppLanguage.en: 'Downloading',
  },
  'media.state.queued': {
    AppLanguage.zhHant: '排隊中',
    AppLanguage.zhHans: '排队中',
    AppLanguage.en: 'Queued',
  },
  'media.error.incompleteFile': {
    AppLanguage.zhHant: '檔案尚未完成或已損毀',
    AppLanguage.zhHans: '文件尚未完成或已损坏',
    AppLanguage.en: 'File is incomplete or corrupted',
  },
  'media.error.missingFile': {
    AppLanguage.zhHant: '檔案已不存在',
    AppLanguage.zhHans: '文件已不存在',
    AppLanguage.en: 'File no longer exists',
  },
  'media.error.photoPermissionDenied': {
    AppLanguage.zhHant: '相簿權限被拒絕',
    AppLanguage.zhHans: '相册权限被拒绝',
    AppLanguage.en: 'Photo access was denied',
  },
  'media.snack.moved': {
    AppLanguage.zhHant: '已移動到 {folder}',
    AppLanguage.zhHans: '已移动到 {folder}',
    AppLanguage.en: 'Moved to {folder}',
  },
  'media.snack.noExportable': {
    AppLanguage.zhHant: '沒有可匯出的檔案',
    AppLanguage.zhHans: '没有可导出的文件',
    AppLanguage.en: 'No files available to export',
  },
  'media.snack.hiddenCount': {
    AppLanguage.zhHant: '已隱藏 {count} 項',
    AppLanguage.zhHans: '已隐藏 {count} 项',
    AppLanguage.en: 'Hidden {count} item(s)',
  },
  'media.snack.unhiddenCount': {
    AppLanguage.zhHant: '已取消隱藏 {count} 項',
    AppLanguage.zhHans: '已取消隐藏 {count} 项',
    AppLanguage.en: 'Unhid {count} item(s)',
  },
  'media.dialog.deleteSelected.title': {
    AppLanguage.zhHant: '刪除已選取的檔案',
    AppLanguage.zhHans: '删除已选取的文件',
    AppLanguage.en: 'Delete selected files',
  },
  'media.dialog.deleteSelected.message': {
    AppLanguage.zhHant: '確定要刪除 {count} 項嗎？',
    AppLanguage.zhHans: '确定要删除 {count} 项吗？',
    AppLanguage.en: 'Delete {count} item(s)?',
  },
  'media.dialog.renameFolder.title': {
    AppLanguage.zhHant: '重新命名資料夾',
    AppLanguage.zhHans: '重新命名文件夹',
    AppLanguage.en: 'Rename folder',
  },
  'media.dialog.deleteFolder.title': {
    AppLanguage.zhHant: '刪除資料夾',
    AppLanguage.zhHans: '删除文件夹',
    AppLanguage.en: 'Delete folder',
  },
  'media.dialog.deleteFolder.message': {
    AppLanguage.zhHant: '確定要刪除「{name}」嗎？其中的檔案會移至{defaultFolder}。',
    AppLanguage.zhHans: '确定要删除「{name}」吗？其中的文件会移至{defaultFolder}。',
    AppLanguage.en:
        'Delete “{name}”? Files inside will be moved to {defaultFolder}.',
  },
  'media.dialog.createFolder.title': {
    AppLanguage.zhHant: '新增資料夾',
    AppLanguage.zhHans: '新增文件夹',
    AppLanguage.en: 'Create folder',
  },
  'media.prompt.enterNewName': {
    AppLanguage.zhHant: '輸入新的名稱',
    AppLanguage.zhHans: '输入新的名称',
    AppLanguage.en: 'Enter a new name',
  },
  'media.prompt.folderName': {
    AppLanguage.zhHant: '輸入資料夾名稱',
    AppLanguage.zhHans: '输入文件夹名称',
    AppLanguage.en: 'Enter folder name',
  },
  'media.youtube.audioOption': {
    AppLanguage.zhHant: '音訊 {kbps}kbps {codec}',
    AppLanguage.zhHans: '音讯 {kbps}kbps {codec}',
    AppLanguage.en: 'Audio {kbps}kbps {codec}',
  },
  'download.error.playFirst': {
    AppLanguage.zhHant: '無法下載：請先播放幾秒讓嗅探到串流網址。',
    AppLanguage.zhHans: '无法下载：请先播放几秒让嗅探到串流网址。',
    AppLanguage.en:
        'Unable to download. Play the video for a few seconds so the stream URL can be detected.',
  },
  'download.error.enqueueFailed': {
    AppLanguage.zhHant: '加入佇列失敗：{error}',
    AppLanguage.zhHans: '加入队列失败：{error}',
    AppLanguage.en: 'Failed to queue download: {error}',
  },
  'download.progress.sanitizingHls': {
    AppLanguage.zhHant: '準備中：清洗 HLS…',
    AppLanguage.zhHans: '准备中：清洗 HLS…',
    AppLanguage.en: 'Preparing: sanitising HLS…',
  },
  'locker.reason.privateMedia': {
    AppLanguage.zhHant: '解鎖以查看私人影片',
    AppLanguage.zhHans: '解锁以查看私人影片',
    AppLanguage.en: 'Unlock to view private videos',
  },
  'share.importPreview.title': {
    AppLanguage.zhHant: '匯入預覽',
    AppLanguage.zhHans: '导入预览',
    AppLanguage.en: 'Import preview',
  },
  'share.importPreview.action.import': {
    AppLanguage.zhHant: '匯入',
    AppLanguage.zhHans: '导入',
    AppLanguage.en: 'Import',
  },
  'share.importPreview.snack.discarded': {
    AppLanguage.zhHant: '已丟棄 {name}',
    AppLanguage.zhHans: '已丢弃 {name}',
    AppLanguage.en: 'Discarded {name}',
  },
  'share.importPreview.snack.allDiscarded': {
    AppLanguage.zhHant: '所有項目已丟棄',
    AppLanguage.zhHans: '所有项目已丢弃',
    AppLanguage.en: 'All items discarded',
  },
  'share.importPreview.hint.swipe': {
    AppLanguage.zhHant: '左右滑動以檢視所有項目',
    AppLanguage.zhHans: '左右滑动以检视所有项目',
    AppLanguage.en: 'Swipe left or right to view all items',
  },
  'share.importPreview.hint.preview': {
    AppLanguage.zhHant: '預覽內容',
    AppLanguage.zhHans: '预览内容',
    AppLanguage.en: 'Preview',
  },
  'share.importPreview.action.discard': {
    AppLanguage.zhHant: '丟棄此項目',
    AppLanguage.zhHans: '丢弃此项目',
    AppLanguage.en: 'Discard this item',
  },
  'share.importPreview.status.saving': {
    AppLanguage.zhHant: '保存中...',
    AppLanguage.zhHans: '保存中...',
    AppLanguage.en: 'Saving…',
  },
  'share.importPreview.status.cancelling': {
    AppLanguage.zhHant: '取消中...',
    AppLanguage.zhHans: '取消中...',
    AppLanguage.en: 'Cancelling…',
  },
  'share.importPreview.empty': {
    AppLanguage.zhHant: '沒有可匯入的項目',
    AppLanguage.zhHans: '没有可导入的项目',
    AppLanguage.en: 'Nothing available to import',
  },
  'share.importPreview.emptyDescription': {
    AppLanguage.zhHant: '請返回並重新選擇分享的內容。',
    AppLanguage.zhHans: '请返回并重新选择分享的内容。',
    AppLanguage.en: 'Go back and choose content to share again.',
  },
  'share.importPreview.error.importFailed': {
    AppLanguage.zhHant: '匯入失敗：{error}',
    AppLanguage.zhHans: '导入失败：{error}',
    AppLanguage.en: 'Import failed: {error}',
  },
  'share.importPreview.error.cancelFailed': {
    AppLanguage.zhHant: '取消匯入失敗：{error}',
    AppLanguage.zhHans: '取消导入失败：{error}',
    AppLanguage.en: 'Failed to cancel import: {error}',
  },
  'share.importPreview.audioLoadFailed': {
    AppLanguage.zhHant: '音訊載入失敗',
    AppLanguage.zhHans: '音讯载入失败',
    AppLanguage.en: 'Failed to load audio',
  },
  'share.importPreview.videoLoadFailed': {
    AppLanguage.zhHant: '影片載入失敗',
    AppLanguage.zhHans: '影片载入失败',
    AppLanguage.en: 'Failed to load video',
  },
  'share.importPreview.error.fileNotFound': {
    AppLanguage.zhHant: '找不到檔案',
    AppLanguage.zhHans: '找不到档案',
    AppLanguage.en: 'File not found',
  },
  'share.importPreview.error.openFile': {
    AppLanguage.zhHant: '無法開啟檔案：{message}',
    AppLanguage.zhHans: '无法开启档案：{message}',
    AppLanguage.en: 'Unable to open file: {message}',
  },
  'browser.download.defaultFolder': {
    AppLanguage.zhHant: '我的下載',
    AppLanguage.zhHans: '我的下载',
    AppLanguage.en: 'My downloads',
  },
  'browser.download.status.processing': {
    AppLanguage.zhHant: '處理中…',
    AppLanguage.zhHans: '处理中…',
    AppLanguage.en: 'Processing…',
  },
  'browser.miniPlayer.error.openFailed': {
    AppLanguage.zhHant: '無法開啟迷你播放器',
    AppLanguage.zhHans: '无法开启迷你播放器',
    AppLanguage.en: 'Unable to open mini player',
  },
  'browser.miniPlayer.tooltip.rewind15': {
    AppLanguage.zhHant: '後退 15 秒',
    AppLanguage.zhHans: '后退 15 秒',
    AppLanguage.en: 'Rewind 15 seconds',
  },
  'browser.miniPlayer.tooltip.playPause': {
    AppLanguage.zhHant: '播放/暫停',
    AppLanguage.zhHans: '播放/暂停',
    AppLanguage.en: 'Play/Pause',
  },
  'browser.miniPlayer.tooltip.forward15': {
    AppLanguage.zhHant: '快轉 15 秒',
    AppLanguage.zhHans: '快进 15 秒',
    AppLanguage.en: 'Forward 15 seconds',
  },
  'browser.dialog.downloadQuality.title': {
    AppLanguage.zhHant: '選擇下載品質',
    AppLanguage.zhHans: '选择下载品质',
    AppLanguage.en: 'Select download quality',
  },
  'browser.dialog.downloadQuality.subtitle': {
    AppLanguage.zhHant: '已擷取到可下載串流，選擇一個品質/種類即可開始下載',
    AppLanguage.zhHans: '已捕获到可下载串流，选择一个品质/种类即可开始下载',
    AppLanguage.en:
        'Detected downloadable streams. Choose a quality/type to start downloading.',
  },
  'browser.snack.addedDownload': {
    AppLanguage.zhHant: '已加入下載',
    AppLanguage.zhHans: '已加入下载',
    AppLanguage.en: 'Added to downloads',
  },
  'browser.snack.copiedLink': {
    AppLanguage.zhHant: '已複製連結',
    AppLanguage.zhHans: '已复制链接',
    AppLanguage.en: 'Link copied',
  },
  'browser.snack.openedNewTab': {
    AppLanguage.zhHant: '已在新分頁開啟',
    AppLanguage.zhHans: '已在新分页打开',
    AppLanguage.en: 'Opened in a new tab',
  },
  'browser.snack.alreadyFavorited': {
    AppLanguage.zhHant: '網址已在收藏',
    AppLanguage.zhHans: '网址已在收藏',
    AppLanguage.en: 'Already in favorites',
  },
  'browser.snack.addedFavorite': {
    AppLanguage.zhHant: '已加入收藏',
    AppLanguage.zhHans: '已加入收藏',
    AppLanguage.en: 'Added to favorites',
  },
  'browser.snack.blockedPopup': {
    AppLanguage.zhHant: '已阻擋彈出視窗',
    AppLanguage.zhHans: '已阻挡弹出窗口',
    AppLanguage.en: 'Pop-up blocked',
  },
  'browser.snack.blockExternal.blocked': {
    AppLanguage.zhHant: '已阻止網頁打開第三方 App({app})',
    AppLanguage.zhHans: '已阻止网页打开第三方 App({app})',
    AppLanguage.en: 'Blocked the page from opening external app ({app})',
  },
  'browser.snack.blockExternal.openedNewTab': {
    AppLanguage.zhHant: '已阻止網頁打開第三方 App({app})，已在新分頁開啟網頁內容',
    AppLanguage.zhHans: '已阻止网页打开第三方 App({app})，已在新分页打开网页内容',
    AppLanguage.en:
        'Blocked the page from opening external app ({app}); opened content in a new tab.',
  },
  'browser.snack.blockExternal.webFallback': {
    AppLanguage.zhHant: '已阻止網頁打開第三方 App({app})，改以網頁顯示內容',
    AppLanguage.zhHans: '已阻止网页打开第三方 App({app})，改以网页显示内容',
    AppLanguage.en:
        'Blocked the page from opening external app ({app}); showing content in the web view instead.',
  },
  'browser.context.copyLink': {
    AppLanguage.zhHant: '複製連結',
    AppLanguage.zhHans: '复制链接',
    AppLanguage.en: 'Copy link',
  },
  'browser.context.downloadLink': {
    AppLanguage.zhHant: '下載連結網址',
    AppLanguage.zhHans: '下载链接网址',
    AppLanguage.en: 'Download link URL',
  },
  'browser.context.openInNewTab': {
    AppLanguage.zhHant: '在新分頁開啟',
    AppLanguage.zhHans: '在新分页打开',
    AppLanguage.en: 'Open in new tab',
  },
  'browser.context.addFavorite': {
    AppLanguage.zhHant: '收藏網址',
    AppLanguage.zhHans: '收藏网址',
    AppLanguage.en: 'Add to favorites',
  },
  'browser.context.addHome': {
    AppLanguage.zhHant: '加入主頁',
    AppLanguage.zhHans: '加入主页',
    AppLanguage.en: 'Add to home',
  },
  'browser.dialog.selectFolder': {
    AppLanguage.zhHant: '選擇資料夾',
    AppLanguage.zhHans: '选择文件夹',
    AppLanguage.en: 'Select folder',
  },
  'browser.shortcuts.emptyHint': {
    AppLanguage.zhHant: '尚未添加任何捷徑\n使用 + 按鈕新增網址到主頁',
    AppLanguage.zhHans: '尚未添加任何捷径\n使用 + 按钮新增网址到主页',
    AppLanguage.en: 'No shortcuts yet\nUse the + button to add sites to Home',
  },
  'browser.shortcuts.editShortcut': {
    AppLanguage.zhHant: '編輯捷徑',
    AppLanguage.zhHans: '编辑捷径',
    AppLanguage.en: 'Edit shortcut',
  },
  'browser.shortcuts.addShortcutTitle': {
    AppLanguage.zhHant: '新增捷徑到主頁',
    AppLanguage.zhHans: '新增捷径到主页',
    AppLanguage.en: 'Add shortcut to Home',
  },
  'browser.tab.newTabTitle': {
    AppLanguage.zhHant: '新分頁',
    AppLanguage.zhHans: '新分页',
    AppLanguage.en: 'New tab',
  },
  'browser.tabManager.addTab': {
    AppLanguage.zhHant: '新增分頁',
    AppLanguage.zhHans: '新增分页',
    AppLanguage.en: 'Add tab',
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

/// Mixin that allows a [StatefulWidget] to automatically rebuild whenever the
/// user changes the application language from settings. Pages that display
/// localized text should apply this mixin so that strings update immediately
/// after the preference switches.
mixin LanguageAwareState<T extends StatefulWidget> on State<T> {
  @protected
  void onLanguageChanged() {}

  void _handleLanguageChanged() {
    if (!mounted) {
      return;
    }
    setState(onLanguageChanged);
  }

  @override
  void initState() {
    super.initState();
    LanguageService.instance.languageListenable.addListener(
      _handleLanguageChanged,
    );
  }

  @override
  void dispose() {
    LanguageService.instance.languageListenable.removeListener(
      _handleLanguageChanged,
    );
    super.dispose();
  }
}

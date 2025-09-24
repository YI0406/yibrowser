import 'package:flutter/material.dart';
import 'soure.dart';
import 'dart:io' show Platform;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:photo_manager/photo_manager.dart';
import 'iap.dart';

/// SettingPage exposes preferences such as whether downloads are
/// automatically saved to the photo album and provides a way to clear
/// temporary cache. It also includes static information like the
/// copyright notice and about section.
class SettingPage extends StatefulWidget {
  const SettingPage({super.key});

  @override
  State<SettingPage> createState() => _SettingPageState();
}

class _SettingPageState extends State<SettingPage> {
  String _cacheSize = '';
  String? _uaMode; // 'iphone' | 'ipad' | 'android'
  bool _uaLoaded = false;
  String? _searchEngine;
  static const Map<String, String> _uaLabel = {
    'iphone': 'iPhone',
    'ipad': 'iPad',
    'android': 'Android',
    'windows': 'Windows',
  };
  static const Map<String, String> _searchEngineLabel = {
    'google': 'Google',
    'bing': 'Bing',
    'yahoo': 'Yahoo',
    'duckduckgo': 'DuckDuckGo',
    'baidu': 'Baidu',
  };

  @override
  void initState() {
    super.initState();
    _refreshCacheSize();
    _loadUaMode();
    _loadSearchEngine();
    // Ensure default OFF only once, and remind about photo permission on open.
    _ensureAutoSaveDefaultOff();
    _checkPhotoPermissionOnOpen();
  }

  Future<void> _loadSearchEngine() async {
    final sp = await SharedPreferences.getInstance();
    String? v = sp.getString('search_engine');
    v ??= 'google'; // default to Google
    await sp.setString('search_engine', v);
    if (!mounted) return;
    setState(() {
      _searchEngine = v;
    });
  }

  Future<void> _saveSearchEngine(String v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('search_engine', v);
    if (!mounted) return;
    setState(() => _searchEngine = v);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 1),
        content: Text('已設定搜尋引擎：${_searchEngineLabel[v]}'),
      ),
    );
  }

  Future<void> _loadUaMode() async {
    final sp = await SharedPreferences.getInstance();
    String? v = sp.getString('ua_mode');
    if (v == null) {
      // Decide default once if there is no saved value
      if (Platform.isIOS) {
        // iOS 一律預設 iPhone（包含 iPad 裝置）
        v = 'iphone';
      } else if (Platform.isAndroid) {
        v = 'android';
      } else {
        v = 'iphone';
      }
      await sp.setString('ua_mode', v);
    }
    if (!mounted) return;
    setState(() {
      _uaMode = v;
      _uaLoaded = true;
    });
  }

  Future<void> _saveUaMode(String v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('ua_mode', v);
    if (!mounted) return;
    setState(() => _uaMode = v);
    uaNotifier.value = v; // 立刻通知瀏覽器改 UA
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 1),
        content: Text('已設定 UA：${_uaLabel[v]}（重啟後保留）'),
      ),
    );
  }

  /// Convert a byte count into a human‑readable string.
  String _formatSize(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    double size = bytes.toDouble();
    int unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    return '${size.toStringAsFixed(2)} ${units[unit]}';
  }

  Future<void> _refreshCacheSize() async {
    final repo = AppRepo.I;
    final bytes = await repo.getCacheSize();
    if (!mounted) return;
    setState(() {
      _cacheSize = _formatSize(bytes);
    });
  }

  /// Ensure "Auto save to gallery" defaults to OFF on first launch,
  /// and never overrides user's later preference.
  Future<void> _ensureAutoSaveDefaultOff() async {
    final sp = await SharedPreferences.getInstance();
    // Use an initialization marker so we don't clobber user's choice later.
    const initKey = 'auto_save_initialized';
    final inited = sp.getBool(initKey) ?? false;
    if (inited) return;

    // First-time initialization -> set default OFF via AppRepo
    try {
      final repo = AppRepo.I;
      // Only set if current value is true or unknown; we want OFF by default.
      if (repo.autoSave.value != false) {
        repo.setAutoSave(false);
      }
      await sp.setBool(initKey, true);
    } catch (_) {
      // Even if AppRepo fails for any reason, mark as initialized to avoid loops.
      await sp.setBool(initKey, true);
    }
  }

  /// On page open, check photo permission; if missing, gently remind user.
  Future<void> _checkPhotoPermissionOnOpen() async {
    try {
      final perm = await PhotoManager.requestPermissionExtend();
      if (!perm.isAuth && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 2),
            content: const Text('尚未取得相簿存取權限，啟用「自動儲存到相簿」前請先到系統設定開啟。'),
            action: SnackBarAction(
              label: '前往設定',
              onPressed: () {
                PhotoManager.openSetting();
              },
            ),
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          duration: Duration(seconds: 1),
          content: Text('無法檢查相簿權限，請至系統設定確認。'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = AppRepo.I;
    // _uaMode will be set by _loadUaMode(); until then, just render the page without auto-writing defaults.
    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: ValueListenableBuilder<bool>(
              valueListenable: repo.premiumUnlocked,
              builder: (context, premium, _) {
                final purchase = PurchaseService();
                final busy = purchase.isIapActive;
                final description =
                    premium ? '高級功能已啟用，廣告已移除。' : '升級後可使用編輯導出、嗅探、匯出等進階功能並去除廣告。';
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FilledButton(
                      onPressed:
                          premium || busy
                              ? null
                              : () async {
                                final ok = await purchase.buyPremium(context);
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    duration: const Duration(seconds: 1),
                                    content: Text(
                                      ok ? '購買成功，已解鎖高級功能。' : '購買未完成',
                                    ),
                                  ),
                                );
                              },
                      child: Text(premium ? '已解鎖高級功能' : '解鎖高級功能＆去廣告'),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed:
                          busy
                              ? null
                              : () async {
                                final ok = await purchase.restore();
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    duration: const Duration(seconds: 1),
                                    content: Text(
                                      ok ? '已還原購買。' : '未找到可還原的購買紀錄。',
                                    ),
                                  ),
                                );
                              },
                      child: const Text('還原購買'),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      description,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                );
              },
            ),
          ),
          const ListTile(title: Text('一般')),
          const Divider(height: 1),
          ValueListenableBuilder<bool>(
            valueListenable: repo.premiumUnlocked,
            builder: (context, premium, _) {
              final subtitle = _uaLabel[_uaMode ?? ''] ?? '未設定';
              return ListTile(
                leading: const Icon(Icons.language_outlined),
                title: const Text('User-Agent (UA)'),
                subtitle: Text(premium ? subtitle : '$subtitle（需高級版）'),
                onTap:
                    premium
                        ? null
                        : () => PurchaseService().showPurchasePrompt(
                          context,
                          featureName: '更改 User-Agent',
                        ),
                trailing: IgnorePointer(
                  ignoring: !premium,
                  child: DropdownButton<String>(
                    value:
                        (_uaMode != null && _uaLabel.containsKey(_uaMode))
                            ? _uaMode
                            : null,
                    hint: const Text('選擇'),
                    items: const [
                      DropdownMenuItem(value: 'iphone', child: Text('iPhone')),
                      DropdownMenuItem(value: 'ipad', child: Text('iPad')),
                      DropdownMenuItem(
                        value: 'android',
                        child: Text('Android'),
                      ),
                      DropdownMenuItem(
                        value: 'windows',
                        child: Text('Windows'),
                      ),
                    ],
                    onChanged:
                        premium
                            ? (v) {
                              if (v == null) return;
                              _saveUaMode(v);
                            }
                            : null,
                  ),
                ),
              );
            },
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.search_outlined),
            title: const Text('搜尋引擎'),
            subtitle: Text(_searchEngineLabel[_searchEngine ?? ''] ?? '未設定'),
            trailing: DropdownButton<String>(
              value:
                  (_searchEngine != null &&
                          _searchEngineLabel.containsKey(_searchEngine))
                      ? _searchEngine
                      : null,
              hint: const Text('選擇'),
              items: const [
                DropdownMenuItem(value: 'google', child: Text('Google')),
                DropdownMenuItem(value: 'bing', child: Text('Bing')),
                DropdownMenuItem(value: 'yahoo', child: Text('Yahoo')),
                DropdownMenuItem(
                  value: 'duckduckgo',
                  child: Text('DuckDuckGo'),
                ),
                DropdownMenuItem(value: 'baidu', child: Text('Baidu')),
              ],
              onChanged: (v) {
                if (v == null) return;
                _saveSearchEngine(v);
              },
            ),
          ),
          const Divider(height: 1),
          // Toggle for automatic saving to gallery（需高級版）
          ValueListenableBuilder<bool>(
            valueListenable: repo.premiumUnlocked,
            builder: (context, premium, _) {
              return ValueListenableBuilder<bool>(
                valueListenable: repo.autoSave,
                builder: (_, bool on, __) {
                  var effectiveValue = on;
                  if (!premium && effectiveValue) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      repo.setAutoSave(false);
                    });
                    effectiveValue = false;
                  }
                  return SwitchListTile(
                    title: const Text('自動儲存到相簿'),
                    subtitle: premium ? null : const Text('升級高級版後才可啟用。'),
                    value: effectiveValue,
                    onChanged: (v) {
                      () async {
                        if (!premium) {
                          await PurchaseService().showPurchasePrompt(
                            context,
                            featureName: '自動儲存到相簿',
                          );
                          return;
                        }
                        if (v) {
                          try {
                            final perm =
                                await PhotoManager.requestPermissionExtend();
                            if (!perm.isAuth) {
                              repo.setAutoSave(false);
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  duration: const Duration(seconds: 2),
                                  content: const Text('自動儲存需要相簿權限，請前往設定開啟。'),
                                  action: SnackBarAction(
                                    label: '前往設定',
                                    onPressed: () {
                                      PhotoManager.openSetting();
                                    },
                                  ),
                                ),
                              );
                              return;
                            }
                          } catch (_) {
                            repo.setAutoSave(false);
                            if (!mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                duration: Duration(seconds: 1),
                                content: Text('無法確認相簿權限，請手動檢查設定。'),
                              ),
                            );
                            return;
                          }
                        }

                        repo.setAutoSave(v);
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            duration: const Duration(seconds: 1),
                            content: Text(v ? '下載完成後將自動存入相簿' : '已關閉自動存相簿'),
                          ),
                        );
                      }();
                    },
                  );
                },
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_sweep_outlined),
            title: const Text('清理快取'),
            subtitle: Text('目前快取大小：$_cacheSize'),
            onTap: () async {
              await repo.clearCache();
              await _refreshCacheSize();
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  duration: Duration(seconds: 1),
                  content: Text('已清理快取'),
                ),
              );
            },
          ),
          const Divider(height: 1),
          // Static sections
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('版權與使用聲明'),
            subtitle: const Text(
              '本應用程式僅提供技術工具，用戶的所有使用行為均與作者無關。請尊重智慧財產權，僅下載您擁有或已獲授權的內容；加密 DRM 流可能無法下載',
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('關於'),
            subtitle: const Text(
              'Yi Apps Copyright © Yi Browser \n聯絡我們: tzuyichan0406@gmail.com',
            ),
            onTap: () async {
              final Uri emailLaunchUri = Uri(
                scheme: 'mailto',
                path: 'tzuyichan0406@gmail.com',
                query: 'subject=App 聯絡&body=您好，',
              );
              if (await canLaunchUrl(emailLaunchUri)) {
                await launchUrl(emailLaunchUri);
              }
            },
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'soure.dart';
import 'dart:io' show Platform;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:photo_manager/photo_manager.dart';
import 'iap.dart';
import 'app_localizations.dart';

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
  static const Map<String, String> _uaLabelKey = {
    'iphone': 'settings.ua.option.iphone',
    'ipad': 'settings.ua.option.ipad',
    'android': 'settings.ua.option.android',
    'windows': 'settings.ua.option.windows',
  };
  static const Map<String, String> _searchEngineLabelKey = {
    'google': 'settings.searchEngine.option.google',
    'bing': 'settings.searchEngine.option.bing',
    'yahoo': 'settings.searchEngine.option.yahoo',
    'duckduckgo': 'settings.searchEngine.option.duckduckgo',
    'baidu': 'settings.searchEngine.option.baidu',
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
        content: Text(
          context.l10n(
            'settings.searchEngine.snack',
            params: {'engine': context.l10n(_searchEngineLabelKey[v]!)},
          ),
        ),
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
        content: Text(
          context.l10n(
            'settings.ua.snack',
            params: {'ua': context.l10n(_uaLabelKey[v]!)},
          ),
        ),
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
            content: Text(context.l10n('settings.photoPermission.reminder')),
            action: SnackBarAction(
              label: context.l10n('common.goToSettings'),

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
        SnackBar(
          duration: const Duration(seconds: 1),
          content: Text(context.l10n('settings.photoPermission.unableCheck')),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = AppRepo.I;
    final languageService = LanguageService.instance;
    // _uaMode will be set by _loadUaMode(); until then, just render the page without auto-writing defaults.
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n('settings.title'))),
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
                    premium
                        ? context.l10n('settings.premium.statusUnlocked')
                        : context.l10n('settings.premium.statusLocked');
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
                                final key =
                                    ok
                                        ? 'settings.premium.purchaseSuccess'
                                        : 'settings.premium.purchaseIncomplete';
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    duration: const Duration(seconds: 1),
                                    content: Text(context.l10n(key)),
                                  ),
                                );
                              },
                      child: Text(
                        context.l10n(
                          premium
                              ? 'settings.premium.button.unlocked'
                              : 'settings.premium.button.upgrade',
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed:
                          busy
                              ? null
                              : () async {
                                final ok = await purchase.restore();
                                if (!mounted) return;
                                final key =
                                    ok
                                        ? 'settings.premium.restoreSuccess'
                                        : 'settings.premium.restoreFailed';
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    duration: const Duration(seconds: 1),
                                    content: Text(context.l10n(key)),
                                  ),
                                );
                              },
                      child: Text(
                        context.l10n('settings.premium.restoreButton'),
                      ),
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
          ValueListenableBuilder<AppLanguage>(
            valueListenable: languageService.languageListenable,
            builder: (context, selectedLanguage, _) {
              return ListTile(
                leading: const Icon(Icons.translate_outlined),
                title: Text(context.l10n('settings.language.title')),
                subtitle: Text(
                  context.l10n(
                    languageService.languageNameKey(selectedLanguage),
                  ),
                ),
                trailing: DropdownButton<AppLanguage>(
                  value: selectedLanguage,
                  items:
                      AppLanguage.values
                          .map(
                            (lang) => DropdownMenuItem<AppLanguage>(
                              value: lang,
                              child: Text(
                                context.l10n(
                                  languageService.languageNameKey(lang),
                                ),
                              ),
                            ),
                          )
                          .toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    () async {
                      await languageService.setLanguage(value);
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          duration: const Duration(seconds: 1),
                          content: Text(
                            context.l10n(
                              'settings.language.snack',
                              params: {
                                'language': context.l10n(
                                  languageService.languageNameKey(value),
                                ),
                              },
                            ),
                          ),
                        ),
                      );
                    }();
                  },
                ),
              );
            },
          ),
          const Divider(height: 1),
          ListTile(title: Text(context.l10n('settings.section.general'))),
          const Divider(height: 1),
          ValueListenableBuilder<bool>(
            valueListenable: repo.premiumUnlocked,
            builder: (context, premium, _) {
              final uaKey = _uaMode != null ? _uaLabelKey[_uaMode!] : null;
              final uaText =
                  uaKey != null
                      ? context.l10n(uaKey)
                      : context.l10n('common.notSet');
              final subtitle =
                  premium
                      ? uaText
                      : '$uaText${context.l10n('settings.requiresPremiumSuffix')}';
              return ListTile(
                leading: const Icon(Icons.language_outlined),
                title: Text(context.l10n('settings.ua.title')),
                subtitle: Text(subtitle),
                onTap:
                    premium
                        ? null
                        : () => PurchaseService().showPurchasePrompt(
                          context,
                          featureName: context.l10n('settings.ua.featureName'),
                        ),
                trailing: IgnorePointer(
                  ignoring: !premium,
                  child: DropdownButton<String>(
                    value:
                        (_uaMode != null && _uaLabelKey.containsKey(_uaMode))
                            ? _uaMode
                            : null,
                    hint: Text(context.l10n('settings.action.select')),
                    items:
                        _uaLabelKey.entries
                            .map(
                              (entry) => DropdownMenuItem<String>(
                                value: entry.key,
                                child: Text(context.l10n(entry.value)),
                              ),
                            )
                            .toList(),
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
            title: Text(context.l10n('settings.searchEngine.title')),
            subtitle: Text(
              _searchEngine != null &&
                      _searchEngineLabelKey.containsKey(_searchEngine)
                  ? context.l10n(_searchEngineLabelKey[_searchEngine!]!)
                  : context.l10n('common.notSet'),
            ),
            trailing: DropdownButton<String>(
              value:
                  (_searchEngine != null &&
                          _searchEngineLabelKey.containsKey(_searchEngine))
                      ? _searchEngine
                      : null,
              hint: Text(context.l10n('settings.action.select')),
              items:
                  _searchEngineLabelKey.entries
                      .map(
                        (entry) => DropdownMenuItem<String>(
                          value: entry.key,
                          child: Text(context.l10n(entry.value)),
                        ),
                      )
                      .toList(),
              onChanged: (v) {
                if (v == null) return;
                _saveSearchEngine(v);
              },
            ),
          ),
          const Divider(height: 1),

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
                    title: Text(context.l10n('settings.autoSave.title')),
                    subtitle:
                        premium
                            ? null
                            : Text(
                              context.l10n('settings.autoSave.premiumHint'),
                            ),
                    value: effectiveValue,
                    onChanged: (v) {
                      () async {
                        if (!premium) {
                          await PurchaseService().showPurchasePrompt(
                            context,
                            featureName: context.l10n(
                              'settings.autoSave.featureName',
                            ),
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
                                  content: Text(
                                    context.l10n(
                                      'settings.autoSave.permissionRequired',
                                    ),
                                  ),
                                  action: SnackBarAction(
                                    label: context.l10n('common.goToSettings'),
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
                              SnackBar(
                                duration: const Duration(seconds: 1),
                                content: Text(
                                  context.l10n(
                                    'settings.autoSave.permissionUnknown',
                                  ),
                                ),
                              ),
                            );
                            return;
                          }
                        }

                        repo.setAutoSave(v);
                        if (!mounted) return;
                        final key =
                            v
                                ? 'settings.autoSave.snack.enabled'
                                : 'settings.autoSave.snack.disabled';
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            duration: const Duration(seconds: 1),
                            content: Text(context.l10n(key)),
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
            title: Text(context.l10n('settings.cache.title')),
            subtitle: Text(
              context.l10n(
                'settings.cache.subtitle',
                params: {'size': _cacheSize},
              ),
            ),
            onTap: () async {
              await repo.clearCache();
              await _refreshCacheSize();
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  duration: const Duration(seconds: 1),
                  content: Text(context.l10n('settings.cache.cleared')),
                ),
              );
            },
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: Text(context.l10n('settings.legal.title')),
            subtitle: Text(context.l10n('settings.legal.description')),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(context.l10n('settings.about.title')),
            subtitle: Text(context.l10n('settings.about.description')),
            onTap: () async {
              final emailLaunchUri = Uri(
                scheme: 'mailto',
                path: 'tzuyichan0406@gmail.com',
                queryParameters: {
                  'subject': context.l10n('settings.about.email.subject'),
                  'body': context.l10n('settings.about.email.body'),
                },
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

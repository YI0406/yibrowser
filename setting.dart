import 'package:flutter/material.dart';
import 'soure.dart';
import 'dart:io' show Platform;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已設定搜尋引擎：${_searchEngineLabel[v]}')));
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已設定 UA：${_uaLabel[v]}（重啟後保留）')));
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

  @override
  Widget build(BuildContext context) {
    final repo = AppRepo.I;
    // _uaMode will be set by _loadUaMode(); until then, just render the page without auto-writing defaults.
    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        children: [
          const ListTile(title: Text('一般')),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.language_outlined),
            title: const Text('User-Agent (UA)'),
            subtitle: Text(_uaLabel[_uaMode ?? ''] ?? '未設定'),
            trailing: DropdownButton<String>(
              value:
                  (_uaMode != null && _uaLabel.containsKey(_uaMode))
                      ? _uaMode
                      : null,
              hint: const Text('選擇'),
              items: const [
                DropdownMenuItem(value: 'iphone', child: Text('iPhone')),
                DropdownMenuItem(value: 'ipad', child: Text('iPad')),
                DropdownMenuItem(value: 'android', child: Text('Android')),
                DropdownMenuItem(value: 'windows', child: Text('Windows')),
              ],
              onChanged: (v) {
                if (v == null) return;
                _saveUaMode(v);
              },
            ),
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
          // Toggle for automatic saving to gallery
          ValueListenableBuilder(
            valueListenable: repo.autoSave,
            builder: (_, bool on, __) {
              return SwitchListTile(
                title: const Text('自動儲存到相簿'),
                value: on,
                onChanged: (v) {
                  repo.setAutoSave(v);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(v ? '下載完成後將自動存入相簿' : '已關閉自動存相簿')),
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
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('已清理快取')));
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

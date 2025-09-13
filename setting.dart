import 'package:flutter/material.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/log.dart';
import 'package:ffmpeg_kit_flutter_new/session.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';
import 'soure.dart';

/// SettingPage provides miscellaneous options, such as toggling automatic
/// gallery saving, viewing copyright information, and about page.
class SettingPage extends StatelessWidget {
  const SettingPage({super.key});

  @override
  Widget build(BuildContext context) {
    final repo = AppRepo.I;
    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        children: [
          const ListTile(title: Text('一般')),
          const Divider(height: 1),
          SwitchListTile(
            title: const Text('自動儲存到相簿'),
            value: true,
            onChanged: (v) {
              // This demo always auto-saves. A real app would update a preference here.
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('此範例預設已自動存相簿')));
            },
          ),
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('版權與使用聲明'),
            subtitle: const Text('請僅下載您擁有或獲授權的內容；加密 DRM 流可能無法下載'),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('關於'),
            subtitle: const Text('Sniffer Browser Demo 1.0.0'),
            onTap: () {},
          ),
        ],
      ),
    );
  }
}

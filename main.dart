import 'package:flutter/material.dart';
import 'browser.dart';
import 'media.dart';
import 'setting.dart';
import 'soure.dart';

/// Entry point of the application. Initializes WebView debugging and sets up
/// the root navigation with three tabs: browser, media, and settings.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Enable debugging for WebView content (useful during development).
  await Sniffer.initWebViewDebug();
  // Load any persisted downloads so media lists persist across restarts.
  await AppRepo.I.init();
  runApp(const MyApp());
}

/// Root widget of the app.
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
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
  int index = 0;
  // List of pages corresponding to the three navigation tabs.
  final pages = const [BrowserPage(), MediaPage(), SettingPage()];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Use IndexedStack so the state of each page persists when switching tabs.
      body: IndexedStack(index: index, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.public), label: '瀏覽器'),
          NavigationDestination(
            icon: Icon(Icons.video_library_outlined),
            label: '媒體',
          ),
          NavigationDestination(icon: Icon(Icons.settings), label: '設定'),
        ],
        onDestinationSelected: (i) => setState(() => index = i),
      ),
    );
  }
}

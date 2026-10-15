import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'm3u_files.dart';
import 'm3u_store.dart';
import 'tv_sync.dart';

const Color kAccent = Color(0xFF8B5CF6); // violet, matches the app icon
const Color kBg = Color(0xFF0F0B1E);
const Color kSurface = Color(0xFF1B1633);

ThemeData _buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF7C3AED),
    brightness: Brightness.dark,
  ).copyWith(primary: kAccent, surface: kSurface);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: kBg,
    appBarTheme: const AppBarTheme(
      backgroundColor: kBg,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Colors.white),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: kSurface,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kAccent, width: 1.6)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: kSurface,
      indicatorColor: kAccent.withOpacity(0.35),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
  );
}

void main() {
  runApp(const TubeBoxApp());
}

class TubeBoxApp extends StatelessWidget {
  const TubeBoxApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TubeBox',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(),
      home: const StartupGate(),
    );
  }
}

// ============================================================================
// STARTUP: storage permission + data folder (default: Documents/TubeBox)
// ============================================================================
class StartupGate extends StatefulWidget {
  const StartupGate({Key? key}) : super(key: key);

  @override
  _StartupGateState createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> with WidgetsBindingObserver {
  String? _basePath;
  bool _loading = true;
  bool _permissionOk = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The user may have just granted "All files access" in system settings.
    if (state == AppLifecycleState.resumed && !_permissionOk) {
      _init();
    }
  }

  Future<bool> _hasStorageAccess() async {
    try {
      var status = await Permission.manageExternalStorage.status;
      if (!status.isGranted) status = await Permission.manageExternalStorage.request();
      if (status.isGranted) return true;
    } catch (_) {}
    try {
      var s = await Permission.storage.status;
      if (!s.isGranted) s = await Permission.storage.request();
      if (s.isGranted) return true;
    } catch (_) {}
    return false;
  }

  Future<void> _init() async {
    final ok = await _hasStorageAccess();
    final prefs = await SharedPreferences.getInstance();
    String? saved = prefs.getString('saved_base_path');
    if (ok && saved == null) {
      // First start: use a sensible default so nobody has to pick a folder.
      try {
        final d = Directory(kDefaultFolder);
        if (!await d.exists()) await d.create(recursive: true);
        saved = kDefaultFolder;
        await prefs.setString('saved_base_path', saved);
      } catch (_) {
        saved = null;
      }
    }
    // A folder inside the app's own storage needs no permission.
    final appOwned = saved != null && saved.contains('/Android/data/');
    if (!mounted) return;
    setState(() {
      _permissionOk = ok || appOwned;
      _basePath = (ok || appOwned) ? saved : null;
      _loading = false;
    });
  }

  Future<void> _pickFolder() async {
    try {
      final String? dir = await FilePicker.platform.getDirectoryPath();
      if (dir == null) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('saved_base_path', dir);
      if (!mounted) return;
      setState(() => _basePath = dir);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open the folder picker: $e')));
    }
  }

  Future<void> _useAppFolder() async {
    try {
      final ext = await getExternalStorageDirectory();
      final dir = ext ?? await getApplicationDocumentsDirectory();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('saved_base_path', dir.path);
      if (!mounted) return;
      setState(() {
        _basePath = dir.path;
        _permissionOk = true;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not use the app folder: $e')));
    }
  }

  Widget _centered(List<Widget> children) {
    return Scaffold(
      appBar: AppBar(title: const Text('TubeBox')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: Image.asset('assets/logo.png', width: 96, height: 96),
              ),
              const SizedBox(height: 20),
              ...children,
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_basePath == null && !_permissionOk) {
      return _centered([
        const Text(
          'TubeBox needs access to files so it can save your .m3u playlists.\nPlease allow "All files access".',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        FilledButton.icon(onPressed: openAppSettings, icon: const Icon(Icons.settings), label: const Text('Open Settings')),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: _init, child: const Text('I allowed it - try again')),
        TextButton(onPressed: _useAppFolder, child: const Text("Skip: use the app's own folder")),
      ]);
    }

    if (_basePath == null) {
      return _centered([
        const Text(
          'Choose the folder where your .m3u files will be saved.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        FilledButton.icon(onPressed: _pickFolder, icon: const Icon(Icons.folder), label: const Text('Choose Folder')),
        TextButton(onPressed: _useAppFolder, child: const Text("Use the app's own folder")),
      ]);
    }

    return HomeShell(key: ValueKey(_basePath), basePath: _basePath!, onChangeFolder: _pickFolder);
  }
}

// ============================================================================
// HOME: M3U Files + TV Sync. The bottom bar slides away while scrolling down
// (content only, like YouTube) and returns as soon as you scroll up.
// ============================================================================
class HomeShell extends StatefulWidget {
  final String basePath;
  final VoidCallback onChangeFolder;
  const HomeShell({Key? key, required this.basePath, required this.onChangeFolder}) : super(key: key);

  @override
  _HomeShellState createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  final ValueNotifier<bool> _navVisible = ValueNotifier<bool>(true);

  @override
  void initState() {
    super.initState();
    _maybeStartReceiver();
  }

  @override
  void dispose() {
    _navVisible.dispose();
    super.dispose();
  }

  /// If this device was set to "Receive on TV" last time, listen again at once.
  Future<void> _maybeStartReceiver() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('tv_receive') ?? false) {
        await TvReceiver.instance.start(widget.basePath);
      }
    } catch (_) {}
  }

  void _go(int i) {
    _navVisible.value = true;
    setState(() => _index = i);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          M3uFilesScreen(
            basePath: widget.basePath,
            navVisible: _navVisible,
            onGoToTvSync: () => _go(1),
          ),
          TvSyncScreen(basePath: widget.basePath, onChangeFolder: widget.onChangeFolder),
        ],
      ),
      bottomNavigationBar: ValueListenableBuilder<bool>(
        valueListenable: _navVisible,
        builder: (context, visible, _) => AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: visible
              ? NavigationBar(
                  selectedIndex: _index,
                  onDestinationSelected: _go,
                  destinations: const [
                    NavigationDestination(icon: Icon(Icons.video_library_outlined), selectedIcon: Icon(Icons.video_library), label: 'M3U Files'),
                    NavigationDestination(icon: Icon(Icons.cast_connected_outlined), selectedIcon: Icon(Icons.cast_connected), label: 'TV Sync'),
                  ],
                )
              : const SizedBox(width: double.infinity),
        ),
      ),
    );
  }
}

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'prefs.dart';

import 'm3u_files.dart';
import 'm3u_store.dart';
import 'tv_sync.dart';

const Color kAccent = Color(0xFF8B5CF6); // violet, matches the app icon
const Color kBg = Color(0xFF0F0B1E);
const Color kSurface = Color(0xFF1B1633);

ButtonStyle _focusRing() => ButtonStyle(
      side: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.focused) ? const BorderSide(color: Colors.white, width: 3) : null),
      minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
    );

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
      side: WidgetStateBorderSide.resolveWith((states) =>
          states.contains(WidgetState.focused) ? const BorderSide(color: Colors.white, width: 3) : BorderSide.none),
    ),
    // Remote-control friendly: every focused control gets a thick white ring.
    focusColor: Colors.white24,
    filledButtonTheme: FilledButtonThemeData(style: _focusRing()),
    outlinedButtonTheme: OutlinedButtonThemeData(style: _focusRing()),
    textButtonTheme: TextButtonThemeData(style: _focusRing()),
    iconButtonTheme: IconButtonThemeData(style: _focusRing()),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      focusColor: Colors.white30,
      focusElevation: 12,
      extendedPadding: EdgeInsets.symmetric(horizontal: 22),
    ),
  );
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // If anything breaks, show the reason on screen instead of a blank page.
  ErrorWidget.builder = (details) => Material(
        color: const Color(0xFF3B1D1D),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(child: Text('TubeBox error:\n${details.exceptionAsString()}', style: const TextStyle(color: Colors.white, fontSize: 14))),
        ),
      );
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

  /// Never blocks: a fresh install on a TV has no "All files access" page, so
  /// asking is only done when the user taps the button (with a time limit).
  Future<bool> _hasStorageAccess({bool ask = false}) async {
    const limit = Duration(seconds: 4);
    try {
      var status = await Permission.manageExternalStorage.status.timeout(limit);
      if (!status.isGranted && ask) status = await Permission.manageExternalStorage.request().timeout(const Duration(seconds: 25));
      if (status.isGranted) return true;
    } catch (_) {}
    try {
      var s = await Permission.storage.status.timeout(limit);
      if (!s.isGranted && ask) s = await Permission.storage.request().timeout(const Duration(seconds: 25));
      if (s.isGranted) return true;
    } catch (_) {}
    return false;
  }

  String _step = 'Starting...';
  String? _fatal;

  Future<void> _init({bool ask = false}) async {
    try {
      await _initInner(ask).timeout(const Duration(seconds: 30));
    } catch (e) {
      // Never stay on the spinner: show what went wrong and offer a way in.
      if (mounted) {
        setState(() {
          _loading = false;
          _fatal = '$e (step: $_step)';
        });
      }
    }
  }

  Future<void> _initInner(bool ask) async {
    if (mounted) setState(() => _step = 'Checking file access...');
    final ok = await _hasStorageAccess(ask: ask);
    if (mounted) setState(() => _step = 'Reading settings...');
    final prefs = await SharedPreferences.getInstance().timeout(const Duration(seconds: 10));
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
      _fatal = null;
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
      return Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(_step, style: const TextStyle(color: Colors.white54)),
          ]),
        ),
      );
    }
    if (_fatal != null && _basePath == null) {
      return _centered([
        Text('TubeBox could not start:\n$_fatal', textAlign: TextAlign.center),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () {
            setState(() {
              _fatal = null;
              _loading = true;
            });
            _init();
          },
          child: const Text('Try again'),
        ),
        TextButton(onPressed: _useAppFolder, child: const Text("Use the app's own folder")),
      ]);
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
        FilledButton.tonal(onPressed: () => _init(ask: true), child: const Text('Allow file access')),
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
  final ValueNotifier<int> _searchRequest = ValueNotifier<int>(0);
  // TV side menu buttons: 0 search, 1 home, 2 TV sync, 3 folder.
  final List<FocusNode> _railNodes = List.generate(4, (i) => FocusNode(debugLabel: 'rail-$i'));
  bool _asking = false;

  @override
  void initState() {
    super.initState();
    _maybeStartReceiver();
  }

  @override
  void dispose() {
    _navVisible.dispose();
    _searchRequest.dispose();
    for (final n in _railNodes) {
      n.dispose();
    }
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

  /// Back: other tab -> first tab, first tab -> "Exit TubeBox?" question.
  Future<void> _onBack() async {
    if (_index != 0) {
      _go(0);
      return;
    }
    if (_asking) return;
    _asking = true;
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Exit TubeBox?'),
        content: const Text('Do you want to close the app?'),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.of(c).pop(false), child: const Text('Stay')),
          FilledButton(onPressed: () => Navigator.of(c).pop(true), child: const Text('Exit')),
        ],
      ),
    );
    _asking = false;
    if (yes == true) SystemNavigator.pop();
  }

  Widget _pages(bool tv) {
    final pages = [
      M3uFilesScreen(
        basePath: widget.basePath,
        navVisible: _navVisible,
        onGoToTvSync: () => _go(1),
        searchRequest: _searchRequest,
        railInset: tv ? _kRailWidth : 0,
      ),
      TvSyncScreen(basePath: widget.basePath, onChangeFolder: widget.onChangeFolder),
    ];
    return IndexedStack(
      index: _index,
      children: [for (int i = 0; i < pages.length; i++) ExcludeFocus(excluding: i != _index, child: pages[i])],
    );
  }

  /// TV: Left from the first column of the content opens the side menu and
  /// lands on the current page's button (like the YouTube TV app).
  KeyEventResult _contentKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.arrowLeft) return KeyEventResult.ignored;
    final pf = FocusManager.instance.primaryFocus;
    if (pf == null) return KeyEventResult.ignored;
    // Let text fields keep their cursor keys.
    if (pf.context?.findAncestorWidgetOfExactType<EditableText>() != null) return KeyEventResult.ignored;
    final moved = pf.focusInDirection(TraversalDirection.left);
    if (moved && _railNodes.any((n) => n.hasPrimaryFocus)) {
      _railNodes[_index + 1].requestFocus();
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final tv = size.width >= 900 && size.width > size.height;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _onBack();
      },
      child: tv ? _tvLayout() : _phoneLayout(),
    );
  }

  Widget _tvLayout() {
    return Scaffold(
      body: Stack(children: [
        Positioned.fill(
          left: _kRailWidth,
          child: Focus(canRequestFocus: false, skipTraversal: true, onKeyEvent: _contentKey, child: _pages(true)),
        ),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          child: _TvRail(
            selected: _index,
            nodes: _railNodes,
            onSearch: () {
              _go(0);
              _searchRequest.value++;
            },
            onHome: () => _go(0),
            onSync: () => _go(1),
            onFolder: widget.onChangeFolder,
          ),
        ),
      ]),
    );
  }

  Widget _phoneLayout() {
    return Scaffold(
      body: _pages(false),
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

const double _kRailWidth = 76;

// ============================================================================
// TV SIDE MENU (like the YouTube TV app): a slim icon strip on the left. When
// the remote focuses it, it opens with names; Right / Back returns to content.
// ============================================================================
class _TvRail extends StatefulWidget {
  final int selected;
  final List<FocusNode> nodes;
  final VoidCallback onSearch, onHome, onSync, onFolder;
  const _TvRail({
    Key? key,
    required this.selected,
    required this.nodes,
    required this.onSearch,
    required this.onHome,
    required this.onSync,
    required this.onFolder,
  }) : super(key: key);

  @override
  State<_TvRail> createState() => _TvRailState();
}

class _TvRailState extends State<_TvRail> {
  bool _open = false;

  Widget _item(int n, IconData icon, IconData activeIcon, String label, VoidCallback onTap, {bool selected = false}) {
    return _RailButton(node: widget.nodes[n], icon: selected ? activeIcon : icon, label: label, open: _open, selected: selected, onTap: onTap);
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (f) {
        if (f != _open) setState(() => _open = f);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        width: _open ? 270 : _kRailWidth,
        decoration: BoxDecoration(
          gradient: _open
              ? const LinearGradient(colors: [Color(0xF2080614), Color(0xE6080614), Color(0x00080614)], stops: [0, 0.8, 1])
              : null,
          color: _open ? null : kBg.withOpacity(0.0),
        ),
        padding: const EdgeInsets.fromLTRB(10, 18, 10, 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(left: 8, bottom: 14),
            child: Row(children: [
              ClipRRect(borderRadius: BorderRadius.circular(10), child: Image.asset('assets/logo.png', width: 40, height: 40)),
              if (_open) const Flexible(child: Padding(padding: EdgeInsets.only(left: 12), child: Text('TubeBox', maxLines: 1, softWrap: false, overflow: TextOverflow.clip, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)))),
            ]),
          ),
          _item(0, Icons.search, Icons.search, 'Search', widget.onSearch),
          _item(1, Icons.home_outlined, Icons.home, 'Home', widget.onHome, selected: widget.selected == 0),
          _item(2, Icons.cast_connected_outlined, Icons.cast_connected, 'TV Sync', widget.onSync, selected: widget.selected == 1),
          const Spacer(),
          _item(3, Icons.folder_open_outlined, Icons.folder_open, 'Change folder', widget.onFolder),
        ]),
      ),
    );
  }
}

class _RailButton extends StatefulWidget {
  final FocusNode node;
  final IconData icon;
  final String label;
  final bool open, selected;
  final VoidCallback onTap;
  const _RailButton({Key? key, required this.node, required this.icon, required this.label, required this.open, required this.selected, required this.onTap}) : super(key: key);

  @override
  State<_RailButton> createState() => _RailButtonState();
}

class _RailButtonState extends State<_RailButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final fg = _focused ? Colors.black : (widget.selected ? kAccent : Colors.white);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: _focused ? Colors.white : (widget.selected && widget.open ? Colors.white12 : Colors.transparent),
        borderRadius: BorderRadius.circular(28),
        child: InkWell(
          focusNode: widget.node,
          borderRadius: BorderRadius.circular(28),
          focusColor: Colors.transparent,
          onFocusChange: (f) => setState(() => _focused = f),
          onTap: widget.onTap,
          child: SizedBox(
            height: 52,
            child: Row(children: [
              const SizedBox(width: 14),
              Icon(widget.icon, color: fg, size: 26),
              if (widget.open)
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 14, right: 10),
                    child: Text(widget.label, maxLines: 1, softWrap: false, overflow: TextOverflow.clip, style: TextStyle(color: fg, fontSize: 17, fontWeight: FontWeight.w600)),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

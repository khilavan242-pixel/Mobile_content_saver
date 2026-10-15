import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'youtube_lists.dart';

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
  runApp(const KodiTvManagerApp());
}

class KodiTvManagerApp extends StatelessWidget {
  const KodiTvManagerApp({Key? key}) : super(key: key);

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
// STARTUP: storage permission + choose the Kodi folder (remembered)
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
    // User may have just granted "All files access" in system settings.
    if (state == AppLifecycleState.resumed && !_permissionOk) {
      _init();
    }
  }

  Future<void> _init() async {
    var status = await Permission.manageExternalStorage.status;
    if (!status.isGranted) {
      status = await Permission.manageExternalStorage.request();
    }
    String? saved;
    if (status.isGranted) {
      final prefs = await SharedPreferences.getInstance();
      saved = prefs.getString('saved_base_path');
    }
    if (!mounted) return;
    setState(() {
      _permissionOk = status.isGranted;
      _basePath = saved;
      _loading = false;
    });
  }

  Future<void> _pickFolder() async {
    final String? dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_base_path', dir);
    if (!mounted) return;
    setState(() => _basePath = dir);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (!_permissionOk) {
      return Scaffold(
        appBar: AppBar(title: const Text("TubeBox")),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset('assets/logo.png', width: 96, height: 96),
                const SizedBox(height: 12),
                const Icon(Icons.folder_off, size: 36, color: Colors.orangeAccent),
                const SizedBox(height: 16),
                const Text(
                  "Storage access is needed to save your playlist and YouTube lists.\nPlease allow \"All files access\".",
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                ElevatedButton(onPressed: openAppSettings, child: const Text("Open Settings")),
                TextButton(onPressed: _init, child: const Text("Try again")),
              ],
            ),
          ),
        ),
      );
    }

    if (_basePath == null) {
      return Scaffold(
        appBar: AppBar(title: const Text("TubeBox")),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset('assets/logo.png', width: 96, height: 96),
                const SizedBox(height: 12),
                const Icon(Icons.folder_open, size: 36, color: kAccent),
                const SizedBox(height: 16),
                const Text(
                  "Choose the folder where Master_Playlist.m3u and your YouTube lists will be saved.",
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                ElevatedButton.icon(
                  onPressed: _pickFolder,
                  icon: const Icon(Icons.folder),
                  label: const Text("Choose Folder"),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return HomeShell(key: ValueKey(_basePath), basePath: _basePath!, onChangeFolder: _pickFolder);
  }
}

// ============================================================================
// HOME: two tabs - Kodi TV Manager and YouTube Lists
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          KodiTvScreen(basePath: widget.basePath, onChangeFolder: widget.onChangeFolder),
          YouTubeListsScreen(basePath: widget.basePath),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.tv_outlined), selectedIcon: Icon(Icons.tv), label: 'Kodi TV'),
          NavigationDestination(icon: Icon(Icons.video_library_outlined), selectedIcon: Icon(Icons.video_library), label: 'YouTube Lists'),
        ],
      ),
    );
  }
}

// ============================================================================
// KODI TV PLAYLIST MANAGER
// ============================================================================
class KodiTvScreen extends StatefulWidget {
  final String basePath;
  final VoidCallback? onChangeFolder;

  const KodiTvScreen({Key? key, required this.basePath, this.onChangeFolder}) : super(key: key);

  @override
  _KodiTvScreenState createState() => _KodiTvScreenState();
}

class _KodiTvScreenState extends State<KodiTvScreen> with WidgetsBindingObserver {
  final TextEditingController _urlCtrl = TextEditingController();
  final TextEditingController _chapterCtrl = TextEditingController(text: '1');
  final TextEditingController _customNameCtrl = TextEditingController();
  
  List<String> _children = ['Lakshya'];
  String _selectedChild = 'Lakshya';

  List<String> _subjects = ['English', 'Math']; 
  String _selectedSubject = 'English';

  late String m3uPath;
  String _lastClipboardText = "";

  @override
  void initState() {
    super.initState();
    m3uPath = '${widget.basePath}/Master_Playlist.m3u';
    WidgetsBinding.instance.addObserver(this); 
    _loadGlobalData();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkClipboardForYouTube();
    }
  }

  Future<void> _checkClipboardForYouTube() async {
    ClipboardData? data = await Clipboard.getData('text/plain');
    if (data != null && data.text != null && data.text != _lastClipboardText) {
      String text = data.text!;
      if (text.contains('youtu.be') || text.contains('youtube.com') || text.contains('#EXTINF')) {
        setState(() {
          _urlCtrl.text = text;
          _lastClipboardText = text;
        });
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("🔗 Data detected and auto-pasted!"),
          backgroundColor: kAccent,
        ));
      }
    }
  }

  Future<void> _loadGlobalData() async {
    try {
      SharedPreferences prefs = await SharedPreferences.getInstance();
      
      List<String>? savedChildren = prefs.getStringList('child_profiles');
      if (savedChildren != null && savedChildren.isNotEmpty) {
        _children = savedChildren;
        if (!_children.contains(_selectedChild)) _selectedChild = _children.first;
      }

      final subFile = File('${widget.basePath}/saved_subjects.txt');
      if (await subFile.exists()) {
        final subLines = await subFile.readAsLines();
        if (subLines.isNotEmpty) {
          _subjects = subLines;
          if (!_subjects.contains(_selectedSubject)) _selectedSubject = _subjects.first;
        }
      }
      setState(() {});
      await _autoCalculateChapter(); 
    } catch (e) {
      debugPrint("Error loading data: $e");
    }
  }

  Future<void> _autoCalculateChapter() async {
    File m3uFile = File(m3uPath);
    if (!await m3uFile.exists()) {
      setState(() => _chapterCtrl.text = "1");
      return;
    }

    String content = await m3uFile.readAsString();
    String searchTag = 'group-title="$_selectedChild - $_selectedSubject"';
    
    int highestChapter = 0;
    List<String> lines = content.split('\n');
    for (String line in lines) {
      if (line.contains(searchTag)) {
        RegExp regExp = RegExp(r'CH(\d+):');
        var match = regExp.firstMatch(line);
        if (match != null) {
          int chNum = int.tryParse(match.group(1)!) ?? 0;
          if (chNum > highestChapter) highestChapter = chNum;
        }
      }
    }
    setState(() {
      _chapterCtrl.text = (highestChapter + 1).toString();
    });
  }

  void _onProfileOrSubjectChanged() {
    _autoCalculateChapter(); 
  }

  Future<void> _saveChildrenToMemory() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('child_profiles', _children);
  }

  Future<void> _saveSubjectsToTextFile() async {
    try {
      final file = File('${widget.basePath}/saved_subjects.txt');
      await file.writeAsString(_subjects.join('\n'));
    } catch (e) {
      _showSnackBar("Error syncing subjects: $e");
    }
  }

  void _showAddChildDialog() {
    TextEditingController ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Add Child Profile"),
        content: TextField(
          controller: ctrl,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: "Enter name", border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
          ElevatedButton(
            onPressed: () {
              String name = ctrl.text.trim();
              if (name.isNotEmpty && !_children.contains(name)) {
                setState(() {
                  _children.add(name);
                  _selectedChild = name;
                });
                _saveChildrenToMemory();
                _onProfileOrSubjectChanged();
              }
              Navigator.pop(context);
            },
            child: const Text("Add"),
          ),
        ],
      ),
    );
  }

  void _removeChildProfile() {
    if (_children.length <= 1) {
      _showSnackBar("You must have at least one child profile!");
      return;
    }
    setState(() {
      _children.remove(_selectedChild);
      _selectedChild = _children.first;
    });
    _saveChildrenToMemory();
    _onProfileOrSubjectChanged();
  }

  void _showAddSubjectDialog() {
    TextEditingController ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Add New Subject"),
        content: TextField(
          controller: ctrl,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: "e.g. Hindi, GK", border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
          ElevatedButton(
            onPressed: () {
              String newSub = ctrl.text.trim();
              if (newSub.isNotEmpty && !_subjects.contains(newSub)) {
                setState(() {
                  _subjects.add(newSub);
                  _selectedSubject = newSub;
                });
                _saveSubjectsToTextFile();
                _onProfileOrSubjectChanged();
              }
              Navigator.pop(context);
            },
            child: const Text("Add"),
          ),
        ],
      ),
    );
  }

  void _removeCurrentSubject() {
    if (_subjects.length <= 1) {
      _showSnackBar("You must have at least one subject!");
      return;
    }
    setState(() {
      _subjects.remove(_selectedSubject);
      _selectedSubject = _subjects.first;
    });
    _saveSubjectsToTextFile();
    _onProfileOrSubjectChanged();
  }

  Future<void> _saveToKodi() async {
    String rawText = _urlCtrl.text.trim();
    if (rawText.isEmpty) {
      _showSnackBar("Please paste a link or ChatGPT text!");
      return;
    }

    File m3uFile = File(m3uPath);
    String existingContent = '';
    
    if (await m3uFile.exists()) {
      existingContent = await m3uFile.readAsString();
    } else {
      await m3uFile.writeAsString("#EXTM3U\n");
    }

    String forcedGroupTitle = "$_selectedChild - $_selectedSubject";

    if (rawText.contains('#EXTINF')) {
      List<String> lines = rawText.split('\n');
      String newEntries = "";
      int addedCount = 0;
      int dupCount = 0;
      
      int currentChapter = int.tryParse(_chapterCtrl.text) ?? 1;

      for (int i = 0; i < lines.length; i++) {
        if (lines[i].trim().startsWith('#EXTINF')) {
          String infoLine = lines[i].trim();
          String urlLine = (i + 1 < lines.length) ? lines[i + 1].trim() : "";
          
          if (infoLine.contains('group-title="')) {
            infoLine = infoLine.replaceAll(RegExp(r'group-title="[^"]*"'), 'group-title="$forcedGroupTitle"');
          } else {
            infoLine = infoLine.replaceFirst('#EXTINF:-1', '#EXTINF:-1 group-title="$forcedGroupTitle"');
          }
          
          if (!infoLine.contains('play-status="')) {
            infoLine = infoLine.replaceFirst('#EXTINF:-1', '#EXTINF:-1 play-status="working"');
          }

          urlLine = urlLine.replaceAll('*', '_');
          infoLine = infoLine.replaceAll('*', '_');
          
          infoLine = infoLine.replaceAllMapped(RegExp(r'tvg-logo="\[(.*?)\]\(.*?\)"'), (match) {
            return 'tvg-logo="${match.group(1)}"';
          });

          RegExp idRegex = RegExp(r'video_id=([a-zA-Z0-9_-]{11})');
          var match = idRegex.firstMatch(urlLine);
          
          if (match != null) {
            String videoId = match.group(1)!;
            if (existingContent.contains(videoId)) {
              dupCount++;
            } else {
              int commaIndex = infoLine.lastIndexOf(',');
              if (commaIndex != -1) {
                  String rawTitle = infoLine.substring(commaIndex + 1).trim();
                  String cleanName = rawTitle.replaceFirst(RegExp(r'^CH\d+:\s*'), '').trim();
                  String newTitle = _chapterCtrl.text.trim().isNotEmpty ? "CH$currentChapter: $cleanName" : cleanName;
                  
                  String beforeComma = infoLine.substring(0, commaIndex);
                  infoLine = '$beforeComma, $newTitle';
              }

              newEntries += '\n$infoLine\n$urlLine\n';
              addedCount++;
              existingContent += videoId;
              currentChapter++; 
            }
          }
        }
      }
      
      if (addedCount > 0) {
        try {
          await m3uFile.writeAsString(newEntries, mode: FileMode.append);
          _showSnackBar("✅ Success! Added $addedCount ChatGPT video(s). (Skipped $dupCount duplicates)", success: true);
          _urlCtrl.clear();
          _autoCalculateChapter(); 
        } catch (e) {
          _showSnackBar("Error saving to file: $e");
        }
      } else {
        _showSnackBar("All found links were already in your TV playlist!", success: false);
      }
      return;
    }

    RegExp regex = RegExp(r'(?:v=|youtu\.be\/|shorts\/|embed\/|video_id=|vi\/)([a-zA-Z0-9_-]{11})');
    Iterable<RegExpMatch> matches = regex.allMatches(rawText);
    List<String> incomingIds = matches.map((m) => m.group(1)!).toSet().toList();

    if (incomingIds.isEmpty) {
      _showSnackBar("No valid YouTube links found in text!", success: false);
      return;
    }

    int currentChapter = int.tryParse(_chapterCtrl.text) ?? 1;
    String customName = _customNameCtrl.text.trim();
    
    int addedCount = 0;
    int dupCount = 0;
    String newEntries = "";

    for (int i = 0; i < incomingIds.length; i++) {
      String videoId = incomingIds[i];

      if (existingContent.contains(videoId)) {
        dupCount++;
        continue;
      }

      String titlePart = customName.isNotEmpty ? customName : "$_selectedSubject Lesson";
      if (incomingIds.length > 1) {
        titlePart += " (Part ${i + 1})";
      }

      String finalTitle = _chapterCtrl.text.trim().isNotEmpty ? "CH$currentChapter: $titlePart" : titlePart;
      
      newEntries += '\n#EXTINF:-1 group-title="$forcedGroupTitle" play-status="working" tvg-logo="https://img.youtube.com/vi/$videoId/hqdefault.jpg", $finalTitle\n';
      newEntries += 'plugin://plugin.video.youtube/play/?video_id=$videoId\n';
      addedCount++;
      currentChapter++;
    }

    if (addedCount > 0) {
      try {
        await m3uFile.writeAsString(newEntries, mode: FileMode.append);
        _showSnackBar("✅ Success! Added $addedCount new video(s). (Skipped $dupCount duplicates)", success: true);
        _urlCtrl.clear();
        _customNameCtrl.clear();
        _autoCalculateChapter(); 
      } catch (e) {
        _showSnackBar("Error saving to file: $e");
      }
    } else {
      _showSnackBar("All found links were already in your TV playlist!", success: false);
    }
  }

  Future<void> _pasteUrl() async {
    ClipboardData? data = await Clipboard.getData('text/plain');
    if (data != null && data.text != null) {
      setState(() {
        _urlCtrl.text = data.text!;
      });
    }
  }

  void _showSnackBar(String message, {bool success = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: success ? Colors.green : Colors.redAccent,
      duration: const Duration(seconds: 4),
    ));
  }

  Widget _section({required IconData icon, required String title, required Widget child}) {
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      color: kSurface,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: kAccent),
                const SizedBox(width: 8),
                Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, letterSpacing: 0.3)),
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }

  Widget _selectorRow({
    required String value,
    required List<String> items,
    required ValueChanged<String> onChanged,
    required VoidCallback onAdd,
    required VoidCallback onRemove,
    required String addTip,
    required String removeTip,
  }) {
    return Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            value: value,
            isExpanded: true,
            borderRadius: BorderRadius.circular(14),
            items: items.map((c) => DropdownMenuItem(value: c, child: Text(c, overflow: TextOverflow.ellipsis))).toList(),
            onChanged: (val) {
              if (val != null) onChanged(val);
            },
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filledTonal(onPressed: onAdd, tooltip: addTip, icon: const Icon(Icons.add)),
        const SizedBox(width: 4),
        IconButton.filledTonal(
          onPressed: onRemove,
          tooltip: removeTip,
          style: IconButton.styleFrom(foregroundColor: Colors.redAccent),
          icon: const Icon(Icons.delete_outline),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset('assets/logo.png', width: 30, height: 30),
            ),
            const SizedBox(width: 10),
            const Text("Kodi TV Manager"),
          ],
        ),
        actions: [
          if (widget.onChangeFolder != null)
            IconButton(
              icon: const Icon(Icons.folder_open),
              tooltip: "Change Folder",
              onPressed: widget.onChangeFolder,
            ),
          IconButton(
            icon: const Icon(Icons.list_alt, color: Colors.orangeAccent),
            tooltip: "Manage Playlist",
            onPressed: () async {
              await Navigator.push(context, MaterialPageRoute(
                builder: (context) => PlaylistManagerScreen(m3uPath: m3uPath, childrenProfiles: _children)
              ));
              _autoCalculateChapter();
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _section(
              icon: Icons.child_care,
              title: "CHILD PROFILE",
              child: _selectorRow(
                value: _selectedChild,
                items: _children,
                onChanged: (v) {
                  setState(() => _selectedChild = v);
                  _onProfileOrSubjectChanged();
                },
                onAdd: _showAddChildDialog,
                onRemove: _removeChildProfile,
                addTip: "Add child",
                removeTip: "Remove this child",
              ),
            ),
            _section(
              icon: Icons.menu_book,
              title: "SUBJECT  (GROUP TITLE)",
              child: _selectorRow(
                value: _selectedSubject,
                items: _subjects,
                onChanged: (v) {
                  setState(() => _selectedSubject = v);
                  _onProfileOrSubjectChanged();
                },
                onAdd: _showAddSubjectDialog,
                onRemove: _removeCurrentSubject,
                addTip: "Add subject",
                removeTip: "Remove this subject",
              ),
            ),
            _section(
              icon: Icons.edit_note,
              title: "TITLE",
              child: Row(
                children: [
                  Expanded(
                    flex: 1,
                    child: TextField(
                      controller: _chapterCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: "Chapter No."),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: _customNameCtrl,
                      decoration: const InputDecoration(labelText: "Custom Name", hintText: "e.g., Train Poetry"),
                    ),
                  ),
                ],
              ),
            ),
            _section(
              icon: Icons.link,
              title: "YOUTUBE LINKS",
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _urlCtrl,
                    minLines: 3,
                    maxLines: 6,
                    decoration: const InputDecoration(
                      hintText: "Paste raw links OR full ChatGPT M3U text here...",
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: _pasteUrl,
                        icon: const Icon(Icons.paste, size: 18),
                        label: const Text("Paste"),
                      ),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: () => setState(() => _urlCtrl.clear()),
                        icon: const Icon(Icons.clear, size: 18),
                        label: const Text("Clear"),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Container(
              height: 58,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: const LinearGradient(colors: [Color(0xFF7C3AED), Color(0xFFEC4899)]),
              ),
              child: ElevatedButton.icon(
                onPressed: _saveToKodi,
                icon: const Icon(Icons.cast, color: Colors.white),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                label: const Text("Build & Save to TV", style: TextStyle(fontSize: 18, color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              "Saving to: $m3uPath",
              style: const TextStyle(color: Colors.grey, fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// PLAYLIST MANAGER (WORLD-CLASS UI: BATCH ACTIONS, STATUS FILTERS)
// ============================================================================
class PlaylistManagerScreen extends StatefulWidget {
  final String m3uPath;
  final List<String> childrenProfiles;

  const PlaylistManagerScreen({Key? key, required this.m3uPath, required this.childrenProfiles}) : super(key: key);

  @override
  _PlaylistManagerScreenState createState() => _PlaylistManagerScreenState();
}

class _PlaylistManagerScreenState extends State<PlaylistManagerScreen> {
  String _selectedFilter = 'All';
  Set<String> _selectedSubjects = {}; 
  String _selectedStatus = 'All'; 
  String _searchQuery = '';
  List<M3uItem> _playlistItems = [];
  Set<M3uItem> _selectedItems = {};
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _selectedFilter = widget.childrenProfiles.isNotEmpty ? widget.childrenProfiles.first : 'All';
    _loadPlaylist();
  }

  Future<void> _loadPlaylist() async {
    File m3uFile = File(widget.m3uPath);
    if (!await m3uFile.exists()) return;
    
    String content = await m3uFile.readAsString();
    List<String> lines = content.split('\n');
    List<M3uItem> items = [];
    
    for (int i = 0; i < lines.length; i++) {
      if (lines[i].startsWith('#EXTINF:')) {
        String info = lines[i];
        String url = (i + 1 < lines.length) ? lines[i + 1] : "";
        
        RegExp groupRegex = RegExp(r'group-title="([^"]+)"');
        String group = groupRegex.firstMatch(info)?.group(1) ?? "Unknown";
        
        RegExp statusRegex = RegExp(r'play-status="([^"]+)"');
        String status = statusRegex.firstMatch(info)?.group(1) ?? "working";

        String name = info.substring(info.lastIndexOf(',') + 1).trim();
        
        items.add(M3uItem(infoLine: info, urlLine: url, groupTitle: group, displayName: name, playStatus: status));
      }
    }
    setState(() => _playlistItems = items);
  }

  void _reorderChapters(String groupTitle) {
    int currentChapter = 1;
    for (M3uItem item in _playlistItems) {
      if (item.groupTitle == groupTitle) {
        String cleanName = item.displayName.replaceFirst(RegExp(r'^CH\d+:\s*'), '').trim();
        String newName = "CH$currentChapter: $cleanName";
        
        item.infoLine = item.infoLine.replaceAll(item.displayName, newName);
        item.displayName = newName;
        currentChapter++;
      }
    }
  }

  Future<void> _savePlaylistToFile() async {
    String newContent = "#EXTM3U\n";
    for (M3uItem item in _playlistItems) {
      newContent += '\n${item.infoLine}\n${item.urlLine}\n';
    }
    await File(widget.m3uPath).writeAsString(newContent);
  }

  Future<void> _deleteSelectedItems() async {
    Set<String> affectedGroups = _selectedItems.map<String>((M3uItem e) => e.groupTitle).toSet();
    
    setState(() {
      _playlistItems.removeWhere((M3uItem item) => _selectedItems.contains(item));
      _selectedItems.clear();
    });

    for (String group in affectedGroups) {
      _reorderChapters(group);
    }
    
    await _savePlaylistToFile();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Videos deleted & chapters corrected!"), backgroundColor: Colors.redAccent));
  }

  Future<void> _updateItemStatus(M3uItem item, String newStatus) async {
    setState(() {
      if (item.infoLine.contains('play-status="')) {
        item.infoLine = item.infoLine.replaceAll(RegExp(r'play-status="[^"]*"'), 'play-status="$newStatus"');
      } else {
        item.infoLine = item.infoLine.replaceFirst('#EXTINF:-1', '#EXTINF:-1 play-status="$newStatus"');
      }
      item.playStatus = newStatus;
    });
    await _savePlaylistToFile();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Marked as ${newStatus.toUpperCase()}"), backgroundColor: Colors.orange));
  }

  Future<void> _playInYouTube(String urlLine) async {
    String videoId = "";
    RegExp regExp = RegExp(r'video_id=([a-zA-Z0-9_-]{11})');
    var match = regExp.firstMatch(urlLine);
    
    if (match != null) {
      videoId = match.group(1)!;
    } else {
      RegExp fallbackReg = RegExp(r'(?:v=|youtu\.be\/|vi\/)([a-zA-Z0-9_-]{11})');
      var fbMatch = fallbackReg.firstMatch(urlLine);
      if (fbMatch != null) videoId = fbMatch.group(1)!;
    }

    if (videoId.isNotEmpty) {
      final Uri appUrl = Uri.parse('vnd.youtube://$videoId');
      final Uri webUrl = Uri.parse('https://www.youtube.com/watch?v=$videoId');
      
      try {
        if (await canLaunchUrl(appUrl)) {
          await launchUrl(appUrl, mode: LaunchMode.externalApplication);
        } else {
          await launchUrl(webUrl, mode: LaunchMode.externalApplication);
        }
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Could not open YouTube."), backgroundColor: Colors.red));
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Invalid YouTube link in M3U."), backgroundColor: Colors.red));
    }
  }

  void _showEditDialog(M3uItem item) {
    TextEditingController titleCtrl = TextEditingController(text: item.displayName);
    TextEditingController groupCtrl = TextEditingController(text: item.groupTitle);
    TextEditingController urlCtrl = TextEditingController(text: item.urlLine);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Edit Video Details"),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: titleCtrl, decoration: const InputDecoration(labelText: "Display Name")),
              const SizedBox(height: 10),
              TextField(controller: groupCtrl, decoration: const InputDecoration(labelText: "Group Title (Subject)")),
              const SizedBox(height: 10),
              TextField(controller: urlCtrl, maxLines: 2, decoration: const InputDecoration(labelText: "Raw URL Code")),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
          ElevatedButton(
            onPressed: () async {
              setState(() {
                item.infoLine = item.infoLine.replaceAll(item.displayName, titleCtrl.text.trim());
                item.infoLine = item.infoLine.replaceAll('group-title="${item.groupTitle}"', 'group-title="${groupCtrl.text.trim()}"');
                
                item.displayName = titleCtrl.text.trim();
                item.groupTitle = groupCtrl.text.trim();
                item.urlLine = urlCtrl.text.trim();
              });
              
              await _savePlaylistToFile();
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Video updated successfully!"), backgroundColor: Colors.green));
            },
            style: ElevatedButton.styleFrom(backgroundColor: kAccent),
            child: const Text("Save Changes", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showItemBottomSheet(M3uItem item) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.play_circle_fill, color: Colors.redAccent, size: 30),
              title: const Text('Play in YouTube', style: TextStyle(fontWeight: FontWeight.bold)),
              onTap: () { Navigator.pop(context); _playInYouTube(item.urlLine); },
            ),
            ListTile(
              leading: const Icon(Icons.edit, color: kAccent),
              title: const Text('Edit Details / M3U Code'),
              onTap: () { Navigator.pop(context); _showEditDialog(item); },
            ),
            const Divider(),
            if (item.playStatus != 'working')
              ListTile(
                leading: const Icon(Icons.check_circle, color: Colors.green),
                title: const Text('Mark as Working (Fix)'),
                onTap: () { Navigator.pop(context); _updateItemStatus(item, 'working'); },
              ),
            if (item.playStatus != 'unavailable')
              ListTile(
                leading: const Icon(Icons.warning_amber_rounded, color: Colors.orange),
                title: const Text('Mark as Video Unavailable'),
                onTap: () { Navigator.pop(context); _updateItemStatus(item, 'unavailable'); },
              ),
            if (item.playStatus != 'kodi_error')
              ListTile(
                leading: const Icon(Icons.volume_off, color: Colors.orange),
                title: const Text('Mark as Kodi Playback Error'),
                onTap: () { Navigator.pop(context); _updateItemStatus(item, 'kodi_error'); },
              ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text('Delete Video'),
              onTap: () {
                Navigator.pop(context);
                setState(() => _selectedItems = {item});
                _deleteSelectedItems();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showGlobalFilters() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true, 
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          
          Set<String> dynamicSubjects = {};
          for (M3uItem item in _playlistItems) {
            if (item.groupTitle.contains(' - ')) {
              dynamicSubjects.add(item.groupTitle.split(' - ').last.trim());
            } else {
              dynamicSubjects.add(item.groupTitle.trim());
            }
          }

          int liveCount = _playlistItems.where((M3uItem item) {
            bool matchesProfile = _selectedFilter == 'All' || item.groupTitle.startsWith(_selectedFilter);
            String itemSubject = item.groupTitle.contains(' - ') ? item.groupTitle.split(' - ').last.trim() : item.groupTitle.trim();
            bool matchesSubject = _selectedSubjects.isEmpty || _selectedSubjects.contains(itemSubject);
            bool matchesStatus = _selectedStatus == 'All' || item.playStatus == _selectedStatus;
            bool matchesSearch = item.displayName.toLowerCase().contains(_searchQuery.toLowerCase());
            return matchesProfile && matchesSubject && matchesStatus && matchesSearch;
          }).length;

          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom, top: 20, left: 20, right: 20
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text("Filters", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                    TextButton(
                      onPressed: () {
                        setSheetState(() {
                          _selectedFilter = 'All';
                          _selectedSubjects.clear();
                          _selectedStatus = 'All';
                        });
                        setState(() {}); 
                      },
                      child: const Text("Reset All", style: TextStyle(color: Colors.redAccent)),
                    )
                  ],
                ),
                const SizedBox(height: 15),

                const Text("Link Health / Status", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.grey)),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  children: [
                    ChoiceChip(label: const Text("All"), selected: _selectedStatus == 'All', selectedColor: kAccent, onSelected: (val) { setSheetState(() => _selectedStatus = 'All'); setState(() => _selectedItems.clear()); }),
                    ChoiceChip(label: const Text("Working"), selected: _selectedStatus == 'working', selectedColor: Colors.green, onSelected: (val) { setSheetState(() => _selectedStatus = 'working'); setState(() => _selectedItems.clear()); }),
                    ChoiceChip(label: const Text("Unavailable"), selected: _selectedStatus == 'unavailable', selectedColor: Colors.orange, onSelected: (val) { setSheetState(() => _selectedStatus = 'unavailable'); setState(() => _selectedItems.clear()); }),
                    ChoiceChip(label: const Text("Kodi Error"), selected: _selectedStatus == 'kodi_error', selectedColor: Colors.orange, onSelected: (val) { setSheetState(() => _selectedStatus = 'kodi_error'); setState(() => _selectedItems.clear()); }),
                  ],
                ),
                const SizedBox(height: 20),

                const Text("Profile (Single Select)", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.grey)),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  children: [
                    ChoiceChip(
                      label: const Text("All"),
                      selected: _selectedFilter == 'All',
                      selectedColor: kAccent,
                      onSelected: (val) {
                        setSheetState(() => _selectedFilter = 'All');
                        setState(() => _selectedItems.clear());
                      },
                    ),
                    ...widget.childrenProfiles.map((String c) => ChoiceChip(
                      label: Text(c),
                      selected: _selectedFilter == c,
                      selectedColor: kAccent,
                      onSelected: (val) {
                        setSheetState(() => _selectedFilter = c);
                        setState(() => _selectedItems.clear());
                      },
                    )).toList(),
                  ],
                ),
                const SizedBox(height: 20),

                const Text("Subject (Multi-Select)", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.grey)),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 5,
                  children: dynamicSubjects.map((String sub) => FilterChip(
                    label: Text(sub),
                    selected: _selectedSubjects.contains(sub),
                    selectedColor: kAccent.withOpacity(0.5),
                    checkmarkColor: Colors.white,
                    onSelected: (bool selected) {
                      setSheetState(() {
                        if (selected) {
                          _selectedSubjects.add(sub);
                        } else {
                          _selectedSubjects.remove(sub);
                        }
                      });
                      setState(() => _selectedItems.clear());
                    },
                  )).toList(),
                ),
                const SizedBox(height: 30),

                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kAccent,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15))
                    ),
                    child: Text("Show $liveCount Videos", style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          );
        }
      ),
    );
  }

  void _showBatchRenameDialog() {
    List<String> currentGroups = _playlistItems.map<String>((M3uItem e) => e.groupTitle).toSet().toList();
    if (currentGroups.isEmpty) return;
    String newGroupCtrl = currentGroups.first;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text("Move to Category"),
          content: DropdownButtonFormField<String>(
            value: newGroupCtrl,
            isExpanded: true,
            items: currentGroups.map((String g) => DropdownMenuItem(value: g, child: Text(g))).toList(),
            onChanged: (val) => setDialogState(() => newGroupCtrl = val!),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
            ElevatedButton(
              onPressed: () async {
                Set<String> oldGroups = _selectedItems.map<String>((M3uItem e) => e.groupTitle).toSet();
                setState(() {
                  for (M3uItem item in _selectedItems) {
                    item.infoLine = item.infoLine.replaceAll('group-title="${item.groupTitle}"', 'group-title="$newGroupCtrl"');
                    item.groupTitle = newGroupCtrl;
                  }
                  _selectedItems.clear();
                });
                for (String oldGroup in oldGroups) _reorderChapters(oldGroup);
                _reorderChapters(newGroupCtrl);
                await _savePlaylistToFile();
                Navigator.pop(context);
              },
              child: const Text("Update Selected"),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    List<M3uItem> filteredItems = _playlistItems.where((M3uItem item) {
      bool matchesProfile = _selectedFilter == 'All' || item.groupTitle.startsWith(_selectedFilter);
      String itemSubject = item.groupTitle.contains(' - ') ? item.groupTitle.split(' - ').last.trim() : item.groupTitle.trim();
      bool matchesSubject = _selectedSubjects.isEmpty || _selectedSubjects.contains(itemSubject);
      bool matchesStatus = _selectedStatus == 'All' || item.playStatus == _selectedStatus;
      bool matchesSearch = item.displayName.toLowerCase().contains(_searchQuery.toLowerCase());
      
      return matchesProfile && matchesSubject && matchesStatus && matchesSearch;
    }).toList();

    bool isAllSelected = _selectedItems.length == filteredItems.length && filteredItems.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(_selectedItems.isEmpty ? "Manage TV Videos" : "${_selectedItems.length} Selected"),
        actions: _selectedItems.isNotEmpty ? [
          IconButton(
            icon: Icon(isAllSelected ? Icons.deselect : Icons.select_all, color: Colors.white),
            tooltip: isAllSelected ? "Deselect All" : "Select All",
            onPressed: () {
              setState(() {
                if (isAllSelected) {
                  _selectedItems.clear();
                } else {
                  _selectedItems.addAll(filteredItems);
                }
              });
            },
          ),
          if (_selectedItems.length == 1)
            IconButton(icon: const Icon(Icons.play_circle_fill, color: Colors.redAccent), tooltip: "Play in YouTube", onPressed: () => _playInYouTube(_selectedItems.first.urlLine)),
          IconButton(icon: const Icon(Icons.edit, color: kAccent), tooltip: "Change Category", onPressed: _showBatchRenameDialog),
          IconButton(icon: const Icon(Icons.delete, color: Colors.red), tooltip: "Delete Selected", onPressed: _deleteSelectedItems),
        ] : [
          IconButton(
            icon: Icon(
              (_selectedFilter == 'All' && _selectedSubjects.isEmpty && _selectedStatus == 'All') ? Icons.filter_list : Icons.filter_list_alt, 
              color: (_selectedFilter == 'All' && _selectedSubjects.isEmpty && _selectedStatus == 'All') ? Colors.white : kAccent
            ),
            tooltip: "Filter",
            onPressed: _showGlobalFilters, 
          )
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: TextField(
              controller: _searchCtrl,
              onChanged: (val) => setState(() => _searchQuery = val),
              decoration: InputDecoration(
                hintText: 'Search videos...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchQuery.isNotEmpty 
                  ? IconButton(icon: const Icon(Icons.clear), onPressed: () { _searchCtrl.clear(); setState(() => _searchQuery = ''); }) 
                  : null,
                filled: true,
                fillColor: Colors.grey.shade900,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: BorderSide.none),
              ),
            ),
          ),
          
          Expanded(
            child: filteredItems.isEmpty 
              ? const Center(child: Text("No videos match your search/filter.", style: TextStyle(color: Colors.grey)))
              : ListView.builder(
              itemCount: filteredItems.length,
              itemBuilder: (context, index) {
                M3uItem item = filteredItems[index];
                bool isSelected = _selectedItems.contains(item);

                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  color: isSelected ? Colors.blue.withOpacity(0.2) : Colors.grey.shade900,
                  elevation: 2,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () {
                      if (_selectedItems.isNotEmpty) {
                        setState(() { isSelected ? _selectedItems.remove(item) : _selectedItems.add(item); });
                      } else {
                        _playInYouTube(item.urlLine);
                      }
                    },
                    onLongPress: () {
                      if (_selectedItems.isEmpty) _showItemBottomSheet(item);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                      child: Row(
                        children: [
                          Checkbox(
                            value: isSelected,
                            activeColor: kAccent,
                            onChanged: (bool? selected) {
                              setState(() { selected == true ? _selectedItems.add(item) : _selectedItems.remove(item); });
                            },
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    if (item.playStatus == 'unavailable') const Padding(padding: EdgeInsets.only(right: 6), child: Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 16)),
                                    if (item.playStatus == 'kodi_error') const Padding(padding: EdgeInsets.only(right: 6), child: Icon(Icons.volume_off, color: Colors.orange, size: 16)),
                                    Expanded(child: Text(item.displayName, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: item.playStatus != 'working' ? Colors.grey : Colors.white))),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(item.groupTitle, style: const TextStyle(color: Colors.orangeAccent, fontSize: 13)),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.more_vert, color: Colors.grey),
                            onPressed: () => _showItemBottomSheet(item),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          )
        ],
      ),
    );
  }
}

class M3uItem {
  String infoLine;
  String urlLine; 
  String groupTitle;
  String displayName;
  String playStatus;
  M3uItem({required this.infoLine, required this.urlLine, required this.groupTitle, required this.displayName, this.playStatus = 'working'});
}

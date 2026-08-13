import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const HomeworkCompanionApp());
}

class HomeworkCompanionApp extends StatelessWidget {
  const HomeworkCompanionApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Homework Companion',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        brightness: Brightness.dark,
      ),
      home: const GeneratorScreen(),
    );
  }
}

class GeneratorScreen extends StatefulWidget {
  const GeneratorScreen({Key? key}) : super(key: key);

  @override
  _GeneratorScreenState createState() => _GeneratorScreenState();
}

class _GeneratorScreenState extends State<GeneratorScreen> {
  String? _basePath; 

  // --- Dynamic Form State ---
  List<String> _subjects = ['English', 'Math', 'Science', 'History', 'Art'];
  String _selectedSubject = 'English';

  List<String> _fileTypes = ['quiz', 'concept', 'image'];
  String _selectedFileType = 'quiz';

  final TextEditingController _chapterCtrl = TextEditingController(text: '1');
  final TextEditingController _fileNumCtrl = TextEditingController(text: '1');
  final TextEditingController _customNameCtrl = TextEditingController();
  final TextEditingController _textContentCtrl = TextEditingController();

  Uint8List? _imageBytes;
  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  // --- Core Permissions & Folder Setup ---
  Future<void> _initializeApp() async {
    if (!await Permission.manageExternalStorage.isGranted) {
      await Permission.manageExternalStorage.request();
    }
    
    if (await Permission.manageExternalStorage.isGranted) {
      SharedPreferences prefs = await SharedPreferences.getInstance();
      String? savedPath = prefs.getString('saved_base_path');

      if (savedPath != null) {
        setState(() {
          _basePath = savedPath;
        });
        await _loadCustomData();
      }
    }
  }

  Future<void> _pickBaseFolder() async {
    String? selectedDirectory = await FilePicker.platform.getDirectoryPath();

    if (selectedDirectory != null) {
      SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString('saved_base_path', selectedDirectory);
      
      setState(() {
        _basePath = selectedDirectory;
      });
      await _loadCustomData();
    }
  }

  // --- Unified Save/Load Logic ---
  Future<void> _loadCustomData() async {
    if (_basePath == null) return;

    try {
      final dir = Directory(_basePath!);
      if (!await dir.exists()) await dir.create(recursive: true);

      // Load Subjects
      final subFile = File('${dir.path}/saved_subjects.txt');
      if (await subFile.exists()) {
        final subLines = await subFile.readAsLines();
        if (subLines.isNotEmpty) _subjects = subLines;
      }

      // Load File Types
      final typeFile = File('${dir.path}/saved_types.txt');
      if (await typeFile.exists()) {
        final typeLines = await typeFile.readAsLines();
        if (typeLines.isNotEmpty) _fileTypes = typeLines;
      }

      setState(() {
        if (!_subjects.contains(_selectedSubject)) _selectedSubject = _subjects.first;
        if (!_fileTypes.contains(_selectedFileType)) _selectedFileType = _fileTypes.first;
      });
    } catch (e) {
      debugPrint("Error loading data: $e");
    }
  }

  Future<void> _saveDataList(List<String> list, String fileName) async {
    if (_basePath == null) return;
    try {
      final file = File('$_basePath/$fileName');
      await file.writeAsString(list.join('\n'));
    } catch (e) {
      _showSnackBar("Error saving list: $e");
    }
  }

  // --- Subject Management ---
  void _showAddSubjectDialog() {
    TextEditingController newSubjectCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Add New Subject"),
        content: TextField(
          controller: newSubjectCtrl,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: "e.g. Hindi, GK", border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
          ElevatedButton(
            onPressed: () {
              String newSub = newSubjectCtrl.text.trim();
              if (newSub.isNotEmpty && !_subjects.contains(newSub)) {
                setState(() {
                  _subjects.add(newSub);
                  _selectedSubject = newSub;
                });
                _saveDataList(_subjects, 'saved_subjects.txt');
              }
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
            child: const Text("Add", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _deleteCurrentSubject() {
    if (_subjects.length <= 1) {
      _showSnackBar("You must have at least one subject!");
      return;
    }
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Delete Subject?"),
        content: Text("Remove '$_selectedSubject' from your list?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
          ElevatedButton(
            onPressed: () {
              setState(() {
                _subjects.remove(_selectedSubject);
                _selectedSubject = _subjects.first;
              });
              _saveDataList(_subjects, 'saved_subjects.txt');
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text("Delete", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  // --- File Type Management ---
  void _showAddTypeDialog() {
    TextEditingController newTypeCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Add New File Type"),
        content: TextField(
          controller: newTypeCtrl,
          decoration: const InputDecoration(hintText: "e.g. worksheet, summary", border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
          ElevatedButton(
            onPressed: () {
              String newType = newTypeCtrl.text.trim().toLowerCase().replaceAll(' ', '_');
              if (newType.isNotEmpty && !_fileTypes.contains(newType)) {
                setState(() {
                  _fileTypes.add(newType);
                  _selectedFileType = newType;
                });
                _saveDataList(_fileTypes, 'saved_types.txt');
              }
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
            child: const Text("Add", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  // --- Image Handling ---
  Future<void> _pickFromGallery() async {
    final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
    if (image != null) {
      final bytes = await image.readAsBytes();
      setState(() => _imageBytes = bytes);
    }
  }

  Future<void> _pasteFromClipboard() async {
    final bytes = await Pasteboard.image;
    if (bytes != null) {
      setState(() => _imageBytes = bytes);
    } else {
      _showSnackBar("No image found on clipboard!");
    }
  }

  // --- Logic & Saving ---
  String _buildFilePath() {
    String chapter = "ch${_chapterCtrl.text.padLeft(2, '0')}";
    String type = _selectedFileType;
    String num = _fileNumCtrl.text;

    String customName = _customNameCtrl.text.trim();
    String suffix = customName.isNotEmpty ? "_${customName.replaceAll(' ', '_')}" : "";

    String extension = type == 'quiz' ? '.json' : (type == 'image' ? '.jpg' : '.txt');
    String fileName = "${chapter}_${type}_${num}$suffix$extension".toLowerCase();

    String dirPath = "$_basePath/$_selectedSubject";
    return "$dirPath/$fileName";
  }

  Future<void> _handleSave() async {
    if (_basePath == null) {
      _showSnackBar("Please select a base folder first.");
      return;
    }

    if (!await Permission.manageExternalStorage.isGranted) {
      _showSnackBar("Storage permission is required to save files.");
      await Permission.manageExternalStorage.request();
      return;
    }

    String fullPath = _buildFilePath();
    File targetFile = File(fullPath);

    if (await targetFile.exists()) {
      bool? overwrite = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text("File Exists"),
          content: Text("A file named\n${fullPath.split('/').last}\nalready exists. Overwrite it?"),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Cancel")),
            ElevatedButton(onPressed: () => Navigator.pop(context, true), style: ElevatedButton.styleFrom(backgroundColor: Colors.red), child: const Text("Overwrite")),
          ],
        ),
      );
      if (overwrite != true) return;
    }

    Directory dir = Directory(fullPath.substring(0, fullPath.lastIndexOf('/')));
    if (!await dir.exists()) await dir.create(recursive: true);

    try {
      if (_selectedFileType == 'image') {
        if (_imageBytes == null) {
          _showSnackBar("Please select or paste an image first!");
          return;
        }
        await targetFile.writeAsBytes(_imageBytes!);
      } else {
        if (_textContentCtrl.text.isEmpty) {
          _showSnackBar("Please paste the text content first!");
          return;
        }
        await targetFile.writeAsString(_textContentCtrl.text);
      }
      _showSnackBar("✅ Saved successfully to $_selectedSubject folder!", success: true);

      _textContentCtrl.clear();
      setState(() => _imageBytes = null);

    } catch (e) {
      _showSnackBar("Error saving file: $e");
    }
  }

  void _showSnackBar(String message, {bool success = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: success ? Colors.green : Colors.redAccent,
      duration: const Duration(seconds: 3),
    ));
  }

  // --- UI Layout ---
  @override
  Widget build(BuildContext context) {
    if (_basePath == null) {
      return Scaffold(
        appBar: AppBar(title: const Text("Setup Required"), centerTitle: true),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.folder_special, size: 80, color: Colors.blueAccent),
                const SizedBox(height: 20),
                const Text(
                  "Where do you want to save your Homework and TV Playlist files?",
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18),
                ),
                const SizedBox(height: 30),
                ElevatedButton(
                  onPressed: _pickBaseFolder,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20)
                  ),
                  child: const Text("Choose Folder", style: TextStyle(fontSize: 20, color: Colors.white)),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text("Homework Generator"),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.smart_toy, color: Colors.greenAccent),
            tooltip: "AI Prompts",
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const PromptManagerScreen()),
              );
            },
          ),
          // NEW FEATURE: Homework File Manager Button
          IconButton(
            icon: const Icon(Icons.folder_open, color: Colors.yellowAccent),
            tooltip: "Manage Saved Files",
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => HomeworkFileManagerScreen(basePath: _basePath!, subjects: _subjects)),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.folder, color: Colors.white70),
            tooltip: "Change Save Folder",
            onPressed: _pickBaseFolder,
          ),
          IconButton(
            icon: const Icon(Icons.tv, color: Colors.blueAccent),
            tooltip: "Kodi TV Manager",
            onPressed: () async {
              // Wait for TV screen to pop, then reload data to sync Subjects if changed
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => KodiTvScreen(basePath: _basePath!)),
              );
              _loadCustomData();
            },
          )
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _selectedSubject,
                    decoration: const InputDecoration(labelText: "Subject Folder", border: OutlineInputBorder()),
                    items: _subjects.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
                    onChanged: (val) => setState(() => _selectedSubject = val!),
                  ),
                ),
                const SizedBox(width: 10),
                InkWell(
                  onTap: _showAddSubjectDialog,
                  child: Container(
                    height: 60, width: 50,
                    decoration: BoxDecoration(color: Colors.blueAccent.withOpacity(0.2), borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.blueAccent)),
                    child: const Icon(Icons.add, color: Colors.blueAccent),
                  ),
                ),
                const SizedBox(width: 10),
                InkWell(
                  onTap: _deleteCurrentSubject,
                  child: Container(
                    height: 60, width: 50,
                    decoration: BoxDecoration(color: Colors.redAccent.withOpacity(0.2), borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.redAccent)),
                    child: const Icon(Icons.delete, color: Colors.redAccent),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 15),

            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _chapterCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: "Chapter No.", border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: TextField(
                    controller: _fileNumCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: "File No.", border: OutlineInputBorder()),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 15),

            TextField(
              controller: _customNameCtrl,
              decoration: const InputDecoration(labelText: "Custom Name (Optional)", hintText: "e.g. My Family", border: OutlineInputBorder()),
            ),
            const SizedBox(height: 20),

            const Text("File Type:", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            Wrap(
              spacing: 10,
              runSpacing: 5,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ..._fileTypes.map((t) => _buildRadio(t.toUpperCase(), t)).toList(),
                TextButton.icon(
                  onPressed: _showAddTypeDialog,
                  icon: const Icon(Icons.add_circle, color: Colors.blueAccent),
                  label: const Text("New Type", style: TextStyle(color: Colors.blueAccent)),
                )
              ],
            ),
            const SizedBox(height: 20),

            if (_selectedFileType != 'image')
              TextField(
                controller: _textContentCtrl,
                maxLines: 8,
                decoration: InputDecoration(
                  labelText: "Paste ${_selectedFileType.toUpperCase()} Content Here",
                  border: const OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              )
            else
              Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      ElevatedButton.icon(onPressed: _pickFromGallery, icon: const Icon(Icons.photo), label: const Text("Gallery")),
                      ElevatedButton.icon(onPressed: _pasteFromClipboard, icon: const Icon(Icons.paste), label: const Text("Paste")),
                    ],
                  ),
                  const SizedBox(height: 15),
                  Container(
                    height: 200,
                    width: double.infinity,
                    decoration: BoxDecoration(border: Border.all(color: Colors.grey), borderRadius: BorderRadius.circular(10)),
                    child: _imageBytes == null
                        ? const Center(child: Text("No Image Selected"))
                        : ClipRRect(borderRadius: BorderRadius.circular(10), child: Image.memory(_imageBytes!, fit: BoxFit.cover)),
                  ),
                ],
              ),

            const SizedBox(height: 30),

            SizedBox(
              height: 60,
              child: ElevatedButton(
                onPressed: _handleSave,
                style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15))),
                child: const Text("Generate & Save File", style: TextStyle(fontSize: 20, color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ),
            
            const SizedBox(height: 10),
            Text("Saving to: $_basePath", style: const TextStyle(fontSize: 10, color: Colors.grey), textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  Widget _buildRadio(String label, String value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Radio<String>(
          value: value,
          groupValue: _selectedFileType,
          onChanged: (val) => setState(() {
            _selectedFileType = val!;
            _textContentCtrl.clear();
            _imageBytes = null;
          }),
        ),
        Text(label, style: const TextStyle(fontSize: 14)),
      ],
    );
  }
}

// ============================================================================
// PROMPT MANAGER FOR AI
// ============================================================================

class PromptManagerScreen extends StatefulWidget {
  const PromptManagerScreen({Key? key}) : super(key: key);

  @override
  _PromptManagerScreenState createState() => _PromptManagerScreenState();
}

class _PromptManagerScreenState extends State<PromptManagerScreen> {
  Map<String, String> _prompts = {};
  
  @override
  void initState() {
    super.initState();
    _loadPrompts();
  }

  Future<void> _loadPrompts() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    String? promptsJson = prefs.getString('saved_ai_prompts');
    if (promptsJson != null) {
      setState(() {
        _prompts = Map<String, String>.from(jsonDecode(promptsJson));
      });
    }
  }

  Future<void> _savePrompts() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_ai_prompts', jsonEncode(_prompts));
  }

  void _showAddPromptDialog() {
    TextEditingController nameCtrl = TextEditingController();
    TextEditingController contentCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Save New AI Prompt"),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: "Prompt Name", hintText: "e.g., Kodi Video Builder", border: OutlineInputBorder()),
              ),
              const SizedBox(height: 15),
              TextField(
                controller: contentCtrl,
                maxLines: 5,
                decoration: const InputDecoration(labelText: "Prompt Text", hintText: "Paste the full prompt here...", border: OutlineInputBorder()),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
          ElevatedButton(
            onPressed: () {
              String name = nameCtrl.text.trim();
              String content = contentCtrl.text.trim();
              
              if (name.isNotEmpty && content.isNotEmpty) {
                setState(() {
                  _prompts[name] = content;
                });
                _savePrompts();
                Navigator.pop(context);
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            child: const Text("Save Prompt", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _copyToClipboard(String content, String name) {
    Clipboard.setData(ClipboardData(text: content));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text("✅ '$name' copied to clipboard!"),
      backgroundColor: Colors.green,
    ));
  }

  void _deletePrompt(String name) {
    setState(() {
      _prompts.remove(name);
    });
    _savePrompts();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("AI Prompts Manager")),
      body: _prompts.isEmpty
          ? const Center(child: Text("No prompts saved yet.\nTap the + button to add one!", textAlign: TextAlign.center))
          : ListView.builder(
              padding: const EdgeInsets.all(15),
              itemCount: _prompts.length,
              itemBuilder: (context, index) {
                String key = _prompts.keys.elementAt(index);
                String content = _prompts[key]!;

                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: ExpansionTile(
                    title: Text(key, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                    subtitle: const Text("Tap to view content or copy", style: TextStyle(color: Colors.grey, fontSize: 12)),
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(15.0),
                        child: Text(content, style: const TextStyle(color: Colors.white70)),
                      ),
                      ButtonBar(
                        alignment: MainAxisAlignment.end,
                        children: [
                          TextButton.icon(
                            onPressed: () => _deletePrompt(key),
                            icon: const Icon(Icons.delete, color: Colors.redAccent),
                            label: const Text("Delete", style: TextStyle(color: Colors.redAccent)),
                          ),
                          ElevatedButton.icon(
                            onPressed: () => _copyToClipboard(content, key),
                            icon: const Icon(Icons.copy, color: Colors.white),
                            label: const Text("Copy Prompt", style: TextStyle(color: Colors.white)),
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                          ),
                        ],
                      )
                    ],
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddPromptDialog,
        backgroundColor: Colors.green,
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }
}

// ============================================================================
// KODI TV PLAYLIST MANAGER
// ============================================================================

class KodiTvScreen extends StatefulWidget {
  final String basePath;

  const KodiTvScreen({Key? key, required this.basePath}) : super(key: key);

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
          backgroundColor: Colors.blueAccent,
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

    // This completely forces ChatGPT to match the dropdowns!
    String forcedGroupTitle = "$_selectedChild - $_selectedSubject";

    if (rawText.contains('#EXTINF')) {
      List<String> lines = rawText.split('\n');
      String newEntries = "";
      int addedCount = 0;
      int dupCount = 0;

      for (int i = 0; i < lines.length; i++) {
        if (lines[i].trim().startsWith('#EXTINF')) {
          String infoLine = lines[i].trim();
          String urlLine = (i + 1 < lines.length) ? lines[i + 1].trim() : "";
          
          if (infoLine.contains('group-title="')) {
            infoLine = infoLine.replaceAll(RegExp(r'group-title="[^"]*"'), 'group-title="$forcedGroupTitle"');
          } else {
            infoLine = infoLine.replaceFirst('#EXTINF:-1', '#EXTINF:-1 group-title="$forcedGroupTitle"');
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
              newEntries += '\n$infoLine\n$urlLine\n';
              addedCount++;
              existingContent += videoId;
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

    String chapter = _chapterCtrl.text.trim();
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

      String finalTitle = chapter.isNotEmpty ? "CH$chapter: $titlePart" : titlePart;
      
      newEntries += '\n#EXTINF:-1 group-title="$forcedGroupTitle" tvg-logo="https://img.youtube.com/vi/$videoId/hqdefault.jpg", $finalTitle\n';
      newEntries += 'plugin://plugin.video.youtube/play/?video_id=$videoId\n';
      addedCount++;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Kodi TV Manager"),
        actions: [
          IconButton(
            icon: const Icon(Icons.list_alt, color: Colors.orangeAccent),
            tooltip: "Manage Playlist",
            onPressed: () async {
              await Navigator.push(context, MaterialPageRoute(
                builder: (context) => PlaylistManagerScreen(m3uPath: m3uPath, childrenProfiles: _children)
              ));
              _autoCalculateChapter();
            },
          )
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text("Child Profile:", style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 5),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _selectedChild,
                    decoration: const InputDecoration(border: OutlineInputBorder()),
                    items: _children.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                    onChanged: (val) {
                      setState(() => _selectedChild = val!);
                      _onProfileOrSubjectChanged();
                    }
                  ),
                ),
                const SizedBox(width: 10),
                InkWell(
                  onTap: _showAddChildDialog,
                  child: Container(
                    height: 60, width: 50,
                    decoration: BoxDecoration(color: Colors.blueAccent.withOpacity(0.2), borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.blueAccent)),
                    child: const Icon(Icons.add, color: Colors.blueAccent),
                  ),
                ),
                const SizedBox(width: 10),
                InkWell(
                  onTap: _removeChildProfile,
                  child: Container(
                    height: 60, width: 50,
                    decoration: BoxDecoration(color: Colors.redAccent.withOpacity(0.2), borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.redAccent)),
                    child: const Icon(Icons.delete, color: Colors.redAccent),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            const Text("Subject (Group Title):", style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 5),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _selectedSubject,
                    decoration: const InputDecoration(border: OutlineInputBorder()),
                    items: _subjects.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
                    onChanged: (val) {
                      setState(() => _selectedSubject = val!);
                      _onProfileOrSubjectChanged();
                    }
                  ),
                ),
                const SizedBox(width: 10),
                InkWell(
                  onTap: _showAddSubjectDialog,
                  child: Container(
                    height: 60, width: 50,
                    decoration: BoxDecoration(color: Colors.blueAccent.withOpacity(0.2), borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.blueAccent)),
                    child: const Icon(Icons.add, color: Colors.blueAccent),
                  ),
                ),
                const SizedBox(width: 10),
                InkWell(
                  onTap: _removeCurrentSubject,
                  child: Container(
                    height: 60, width: 50,
                    decoration: BoxDecoration(color: Colors.redAccent.withOpacity(0.2), borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.redAccent)),
                    child: const Icon(Icons.delete, color: Colors.redAccent),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            Row(
              children: [
                Expanded(
                  flex: 1,
                  child: TextField(
                    controller: _chapterCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: "Chapter No.", border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 15),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _customNameCtrl,
                    decoration: const InputDecoration(labelText: "Custom Name", hintText: "e.g., Train Poetry", border: OutlineInputBorder()),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            const Text("YouTube Links:", style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 5),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlCtrl,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      hintText: "Paste raw links OR full ChatGPT M3U text here...", 
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                ElevatedButton.icon(
                  onPressed: _pasteUrl, 
                  icon: const Icon(Icons.paste), 
                  label: const Text("Paste"),
                  style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 15))
                ),
              ],
            ),
            
            const SizedBox(height: 30),

            SizedBox(
              height: 60,
              child: ElevatedButton(
                onPressed: _saveToKodi,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueAccent, 
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15))
                ),
                child: const Text("Build & Save to TV", style: TextStyle(fontSize: 20, color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ),
            
            const SizedBox(height: 20),
            Text(
              "Saving to: $m3uPath", 
              style: const TextStyle(color: Colors.grey, fontSize: 12),
              textAlign: TextAlign.center,
            )
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// NEW FEATURE: HOMEWORK FILE MANAGER (Review, Edit, Delete Quizzes & Images)
// ============================================================================
class HomeworkFileManagerScreen extends StatefulWidget {
  final String basePath;
  final List<String> subjects;

  const HomeworkFileManagerScreen({Key? key, required this.basePath, required this.subjects}) : super(key: key);

  @override
  _HomeworkFileManagerScreenState createState() => _HomeworkFileManagerScreenState();
}

class _HomeworkFileManagerScreenState extends State<HomeworkFileManagerScreen> {
  late String _selectedSubject;
  List<FileSystemEntity> _files = [];

  @override
  void initState() {
    super.initState();
    _selectedSubject = widget.subjects.isNotEmpty ? widget.subjects.first : '';
    _loadFiles();
  }

  Future<void> _loadFiles() async {
    if (_selectedSubject.isEmpty) return;
    final dir = Directory('${widget.basePath}/$_selectedSubject');
    if (await dir.exists()) {
      setState(() {
        _files = dir.listSync().where((f) => f is File).toList();
      });
    } else {
      setState(() => _files = []);
    }
  }

  void _openFile(File file) async {
    String ext = file.path.split('.').last.toLowerCase();
    
    if (ext == 'jpg' || ext == 'png') {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          content: Image.file(file),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text("Close"))],
        ),
      );
    } else if (ext == 'txt' || ext == 'json') {
      String content = await file.readAsString();
      TextEditingController editorCtrl = TextEditingController(text: content);
      
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text("Editing: ${file.path.split('/').last}", style: const TextStyle(fontSize: 14)),
          content: SingleChildScrollView(
            child: TextField(
              controller: editorCtrl,
              maxLines: null,
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
            ElevatedButton(
              onPressed: () async {
                await file.writeAsString(editorCtrl.text);
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("File updated!"), backgroundColor: Colors.green));
              },
              child: const Text("Save Changes"),
            )
          ],
        ),
      );
    }
  }

  Future<void> _deleteFile(File file) async {
    await file.delete();
    _loadFiles();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("File deleted."), backgroundColor: Colors.redAccent));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Manage Homework Files")),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(15),
            child: DropdownButtonFormField<String>(
              value: _selectedSubject,
              decoration: const InputDecoration(labelText: "Select Subject Folder", border: OutlineInputBorder()),
              items: widget.subjects.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
              onChanged: (val) {
                setState(() => _selectedSubject = val!);
                _loadFiles();
              },
            ),
          ),
          Expanded(
            child: _files.isEmpty 
              ? const Center(child: Text("No files found in this folder."))
              : ListView.builder(
                  itemCount: _files.length,
                  itemBuilder: (context, index) {
                    File file = _files[index] as File;
                    String fileName = file.path.split('/').last;
                    return Card(
                      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      child: ListTile(
                        leading: const Icon(Icons.insert_drive_file, color: Colors.yellowAccent),
                        title: Text(fileName, style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: const Text("Tap to view or edit"),
                        onTap: () => _openFile(file),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete, color: Colors.red),
                          onPressed: () => _deleteFile(file),
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

// ============================================================================
// PLAYLIST MANAGER (MULTI-SELECT, BATCH RENAME, AUTO-CHAPTER FIXING)
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
  List<M3uItem> _playlistItems = [];
  Set<M3uItem> _selectedItems = {};

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
        
        String name = info.substring(info.lastIndexOf(',') + 1).trim();
        
        items.add(M3uItem(infoLine: info, urlLine: url, groupTitle: group, displayName: name));
      }
    }
    setState(() => _playlistItems = items);
  }

  // --- AUTO CHAPTER CORRECTION LOGIC ---
  void _reorderChapters(String groupTitle) {
    int currentChapter = 1;
    for (var item in _playlistItems) {
      if (item.groupTitle == groupTitle) {
        // Find existing clean name by stripping out old CH number
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
    for (var item in _playlistItems) {
      newContent += '\n${item.infoLine}\n${item.urlLine}\n';
    }
    await File(widget.m3uPath).writeAsString(newContent);
  }

  Future<void> _deleteSelectedItems() async {
    Set<String> affectedGroups = _selectedItems.map((e) => e.groupTitle).toSet();
    
    setState(() {
      _playlistItems.removeWhere((item) => _selectedItems.contains(item));
      _selectedItems.clear();
    });

    // Fix chapter numbering for the groups that just had videos deleted!
    for (String group in affectedGroups) {
      _reorderChapters(group);
    }
    
    await _savePlaylistToFile();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Videos deleted and chapters auto-corrected!"), backgroundColor: Colors.redAccent));
  }

  void _showBatchRenameDialog() {
    List<String> currentGroups = _playlistItems.map((e) => e.groupTitle).toSet().toList();
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
            items: currentGroups.map((g) => DropdownMenuItem(value: g, child: Text(g))).toList(),
            onChanged: (val) => setDialogState(() => newGroupCtrl = val!),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
            ElevatedButton(
              onPressed: () async {
                Set<String> oldGroups = _selectedItems.map((e) => e.groupTitle).toSet();
                
                setState(() {
                  for (var item in _selectedItems) {
                    item.infoLine = item.infoLine.replaceAll('group-title="${item.groupTitle}"', 'group-title="$newGroupCtrl"');
                    item.groupTitle = newGroupCtrl;
                  }
                  _selectedItems.clear();
                });

                for (String oldGroup in oldGroups) _reorderChapters(oldGroup);
                _reorderChapters(newGroupCtrl);

                await _savePlaylistToFile();
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Videos moved and chapters auto-corrected!"), backgroundColor: Colors.green));
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
    List<M3uItem> filteredItems = _selectedFilter == 'All' 
        ? _playlistItems 
        : _playlistItems.where((item) => item.groupTitle.startsWith(_selectedFilter)).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(_selectedItems.isEmpty ? "Manage TV Videos" : "${_selectedItems.length} Selected"),
        actions: _selectedItems.isNotEmpty ? [
          IconButton(icon: const Icon(Icons.edit, color: Colors.blueAccent), tooltip: "Change Category", onPressed: _showBatchRenameDialog),
          IconButton(icon: const Icon(Icons.delete, color: Colors.red), tooltip: "Delete Selected", onPressed: _deleteSelectedItems),
        ] : [],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            color: Colors.grey.shade900,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  const SizedBox(width: 10),
                  _buildTab('All'),
                  ...widget.childrenProfiles.map((c) => _buildTab(c)).toList(),
                ],
              ),
            ),
          ),
          
          Expanded(
            child: ListView.builder(
              itemCount: filteredItems.length,
              itemBuilder: (context, index) {
                var item = filteredItems[index];
                bool isSelected = _selectedItems.contains(item);

                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  color: isSelected ? Colors.blue.withOpacity(0.2) : null,
                  child: CheckboxListTile(
                    value: isSelected,
                    onChanged: (bool? selected) {
                      setState(() {
                        if (selected == true) {
                          _selectedItems.add(item);
                        } else {
                          _selectedItems.remove(item);
                        }
                      });
                    },
                    title: Text(item.displayName, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(item.groupTitle, style: const TextStyle(color: Colors.orangeAccent)),
                    secondary: IconButton(
                      icon: const Icon(Icons.delete, color: Colors.red),
                      onPressed: () {
                        setState(() => _selectedItems = {item});
                        _deleteSelectedItems();
                      }, 
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

  Widget _buildTab(String name) {
    bool isSelected = _selectedFilter == name;
    return GestureDetector(
      onTap: () => setState(() {
        _selectedFilter = name;
        _selectedItems.clear(); // Clear selections when changing tabs
      }),
      child: Container(
        margin: const EdgeInsets.only(right: 10),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? Colors.blueAccent : Colors.grey.shade800,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(name, style: TextStyle(color: isSelected ? Colors.white : Colors.grey.shade400, fontWeight: FontWeight.bold)),
      ),
    );
  }
}

class M3uItem {
  String infoLine;
  final String urlLine;
  String groupTitle;
  String displayName;
  M3uItem({required this.infoLine, required this.urlLine, required this.groupTitle, required this.displayName});
}


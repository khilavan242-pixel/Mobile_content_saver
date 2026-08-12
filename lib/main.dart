import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // Added for Clipboard
import 'package:permission_handler/permission_handler.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pasteboard/pasteboard.dart';

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

  // --- Core Permissions & Startup ---
  Future<void> _initializeApp() async {
    if (!await Permission.manageExternalStorage.isGranted) {
      await Permission.manageExternalStorage.request();
    }
    if (await Permission.manageExternalStorage.isGranted) {
      await _loadCustomData();
    }
  }

  // --- Unified Save/Load Logic ---
  Future<void> _loadCustomData() async {
    try {
      final dir = Directory('/storage/emulated/0/Documents/Homework');
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
    try {
      final file = File('/storage/emulated/0/Documents/Homework/$fileName');
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

    String dirPath = "/storage/emulated/0/Documents/Homework/$_selectedSubject";
    return "$dirPath/$fileName";
  }

  Future<void> _handleSave() async {
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
    return Scaffold(
      appBar: AppBar(
        title: const Text("Homework Generator"),
        centerTitle: true,
        actions: [
          // NEW: Button to open the Kodi TV Playlist Manager
          IconButton(
            icon: const Icon(Icons.tv, color: Colors.blueAccent),
            tooltip: "Kodi TV Manager",
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const KodiTvScreen()),
              );
            },
          )
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // --- SUBJECT ROW WITH ADD AND DELETE BUTTONS ---
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

            // --- DYNAMIC FILE TYPE ROW WITH ADD BUTTON ---
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
// NEW FEATURE: KODI TV PLAYLIST MANAGER
// ============================================================================

class KodiTvScreen extends StatefulWidget {
  const KodiTvScreen({Key? key}) : super(key: key);

  @override
  _KodiTvScreenState createState() => _KodiTvScreenState();
}

class _KodiTvScreenState extends State<KodiTvScreen> {
  final TextEditingController _urlCtrl = TextEditingController();
  
  // The Child Profile logic we discussed
  List<String> _children = ['Lakshya', 'Child 2'];
  String _selectedChild = 'Lakshya';

  // We pull subjects from your existing app data
  List<String> _subjects = ['English', 'Math']; 
  String _selectedSubject = 'English';

  final String m3uPath = '/storage/emulated/0/Documents/Homework/Master_Playlist.m3u';

  @override
  void initState() {
    super.initState();
    _loadSubjects();
  }

  Future<void> _loadSubjects() async {
    try {
      final subFile = File('/storage/emulated/0/Documents/Homework/saved_subjects.txt');
      if (await subFile.exists()) {
        final subLines = await subFile.readAsLines();
        if (subLines.isNotEmpty) {
          setState(() {
            _subjects = subLines;
            _selectedSubject = _subjects.first;
          });
        }
      }
    } catch (e) {
      debugPrint("Error loading subjects: $e");
    }
  }

  // Extracts YouTube ID using Regex
  String? _extractYouTubeId(String url) {
    final RegExp regExp = RegExp(
      r'(?<=watch\?v=|/videos/|embed/|youtu.be/|/v/|/e/|watch\?v%3D|watch\?feature=player_embedded&v=|%2Fvideos%2F|embed%2F|youtu.be%2F|%2Fv%2F)[^#\&\?\n]*',
      caseSensitive: false,
      multiLine: false,
    );
    final match = regExp.firstMatch(url);
    return match?.group(0);
  }

  Future<void> _saveToKodi() async {
    String url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      _showSnackBar("Please enter a YouTube link!");
      return;
    }

    String? videoId = _extractYouTubeId(url);
    if (videoId == null || videoId.length < 10) {
      _showSnackBar("Invalid YouTube Link!");
      return;
    }

    File m3uFile = File(m3uPath);
    
    // Duplicate Scanner Logic
    if (await m3uFile.exists()) {
      String content = await m3uFile.readAsString();
      if (content.contains(videoId)) {
        _showSnackBar("Duplicate! Video already on TV.", success: false);
        return;
      }
    } else {
      // First time setup: Write the #EXTM3U tag
      await m3uFile.writeAsString("#EXTM3U\n\n");
    }

    // Build the Kodi String
    String groupTitle = "$_selectedChild - $_selectedSubject";
    String kodiCode = '''
#EXTINF:-1 group-title="$groupTitle" tvg-logo="https://img.youtube.com/vi/$videoId/hqdefault.jpg", $_selectedSubject Lesson
plugin://plugin.video.youtube/play/?video_id=$videoId
''';

    // Append to file
    try {
      await m3uFile.writeAsString("$kodiCode\n", mode: FileMode.append);
      _showSnackBar("✅ Saved to Kodi TV!", success: true);
      _urlCtrl.clear();
    } catch (e) {
      _showSnackBar("Error saving: $e");
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
      duration: const Duration(seconds: 3),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Kodi TV Manager")),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text("Child Profile:", style: TextStyle(fontWeight: FontWeight.bold)),
            DropdownButtonFormField<String>(
              value: _selectedChild,
              decoration: const InputDecoration(border: OutlineInputBorder()),
              items: _children.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
              onChanged: (val) => setState(() => _selectedChild = val!),
            ),
            const SizedBox(height: 20),

            const Text("Subject (Group Title):", style: TextStyle(fontWeight: FontWeight.bold)),
            DropdownButtonFormField<String>(
              value: _selectedSubject,
              decoration: const InputDecoration(border: OutlineInputBorder()),
              items: _subjects.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
              onChanged: (val) => setState(() => _selectedSubject = val!),
            ),
            const SizedBox(height: 20),

            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlCtrl,
                    decoration: const InputDecoration(
                      labelText: "YouTube Link", 
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


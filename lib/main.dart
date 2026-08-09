import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
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
        brightness: Brightness.dark, // Clean dark mode for mobile
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
  // --- Form State ---
  String _selectedSubject = 'English';
  final List<String> _subjects = ['English', 'Math', 'Science', 'History', 'Art'];
  
  String _fileType = 'quiz'; // 'quiz', 'concept', or 'image'
  
  final TextEditingController _chapterCtrl = TextEditingController(text: '1');
  final TextEditingController _fileNumCtrl = TextEditingController(text: '1');
  final TextEditingController _customNameCtrl = TextEditingController();
  final TextEditingController _textContentCtrl = TextEditingController();

  Uint8List? _imageBytes; // Holds the image if gallery/clipboard is used
  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _requestPermissions();
  }

  // --- Core Android 11+ Permission Request ---
  Future<void> _requestPermissions() async {
    if (!await Permission.manageExternalStorage.isGranted) {
      await Permission.manageExternalStorage.request();
    }
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
    String chapter = "ch${_chapterCtrl.text.padLeft(2, '0')}"; // Forces ch01
    String type = _fileType;
    String num = _fileNumCtrl.text;
    
    // Format custom name (replace spaces with underscores)
    String customName = _customNameCtrl.text.trim();
    String suffix = customName.isNotEmpty ? "_${customName.replaceAll(' ', '_')}" : "";
    
    String extension = type == 'quiz' ? '.json' : (type == 'concept' ? '.txt' : '.jpg');
    String fileName = "${chapter}_${type}_${num}$suffix$extension".toLowerCase();
    
    // The exact mobile path for Documents/Homework
    String dirPath = "/storage/emulated/0/Documents/Homework/$_selectedSubject";
    return "$dirPath/$fileName";
  }

  Future<void> _handleSave() async {
    if (!await Permission.manageExternalStorage.isGranted) {
      _showSnackBar("Storage permission is required to save files.");
      await _requestPermissions();
      return;
    }

    String fullPath = _buildFilePath();
    File targetFile = File(fullPath);

    // Safety Check: Overwrite Warning
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

    // Ensure the folder exists
    Directory dir = Directory(fullPath.substring(0, fullPath.lastIndexOf('/')));
    if (!await dir.exists()) await dir.create(recursive: true);

    // Write the data
    try {
      if (_fileType == 'image') {
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
      _showSnackBar("✅ Saved successfully to ${_selectedSubject} folder!", success: true);
      
      // Optional: Clear form after save
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
      appBar: AppBar(title: const Text("Homework Generator"), centerTitle: true),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Subject Dropdown
            DropdownButtonFormField<String>(
              value: _selectedSubject,
              decoration: const InputDecoration(labelText: "Subject Folder", border: OutlineInputBorder()),
              items: _subjects.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
              onChanged: (val) => setState(() => _selectedSubject = val!),
            ),
            const SizedBox(height: 15),

            // Number Inputs Row
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

            // Optional Name
            TextField(
              controller: _customNameCtrl,
              decoration: const InputDecoration(labelText: "Custom Name (Optional)", hintText: "e.g. My Family", border: OutlineInputBorder()),
            ),
            const SizedBox(height: 20),

            // File Type Selector
            const Text("File Type:", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildRadio("Quiz", 'quiz'),
                _buildRadio("Concept", 'concept'),
                _buildRadio("Image", 'image'),
              ],
            ),
            const SizedBox(height: 20),

            // Smart Input Area (Changes based on selection)
            if (_fileType != 'image')
              TextField(
                controller: _textContentCtrl,
                maxLines: 8,
                decoration: InputDecoration(
                  labelText: "Paste ${_fileType.toUpperCase()} Content Here",
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

            // Save Button
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
      children: [
        Radio<String>(
          value: value,
          groupValue: _fileType,
          onChanged: (val) => setState(() {
            _fileType = val!;
            _textContentCtrl.clear();
            _imageBytes = null;
          }),
        ),
        Text(label),
      ],
    );
  }
}


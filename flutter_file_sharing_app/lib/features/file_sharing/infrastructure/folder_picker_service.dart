import 'package:file_picker/file_picker.dart';

class FolderPickerService {
  Future<String?> pickFolder() async {
    return await FilePicker.platform.getDirectoryPath();
  }
}

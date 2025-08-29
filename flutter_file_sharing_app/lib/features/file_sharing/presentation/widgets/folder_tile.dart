import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../file_sharing/domain/entities/shared_folder.dart';
import '../../../../main.dart';
import '../../../file_sharing/domain/repositories/file_sharing_repository.dart';

class FolderTile extends StatelessWidget {
  final SharedFolder folder;
  const FolderTile({Key? key, required this.folder}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onLongPress: () => _editPolicies(context),
      child: ListTile(
        leading: const Icon(Icons.folder),
        title: Text(folder.name),
        subtitle: Text(folder.path ?? ''),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(folder.isShared ? Icons.cloud_done : Icons.cloud_off,
                color: folder.isShared ? Colors.green : Colors.grey, size: 20),
            const SizedBox(width: 6),
            Icon(folder.autoApprove ? Icons.flash_on : Icons.handshake,
                color: folder.autoApprove ? Colors.orange : Colors.blueGrey,
                size: 18),
            const SizedBox(width: 6),
            Icon(folder.allowPreview ? Icons.visibility : Icons.visibility_off,
                color: folder.allowPreview ? Colors.teal : Colors.redAccent,
                size: 18),
          ],
        ),
      ),
    );
  }

  void _editPolicies(BuildContext context) async {
    bool autoApprove = folder.autoApprove;
    bool allowPreview = folder.allowPreview;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) {
          return StatefulBuilder(builder: (ctx, setState) {
            return AlertDialog(
              title: const Text('Edit Policies'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Auto-approve requests'),
                    value: autoApprove,
                    onChanged: (v) => setState(() => autoApprove = v ?? false),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                        'Allow preview (list files before approval)'),
                    value: allowPreview,
                    onChanged: (v) => setState(() => allowPreview = v ?? true),
                  ),
                ],
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: const Text('Cancel')),
                ElevatedButton(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    child: const Text('Save')),
              ],
            );
          });
        });
    if (confirmed != true) return;
    final repo = context.read<FileSharingRepository>();
    final model = context.read<SharedFoldersModel>();
    final updated =
        folder.copyWith(autoApprove: autoApprove, allowPreview: allowPreview);
    await repo.updateSharedFolder(updated);
    model.setFolders([
      for (final f in model.folders)
        if (f.id == folder.id) updated else f,
    ]);
  }
}

// (helper functions removed; using Provider context.read directly)

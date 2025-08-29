import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_file_sharing_app/features/file_sharing/presentation/pages/home_page.dart';
import 'package:flutter_file_sharing_app/features/file_sharing/presentation/widgets/folder_tile.dart';
import 'package:provider/provider.dart';
import 'package:flutter_file_sharing_app/main.dart';
import 'package:flutter_file_sharing_app/features/file_sharing/domain/entities/shared_folder.dart';

void main() {
  testWidgets('HomePage has a title and a message',
      (WidgetTester tester) async {
    await tester.pumpWidget(MultiProvider(providers: [
      ChangeNotifierProvider(create: (_) => SharedFoldersModel()),
      ChangeNotifierProvider(create: (_) => PeersModel()),
      ChangeNotifierProvider(create: (_) => FileRequestsModel()),
    ], child: const MaterialApp(home: HomePage())));

    final titleFinder = find.text('File Sharing App');
    final messageFinder = find.text('Share your files with peers');

    expect(titleFinder, findsOneWidget);
    expect(messageFinder, findsOneWidget);
  });

  testWidgets('HomePage displays folder tiles', (WidgetTester tester) async {
    await tester.pumpWidget(MultiProvider(providers: [
      ChangeNotifierProvider(
          create: (_) => SharedFoldersModel()
            ..addFolder(SharedFolder(id: '1', name: 'Docs'))),
      ChangeNotifierProvider(create: (_) => PeersModel()),
      ChangeNotifierProvider(create: (_) => FileRequestsModel()),
    ], child: const MaterialApp(home: HomePage())));
    await tester.pump();
    final folderTileFinder = find.byType(FolderTile);
    expect(folderTileFinder, findsOneWidget);
  });

  testWidgets('HomePage has a button to add a folder',
      (WidgetTester tester) async {
    await tester.pumpWidget(MultiProvider(providers: [
      ChangeNotifierProvider(create: (_) => SharedFoldersModel()),
      ChangeNotifierProvider(create: (_) => PeersModel()),
      ChangeNotifierProvider(create: (_) => FileRequestsModel()),
    ], child: const MaterialApp(home: HomePage())));

    final addFolderButtonFinder = find.byIcon(Icons.add);

    expect(addFolderButtonFinder, findsOneWidget);
  });
}

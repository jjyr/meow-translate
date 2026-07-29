import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

import '../jobs/job_controller.dart';
import 'drop_page.dart';
import 'history_page.dart';
import 'settings_page.dart';

final class RootWindow extends StatefulWidget {
  const RootWindow({required this.controller, super.key});

  final JobController controller;

  @override
  State<RootWindow> createState() => _RootWindowState();
}

final class _RootWindowState extends State<RootWindow> {
  var _pageIndex = 0;

  @override
  Widget build(BuildContext context) {
    return MacosWindow(
      titleBar: const TitleBar(title: Text('Meow')),
      sidebar: Sidebar(
        minWidth: 190,
        startWidth: 210,
        maxWidth: 280,
        builder: (context, scrollController) => SidebarItems(
          currentIndex: _pageIndex,
          scrollController: scrollController,
          onChanged: (value) => setState(() => _pageIndex = value),
          items: const [
            SidebarItem(
              leading: MacosIcon(CupertinoIcons.book),
              label: Text('Translate'),
            ),
            SidebarItem(
              leading: MacosIcon(CupertinoIcons.list_bullet),
              label: Text('Jobs'),
            ),
            SidebarItem(
              leading: MacosIcon(CupertinoIcons.gear),
              label: Text('Settings'),
            ),
          ],
        ),
      ),
      child: IndexedStack(
        index: _pageIndex,
        children: [
          DropPage(
            controller: widget.controller,
            onShowJobs: () => setState(() => _pageIndex = 1),
          ),
          HistoryPage(controller: widget.controller),
          SettingsPage(controller: widget.controller),
        ],
      ),
    );
  }
}

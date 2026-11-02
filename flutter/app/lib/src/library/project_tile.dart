import 'package:flutter/material.dart';
import 'package:voxscripta_engine/voxscripta_engine.dart';

import '../formatting.dart';
import '../platform_traits.dart';

/// One recording in the list.
///
/// Carries the same two lines the SwiftUI row does — name, then duration —
/// plus the date, which there is room for here. The platform differences are
/// the ones that are genuinely conventions rather than taste: a pointer gets
/// hover, a tooltip and right-click; a finger gets long-press and a taller row.
class ProjectTile extends StatelessWidget {
  const ProjectTile({
    super.key,
    required this.project,
    required this.isSelected,
    required this.onOpen,
    required this.onReveal,
    required this.onDelete,
  });

  final ProjectEntry project;
  final bool isSelected;
  final VoidCallback onOpen;
  final VoidCallback onReveal;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tile = ListTile(
      selected: isSelected,
      onTap: onOpen,
      onLongPress:
          PlatformTraits.usesLongPressForMenu ? () => _showMenu(context, null) : null,
      title: Text(project.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${Formatting.duration(project.duration)}  ·  '
        '${Formatting.relativeDate(project.modifiedAt)}',
        style: theme.textTheme.bodySmall?.copyWith(
          // Tabular figures so a column of durations lines up, which is what
          // the SwiftUI row's monospacedDigit does.
          fontFeatures: const [FontFeature.tabularFigures()],
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: PlatformTraits.hasPointer
          ? null
          : IconButton(
              icon: const Icon(Icons.more_vert),
              // On touch there is no hover, so the menu needs a visible way in
              // as well as the long-press.
              onPressed: () => _showMenu(context, null),
            ),
    );

    if (!PlatformTraits.hasPointer) return tile;

    return Tooltip(
      message: '${project.displayName} · ${Formatting.duration(project.duration)}. '
          'Click to open its transcript.',
      waitDuration: const Duration(milliseconds: 600),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onSecondaryTapDown: (details) => _showMenu(context, details.globalPosition),
        child: tile,
      ),
    );
  }

  /// The context menu, in the place the platform expects it: at the pointer on
  /// a desktop, anchored to the row on a touch screen.
  Future<void> _showMenu(BuildContext context, Offset? at) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    final box = context.findRenderObject() as RenderBox?;
    if (overlay == null || box == null) return;

    final origin = at ?? box.localToGlobal(box.size.centerRight(Offset.zero));
    final position = RelativeRect.fromRect(
      Rect.fromPoints(origin, origin),
      Offset.zero & overlay.size,
    );

    final choice = await showMenu<_RowAction>(
      context: context,
      position: position,
      items: [
        PopupMenuItem(
          value: _RowAction.reveal,
          child: Text('Show in ${PlatformTraits.fileManagerName}'),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(value: _RowAction.delete, child: Text('Delete…')),
      ],
    );

    switch (choice) {
      case _RowAction.reveal:
        onReveal();
      case _RowAction.delete:
        onDelete();
      case null:
        break;
    }
  }
}

enum _RowAction { reveal, delete }

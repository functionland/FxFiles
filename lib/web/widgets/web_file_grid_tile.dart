import 'package:flutter/material.dart';

/// One cell of the web file grids — the grid counterpart of the
/// `ListTile` rows in WebBucketScreen / WebCloudFilesScreen, and a
/// visual mirror of the native browser's `_buildGridItem`
/// (lib/features/browser/screens/file_browser_screen.dart): rounded
/// surface, thumbnail area on top, name + meta footer underneath.
///
/// Deliberately dumb: the caller supplies the already-built [thumbnail]
/// (a filling `WebThumb` for images, a type icon otherwise) and the
/// [menu], so this widget adds no fetching of its own and both screens
/// keep their existing action wiring.
class WebFileGridTile extends StatelessWidget {
  /// Fills the tile's upper area. Use `WebThumb(fill: true)` for images
  /// and a plain `Icon` for everything else.
  final Widget thumbnail;

  final String name;

  /// Size / date line. Omitted (no reserved space) when null.
  final String? subtitle;

  /// Compact tag chips, shown under [subtitle] in the roomier 2-column
  /// layout only — in a 3-column cell there is no honest room for them.
  final Widget? tags;

  /// Overflow menu, pinned to the tile's top-right corner.
  final Widget? menu;

  final VoidCallback? onTap;

  /// Denser typography for the 3-column grid.
  final bool dense;

  const WebFileGridTile({
    super.key,
    required this.thumbnail,
    required this.name,
    this.subtitle,
    this.tags,
    this.menu,
    this.onTap,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.3),
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Center(child: thumbnail),
                  if (menu != null)
                    Positioned(
                      top: 2,
                      right: 2,
                      // The menu sits over the image, so give it a
                      // scrim disc — a bare icon is unreadable on a
                      // light photo. Keep the offsets POSITIVE: the
                      // tile clips (Clip.antiAlias), so a negative
                      // inset would shave the button.
                      child: _MenuScrim(child: menu!),
                    ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(8, dense ? 4 : 6, 8, dense ? 6 : 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: dense ? 11 : 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: dense ? 9 : 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  if (tags != null && !dense)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: tags!,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MenuScrim extends StatelessWidget {
  final Widget child;
  const _MenuScrim({required this.child});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.55),
      ),
      child: child,
    );
  }
}

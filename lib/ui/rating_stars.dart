import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/library.dart';
import 'glyphs.dart';
import 'theme.dart';
import 'widgets.dart';

/// Five stars showing the user's rating of a track, album or artist. Click
/// a star to rate; click the current rating again to clear it.
class RatingStars extends ConsumerStatefulWidget {
  final String id;

  /// The rating the server gave when the item was fetched.
  final int fetched;
  final double size;
  final Color? color;

  /// What is being rated, for tooltips, such as "track".
  final String what;

  const RatingStars({
    super.key,
    required this.id,
    required this.fetched,
    this.size = 22,
    this.color,
    this.what = 'track',
  });

  @override
  ConsumerState<RatingStars> createState() => _RatingStarsState();
}

class _RatingStarsState extends ConsumerState<RatingStars> {
  int? _hover;

  Future<void> _rate(int stars) async {
    final notifier = ref.read(ratingsProvider.notifier);
    final current = notifier.ratingOf(widget.id, fetched: widget.fetched);
    try {
      await notifier.rate(
        widget.id,
        stars == current ? 0 : stars,
        fetched: widget.fetched,
      );
    } catch (e) {
      if (mounted) toast(context, 'Could not save rating: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final rating = ref.watch(
      ratingsProvider.select((m) => m[widget.id] ?? widget.fetched),
    );
    final shown = _hover ?? rating;
    final on = widget.color ?? oampAccent;
    return Semantics(
      label: rating == 0
          ? 'Not rated'
          : 'Rated $rating ${rating == 1 ? 'star' : 'stars'}',
      child: MouseRegion(
        onExit: (_) => setState(() => _hover = null),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 1; i <= 5; i++)
              Tooltip(
                message: i == rating
                    ? 'Clear rating'
                    : 'Rate ${widget.what} $i ${i == 1 ? 'star' : 'stars'}',
                waitDuration: const Duration(milliseconds: 600),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  onEnter: (_) => setState(() => _hover = i),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _rate(i),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: widget.size * 0.08,
                        vertical: widget.size * 0.15,
                      ),
                      child: StarGlyph(
                        key: ValueKey('star$i'),
                        size: widget.size,
                        filled: i <= shown,
                        color: i <= shown
                            ? (_hover != null ? on.withValues(alpha: 0.7) : on)
                            : OAmpColors.textFaint,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A small dialog for rating a track from its menu.
Future<void> showRatingDialog(
  BuildContext context, {
  required String id,
  required int fetched,
  required String title,
  String what = 'track',
}) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
    content: Center(
      heightFactor: 1,
      child: RatingStars(id: id, fetched: fetched, size: 34, what: what),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Done'),
      ),
    ],
  ),
);

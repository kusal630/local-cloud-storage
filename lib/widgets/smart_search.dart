import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../core/haptics/haptic_feedback.dart';

/// Search filter chips for advanced file filtering.
enum FileFilter {
  all('All', Icons.all_inclusive_rounded),
  images('Images', Icons.image_rounded),
  videos('Videos', Icons.movie_rounded),
  audio('Audio', Icons.audio_file_rounded),
  documents('Docs', Icons.description_rounded),
  archives('Archives', Icons.archive_rounded),
  notes('Notes', Icons.note_rounded);

  const FileFilter(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Search bar with filter chips for smart file search.
class SmartSearchBar extends StatefulWidget {
  const SmartSearchBar({
    super.key,
    this.onChanged,
    this.onFilterChanged,
    this.hint = 'Search files...',
  });

  final ValueChanged<String>? onChanged;
  final ValueChanged<FileFilter>? onFilterChanged;
  final String hint;

  @override
  State<SmartSearchBar> createState() => _SmartSearchBarState();
}

class _SmartSearchBarState extends State<SmartSearchBar> {
  FileFilter _selectedFilter = FileFilter.all;
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Search bar
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SearchBar(
            controller: _controller,
            focusNode: _focusNode,
            hintText: widget.hint,
            leading: Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Icon(Icons.search_rounded, color: scheme.onSurfaceVariant),
            ),
            trailing: [
              if (_controller.text.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.clear_rounded, size: 20),
                  onPressed: () {
                    _controller.clear();
                    widget.onChanged?.call('');
                    AppHaptics.light();
                  },
                ),
            ],
            onChanged: (value) {
              setState(() {});
              widget.onChanged?.call(value);
            },
          ),
        ),
        const SizedBox(height: 8),
        // Filter chips
        SizedBox(
          height: 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: FileFilter.values.length,
            separatorBuilder: (_, i) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final filter = FileFilter.values[index];
              final selected = filter == _selectedFilter;
              return FilterChip(
                selected: selected,
                label: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(filter.icon, size: 16),
                    const SizedBox(width: 4),
                    Text(filter.label),
                  ],
                ),
                onSelected: (_) {
                  AppHaptics.selection();
                  setState(() => _selectedFilter = filter);
                  widget.onFilterChanged?.call(filter);
                },
                selectedColor: scheme.primaryContainer,
                checkmarkColor: scheme.onPrimaryContainer,
              );
            },
          ),
        ),
      ],
    ).animate().fadeIn(duration: 200.ms);
  }
}

/// Recent search history chip.
class RecentSearchChip extends StatelessWidget {
  const RecentSearchChip({
    super.key,
    required this.query,
    required this.onTap,
    required this.onDelete,
  });

  final String query;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () {
        AppHaptics.light();
        onTap();
      },
      child: Chip(
        avatar: Icon(Icons.history_rounded, size: 16, color: scheme.outline),
        label: Text(query, style: const TextStyle(fontSize: 12)),
        deleteIcon: Icon(Icons.close_rounded, size: 14, color: scheme.outline),
        onDeleted: () {
          AppHaptics.light();
          onDelete();
        },
        backgroundColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
      ),
    );
  }
}

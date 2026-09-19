import 'package:flutter/material.dart';
import '../core/haptics/haptic_feedback.dart';

/// Help article data.
class HelpArticle {
  const HelpArticle({
    required this.id,
    required this.title,
    required this.summary,
    required this.content,
    this.category = 'general',
  });

  final String id;
  final String title;
  final String summary;
  final String content;
  final String category;
}

/// Help center widget with searchable articles.
class HelpCenter extends StatefulWidget {
  const HelpCenter({
    super.key,
    required this.articles,
    this.onArticleTap,
  });

  final List<HelpArticle> articles;
  final ValueChanged<HelpArticle>? onArticleTap;

  @override
  State<HelpCenter> createState() => _HelpCenterState();
}

class _HelpCenterState extends State<HelpCenter> {
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final filtered = widget.articles.where((a) {
      if (_search.isEmpty) return true;
      return a.title.toLowerCase().contains(_search.toLowerCase()) ||
          a.summary.toLowerCase().contains(_search.toLowerCase());
    }).toList();

    final categories = filtered.map((a) => a.category).toSet().toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Search
        Padding(
          padding: const EdgeInsets.all(16),
          child: SearchBar(
            hintText: 'Search help...',
            leading: const Padding(
              padding: EdgeInsets.only(left: 12),
              child: Icon(Icons.search_rounded, size: 20),
            ),
            onChanged: (v) => setState(() => _search = v),
          ),
        ),
        // Articles by category
        Expanded(
          child: ListView.builder(
            itemCount: categories.length,
            itemBuilder: (context, catIndex) {
              final category = categories[catIndex];
              final catArticles = filtered
                  .where((a) => a.category == category)
                  .toList();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Text(
                      category.toUpperCase(),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ),
                  ...catArticles.map((article) => ListTile(
                        title: Text(article.title),
                        subtitle: Text(
                          article.summary,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing:
                            const Icon(Icons.chevron_right_rounded, size: 20),
                        onTap: () {
                          AppHaptics.light();
                          widget.onArticleTap?.call(article);
                        },
                      )),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

/// FAQ accordion widget.
class FaqAccordion extends StatefulWidget {
  const FaqAccordion({
    super.key,
    required this.question,
    required this.answer,
  });

  final String question;
  final String answer;

  @override
  State<FaqAccordion> createState() => _FaqAccordionState();
}

class _FaqAccordionState extends State<FaqAccordion> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: InkWell(
        onTap: () {
          AppHaptics.light();
          setState(() => _expanded = !_expanded);
        },
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.question,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
              if (_expanded) ...[
                const SizedBox(height: 12),
                Text(
                  widget.answer,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.5,
                      ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Contact support button.
class ContactSupport extends StatelessWidget {
  const ContactSupport({
    super.key,
    required this.onTap,
  });

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: InkWell(
        onTap: () {
          AppHaptics.light();
          onTap();
        },
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.support_agent_rounded,
                    color: scheme.onPrimaryContainer),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Contact Support',
                      style:
                          Theme.of(context).textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Get help from our team',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: scheme.outline),
            ],
          ),
        ),
      ),
    );
  }
}

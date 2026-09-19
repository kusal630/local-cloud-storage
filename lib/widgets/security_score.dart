import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

/// Security score indicator showing overall security health.
class SecurityScore extends StatelessWidget {
  const SecurityScore({
    super.key,
    required this.score,
    required this.checks,
  });

  final int score; // 0-100
  final List<SecurityCheck> checks;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = _scoreColor(score);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.shield_rounded, color: color, size: 24),
                const SizedBox(width: 8),
                Text(
                  'Security Score',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '$score/100',
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Score bar
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: score / 100,
                minHeight: 8,
                color: color,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
            const SizedBox(height: 16),
            // Checks
            ...checks.map((check) => _SecurityCheckRow(check: check)),
          ],
        ),
      ),
    ).animate().fadeIn(duration: 300.ms);
  }

  Color _scoreColor(int score) {
    if (score >= 80) return Colors.green;
    if (score >= 60) return Colors.orange;
    return Colors.red;
  }
}

/// Individual security check item.
class SecurityCheck {
  const SecurityCheck({
    required this.name,
    required this.passed,
    this.description,
  });

  final String name;
  final bool passed;
  final String? description;
}

class _SecurityCheckRow extends StatelessWidget {
  const _SecurityCheckRow({required this.check});

  final SecurityCheck check;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            check.passed
                ? Icons.check_circle_rounded
                : Icons.warning_rounded,
            color: check.passed ? Colors.green : Colors.orange,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  check.name,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                ),
                if (check.description != null)
                  Text(
                    check.description!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.outline,
                        ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Quick security tips widget.
class SecurityTips extends StatelessWidget {
  const SecurityTips({super.key, required this.tips});

  final List<SecurityTip> tips;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.lightbulb_rounded,
                    color: scheme.tertiary, size: 20),
                const SizedBox(width: 8),
                Text(
                  'Security Tips',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...tips.map((tip) => _SecurityTipRow(tip: tip)),
          ],
        ),
      ),
    );
  }
}

class SecurityTip {
  const SecurityTip({
    required this.title,
    required this.description,
    this.action,
    this.onTap,
  });

  final String title;
  final String description;
  final String? action;
  final VoidCallback? onTap;
}

class _SecurityTipRow extends StatelessWidget {
  const _SecurityTipRow({required this.tip});

  final SecurityTip tip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lightbulb_outline_rounded,
              size: 16, color: scheme.outline),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tip.title,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  tip.description,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
                if (tip.action != null && tip.onTap != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: GestureDetector(
                      onTap: tip.onTap,
                      child: Text(
                        tip.action!,
                        style: TextStyle(
                          color: scheme.primary,
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

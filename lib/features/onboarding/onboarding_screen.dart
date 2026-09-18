import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// First-run value intro: 3 short pages, skippable, shown exactly once.
/// (Research: teach value fast, then get out of the way — details live in
/// contextual empty states, not in a manual.)
class OnboardingFlow extends StatefulWidget {
  const OnboardingFlow({super.key, required this.onDone});
  final VoidCallback onDone;

  static const _seenKey = 'onboarding_seen_v1';

  static Future<bool> seen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_seenKey) ?? false;
    } catch (_) {
      return true;
    }
  }

  static Future<void> markSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_seenKey, true);
    } catch (_) {}
  }

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  final _controller = PageController();
  int _page = 0;

  static const _pages = [
    (
      icon: Icons.cloud_off_rounded,
      title: 'Your disk, now a cloud',
      body:
          'Turn any folder, SSD, or SD card into private storage that works without the internet.',
    ),
    (
      icon: Icons.qr_code_2_rounded,
      title: 'Pair in seconds',
      body:
          'Start a node, scan the QR on your other device, and browse. Nothing leaves your network.',
    ),
    (
      icon: Icons.backup_rounded,
      title: 'Backed up like a pro',
      body:
          'Auto Backup uploads new photos, versions keep history, and trash keeps mistakes recoverable.',
    ),
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    await OnboardingFlow.markSeen();
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _finish,
                child: const Text('Skip'),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: _pages.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (_, i) {
                  final page = _pages[i];
                  return Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 120,
                          height: 120,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                scheme.primary,
                                scheme.tertiary
                              ],
                            ),
                            borderRadius: BorderRadius.circular(34),
                          ),
                          child: Icon(page.icon,
                              size: 56, color: scheme.onPrimary),
                        ),
                        const SizedBox(height: 28),
                        Text(page.title,
                            textAlign: TextAlign.center,
                            style: Theme.of(context)
                                .textTheme
                                .headlineSmall
                                ?.copyWith(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 12),
                        Text(page.body,
                            textAlign: TextAlign.center,
                            style: Theme.of(context)
                                .textTheme
                                .bodyLarge
                                ?.copyWith(
                                    color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  );
                },
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < _pages.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin:
                        const EdgeInsets.symmetric(horizontal: 4),
                    width: _page == i ? 24 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _page == i
                          ? scheme.primary
                          : scheme.outlineVariant,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: FilledButton(
                onPressed: () {
                  if (_page == _pages.length - 1) {
                    _finish();
                  } else {
                    _controller.nextPage(
                      duration:
                          const Duration(milliseconds: 250),
                      curve: Curves.easeOut,
                    );
                  }
                },
                child: Text(
                    _page == _pages.length - 1 ? 'Get started' : 'Next'),
              ),
            ),
            const SizedBox(height: 28),
          ],
        ),
      ),
    );
  }
}

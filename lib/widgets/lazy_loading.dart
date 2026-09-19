import 'package:flutter/material.dart';

/// Lazy loading wrapper that only builds visible items.
///
/// For large file lists (1000+), this prevents jank by only building
/// items that are about to scroll into view.
class LazyLoadList extends StatefulWidget {
  const LazyLoadList({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.scrollDirection = Axis.vertical,
    this.padding,
    this.physics,
  });

  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;
  final Axis scrollDirection;
  final EdgeInsetsGeometry? padding;
  final ScrollPhysics? physics;

  @override
  State<LazyLoadList> createState() => _LazyLoadListState();
}

class _LazyLoadListState extends State<LazyLoadList> {
  final _controller = ScrollController();
  final _visibleIndices = <int>{};

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
  }

  @override
  void dispose() {
    _controller.removeListener(_onScroll);
    _controller.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_controller.hasClients) return;
    final viewport = _controller.position.viewportDimension;
    final offset = _controller.offset;
    final start = (offset / 100).floor();
    final end = ((offset + viewport) / 100).ceil() + 2;

    final newVisible = <int>{};
    for (var i = start; i < end && i < widget.itemCount; i++) {
      newVisible.add(i);
    }

    if (newVisible.difference(_visibleIndices).isNotEmpty) {
      setState(() {
        _visibleIndices.addAll(newVisible);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: _controller,
      scrollDirection: widget.scrollDirection,
      padding: widget.padding,
      physics: widget.physics,
      itemCount: widget.itemCount,
      itemBuilder: (context, index) {
        // Only build items that are visible or in cache range
        if (!_visibleIndices.contains(index)) {
          return const SizedBox.shrink();
        }
        return widget.itemBuilder(context, index);
      },
    );
  }
}

/// Performance-optimized grid view with lazy item building.
class LazyLoadGrid extends StatefulWidget {
  const LazyLoadGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    required this.gridDelegate,
    this.padding,
    this.physics,
  });

  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;
  final SliverGridDelegate gridDelegate;
  final EdgeInsetsGeometry? padding;
  final ScrollPhysics? physics;

  @override
  State<LazyLoadGrid> createState() => _LazyLoadGridState();
}

class _LazyLoadGridState extends State<LazyLoadGrid> {
  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: widget.padding,
      physics: widget.physics,
      gridDelegate: widget.gridDelegate,
      itemCount: widget.itemCount,
      // Flutter's GridView already has built-in lazy loading via slivers
      itemBuilder: widget.itemBuilder,
    );
  }
}

/// Animated list item with entrance animation.
class AnimatedListItem extends StatelessWidget {
  const AnimatedListItem({
    super.key,
    required this.index,
    required this.child,
    this.delay = 50,
  });

  final int index;
  final Widget child;
  final int delay;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: Duration(milliseconds: 300 + (index * delay).clamp(0, 1000)),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, 20 * (1 - value)),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

import 'package:flutter/material.dart';

const _kDividerThickness = 6.0;
const _kDropZoneRatio = 0.25;
const _kMinPaneSize = 80.0;

enum SplitDirection { horizontal, vertical }

sealed class SplitNode {
  final String id;
  SplitNode(this.id);
}

class SplitLeaf extends SplitNode {
  int tabIndex;
  SplitLeaf({required String id, required this.tabIndex}) : super(id);
}

class SplitBranch extends SplitNode {
  SplitDirection direction;
  SplitNode first;
  SplitNode second;
  double ratio;

  SplitBranch({
    required String id,
    required this.direction,
    required this.first,
    required this.second,
    this.ratio = 0.5,
  }) : super(id);
}

enum DropPosition { left, right, top, bottom }

class SplitViewController {
  SplitNode root;
  String? focusedLeafId;
  int _nextId = 0;

  SplitViewController({required int initialTabIndex})
      : root = SplitLeaf(id: '0', tabIndex: initialTabIndex) {
    focusedLeafId = '0';
    _nextId = 1;
  }

  String _genId() => '${_nextId++}';

  void splitLeaf(String leafId, DropPosition position, int newTabIndex) {
    final leaf = _findLeaf(root, leafId);
    if (leaf == null) return;

    final direction = (position == DropPosition.left ||
            position == DropPosition.right)
        ? SplitDirection.horizontal
        : SplitDirection.vertical;

    final newLeaf = SplitLeaf(id: _genId(), tabIndex: newTabIndex);
    final isFirstNew =
        position == DropPosition.left || position == DropPosition.top;

    final branch = SplitBranch(
      id: _genId(),
      direction: direction,
      first: isFirstNew ? newLeaf : SplitLeaf(id: leaf.id, tabIndex: leaf.tabIndex),
      second: isFirstNew ? SplitLeaf(id: leaf.id, tabIndex: leaf.tabIndex) : newLeaf,
    );

    _replaceNode(leafId, branch);
    focusedLeafId = newLeaf.id;
  }

  void closeLeaf(String leafId) {
    if (root is SplitLeaf) return;
    final parent = _findParent(root, leafId);
    if (parent == null) return;

    final sibling =
        parent.first.id == leafId ? parent.second : parent.first;

    _replaceNode(parent.id, sibling);

    if (focusedLeafId == leafId) {
      focusedLeafId = _firstLeaf(root)?.id;
    }
  }

  void removeTabFromAll(int tabIndex) {
    final leaves = <SplitLeaf>[];
    _collectLeaves(root, leaves);
    for (final leaf in leaves) {
      if (leaf.tabIndex == tabIndex) {
        if (root is SplitLeaf) {
          // Last pane, don't close
          continue;
        }
        closeLeaf(leaf.id);
      }
    }
    // Adjust indices for tabs after the removed one
    final allLeaves = <SplitLeaf>[];
    _collectLeaves(root, allLeaves);
    for (final leaf in allLeaves) {
      if (leaf.tabIndex > tabIndex) {
        leaf.tabIndex--;
      }
    }
  }

  SplitLeaf? focusedLeaf() {
    if (focusedLeafId == null) return null;
    return _findLeaf(root, focusedLeafId!);
  }

  List<SplitLeaf> allLeaves() {
    final leaves = <SplitLeaf>[];
    _collectLeaves(root, leaves);
    return leaves;
  }

  void _collectLeaves(SplitNode node, List<SplitLeaf> out) {
    if (node is SplitLeaf) {
      out.add(node);
    } else if (node is SplitBranch) {
      _collectLeaves(node.first, out);
      _collectLeaves(node.second, out);
    }
  }

  SplitLeaf? _findLeaf(SplitNode node, String id) {
    if (node is SplitLeaf && node.id == id) return node;
    if (node is SplitBranch) {
      return _findLeaf(node.first, id) ?? _findLeaf(node.second, id);
    }
    return null;
  }

  SplitLeaf? _firstLeaf(SplitNode node) {
    if (node is SplitLeaf) return node;
    if (node is SplitBranch) return _firstLeaf(node.first);
    return null;
  }

  SplitBranch? _findParent(SplitNode node, String childId) {
    if (node is SplitBranch) {
      if (node.first.id == childId || node.second.id == childId) return node;
      return _findParent(node.first, childId) ??
          _findParent(node.second, childId);
    }
    return null;
  }

  void _replaceNode(String targetId, SplitNode replacement) {
    if (root.id == targetId) {
      root = replacement;
      return;
    }
    _replaceInTree(root, targetId, replacement);
  }

  void _replaceInTree(SplitNode node, String targetId, SplitNode replacement) {
    if (node is SplitBranch) {
      if (node.first.id == targetId) {
        node.first = replacement;
        return;
      }
      if (node.second.id == targetId) {
        node.second = replacement;
        return;
      }
      _replaceInTree(node.first, targetId, replacement);
      _replaceInTree(node.second, targetId, replacement);
    }
  }
}

class SplitView extends StatefulWidget {
  final SplitViewController controller;
  final Widget Function(int tabIndex, String leafId, bool focused) paneBuilder;
  final void Function(String leafId) onFocusChanged;
  final void Function() onChanged;
  final int tabCount;

  const SplitView({
    super.key,
    required this.controller,
    required this.paneBuilder,
    required this.onFocusChanged,
    required this.onChanged,
    required this.tabCount,
  });

  @override
  State<SplitView> createState() => _SplitViewState();
}

class _SplitViewState extends State<SplitView> {
  @override
  Widget build(BuildContext context) {
    return _buildNode(widget.controller.root);
  }

  Widget _buildNode(SplitNode node) {
    if (node is SplitLeaf) {
      return _buildLeafPane(node);
    }
    if (node is SplitBranch) {
      return _buildBranch(node);
    }
    return const SizedBox.shrink();
  }

  Widget _buildBranch(SplitBranch branch) {
    final isHorizontal = branch.direction == SplitDirection.horizontal;

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalSize = isHorizontal
            ? constraints.maxWidth
            : constraints.maxHeight;
        final dividerSize = _kDividerThickness;
        final availableSize = totalSize - dividerSize;
        final firstSize = (availableSize * branch.ratio)
            .clamp(_kMinPaneSize, availableSize - _kMinPaneSize);
        final secondSize = availableSize - firstSize;

        final children = <Widget>[
          SizedBox(
            width: isHorizontal ? firstSize : null,
            height: isHorizontal ? null : firstSize,
            child: _buildNode(branch.first),
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanUpdate: (details) {
              setState(() {
                final delta = isHorizontal
                    ? details.delta.dx
                    : details.delta.dy;
                final newFirstSize = (firstSize + delta)
                    .clamp(_kMinPaneSize, availableSize - _kMinPaneSize);
                branch.ratio = newFirstSize / availableSize;
              });
              widget.onChanged();
            },
            child: MouseRegion(
              cursor: isHorizontal
                  ? SystemMouseCursors.resizeColumn
                  : SystemMouseCursors.resizeRow,
              child: Container(
                width: isHorizontal ? dividerSize : null,
                height: isHorizontal ? null : dividerSize,
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
          ),
          SizedBox(
            width: isHorizontal ? secondSize : null,
            height: isHorizontal ? null : secondSize,
            child: _buildNode(branch.second),
          ),
        ];

        return isHorizontal
            ? Row(children: children)
            : Column(children: children);
      },
    );
  }

  Widget _buildLeafPane(SplitLeaf leaf) {
    final focused = widget.controller.focusedLeafId == leaf.id;
    final tabIndex = leaf.tabIndex;

    if (tabIndex < 0 || tabIndex >= widget.tabCount) {
      return Container(color: Colors.black);
    }

    return GestureDetector(
      onTap: () {
        widget.controller.focusedLeafId = leaf.id;
        widget.onFocusChanged(leaf.id);
      },
      child: DragTarget<int>(
        builder: (context, candidateData, rejectedData) {
          final showDropZones = candidateData.isNotEmpty;
          return Stack(
            children: [
              Container(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: focused
                        ? Theme.of(context).colorScheme.primary
                        : Colors.transparent,
                    width: 1,
                  ),
                ),
                child: widget.paneBuilder(tabIndex, leaf.id, focused),
              ),
              if (showDropZones) ..._buildDropZones(leaf),
            ],
          );
        },
        onWillAcceptWithDetails: (details) {
          return details.data != leaf.tabIndex;
        },
        onAcceptWithDetails: (details) {
          // Determine drop position based on pointer location
          // This is handled by individual drop zones
        },
      ),
    );
  }

  List<Widget> _buildDropZones(SplitLeaf leaf) {
    return [
      // Left
      _dropZone(
        leaf,
        DropPosition.left,
        Alignment.centerLeft,
        FractionalOffset(0, 0),
        _kDropZoneRatio,
        1.0,
      ),
      // Right
      _dropZone(
        leaf,
        DropPosition.right,
        Alignment.centerRight,
        FractionalOffset(1 - _kDropZoneRatio, 0),
        _kDropZoneRatio,
        1.0,
      ),
      // Top
      _dropZone(
        leaf,
        DropPosition.top,
        Alignment.topCenter,
        FractionalOffset(0, 0),
        1.0,
        _kDropZoneRatio,
      ),
      // Bottom
      _dropZone(
        leaf,
        DropPosition.bottom,
        Alignment.bottomCenter,
        FractionalOffset(0, 1 - _kDropZoneRatio),
        1.0,
        _kDropZoneRatio,
      ),
    ];
  }

  Widget _dropZone(
    SplitLeaf leaf,
    DropPosition position,
    Alignment alignment,
    FractionalOffset offset,
    double widthFactor,
    double heightFactor,
  ) {
    return Positioned.fill(
      child: FractionallySizedBox(
        alignment: alignment,
        widthFactor: widthFactor,
        heightFactor: heightFactor,
        child: DragTarget<int>(
          builder: (context, candidates, rejected) {
            return Container(
              color: candidates.isNotEmpty
                  ? Theme.of(context).colorScheme.primary.withAlpha(60)
                  : Colors.transparent,
            );
          },
          onWillAcceptWithDetails: (details) {
            return details.data != leaf.tabIndex;
          },
          onAcceptWithDetails: (details) {
            setState(() {
              widget.controller.splitLeaf(leaf.id, position, details.data);
            });
            widget.onChanged();
          },
        ),
      ),
    );
  }
}

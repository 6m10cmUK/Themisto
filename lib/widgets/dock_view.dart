import 'package:flutter/material.dart';

const _kDividerThickness = 6.0;
const _kDropEdgeRatio = 0.25;
const _kMinPaneSize = 80.0;
const _kTabBarHeight = 32.0;

enum DockDirection { horizontal, vertical }

sealed class DockNode {
  final String id;
  DockNode(this.id);
}

class DockLeaf extends DockNode {
  List<int> tabIndices;
  int activeTabIndex;

  DockLeaf({
    required String id,
    required this.tabIndices,
    int? activeTabIndex,
  })  : activeTabIndex =
            activeTabIndex ?? (tabIndices.isNotEmpty ? tabIndices.first : 0),
        super(id);
}

class DockBranch extends DockNode {
  DockDirection direction;
  DockNode first;
  DockNode second;
  double ratio;

  DockBranch({
    required String id,
    required this.direction,
    required this.first,
    required this.second,
    this.ratio = 0.5,
  }) : super(id);
}

class DockTabDragData {
  final int tabIndex;
  final String sourceLeafId;

  DockTabDragData({required this.tabIndex, required this.sourceLeafId});
}

enum DockDropPosition { left, right, top, bottom, center }

class DockViewController {
  DockNode root;
  String? focusedLeafId;
  int _nextId = 0;

  DockViewController({required int initialTabIndex})
      : root = DockLeaf(
          id: '0',
          tabIndices: [initialTabIndex],
        ) {
    focusedLeafId = '0';
    _nextId = 1;
  }

  String _genId() => '${_nextId++}';

  void addTabToLeaf(String leafId, int tabIndex) {
    final leaf = _findLeaf(root, leafId);
    if (leaf == null) return;
    if (!leaf.tabIndices.contains(tabIndex)) {
      leaf.tabIndices.add(tabIndex);
    }
    leaf.activeTabIndex = tabIndex;
  }

  void moveTabToLeaf(String targetLeafId, int tabIndex) {
    // Remove from source leaf
    for (final leaf in allLeaves()) {
      if (leaf.tabIndices.contains(tabIndex)) {
        leaf.tabIndices.remove(tabIndex);
        if (leaf.activeTabIndex == tabIndex) {
          leaf.activeTabIndex =
              leaf.tabIndices.isNotEmpty ? leaf.tabIndices.last : -1;
        }
        if (leaf.tabIndices.isEmpty) {
          _closeLeaf(leaf.id);
        }
        break;
      }
    }
    // Add to target
    final target = _findLeaf(root, targetLeafId);
    if (target != null) {
      if (!target.tabIndices.contains(tabIndex)) {
        target.tabIndices.add(tabIndex);
      }
      target.activeTabIndex = tabIndex;
      focusedLeafId = targetLeafId;
    }
  }

  void splitLeaf(String leafId, DockDropPosition position, int tabIndex) {
    if (position == DockDropPosition.center) {
      moveTabToLeaf(leafId, tabIndex);
      return;
    }

    final leaf = _findLeaf(root, leafId);
    if (leaf == null) return;

    // Remove tabIndex from its current leaf
    for (final l in allLeaves()) {
      if (l.tabIndices.contains(tabIndex)) {
        l.tabIndices.remove(tabIndex);
        if (l.activeTabIndex == tabIndex) {
          l.activeTabIndex =
              l.tabIndices.isNotEmpty ? l.tabIndices.last : -1;
        }
        if (l.tabIndices.isEmpty && l.id != leafId) {
          _closeLeaf(l.id);
        }
        break;
      }
    }

    final direction =
        (position == DockDropPosition.left || position == DockDropPosition.right)
            ? DockDirection.horizontal
            : DockDirection.vertical;

    final newLeaf = DockLeaf(
      id: _genId(),
      tabIndices: [tabIndex],
    );

    final isFirstNew =
        position == DockDropPosition.left || position == DockDropPosition.top;

    final existingCopy = DockLeaf(
      id: leaf.id,
      tabIndices: List.of(leaf.tabIndices),
      activeTabIndex: leaf.activeTabIndex,
    );

    final branch = DockBranch(
      id: _genId(),
      direction: direction,
      first: isFirstNew ? newLeaf : existingCopy,
      second: isFirstNew ? existingCopy : newLeaf,
    );

    _replaceNode(leafId, branch);
    focusedLeafId = newLeaf.id;
  }

  void activateTab(String leafId, int tabIndex) {
    final leaf = _findLeaf(root, leafId);
    if (leaf != null && leaf.tabIndices.contains(tabIndex)) {
      leaf.activeTabIndex = tabIndex;
      focusedLeafId = leafId;
    }
  }

  void reorderTab(String leafId, int oldPos, int newPos) {
    final leaf = _findLeaf(root, leafId);
    if (leaf == null) return;
    if (oldPos < 0 || oldPos >= leaf.tabIndices.length) return;
    if (newPos < 0 || newPos >= leaf.tabIndices.length) return;
    final tab = leaf.tabIndices.removeAt(oldPos);
    leaf.tabIndices.insert(newPos, tab);
  }

  void closeTab(int tabIndex) {
    for (final leaf in allLeaves()) {
      leaf.tabIndices.remove(tabIndex);
      if (leaf.activeTabIndex == tabIndex) {
        leaf.activeTabIndex =
            leaf.tabIndices.isNotEmpty ? leaf.tabIndices.last : -1;
      }
      if (leaf.tabIndices.isEmpty) {
        _closeLeaf(leaf.id);
      }
    }
    _adjustIndicesAfterRemoval(tabIndex);
  }

  void _adjustIndicesAfterRemoval(int removedIndex) {
    for (final leaf in allLeaves()) {
      leaf.tabIndices =
          leaf.tabIndices.map((i) => i > removedIndex ? i - 1 : i).toList();
      if (leaf.activeTabIndex > removedIndex) {
        leaf.activeTabIndex--;
      }
    }
  }

  DockLeaf? focusedLeaf() {
    if (focusedLeafId == null) return null;
    return _findLeaf(root, focusedLeafId!);
  }

  List<DockLeaf> allLeaves() {
    final out = <DockLeaf>[];
    _collectLeaves(root, out);
    return out;
  }

  DockLeaf? findLeafContaining(int tabIndex) {
    for (final leaf in allLeaves()) {
      if (leaf.tabIndices.contains(tabIndex)) return leaf;
    }
    return null;
  }

  void _closeLeaf(String leafId) {
    if (root is DockLeaf) return;
    final parent = _findParent(root, leafId);
    if (parent == null) return;

    final sibling =
        parent.first.id == leafId ? parent.second : parent.first;
    _replaceNode(parent.id, sibling);

    if (focusedLeafId == leafId) {
      focusedLeafId = _firstLeaf(root)?.id;
    }
  }

  void _collectLeaves(DockNode node, List<DockLeaf> out) {
    if (node is DockLeaf) {
      out.add(node);
    } else if (node is DockBranch) {
      _collectLeaves(node.first, out);
      _collectLeaves(node.second, out);
    }
  }

  DockLeaf? _findLeaf(DockNode node, String id) {
    if (node is DockLeaf && node.id == id) return node;
    if (node is DockBranch) {
      return _findLeaf(node.first, id) ?? _findLeaf(node.second, id);
    }
    return null;
  }

  DockLeaf? _firstLeaf(DockNode node) {
    if (node is DockLeaf) return node;
    if (node is DockBranch) return _firstLeaf(node.first);
    return null;
  }

  DockBranch? _findParent(DockNode node, String childId) {
    if (node is DockBranch) {
      if (node.first.id == childId || node.second.id == childId) return node;
      return _findParent(node.first, childId) ??
          _findParent(node.second, childId);
    }
    return null;
  }

  void _replaceNode(String targetId, DockNode replacement) {
    if (root.id == targetId) {
      root = replacement;
      return;
    }
    _replaceInTree(root, targetId, replacement);
  }

  void _replaceInTree(
      DockNode node, String targetId, DockNode replacement) {
    if (node is DockBranch) {
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

// ---------------------------------------------------------------------------
// Widget
// ---------------------------------------------------------------------------

class DockView extends StatefulWidget {
  final DockViewController controller;
  final int tabCount;
  final Widget Function(int tabIndex) tabBuilder;
  final Widget Function(int tabIndex, String leafId, bool focused) paneBuilder;
  final void Function(String leafId) onFocusChanged;
  final void Function(int tabIndex) onTabClosed;
  final void Function(int tabIndex)? onTabReloaded;
  final void Function() onChanged;

  const DockView({
    super.key,
    required this.controller,
    required this.tabCount,
    required this.tabBuilder,
    required this.paneBuilder,
    required this.onFocusChanged,
    required this.onTabClosed,
    this.onTabReloaded,
    required this.onChanged,
  });

  @override
  State<DockView> createState() => _DockViewState();
}

class _DockViewState extends State<DockView> {
  @override
  Widget build(BuildContext context) {
    return _buildNode(widget.controller.root);
  }

  Widget _buildNode(DockNode node) {
    if (node is DockLeaf) return _buildLeaf(node);
    if (node is DockBranch) return _buildBranch(node);
    return const SizedBox.shrink();
  }

  // -- Branch (divider + two children) --------------------------------------

  Widget _buildBranch(DockBranch branch) {
    final isHorizontal = branch.direction == DockDirection.horizontal;

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalSize =
            isHorizontal ? constraints.maxWidth : constraints.maxHeight;
        const dividerSize = _kDividerThickness;
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
                final delta =
                    isHorizontal ? details.delta.dx : details.delta.dy;
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

  // -- Leaf (tab bar + content) ---------------------------------------------

  Widget _buildLeaf(DockLeaf leaf) {
    final focused = widget.controller.focusedLeafId == leaf.id;

    return Listener(
      onPointerDown: (_) {
        if (widget.controller.focusedLeafId != leaf.id) {
          widget.controller.focusedLeafId = leaf.id;
          widget.onFocusChanged(leaf.id);
          setState(() {});
        }
      },
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: focused
                ? Theme.of(context).colorScheme.primary
                : Colors.transparent,
            width: 1,
          ),
        ),
        child: Column(
          children: [
            _buildLeafTabBar(leaf, focused),
            Expanded(child: _buildLeafContent(leaf, focused)),
          ],
        ),
      ),
    );
  }

  // -- Tab bar --------------------------------------------------------------

  Widget _buildLeafTabBar(DockLeaf leaf, bool focused) {
    return DragTarget<DockTabDragData>(
      onWillAcceptWithDetails: (details) {
        // Accept drops from other leaves
        if (details.data.sourceLeafId == leaf.id &&
            leaf.tabIndices.length <= 1) {
          return false;
        }
        return true;
      },
      onAcceptWithDetails: (details) {
        setState(() {
          if (details.data.sourceLeafId != leaf.id) {
            widget.controller.moveTabToLeaf(leaf.id, details.data.tabIndex);
          }
        });
        widget.onChanged();
      },
      builder: (context, candidates, rejected) {
        final highlight = candidates.isNotEmpty;
        return Container(
          height: _kTabBarHeight,
          decoration: BoxDecoration(
            color: highlight
                ? Theme.of(context).colorScheme.primary.withAlpha(30)
                : Theme.of(context).colorScheme.surfaceContainerLow,
            border: Border(
              bottom: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
                width: 1,
              ),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: leaf.tabIndices.map((tabIndex) {
                    return _buildDraggableTab(leaf, tabIndex);
                  }).toList(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDraggableTab(DockLeaf leaf, int tabIndex) {
    final isActive = tabIndex == leaf.activeTabIndex;
    final isFocused = widget.controller.focusedLeafId == leaf.id;

    if (tabIndex < 0 || tabIndex >= widget.tabCount) {
      return const SizedBox.shrink();
    }

    final tabContent = GestureDetector(
      onTap: () {
        setState(() {
          widget.controller.activateTab(leaf.id, tabIndex);
        });
        widget.onFocusChanged(leaf.id);
      },
      child: Container(
        height: _kTabBarHeight,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: isActive
              ? Theme.of(context).colorScheme.surface
              : Colors.transparent,
          border: Border(
            bottom: BorderSide(
              color: isActive && isFocused
                  ? Theme.of(context).colorScheme.primary
                  : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            DefaultTextStyle(
              style: TextStyle(
                fontSize: 13,
                fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                color: Theme.of(context).colorScheme.onSurface,
              ),
              child: widget.tabBuilder(tabIndex),
            ),
            if (widget.onTabReloaded != null) ...[
              const SizedBox(width: 4),
              _tabIconButton(
                  Icons.refresh, () => widget.onTabReloaded!(tabIndex)),
            ],
            const SizedBox(width: 4),
            _tabIconButton(Icons.close, () => widget.onTabClosed(tabIndex)),
          ],
        ),
      ),
    );

    return Draggable<DockTabDragData>(
      data: DockTabDragData(tabIndex: tabIndex, sourceLeafId: leaf.id),
      feedback: Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(6),
          ),
          child: DefaultTextStyle(
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.onSurface,
            ),
            child: widget.tabBuilder(tabIndex),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: tabContent),
      child: tabContent,
    );
  }

  Widget _tabIconButton(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 20,
        height: 20,
        child: Center(
          child: Icon(icon, size: 14),
        ),
      ),
    );
  }

  // -- Leaf content with drop zones -----------------------------------------

  Widget _buildLeafContent(DockLeaf leaf, bool focused) {
    final activeTab = leaf.activeTabIndex;
    if (activeTab < 0 ||
        !leaf.tabIndices.contains(activeTab) ||
        activeTab >= widget.tabCount) {
      return Container(color: Colors.black);
    }

    return DragTarget<DockTabDragData>(
      builder: (context, candidates, rejected) {
        final showDropZones = candidates.isNotEmpty;
        return Stack(
          children: [
            widget.paneBuilder(activeTab, leaf.id, focused),
            if (showDropZones) ..._buildDropZones(leaf),
          ],
        );
      },
      onWillAcceptWithDetails: (details) {
        if (details.data.sourceLeafId == leaf.id &&
            leaf.tabIndices.length <= 1) {
          return false;
        }
        return true;
      },
      onAcceptWithDetails: (details) {
        // Handled by individual zone targets
      },
    );
  }

  List<Widget> _buildDropZones(DockLeaf leaf) {
    return [
      // Center (behind edges so edges take priority)
      _dropZone(
        leaf,
        DockDropPosition.center,
        Alignment.center,
        1.0 - 2 * _kDropEdgeRatio,
        1.0 - 2 * _kDropEdgeRatio,
      ),
      // Left
      _dropZone(
        leaf,
        DockDropPosition.left,
        Alignment.centerLeft,
        _kDropEdgeRatio,
        1.0,
      ),
      // Right
      _dropZone(
        leaf,
        DockDropPosition.right,
        Alignment.centerRight,
        _kDropEdgeRatio,
        1.0,
      ),
      // Top
      _dropZone(
        leaf,
        DockDropPosition.top,
        Alignment.topCenter,
        1.0,
        _kDropEdgeRatio,
      ),
      // Bottom
      _dropZone(
        leaf,
        DockDropPosition.bottom,
        Alignment.bottomCenter,
        1.0,
        _kDropEdgeRatio,
      ),
    ];
  }

  Widget _dropZone(
    DockLeaf leaf,
    DockDropPosition position,
    Alignment alignment,
    double widthFactor,
    double heightFactor,
  ) {
    return Positioned.fill(
      child: FractionallySizedBox(
        alignment: alignment,
        widthFactor: widthFactor,
        heightFactor: heightFactor,
        child: DragTarget<DockTabDragData>(
          builder: (context, candidates, rejected) {
            return Container(
              color: candidates.isNotEmpty
                  ? Theme.of(context).colorScheme.primary.withAlpha(60)
                  : Colors.transparent,
            );
          },
          onWillAcceptWithDetails: (details) {
            if (details.data.sourceLeafId == leaf.id &&
                leaf.tabIndices.length <= 1) {
              return false;
            }
            // Reject center drop to self (already in this leaf)
            if (position == DockDropPosition.center &&
                details.data.sourceLeafId == leaf.id) {
              return false;
            }
            return true;
          },
          onAcceptWithDetails: (details) {
            setState(() {
              widget.controller
                  .splitLeaf(leaf.id, position, details.data.tabIndex);
            });
            widget.onChanged();
          },
        ),
      ),
    );
  }
}

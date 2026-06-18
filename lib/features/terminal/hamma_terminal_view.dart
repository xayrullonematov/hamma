// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'package:xterm/xterm.dart';
import 'package:xterm/src/ui/custom_text_edit.dart';
import 'package:xterm/src/ui/gesture/gesture_detector.dart';
import 'package:xterm/src/ui/input_map.dart';
import 'package:xterm/src/ui/keyboard_listener.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/src/ui/scroll_handler.dart';
import 'package:xterm/src/ui/shortcut/actions.dart';

class HammaTerminalView extends StatefulWidget {
  const HammaTerminalView(
    this.terminal, {
    super.key,
    this.controller,
    this.theme = TerminalThemes.defaultTheme,
    this.textStyle = const TerminalStyle(),
    this.textScaler,
    this.padding,
    this.scrollController,
    this.autoResize = true,
    this.backgroundOpacity = 1,
    this.focusNode,
    this.autofocus = false,
    this.onTapUp,
    this.onSecondaryTapDown,
    this.onSecondaryTapUp,
    this.mouseCursor = SystemMouseCursors.text,
    this.keyboardType = TextInputType.emailAddress,
    this.keyboardAppearance = Brightness.dark,
    this.cursorType = TerminalCursorType.block,
    this.alwaysShowCursor = false,
    this.deleteDetection = false,
    this.shortcuts,
    this.onKeyEvent,
    this.readOnly = false,
    this.hardwareKeyboardOnly = false,
    this.simulateScroll = true,
    this.onExplainWithCopilot,
  });

  /// The underlying terminal that this widget renders.
  final Terminal terminal;

  final TerminalController? controller;

  /// The theme to use for this terminal.
  final TerminalTheme theme;

  /// The style to use for painting characters.
  final TerminalStyle textStyle;

  final TextScaler? textScaler;

  /// Padding around the inner [Scrollable] widget.
  final EdgeInsets? padding;

  /// Scroll controller for the inner [Scrollable] widget.
  final ScrollController? scrollController;

  /// Should this widget automatically notify the underlying terminal when its
  /// size changes. [true] by default.
  final bool autoResize;

  /// Opacity of the terminal background. Set to 0 to make the terminal
  /// background transparent.
  final double backgroundOpacity;

  /// An optional focus node to use as the focus node for this widget.
  final FocusNode? focusNode;

  /// True if this widget will be selected as the initial focus when no other
  /// node in its scope is currently focused.
  final bool autofocus;

  /// Callback for when the user taps on the terminal.
  final void Function(TapUpDetails, CellOffset)? onTapUp;

  /// Function called when the user taps on the terminal with a secondary
  /// button.
  final void Function(TapDownDetails, CellOffset)? onSecondaryTapDown;

  /// Function called when the user stops holding down a secondary button.
  final void Function(TapUpDetails, CellOffset)? onSecondaryTapUp;

  /// The mouse cursor for mouse pointers that are hovering over the terminal.
  /// [SystemMouseCursors.text] by default.
  final MouseCursor mouseCursor;

  /// The type of information for which to optimize the text input control.
  /// [TextInputType.emailAddress] by default.
  final TextInputType keyboardType;

  /// The appearance of the keyboard. [Brightness.dark] by default.
  ///
  /// This setting is only honored on iOS devices.
  final Brightness keyboardAppearance;

  /// The type of cursor to use. [TerminalCursorType.block] by default.
  final TerminalCursorType cursorType;

  /// Whether to always show the cursor. This is useful for debugging.
  /// [false] by default.
  final bool alwaysShowCursor;

  /// Workaround to detect delete key for platforms and IMEs that does not
  /// emit hardware delete event. Prefered on mobile platforms. [false] by
  /// default.
  final bool deleteDetection;

  /// Shortcuts for this terminal. This has higher priority than input handler
  /// of the terminal If not provided, [defaultTerminalShortcuts] will be used.
  final Map<ShortcutActivator, Intent>? shortcuts;

  /// Keyboard event handler of the terminal. This has higher priority than
  /// [shortcuts] and input handler of the terminal.
  final FocusOnKeyEventCallback? onKeyEvent;

  /// True if no input should send to the terminal.
  final bool readOnly;

  /// True if only hardware keyboard events should be used as input. This will
  /// also prevent any on-screen keyboard to be shown.
  final bool hardwareKeyboardOnly;

  /// If true, when the terminal is in alternate buffer (for example running
  /// vim, man, etc), if the application does not declare that it can handle
  /// scrolling, the terminal will simulate scrolling by sending up/down arrow
  /// keys to the application. This is standard behavior for most terminal
  /// emulators. True by default.
  final bool simulateScroll;

  /// Called when the user clicks 'Explain with Copilot' from the selection menu.
  final void Function(String)? onExplainWithCopilot;

  @override
  State<HammaTerminalView> createState() => HammaTerminalViewState();
}

class HammaTerminalViewState extends State<HammaTerminalView> {
  late FocusNode _focusNode;

  late final ShortcutManager _shortcutManager;

  final _customTextEditKey = GlobalKey<CustomTextEditState>();

  final _scrollableKey = GlobalKey<ScrollableState>();

  final _viewportKey = GlobalKey();

  String? _composingText;

  late TerminalController _controller;

  late ScrollController _scrollController;

  RenderTerminal get renderTerminal =>
      _viewportKey.currentContext!.findRenderObject() as RenderTerminal;

  @override
  void initState() {
    _focusNode = widget.focusNode ?? FocusNode();
    _controller = widget.controller ?? TerminalController();
    _scrollController = widget.scrollController ?? ScrollController();
    _shortcutManager = ShortcutManager(
      shortcuts: widget.shortcuts ?? defaultTerminalShortcuts,
    );
    super.initState();
  }

  @override
  void didUpdateWidget(HammaTerminalView oldWidget) {
    if (oldWidget.focusNode != widget.focusNode) {
      if (oldWidget.focusNode == null) {
        _focusNode.dispose();
      }
      _focusNode = widget.focusNode ?? FocusNode();
    }
    if (oldWidget.controller != widget.controller) {
      if (oldWidget.controller == null) {
        _controller.dispose();
      }
      _controller = widget.controller ?? TerminalController();
    }
    if (oldWidget.scrollController != widget.scrollController) {
      if (oldWidget.scrollController == null) {
        _scrollController.dispose();
      }
      _scrollController = widget.scrollController ?? ScrollController();
    }
    _shortcutManager.shortcuts = widget.shortcuts ?? defaultTerminalShortcuts;
    super.didUpdateWidget(oldWidget);
  }

  @override
  void dispose() {
    if (widget.focusNode == null) {
      _focusNode.dispose();
    }
    if (widget.controller == null) {
      _controller.dispose();
    }
    if (widget.scrollController == null) {
      _scrollController.dispose();
    }
    _shortcutManager.dispose();
    super.dispose();
  }

  void _copySelectionToClipboard() async {
    final selection = _controller.selection;
    if (selection != null) {
      final text = widget.terminal.buffer.getText(
        selection,
      );
      if (text.isNotEmpty) {
        await Clipboard.setData(ClipboardData(text: text));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Copied selection to clipboard'),
              duration: Duration(seconds: 1),
            ),
          );
        }
      }
    }
  }

  void _pasteFromClipboard() async {
    if (widget.readOnly) return;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      widget.terminal.textInput(data.text!);
      _scrollToBottom();
    }
  }

  void _selectAll() {
    final lastLine = widget.terminal.buffer.lines.length - 1;
    final lastCol = widget.terminal.viewWidth - 1;
    _controller.setSelection(
      widget.terminal.buffer.createAnchor(0, 0),
      widget.terminal.buffer.createAnchor(lastCol, lastLine),
    );
  }

  void _explainWithCopilot() {
    final selection = _controller.selection;
    if (selection != null) {
      final text = widget.terminal.buffer.getText(
        selection,
      );
      if (text.isNotEmpty && widget.onExplainWithCopilot != null) {
        widget.onExplainWithCopilot!(text);
      }
    }
  }

  void _showContextMenu(BuildContext context, Offset globalPosition) async {
    final selection = _controller.selection;
    final hasSelection = selection != null;
    final overlay = Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
    final hasClipboard = clipboardData?.text != null && clipboardData!.text!.isNotEmpty;

    if (!context.mounted) return;

    final result = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      color: Colors.grey[900],
      elevation: 8,
      items: [
        PopupMenuItem(
          value: 'copy',
          enabled: hasSelection,
          child: Row(
            children: [
              Icon(Icons.copy, size: 16, color: hasSelection ? Colors.white : Colors.white24),
              const SizedBox(width: 8),
              const Text('Copy', style: TextStyle(color: Colors.white, fontSize: 13)),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'paste',
          enabled: hasClipboard && !widget.readOnly,
          child: Row(
            children: [
              Icon(Icons.paste, size: 16, color: (hasClipboard && !widget.readOnly) ? Colors.white : Colors.white24),
              const SizedBox(width: 8),
              const Text('Paste', style: TextStyle(color: Colors.white, fontSize: 13)),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'select_all',
          child: Row(
            children: [
              const Icon(Icons.select_all, size: 16, color: Colors.white),
              const SizedBox(width: 8),
              const Text('Select All', style: TextStyle(color: Colors.white, fontSize: 13)),
            ],
          ),
        ),
        if (hasSelection) ...[
          PopupMenuItem(
            value: 'clear_selection',
            child: Row(
              children: [
                const Icon(Icons.clear, size: 16, color: Colors.white),
                const SizedBox(width: 8),
                const Text('Clear Selection', style: TextStyle(color: Colors.white, fontSize: 13)),
              ],
            ),
          ),
          if (widget.onExplainWithCopilot != null)
            PopupMenuItem(
              value: 'copilot',
              child: Row(
                children: [
                  const Icon(Icons.smart_toy_outlined, size: 16, color: Colors.cyanAccent),
                  const SizedBox(width: 8),
                  const Text('Explain with Copilot', style: TextStyle(color: Colors.cyanAccent, fontSize: 13, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
        ],
      ],
    );

    if (result == 'copy') {
      _copySelectionToClipboard();
    } else if (result == 'paste') {
      _pasteFromClipboard();
    } else if (result == 'select_all') {
      _selectAll();
    } else if (result == 'clear_selection') {
      _controller.clearSelection();
    } else if (result == 'copilot') {
      _explainWithCopilot();
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget child = Scrollable(
      key: _scrollableKey,
      controller: _scrollController,
      viewportBuilder: (context, offset) {
        return _HammaTerminalView(
          key: _viewportKey,
          terminal: widget.terminal,
          controller: _controller,
          offset: offset,
          padding: MediaQuery.of(context).padding,
          autoResize: widget.autoResize,
          textStyle: widget.textStyle,
          textScaler: widget.textScaler ?? MediaQuery.textScalerOf(context),
          theme: widget.theme,
          focusNode: _focusNode,
          cursorType: widget.cursorType,
          alwaysShowCursor: widget.alwaysShowCursor,
          onEditableRect: _onEditableRect,
          composingText: _composingText,
        );
      },
    );

    child = TerminalScrollGestureHandler(
      terminal: widget.terminal,
      simulateScroll: widget.simulateScroll,
      getCellOffset: (offset) => renderTerminal.getCellOffset(offset),
      getLineHeight: () => renderTerminal.lineHeight,
      child: child,
    );

    if (!widget.hardwareKeyboardOnly) {
      child = CustomTextEdit(
        key: _customTextEditKey,
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        inputType: widget.keyboardType,
        keyboardAppearance: widget.keyboardAppearance,
        deleteDetection: widget.deleteDetection,
        onInsert: _onInsert,
        onDelete: () {
          _scrollToBottom();
          widget.terminal.keyInput(TerminalKey.backspace);
        },
        onComposing: _onComposing,
        onAction: (action) {
          _scrollToBottom();
          if (action == TextInputAction.done) {
            widget.terminal.keyInput(TerminalKey.enter);
          }
        },
        onKeyEvent: _handleKeyEvent,
        readOnly: widget.readOnly,
        child: child,
      );
    } else if (!widget.readOnly) {
      // Only listen for key input from a hardware keyboard.
      child = CustomKeyboardListener(
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        onInsert: _onInsert,
        onComposing: _onComposing,
        onKeyEvent: _handleKeyEvent,
        child: child,
      );
    }

    child = TerminalActions(
      terminal: widget.terminal,
      controller: _controller,
      child: child,
    );

    child = KeyboardVisibilty(
      onKeyboardShow: _onKeyboardShow,
      child: child,
    );

    child = HammaTerminalGestureHandler(
      terminalView: this,
      terminalController: _controller,
      onTapUp: _onTapUp,
      onTapDown: _onTapDown,
      onSecondaryTapDown:
          widget.onSecondaryTapDown != null ? _onSecondaryTapDown : null,
      onSecondaryTapUp:
          widget.onSecondaryTapUp != null ? _onSecondaryTapUp : null,
      readOnly: widget.readOnly,
      child: child,
    );

    child = MouseRegion(
      cursor: widget.mouseCursor,
      child: child,
    );

    child = Container(
      color: widget.theme.background.withValues(alpha: widget.backgroundOpacity),
      padding: widget.padding,
      child: child,
    );

    return child;
  }

  void requestKeyboard() {
    _customTextEditKey.currentState?.requestKeyboard();
  }

  void closeKeyboard() {
    _customTextEditKey.currentState?.closeKeyboard();
  }

  Rect get cursorRect {
    return renderTerminal.cursorOffset & renderTerminal.cellSize;
  }

  Rect get globalCursorRect {
    return renderTerminal.localToGlobal(renderTerminal.cursorOffset) &
        renderTerminal.cellSize;
  }

  void _onTapUp(TapUpDetails details) {
    final offset = renderTerminal.getCellOffset(details.localPosition);
    widget.onTapUp?.call(details, offset);
  }

  void _onTapDown(_) {
    if (_controller.selection != null) {
      _controller.clearSelection();
    } else {
      if (!widget.hardwareKeyboardOnly) {
        _customTextEditKey.currentState?.requestKeyboard();
      } else {
        _focusNode.requestFocus();
      }
    }
  }

  void _onSecondaryTapDown(TapDownDetails details) {
    final offset = renderTerminal.getCellOffset(details.localPosition);
    widget.onSecondaryTapDown?.call(details, offset);
  }

  void _onSecondaryTapUp(TapUpDetails details) {
    final offset = renderTerminal.getCellOffset(details.localPosition);
    widget.onSecondaryTapUp?.call(details, offset);
  }

  bool get hasInputConnection {
    return _customTextEditKey.currentState?.hasInputConnection == true;
  }

  void _onInsert(String text) {
    final key = charToTerminalKey(text.trim());

    // On mobile platforms there is no guarantee that virtual keyboard will
    // generate hardware key events. So we need first try to send the key
    // as a hardware key event. If it fails, then we send it as a text input.
    final consumed = key == null ? false : widget.terminal.keyInput(key);

    if (!consumed) {
      widget.terminal.textInput(text);
    }

    _scrollToBottom();
  }

  void _onComposing(String? text) {
    setState(() => _composingText = text);
  }

  KeyEventResult _handleKeyEvent(FocusNode focusNode, KeyEvent event) {
    // Check Copy / Paste keyboard shortcuts
    final isControlPressed = HardwareKeyboard.instance.isControlPressed;
    final isMetaPressed = HardwareKeyboard.instance.isMetaPressed;
    final isShiftPressed = HardwareKeyboard.instance.isShiftPressed;

    final isCopyShortcut = (Platform.isMacOS && isMetaPressed && event.logicalKey == LogicalKeyboardKey.keyC) ||
                           (!Platform.isMacOS && isControlPressed && isShiftPressed && event.logicalKey == LogicalKeyboardKey.keyC);

    final isPasteShortcut = (Platform.isMacOS && isMetaPressed && event.logicalKey == LogicalKeyboardKey.keyV) ||
                            (!Platform.isMacOS && isControlPressed && isShiftPressed && event.logicalKey == LogicalKeyboardKey.keyV);

    if (isCopyShortcut && event is KeyDownEvent) {
      _copySelectionToClipboard();
      return KeyEventResult.handled;
    }

    if (isPasteShortcut && event is KeyDownEvent) {
      _pasteFromClipboard();
      return KeyEventResult.handled;
    }

    final resultOverride = widget.onKeyEvent?.call(focusNode, event);
    if (resultOverride != null && resultOverride != KeyEventResult.ignored) {
      return resultOverride;
    }

    // ignore: invalid_use_of_protected_member
    final shortcutResult = _shortcutManager.handleKeypress(
      focusNode.context!,
      event,
    );

    if (shortcutResult != KeyEventResult.ignored) {
      return shortcutResult;
    }

    if (event is KeyUpEvent) {
      return KeyEventResult.ignored;
    }

    final key = keyToTerminalKey(event.logicalKey);

    if (key == null) {
      return KeyEventResult.ignored;
    }

    final handled = widget.terminal.keyInput(
      key,
      ctrl: HardwareKeyboard.instance.isControlPressed,
      alt: HardwareKeyboard.instance.isAltPressed,
      shift: HardwareKeyboard.instance.isShiftPressed,
    );

    if (handled) {
      _scrollToBottom();
    }

    return handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  void _onKeyboardShow() {
    if (_focusNode.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottom();
      });
    }
  }

  void _onEditableRect(Rect rect, Rect caretRect) {
    _customTextEditKey.currentState?.setEditableRect(rect, caretRect);
  }

  void _scrollToBottom() {
    final position = _scrollableKey.currentState?.position;
    if (position != null) {
      position.jumpTo(position.maxScrollExtent);
    }
  }
}

class _HammaTerminalView extends LeafRenderObjectWidget {
  const _HammaTerminalView({
    super.key,
    required this.terminal,
    required this.controller,
    required this.offset,
    required this.padding,
    required this.autoResize,
    required this.textStyle,
    required this.textScaler,
    required this.theme,
    required this.focusNode,
    required this.cursorType,
    required this.alwaysShowCursor,
    this.onEditableRect,
    this.composingText,
  });

  final Terminal terminal;

  final TerminalController controller;

  final ViewportOffset offset;

  final EdgeInsets padding;

  final bool autoResize;

  final TerminalStyle textStyle;

  final TextScaler textScaler;

  final TerminalTheme theme;

  final FocusNode focusNode;

  final TerminalCursorType cursorType;

  final bool alwaysShowCursor;

  final EditableRectCallback? onEditableRect;

  final String? composingText;

  @override
  RenderTerminal createRenderObject(BuildContext context) {
    return RenderTerminal(
      terminal: terminal,
      controller: controller,
      offset: offset,
      padding: padding,
      autoResize: autoResize,
      textStyle: textStyle,
      textScaler: textScaler,
      theme: theme,
      focusNode: focusNode,
      cursorType: cursorType,
      alwaysShowCursor: alwaysShowCursor,
      onEditableRect: onEditableRect,
      composingText: composingText,
    );
  }

  @override
  void updateRenderObject(BuildContext context, RenderTerminal renderObject) {
    renderObject
      ..terminal = terminal
      ..controller = controller
      ..offset = offset
      ..padding = padding
      ..autoResize = autoResize
      ..textStyle = textStyle
      ..textScaler = textScaler
      ..theme = theme
      ..focusNode = focusNode
      ..cursorType = cursorType
      ..alwaysShowCursor = alwaysShowCursor
      ..onEditableRect = onEditableRect
      ..composingText = composingText;
  }
}

class HammaTerminalGestureHandler extends StatefulWidget {
  const HammaTerminalGestureHandler({
    super.key,
    required this.terminalView,
    required this.terminalController,
    this.child,
    this.onTapUp,
    this.onSingleTapUp,
    this.onTapDown,
    this.onSecondaryTapDown,
    this.onSecondaryTapUp,
    this.onTertiaryTapDown,
    this.onTertiaryTapUp,
    this.readOnly = false,
  });

  final HammaTerminalViewState terminalView;

  final TerminalController terminalController;

  final Widget? child;

  final GestureTapUpCallback? onTapUp;

  final GestureTapUpCallback? onSingleTapUp;

  final GestureTapDownCallback? onTapDown;

  final GestureTapDownCallback? onSecondaryTapDown;

  final GestureTapUpCallback? onSecondaryTapUp;

  final GestureTapDownCallback? onTertiaryTapDown;

  final GestureTapUpCallback? onTertiaryTapUp;

  final bool readOnly;

  @override
  State<HammaTerminalGestureHandler> createState() => _HammaTerminalGestureHandlerState();
}

class _HammaTerminalGestureHandlerState extends State<HammaTerminalGestureHandler> {
  HammaTerminalViewState get terminalView => widget.terminalView;

  RenderTerminal get renderTerminal => terminalView.renderTerminal;

  DragStartDetails? _lastDragStartDetails;

  LongPressStartDetails? _lastLongPressStartDetails;

  CellOffset? _dragStartCell;
  CellOffset? _longPressStartCell;

  @override
  Widget build(BuildContext context) {
    return TerminalGestureDetector(
      onTapUp: widget.onTapUp,
      onSingleTapUp: onSingleTapUp,
      onTapDown: onTapDown,
      onSecondaryTapDown: onSecondaryTapDown,
      onSecondaryTapUp: onSecondaryTapUp,
      onTertiaryTapDown: onSecondaryTapDown,
      onTertiaryTapUp: onSecondaryTapUp,
      onLongPressStart: onLongPressStart,
      onLongPressMoveUpdate: onLongPressMoveUpdate,
      onDragStart: onDragStart,
      onDragUpdate: onDragUpdate,
      onDoubleTapDown: onDoubleTapDown,
      child: widget.child,
    );
  }

  bool get _shouldSendTapEvent =>
      !widget.readOnly &&
      !widget.terminalController.suspendedPointerInputs &&
      widget.terminalController.pointerInput.inputs.contains(PointerInput.tap);

  void _tapDown(
    GestureTapDownCallback? callback,
    TapDownDetails details,
    TerminalMouseButton button, {
    bool forceCallback = false,
  }) {
    var handled = false;
    if (_shouldSendTapEvent) {
      handled = renderTerminal.mouseEvent(
        button,
        TerminalMouseButtonState.down,
        details.localPosition,
      );
    }
    if (!handled || forceCallback) {
      callback?.call(details);
    }
  }

  void _tapUp(
    GestureTapUpCallback? callback,
    TapUpDetails details,
    TerminalMouseButton button, {
    bool forceCallback = false,
  }) {
    var handled = false;
    if (_shouldSendTapEvent) {
      handled = renderTerminal.mouseEvent(
        button,
        TerminalMouseButtonState.up,
        details.localPosition,
      );
    }
    if (!handled || forceCallback) {
      callback?.call(details);
    }
  }

  void onTapDown(TapDownDetails details) {
    _tapDown(
      widget.onTapDown,
      details,
      TerminalMouseButton.left,
      forceCallback: true,
    );
  }

  void onSingleTapUp(TapUpDetails details) {
    _tapUp(widget.onSingleTapUp, details, TerminalMouseButton.left);
  }

  void onSecondaryTapDown(TapDownDetails details) {
    _tapDown(widget.onSecondaryTapDown, details, TerminalMouseButton.right);
  }

  void onSecondaryTapUp(TapUpDetails details) {
    _tapUp(
      (details) {
        terminalView._showContextMenu(context, details.globalPosition);
      },
      details,
      TerminalMouseButton.right,
      forceCallback: true,
    );
  }

  void onSecondaryTapUp2(TapUpDetails details) {
    _tapUp(
      (details) {
        terminalView._showContextMenu(context, details.globalPosition);
      },
      details,
      TerminalMouseButton.right,
      forceCallback: true,
    );
  }

  void onTertiaryTapDown(TapDownDetails details) {
    _tapDown(widget.onTertiaryTapDown, details, TerminalMouseButton.middle);
  }

  void onTertiaryTapUp(TapUpDetails details) {
    _tapUp(widget.onTertiaryTapUp, details, TerminalMouseButton.right);
  }

  void onDoubleTapDown(TapDownDetails details) {
    renderTerminal.selectWord(details.localPosition);
    Future.delayed(const Duration(milliseconds: 200), () {
      if (mounted) {
        terminalView._showContextMenu(context, details.globalPosition);
      }
    });
  }

  void onLongPressStart(LongPressStartDetails details) {
    _lastLongPressStartDetails = details;
    _longPressStartCell = renderTerminal.getCellOffset(details.localPosition);
    renderTerminal.selectWord(details.localPosition);
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) {
        terminalView._showContextMenu(context, details.globalPosition);
      }
    });
  }

  void onLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    if (_longPressStartCell != null) {
      final fromBoundary = terminalView.widget.terminal.buffer.getWordBoundary(_longPressStartCell!);
      if (fromBoundary == null) return;
      final toOffset = renderTerminal.getCellOffset(details.localPosition);
      final toBoundary = terminalView.widget.terminal.buffer.getWordBoundary(toOffset);
      if (toBoundary == null) return;
      final range = fromBoundary.merge(toBoundary);
      widget.terminalController.setSelection(
        terminalView.widget.terminal.buffer.createAnchorFromOffset(range.begin),
        terminalView.widget.terminal.buffer.createAnchorFromOffset(range.end),
        mode: SelectionMode.line,
      );
    } else {
      renderTerminal.selectWord(
        _lastLongPressStartDetails!.localPosition,
        details.localPosition,
      );
    }
    _handleAutoScroll(details.localPosition);
  }

  void onDragStart(DragStartDetails details) {
    _lastDragStartDetails = details;
    _dragStartCell = renderTerminal.getCellOffset(details.localPosition);

    details.kind == PointerDeviceKind.mouse
        ? renderTerminal.selectCharacters(details.localPosition)
        : renderTerminal.selectWord(details.localPosition);
  }

  void onDragUpdate(DragUpdateDetails details) {
    if (_dragStartCell != null) {
      final currentCell = renderTerminal.getCellOffset(details.localPosition);
      var toPosition = currentCell;
      if (toPosition.x >= _dragStartCell!.x) {
        toPosition = CellOffset(toPosition.x + 1, toPosition.y);
      }
      widget.terminalController.setSelection(
        terminalView.widget.terminal.buffer.createAnchorFromOffset(_dragStartCell!),
        terminalView.widget.terminal.buffer.createAnchorFromOffset(toPosition),
      );
    } else {
      renderTerminal.selectCharacters(
        _lastDragStartDetails!.localPosition,
        details.localPosition,
      );
    }
    _handleAutoScroll(details.localPosition);
  }

  void _handleAutoScroll(Offset localPosition) {
    final localY = localPosition.dy;
    final viewHeight = renderTerminal.size.height;
    
    // Auto-scroll the view when dragging near the top or bottom edges
    if (localY < 20) {
      final currentScroll = terminalView._scrollController.offset;
      final target = math.max(0.0, currentScroll - 15.0);
      if (target != currentScroll) {
        terminalView._scrollController.jumpTo(target);
      }
    } else if (localY > viewHeight - 20) {
      final currentScroll = terminalView._scrollController.offset;
      final maxScroll = terminalView._scrollController.position.maxScrollExtent;
      final target = math.min(maxScroll, currentScroll + 15.0);
      if (target != currentScroll) {
        terminalView._scrollController.jumpTo(target);
      }
    }
  }
}

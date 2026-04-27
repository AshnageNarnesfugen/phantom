import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/phantom_theme.dart';
import '../../core/protocol/message.dart' show MessageStatus;

// ── ChatBubble ────────────────────────────────────────────────────────────────
// El widget más importante — future theme hook: el tema puede reemplazar esto
// completamente con su propio BubbleWidget.

class ChatBubble extends StatelessWidget {
  final String text;
  final bool isOutgoing;
  final String timeLabel;   // ya con ruido aplicado, formateado
  final bool showTail;      // primer mensaje de un bloque del mismo sender
  final MessageStatus status;

  const ChatBubble({
    super.key,
    required this.text,
    required this.isOutgoing,
    required this.timeLabel,
    this.showTail = false,
    this.status = MessageStatus.sent,
  });

  @override
  Widget build(BuildContext context) {
    final t = PhantomTheme.tokensOf(context);

    final bgColor = isOutgoing ? t.bubbleOut : t.bubbleIn;
    final textColor = isOutgoing ? t.bubbleOutText : t.bubbleInText;
    final borderColor = isOutgoing
        ? t.accentLight.withValues(alpha: 0.25)
        : Colors.transparent;

    return Align(
      alignment: isOutgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: EdgeInsets.only(
          left: isOutgoing ? 64 : 0,
          right: isOutgoing ? 0 : 64,
          bottom: 2,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: bgColor,
          border: Border.all(color: borderColor, width: 0.5),
          borderRadius: BorderRadius.only(
            topLeft:     const Radius.circular(14),
            topRight:    const Radius.circular(14),
            bottomLeft:  Radius.circular(isOutgoing ? 14 : (showTail ? 4 : 14)),
            bottomRight: Radius.circular(isOutgoing ? (showTail ? 4 : 14) : 14),
          ),
        ),
        child: Column(
          crossAxisAlignment:
              isOutgoing ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              text,
              style: TextStyle(
                color: textColor,
                fontSize: 15,
                height: 1.45,
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  timeLabel,
                  style: TextStyle(
                    color: textColor.withValues(alpha: 0.45),
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
                if (isOutgoing) ...[
                  const SizedBox(width: 4),
                  _StatusIcon(status: status, color: textColor.withValues(alpha: 0.55)),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  final MessageStatus status;
  final Color color;

  const _StatusIcon({required this.status, required this.color});

  @override
  Widget build(BuildContext context) {
    final (icon, size) = switch (status) {
      MessageStatus.sending   => (Icons.schedule, 11.0),
      MessageStatus.sent      => (Icons.check, 11.0),
      MessageStatus.delivered => (Icons.done_all, 11.0),
      MessageStatus.read      => (Icons.done_all, 11.0),
      MessageStatus.failed    => (Icons.error_outline, 11.0),
    };

    final iconColor = status == MessageStatus.read
        ? PhantomTheme.tokensOf(context).accentLight
        : color;

    return Icon(icon, size: size, color: iconColor);
  }
}

// ── MessageInput ──────────────────────────────────────────────────────────────

class MessageInput extends StatefulWidget {
  final void Function(String text) onSend;
  final VoidCallback? onAttach;

  const MessageInput({
    super.key,
    required this.onSend,
    this.onAttach,
  });

  @override
  State<MessageInput> createState() => _MessageInputState();
}

class _MessageInputState extends State<MessageInput> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(() {
      final has = _ctrl.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
    });
  }

  void _send() {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    widget.onSend(text);
    _ctrl.clear();
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final t = PhantomTheme.tokensOf(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: t.bgSurface,
        border: Border(top: BorderSide(color: t.divider, width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            // Attach
            _IconBtn(
              icon: Icons.add,
              color: t.iconDefault,
              onTap: widget.onAttach,
            ),
            const SizedBox(width: 8),

            // Input field
            Expanded(
              child: Container(
                constraints: const BoxConstraints(maxHeight: 120),
                decoration: BoxDecoration(
                  color: t.bgSubtle,
                  borderRadius: BorderRadius.circular(t.radiusInput),
                  border: Border.all(color: t.inputBorder, width: 0.5),
                ),
                child: TextField(
                  controller: _ctrl,
                  focusNode: _focus,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  style: TextStyle(
                    color: t.textPrimary,
                    fontSize: 15,
                    fontFamily: 'monospace',
                  ),
                  decoration: InputDecoration(
                    hintText: 'message',
                    hintStyle: TextStyle(
                      color: t.textDisabled,
                      fontSize: 15,
                      fontFamily: 'monospace',
                    ),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                  ),
                  onSubmitted: (_) => _send(),
                ),
              ),
            ),
            const SizedBox(width: 8),

            // Send button
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 150),
              child: _hasText
                  ? _SendBtn(onTap: _send, color: t.accentLight)
                  : _IconBtn(icon: Icons.mic_none, color: t.iconDefault),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }
}

class _SendBtn extends StatelessWidget {
  final VoidCallback onTap;
  final Color color;

  const _SendBtn({required this.onTap, required this.color});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.3), width: 0.5),
        ),
        child: Icon(Icons.arrow_upward_rounded, color: color, size: 18),
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  const _IconBtn({required this.icon, required this.color, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 38,
        height: 38,
        child: Icon(icon, color: color, size: 20),
      ),
    );
  }
}

// ── ConversationTile ──────────────────────────────────────────────────────────

class ConversationTile extends StatelessWidget {
  final String displayName;
  final String phantomId;
  final String? lastMessage;
  final String? timeLabel;
  final int unreadCount;
  final bool isOnline;       // placeholder — en Phantom no hay "online"
  final VoidCallback onTap;

  const ConversationTile({
    super.key,
    required this.displayName,
    required this.phantomId,
    this.lastMessage,
    this.timeLabel,
    this.unreadCount = 0,
    this.isOnline = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = PhantomTheme.tokensOf(context);

    return InkWell(
      onTap: onTap,
      splashColor: t.accentLight.withValues(alpha: 0.06),
      highlightColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: t.divider, width: 0.5)),
        ),
        child: Row(
          children: [
            // Avatar — letra inicial + accent ring si hay unread
            _Avatar(
              name: displayName,
              hasUnread: unreadCount > 0,
              tokens: t,
            ),
            const SizedBox(width: 12),

            // Texto
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          displayName,
                          style: TextStyle(
                            color: t.textPrimary,
                            fontSize: 15,
                            fontFamily: 'monospace',
                            fontWeight: unreadCount > 0
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (timeLabel != null)
                        Text(
                          timeLabel!,
                          style: TextStyle(
                            color: unreadCount > 0
                                ? t.accentLight
                                : t.textDisabled,
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          lastMessage ?? _shortId(phantomId),
                          style: TextStyle(
                            color: unreadCount > 0
                                ? t.textSecondary
                                : t.textDisabled,
                            fontSize: 13,
                            fontFamily: 'monospace',
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                      if (unreadCount > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: t.accentLight.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '$unreadCount',
                            style: TextStyle(
                              color: t.accentLight,
                              fontSize: 11,
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _shortId(String id) =>
      id.length > 12 ? '${id.substring(0, 6)}…${id.substring(id.length - 4)}' : id;
}

class _Avatar extends StatelessWidget {
  final String name;
  final bool hasUnread;
  final PhantomTokens tokens;

  const _Avatar({
    required this.name,
    required this.hasUnread,
    required this.tokens,
  });

  @override
  Widget build(BuildContext context) {
    final letter = name.isNotEmpty ? name[0].toUpperCase() : '?';
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: tokens.bgSubtle,
        borderRadius: BorderRadius.circular(tokens.radiusCard),
        border: Border.all(
          color: hasUnread
              ? tokens.accentLight.withValues(alpha: 0.5)
              : tokens.divider,
          width: hasUnread ? 1.5 : 0.5,
        ),
      ),
      child: Center(
        child: Text(
          letter,
          style: TextStyle(
            color: hasUnread ? tokens.accentLight : tokens.textSecondary,
            fontSize: 17,
            fontFamily: 'monospace',
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

// ── PhantomIdDisplay ──────────────────────────────────────────────────────────
// Muestra un PhantomID con opción de copiar y QR futuro.

class PhantomIdDisplay extends StatefulWidget {
  final String phantomId;
  final bool compact;

  const PhantomIdDisplay({
    super.key,
    required this.phantomId,
    this.compact = false,
  });

  @override
  State<PhantomIdDisplay> createState() => _PhantomIdDisplayState();
}

class _PhantomIdDisplayState extends State<PhantomIdDisplay> {
  bool _copied = false;

  void _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.phantomId));
    setState(() => _copied = true);
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = PhantomTheme.tokensOf(context);

    if (widget.compact) {
      return GestureDetector(
        onTap: _copy,
        child: Text(
          _shortId(widget.phantomId),
          style: TextStyle(
            color: t.accentLight,
            fontSize: 12,
            fontFamily: 'monospace',
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: _copy,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: t.bgSubtle,
          borderRadius: BorderRadius.circular(t.radiusCard),
          border: Border.all(color: t.inputBorder, width: 0.5),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                widget.phantomId,
                style: TextStyle(
                  color: t.accentLight,
                  fontSize: 12,
                  fontFamily: 'monospace',
                  letterSpacing: 0.5,
                ),
              ),
            ),
            const SizedBox(width: 8),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Icon(
                _copied ? Icons.check : Icons.copy_outlined,
                key: ValueKey(_copied),
                size: 16,
                color: _copied ? t.accentLight : t.iconDefault,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _shortId(String id) =>
      id.length > 12 ? '${id.substring(0, 6)}…${id.substring(id.length - 4)}' : id;
}

// ── SeedPhraseGrid ────────────────────────────────────────────────────────────

class SeedPhraseGrid extends StatelessWidget {
  final String seedPhrase;
  final bool obscured;

  const SeedPhraseGrid({
    super.key,
    required this.seedPhrase,
    this.obscured = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = PhantomTheme.tokensOf(context);
    final words = seedPhrase.split(' ');

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 2.2,
      ),
      itemCount: words.length,
      itemBuilder: (context, i) {
        final word = words[i];
        return Container(
          decoration: BoxDecoration(
            color: t.bgSubtle,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: t.inputBorder, width: 0.5),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '${i + 1}.',
                style: TextStyle(
                  color: t.textDisabled,
                  fontSize: 10,
                  fontFamily: 'monospace',
                ),
              ),
              const SizedBox(width: 3),
              Text(
                obscured ? '••••' : word,
                style: TextStyle(
                  color: obscured ? t.textDisabled : t.textPrimary,
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ── Phantom divider ───────────────────────────────────────────────────────────

class PhantomDivider extends StatelessWidget {
  final String? label;

  const PhantomDivider({super.key, this.label});

  @override
  Widget build(BuildContext context) {
    final t = PhantomTheme.tokensOf(context);
    if (label == null) {
      return Divider(color: t.divider, thickness: 0.5, height: 1);
    }
    return Row(
      children: [
        Expanded(child: Divider(color: t.divider, thickness: 0.5)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            label!,
            style: TextStyle(
              color: t.textDisabled,
              fontSize: 11,
              fontFamily: 'monospace',
            ),
          ),
        ),
        Expanded(child: Divider(color: t.divider, thickness: 0.5)),
      ],
    );
  }
}

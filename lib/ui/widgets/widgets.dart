import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import '../theme/phantom_theme.dart';
import '../../core/protocol/message.dart' show MessageStatus, MessageType;

// ── ChatBubble ────────────────────────────────────────────────────────────────

class ChatBubble extends StatelessWidget {
  final String text;
  final bool isOutgoing;
  final String timeLabel;
  final bool showTail;
  final MessageStatus status;
  final String? replyPreview;
  final Uint8List? mediaContent;
  final MessageType messageType;
  final bool glassEnabled;
  final double glassOpacity;
  final double glassBlur;

  const ChatBubble({
    super.key,
    required this.text,
    required this.isOutgoing,
    required this.timeLabel,
    this.showTail = false,
    this.status = MessageStatus.sent,
    this.replyPreview,
    this.mediaContent,
    this.messageType = MessageType.text,
    this.glassEnabled = false,
    this.glassOpacity = 0.12,
    this.glassBlur = 10.0,
  });

  @override
  Widget build(BuildContext context) {
    final t = PhantomTheme.tokensOf(context);

    final bgColor     = isOutgoing ? t.bubbleOut : t.bubbleIn;
    final textColor   = isOutgoing ? t.bubbleOutText : t.bubbleInText;
    final borderColor = isOutgoing
        ? t.accentLight.withValues(alpha: 0.25)
        : Colors.transparent;

    final isImage = messageType == MessageType.image;
    final isMedia = isImage || messageType == MessageType.file;

    final br = BorderRadius.only(
      topLeft:     const Radius.circular(14),
      topRight:    const Radius.circular(14),
      bottomLeft:  Radius.circular(isOutgoing ? 14 : (showTail ? 4 : 14)),
      bottomRight: Radius.circular(isOutgoing ? (showTail ? 4 : 14) : 14),
    );

    final pad = EdgeInsets.fromLTRB(
      isImage ? 4 : 14,
      isImage ? 4 : 9,
      isImage ? 4 : 14,
      isImage ? 4 : 9,
    );

    final inner = _buildInner(t, textColor, isImage);

    final Widget bubble = glassEnabled
        ? ClipRRect(
            borderRadius: br,
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(
                  sigmaX: glassBlur, sigmaY: glassBlur,
                  tileMode: TileMode.clamp),
              child: Container(
                padding: pad,
                decoration: BoxDecoration(
                  color: (isOutgoing ? t.accentLight : t.bgSurface)
                      .withValues(alpha: isOutgoing
                          ? (glassOpacity + 0.06).clamp(0.08, 0.52)
                          : (glassOpacity * 1.4).clamp(0.08, 0.50)),
                  border: Border.all(
                      color: Colors.white.withValues(alpha: 0.12), width: 0.5),
                ),
                child: inner,
              ),
            ),
          )
        : Container(
            padding: pad,
            decoration: BoxDecoration(
              color: bgColor,
              border: Border.all(color: borderColor, width: 0.5),
              borderRadius: br,
            ),
            child: inner,
          );

    return Align(
      alignment: isOutgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: EdgeInsets.only(
          left: isOutgoing ? 48 : 0,
          right: isOutgoing ? 0 : 48,
          bottom: 2,
        ),
        constraints: isMedia
            ? BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.7)
            : null,
        child: bubble,
      ),
    );
  }

  // In glass mode enforce readable text regardless of wallpaper colours.
  Color _effectiveTextColor(Color base) {
    if (!glassEnabled) return base;
    return Colors.white.withValues(alpha: isOutgoing ? 0.95 : 0.88);
  }

  Widget _buildInner(PhantomTokens t, Color textColor, bool isImage) {
    textColor = _effectiveTextColor(textColor);
    return Column(
      crossAxisAlignment:
          isOutgoing ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (replyPreview != null) ...[
          Container(
            padding: const EdgeInsets.fromLTRB(8, 5, 8, 5),
            margin: const EdgeInsets.only(bottom: 6),
            decoration: BoxDecoration(
              color: textColor.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(6),
              border: Border(
                left: BorderSide(
                    color: textColor.withValues(alpha: 0.4), width: 2),
              ),
            ),
            child: Text(
              replyPreview!,
              style: TextStyle(
                color: textColor.withValues(alpha: 0.6),
                fontSize: 12,
                fontFamily: 'monospace',
                height: 1.3,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
        _buildContent(textColor),
        if (isImage)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(timeLabel,
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.8),
                        fontSize: 10,
                        fontFamily: 'monospace')),
                if (isOutgoing) ...[
                  const SizedBox(width: 4),
                  _StatusIcon(
                      status: status,
                      color: Colors.white.withValues(alpha: 0.8)),
                ],
              ],
            ),
          )
        else ...[
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(timeLabel,
                  style: TextStyle(
                      color: textColor.withValues(alpha: 0.45),
                      fontSize: 11,
                      fontFamily: 'monospace')),
              if (isOutgoing) ...[
                const SizedBox(width: 4),
                _StatusIcon(
                    status: status,
                    color: textColor.withValues(alpha: 0.55)),
              ],
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildContent(Color textColor) {
    switch (messageType) {
      case MessageType.image:
        if (mediaContent != null) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.memory(
              mediaContent!,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _fallbackText(textColor),
            ),
          );
        }
        return _fallbackText(textColor);

      case MessageType.file:
        if (mediaContent != null) {
          final nullIdx = mediaContent!.indexOf(0);
          final fileName = nullIdx >= 0
              ? utf8.decode(mediaContent!.sublist(0, nullIdx))
              : 'file';
          final lower = fileName.toLowerCase();
          final isAudio = lower.endsWith('.m4a') || lower.endsWith('.mp3') ||
              lower.endsWith('.ogg') || lower.endsWith('.wav') ||
              lower.endsWith('.aac');
          if (isAudio && nullIdx >= 0) {
            final audioBytes = mediaContent!.sublist(nullIdx + 1);
            return _AudioPlayerBubble(bytes: audioBytes, textColor: textColor);
          }
          return _FileTile(fileName: fileName, textColor: textColor);
        }
        return _fallbackText(textColor);

      default:
        return Text(
          text,
          style: TextStyle(
            color: textColor,
            fontSize: 15,
            height: 1.45,
            fontFamily: 'monospace',
            shadows: glassEnabled
                ? [Shadow(color: Colors.black.withValues(alpha: 0.55), blurRadius: 4)]
                : null,
          ),
        );
    }
  }

  Widget _fallbackText(Color textColor) => Text(
        text,
        style: TextStyle(
            color: textColor,
            fontSize: 15,
            height: 1.45,
            fontFamily: 'monospace'),
      );
}

// ── AudioPlayerBubble ─────────────────────────────────────────────────────────

class _AudioPlayerBubble extends StatefulWidget {
  final Uint8List bytes;
  final Color textColor;

  const _AudioPlayerBubble({required this.bytes, required this.textColor});

  @override
  State<_AudioPlayerBubble> createState() => _AudioPlayerBubbleState();
}

class _AudioPlayerBubbleState extends State<_AudioPlayerBubble> {
  final _player = AudioPlayer();
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  final _subs = <StreamSubscription<dynamic>>[];

  @override
  void initState() {
    super.initState();
    _subs.add(_player.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _playing = s == PlayerState.playing);
    }));
    _subs.add(_player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    }));
    _subs.add(_player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    }));
  }

  @override
  void dispose() {
    for (final s in _subs) { s.cancel(); }
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _player.pause();
    } else {
      if (_duration > Duration.zero &&
          _position.inMilliseconds >= _duration.inMilliseconds - 200) {
        await _player.seek(Duration.zero);
      }
      await _player.play(BytesSource(widget.bytes));
    }
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.textColor;
    final progress = _duration.inMilliseconds > 0
        ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: _toggle,
          child: Icon(
            _playing ? Icons.pause_circle_outline : Icons.play_circle_outline,
            color: c,
            size: 36,
          ),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 120,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: progress,
                  backgroundColor: c.withValues(alpha: 0.2),
                  color: c,
                  minHeight: 3,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${_fmt(_position)} / ${_fmt(_duration)}',
              style: TextStyle(
                color: c.withValues(alpha: 0.6),
                fontSize: 10,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ── FileTile ──────────────────────────────────────────────────────────────────

class _FileTile extends StatelessWidget {
  final String fileName;
  final Color textColor;

  const _FileTile({required this.fileName, required this.textColor});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.insert_drive_file_outlined, color: textColor, size: 22),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            fileName,
            style: TextStyle(
                color: textColor, fontSize: 13, fontFamily: 'monospace'),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
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
  final void Function(Uint8List bytes, String fileName)? onSendFile;
  final String? replyPreview;
  final VoidCallback? onCancelReply;
  final bool glassEnabled;
  final double glassOpacity;
  final double glassBlur;

  const MessageInput({
    super.key,
    required this.onSend,
    this.onSendFile,
    this.replyPreview,
    this.onCancelReply,
    this.glassEnabled = false,
    this.glassOpacity = 0.12,
    this.glassBlur = 10.0,
  });

  @override
  State<MessageInput> createState() => _MessageInputState();
}

class _MessageInputState extends State<MessageInput> {
  final _ctrl     = TextEditingController();
  final _focus    = FocusNode();
  final _recorder = AudioRecorder();
  bool _hasText      = false;
  bool _isRecording  = false;
  int  _recordSecs   = 0;
  Timer? _recordTimer;

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

  Future<void> _toggleRecord() async {
    if (_isRecording) {
      _recordTimer?.cancel();
      final path = await _recorder.stop();
      if (mounted) setState(() { _isRecording = false; _recordSecs = 0; });
      if (path != null && widget.onSendFile != null) {
        final bytes = await File(path).readAsBytes();
        final ts    = DateTime.now().millisecondsSinceEpoch;
        widget.onSendFile!(bytes, 'voice_$ts.m4a');
      }
    } else {
      final hasPerms = await _recorder.hasPermission();
      if (!hasPerms) return;
      final dir  = await getTemporaryDirectory();
      final path = '${dir.path}/ph_rec_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
      if (mounted) setState(() { _isRecording = true; _recordSecs = 0; });
      _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _recordSecs++);
      });
    }
  }

  void _showAttachSheet(BuildContext ctx, PhantomTokens t) {
    showModalBottomSheet(
      context: ctx,
      backgroundColor: t.bgSurface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(t.radiusCard))),
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(width: 36, height: 3,
              decoration: BoxDecoration(color: t.divider, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 4),
          _AttachItem(icon: Icons.image_outlined, label: 'photo from gallery', tokens: t,
            onTap: () async {
              Navigator.pop(ctx);
              final picked = await ImagePicker().pickImage(
                  source: ImageSource.gallery, imageQuality: 80);
              if (picked != null && widget.onSendFile != null) {
                final bytes = await picked.readAsBytes();
                widget.onSendFile!(bytes, picked.name);
              }
            }),
          _AttachItem(icon: Icons.videocam_outlined, label: 'video from gallery', tokens: t,
            onTap: () async {
              Navigator.pop(ctx);
              final picked = await ImagePicker().pickVideo(source: ImageSource.gallery);
              if (picked != null && widget.onSendFile != null) {
                final bytes = await picked.readAsBytes();
                widget.onSendFile!(bytes, picked.name);
              }
            }),
          _AttachItem(icon: Icons.camera_alt_outlined, label: 'take photo', tokens: t,
            onTap: () async {
              Navigator.pop(ctx);
              final picked = await ImagePicker().pickImage(
                  source: ImageSource.camera, imageQuality: 80);
              if (picked != null && widget.onSendFile != null) {
                final bytes = await picked.readAsBytes();
                widget.onSendFile!(bytes, picked.name);
              }
            }),
          _AttachItem(icon: Icons.folder_outlined, label: 'file', tokens: t,
            onTap: () async {
              Navigator.pop(ctx);
              final result = await FilePicker.platform.pickFiles(withData: true);
              if (result != null) {
                final f = result.files.single;
                final bytes = f.bytes;
                if (bytes != null && widget.onSendFile != null) {
                  widget.onSendFile!(bytes, f.name);
                }
              }
            }),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  String _fmtSecs(int s) =>
      '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final t = PhantomTheme.tokensOf(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.replyPreview != null)
          Container(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            decoration: BoxDecoration(
              color: t.bgSubtle,
              border: Border(top: BorderSide(color: t.divider, width: 0.5)),
            ),
            child: Row(
              children: [
                Container(width: 2, height: 32, color: t.accentLight),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.replyPreview!,
                    style: TextStyle(color: t.textSecondary,
                        fontFamily: 'monospace', fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.close, size: 16, color: t.iconDefault),
                  onPressed: widget.onCancelReply,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
              ],
            ),
          ),
        _GlassBar(
          enabled: widget.glassEnabled,
          opacity: widget.glassOpacity,
          blur: widget.glassBlur,
          bgColor: t.bgSurface,
          divider: t.divider,
          child: SafeArea(
            top: false,
            child: Row(
              children: [
                _IconBtn(
                  icon: Icons.add,
                  color: widget.glassEnabled
                      ? Colors.white.withValues(alpha: 0.80)
                      : t.iconDefault,
                  onTap: () => _showAttachSheet(context, t),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Container(
                    constraints: const BoxConstraints(maxHeight: 120),
                    decoration: BoxDecoration(
                      color: _isRecording
                          ? const Color(0xFFCF6679).withValues(alpha: 0.1)
                          : t.bgSubtle,
                      borderRadius: BorderRadius.circular(t.radiusInput),
                      border: Border.all(
                        color: _isRecording
                            ? const Color(0xFFCF6679).withValues(alpha: 0.5)
                            : t.inputBorder,
                        width: 0.5,
                      ),
                    ),
                    child: _isRecording
                        ? Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 10),
                            child: Row(
                              children: [
                                const Icon(Icons.fiber_manual_record,
                                    color: Color(0xFFCF6679), size: 10),
                                const SizedBox(width: 8),
                                Text(
                                  'recording  ${_fmtSecs(_recordSecs)}',
                                  style: const TextStyle(
                                    color: Color(0xFFCF6679),
                                    fontSize: 14,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ],
                            ),
                          )
                        : TextField(
                            controller: _ctrl,
                            focusNode: _focus,
                            maxLines: null,
                            keyboardType: TextInputType.multiline,
                            textInputAction: TextInputAction.newline,
                            style: TextStyle(
                                color: t.textPrimary,
                                fontSize: 15,
                                fontFamily: 'monospace'),
                            decoration: InputDecoration(
                              hintText: 'message',
                              hintStyle: TextStyle(
                                  color: t.textDisabled,
                                  fontSize: 15,
                                  fontFamily: 'monospace'),
                              border: InputBorder.none,
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 10),
                            ),
                            onSubmitted: (_) => _send(),
                          ),
                  ),
                ),
                const SizedBox(width: 8),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 150),
                  child: _hasText
                      ? _SendBtn(key: const ValueKey('send'),
                          onTap: _send, color: t.accentLight)
                      : _IconBtn(
                          key: const ValueKey('mic'),
                          icon: _isRecording
                              ? Icons.stop_circle_outlined
                              : Icons.mic_none,
                          color: _isRecording
                              ? const Color(0xFFFF6B6B)
                              : (widget.glassEnabled
                                  ? Colors.white.withValues(alpha: 0.80)
                                  : t.iconDefault),
                          onTap: _toggleRecord,
                        ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _recordTimer?.cancel();
    _recorder.dispose();
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }
}

class _AttachItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final PhantomTokens tokens;
  final VoidCallback onTap;

  const _AttachItem({
    required this.icon,
    required this.label,
    required this.tokens,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    return ListTile(
      leading: Icon(icon, color: t.iconDefault, size: 22),
      title: Text(label,
          style: TextStyle(
              color: t.textPrimary, fontFamily: 'monospace', fontSize: 14)),
      dense: true,
      onTap: onTap,
    );
  }
}

// ── GlassBar ──────────────────────────────────────────────────────────────────
// Wraps a bar widget with BackdropFilter blur when glass mode is active,
// otherwise falls back to a plain coloured container with a top border.

class _GlassBar extends StatelessWidget {
  final bool enabled;
  final double opacity;
  final double blur;
  final Color bgColor;
  final Color divider;
  final Widget child;

  const _GlassBar({
    required this.enabled,
    required this.opacity,
    required this.blur,
    required this.bgColor,
    required this.divider,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (!enabled) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: bgColor,
          border: Border(top: BorderSide(color: divider, width: 0.5)),
        ),
        child: child,
      );
    }
    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(
            sigmaX: blur, sigmaY: blur, tileMode: TileMode.clamp),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: bgColor.withValues(alpha: (opacity * 1.8).clamp(0.10, 0.75)),
            border: Border(
                top: BorderSide(
                    color: divider.withValues(alpha: 0.25), width: 0.5)),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _SendBtn extends StatelessWidget {
  final VoidCallback onTap;
  final Color color;

  const _SendBtn({super.key, required this.onTap, required this.color});

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

  const _IconBtn({super.key, required this.icon, required this.color, this.onTap});

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
  final bool isOnline;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Uint8List? avatarBytes;

  const ConversationTile({
    super.key,
    required this.displayName,
    required this.phantomId,
    this.lastMessage,
    this.timeLabel,
    this.unreadCount = 0,
    this.isOnline = false,
    required this.onTap,
    this.onLongPress,
    this.avatarBytes,
  });

  @override
  Widget build(BuildContext context) {
    final t = PhantomTheme.tokensOf(context);

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      splashColor: t.accentLight.withValues(alpha: 0.06),
      highlightColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: t.divider, width: 0.5)),
        ),
        child: Row(
          children: [
            // Avatar — initial letter + accent ring + online dot
            _Avatar(
              name:        displayName,
              hasUnread:   unreadCount > 0,
              isOnline:    isOnline,
              tokens:      t,
              avatarBytes: avatarBytes,
            ),
            const SizedBox(width: 12),

            // Text content
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
  final bool isOnline;
  final PhantomTokens tokens;
  final Uint8List? avatarBytes;

  const _Avatar({
    required this.name,
    required this.hasUnread,
    required this.isOnline,
    required this.tokens,
    this.avatarBytes,
  });

  @override
  Widget build(BuildContext context) {
    final letter = name.isNotEmpty ? name[0].toUpperCase() : '?';
    return Stack(
      children: [
        Container(
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
            image: avatarBytes != null
                ? DecorationImage(
                    image: MemoryImage(avatarBytes!),
                    fit: BoxFit.cover,
                  )
                : null,
          ),
          child: avatarBytes == null
              ? Center(
                  child: Text(
                    letter,
                    style: TextStyle(
                      color: hasUnread ? tokens.accentLight : tokens.textSecondary,
                      fontSize: 17,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                )
              : null,
        ),
        if (isOnline)
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 11,
              height: 11,
              decoration: BoxDecoration(
                color: const Color(0xFF4CAF50),
                shape: BoxShape.circle,
                border: Border.all(color: tokens.bgBase, width: 2),
              ),
            ),
          ),
      ],
    );
  }
}

// ── PhantomIdDisplay ──────────────────────────────────────────────────────────

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

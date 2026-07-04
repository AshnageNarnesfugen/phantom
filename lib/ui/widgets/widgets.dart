import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:open_file/open_file.dart';
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
  /// Non-null when this media is an unresolved CID pointer: the bytes haven't
  /// been downloaded, so render a download card (name + size + button)
  /// instead of trying to show content. Cleared once resolved.
  final ({String name, int size})? pendingDownload;
  final bool downloading;
  final VoidCallback? onDownload;
  final bool glassEnabled;
  final double glassOpacity;
  final double glassBlur;
  final ui.Image? blurredBg;
  final Listenable? scrollNotifier;
  final bool noiseEnabled;
  final double noiseStrength;
  final ui.Image? noiseImage;

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
    this.pendingDownload,
    this.downloading = false,
    this.onDownload,
    this.glassEnabled = false,
    this.glassOpacity = 0.12,
    this.glassBlur = 10.0,
    this.blurredBg,
    this.scrollNotifier,
    this.noiseEnabled = false,
    this.noiseStrength = 0.15,
    this.noiseImage,
  });

  @override
  Widget build(BuildContext context) {
    final t = PhantomTheme.tokensOf(context);

    final bgColor     = isOutgoing ? t.bubbleOut : t.bubbleIn;
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

    // Tint computed first so it can feed the contrast check below.
    final tintAlpha = isOutgoing
        ? (glassOpacity + 0.06).clamp(0.08, 0.52)
        : (glassOpacity * 1.4).clamp(0.08, 0.50);
    final tintBase  = isOutgoing ? t.accentLight : t.bgSurface;
    final tintColor = tintBase.withValues(alpha: tintAlpha);

    // Resolve text colour with WCAG contrast guarantee.
    final Color textColor;
    if (glassEnabled) {
      if (blurredBg != null) {
        // Frosted wallpaper: text shadow handles low-contrast areas;
        // exact pixel colour is unknown here, so default to white.
        textColor = Colors.white.withValues(alpha: isOutgoing ? 0.95 : 0.88);
      } else {
        // Tinted-only fallback: surface is fully deterministic.
        final surface = ContrastUtils.composite(tintBase, tintAlpha, t.bgBase);
        final useWhite = ContrastUtils.contrastRatio(Colors.white, surface)
                       >= ContrastUtils.contrastRatio(Colors.black, surface);
        textColor = useWhite
            ? Colors.white.withValues(alpha: isOutgoing ? 0.95 : 0.88)
            : const Color(0xDD000000);
      }
    } else {
      textColor = isOutgoing ? t.bubbleOutText : t.bubbleInText;
    }

    final inner = _buildInner(t, textColor, isImage);

    final Widget bubble;
    if (glassEnabled && blurredBg != null) {
      // Static-parallax frosted glass: pre-blurred bg sampled at screen position.
      // No BackdropFilter — zero scroll jank.
      bubble = ClipRRect(
        borderRadius: br,
        child: Builder(builder: (ctx) {
          final scrSize = MediaQuery.sizeOf(ctx);
          return CustomPaint(
            painter: _FrostedBubblePainter(
              blurredBg: blurredBg!,
              screenSize: scrSize,
              tint: tintColor,
              getBox: () => ctx.findRenderObject() as RenderBox?,
              scrollNotifier: scrollNotifier,
              noiseEnabled: noiseEnabled,
              noiseStrength: noiseStrength,
              noiseImage: noiseImage,
            ),
            child: Container(
              padding: pad,
              decoration: BoxDecoration(
                border: Border.all(
                    color: Colors.white.withValues(alpha: 0.12), width: 0.5),
              ),
              child: inner,
            ),
          );
        }),
      );
    } else if (glassEnabled) {
      // Animated fallback bg (no wallpaper): semi-transparent tint, no blur.
      bubble = ClipRRect(
        borderRadius: br,
        child: Container(
          padding: pad,
          decoration: BoxDecoration(
            color: tintColor,
            border: Border.all(
                color: Colors.white.withValues(alpha: 0.12), width: 0.5),
          ),
          child: inner,
        ),
      );
    } else {
      bubble = Container(
        padding: pad,
        decoration: BoxDecoration(
          color: bgColor,
          border: Border.all(color: borderColor, width: 0.5),
          borderRadius: br,
        ),
        child: inner,
      );
    }

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

  Widget _buildInner(PhantomTokens t, Color textColor, bool isImage) {
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
    // Unresolved CID media: show the download card regardless of type.
    if (pendingDownload != null) {
      return _MediaDownloadCard(
        name: pendingDownload!.name,
        size: pendingDownload!.size,
        isImage: messageType == MessageType.image,
        downloading: downloading,
        textColor: textColor,
        onDownload: onDownload,
      );
    }
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
          final isVideo = lower.endsWith('.mp4') || lower.endsWith('.mov') ||
              lower.endsWith('.webm') || lower.endsWith('.mkv') ||
              lower.endsWith('.3gp') || lower.endsWith('.avi') ||
              lower.endsWith('.m4v');
          final bytes = nullIdx >= 0 ? mediaContent!.sublist(nullIdx + 1) : null;
          if (isAudio && bytes != null) {
            return _AudioPlayerBubble(bytes: bytes, textColor: textColor);
          }
          // Video and every other file are tappable: bytes are written to a
          // temp file and handed to the system viewer via open_file. Videos
          // get a play affordance so they read as playable, not just "a file".
          return _FileTile(
            fileName: fileName,
            bytes: bytes,
            isVideo: isVideo,
            textColor: textColor,
          );
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

// ── FrostedBubblePainter ──────────────────────────────────────────────────────
// Samples the pre-blurred background at the bubble's current screen position so
// each bubble shows the correct "window" into a fixed background — static
// parallax frosted glass with zero BackdropFilter overhead.

class _FrostedBubblePainter extends CustomPainter {
  final ui.Image blurredBg;
  final Size screenSize;
  final Color tint;
  final RenderBox? Function() getBox;
  final bool noiseEnabled;
  final double noiseStrength;
  final ui.Image? noiseImage;

  _FrostedBubblePainter({
    required this.blurredBg,
    required this.screenSize,
    required this.tint,
    required this.getBox,
    Listenable? scrollNotifier,
    this.noiseEnabled = false,
    this.noiseStrength = 0.15,
    this.noiseImage,
  }) : super(repaint: scrollNotifier);

  @override
  void paint(Canvas canvas, Size size) {
    final box = getBox();
    if (box == null || !box.hasSize) return;

    final imgW = blurredBg.width.toDouble();
    final imgH = blurredBg.height.toDouble();
    final scrW = screenSize.width;
    final scrH = screenSize.height;

    // BoxFit.cover: choose the scale that fills the screen on both axes.
    final scale = imgW / scrW > imgH / scrH ? scrH / imgH : scrW / imgW;
    final ox = (scrW - imgW * scale) / 2; // horizontal letterbox offset
    final oy = (scrH - imgH * scale) / 2; // vertical letterbox offset

    // Bubble's top-left in screen (logical) coordinates.
    final gp = box.localToGlobal(Offset.zero);

    // Map bubble rect → source rect inside the blurred image.
    final src = Rect.fromLTWH(
      (gp.dx - ox) / scale,
      (gp.dy - oy) / scale,
      size.width / scale,
      size.height / scale,
    );
    final dst = Rect.fromLTWH(0, 0, size.width, size.height);

    canvas.drawImageRect(blurredBg, src, dst, Paint());
    canvas.drawRect(dst, Paint()..color = tint);

    if (noiseEnabled && noiseImage != null && noiseStrength > 0) {
      // Cubic curve: effectively zero below 0.3, intense only above 0.85.
      final s = math.pow(noiseStrength, 3).toDouble();
      final id = Float64List(16)
        ..[0] = 1 ..[5] = 1 ..[10] = 1 ..[15] = 1;
      // Separate blendMode from colorFilter: blendMode on saveLayer so the
      // colorFilter fully neutralises the noise before the overlay composite.
      canvas.saveLayer(dst, Paint()..blendMode = BlendMode.overlay);
      canvas.drawRect(
        dst,
        Paint()
          ..shader = ui.ImageShader(noiseImage!, TileMode.repeated, TileMode.repeated, id)
          ..colorFilter = ui.ColorFilter.matrix([
              s, 0, 0, 0, (1 - s) * 128,
              0, s, 0, 0, (1 - s) * 128,
              0, 0, s, 0, (1 - s) * 128,
              0, 0, 0, 1, 0,
            ]),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_FrostedBubblePainter old) =>
      old.blurredBg != blurredBg ||
      old.tint != tint ||
      old.screenSize != screenSize ||
      old.noiseEnabled != noiseEnabled ||
      old.noiseStrength != noiseStrength ||
      old.noiseImage != noiseImage;
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
  PlayerState _playerState = PlayerState.stopped;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  final _subs = <StreamSubscription<dynamic>>[];

  bool get _playing => _playerState == PlayerState.playing;

  @override
  void initState() {
    super.initState();
    _subs.add(_player.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _playerState = s);
    }));
    _subs.add(_player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    }));
    _subs.add(_player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    }));
    // Reset position to zero when playback finishes so next tap starts fresh.
    _subs.add(_player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _position = Duration.zero);
    }));
  }

  @override
  void dispose() {
    for (final s in _subs) { s.cancel(); }
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_playerState == PlayerState.playing) {
      await _player.pause();
    } else if (_playerState == PlayerState.paused) {
      await _player.resume();
    } else {
      // stopped or completed — play from beginning
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

/// A resolved file/video message. Tapping writes the bytes to a temp file and
/// opens it with the system viewer (open_file). Videos show a play affordance
/// so they read as playable rather than an inert attachment — the field bug
/// was that a sent video showed only its name with no way to open or view it.
class _FileTile extends StatefulWidget {
  final String fileName;
  final Uint8List? bytes;
  final bool isVideo;
  final Color textColor;

  const _FileTile({
    required this.fileName,
    required this.textColor,
    this.bytes,
    this.isVideo = false,
  });

  @override
  State<_FileTile> createState() => _FileTileState();
}

class _FileTileState extends State<_FileTile> {
  bool _opening = false;

  Future<void> _open() async {
    final bytes = widget.bytes;
    if (bytes == null || _opening) return;
    setState(() => _opening = true);
    try {
      final dir = await getTemporaryDirectory();
      // The filename is untrusted (from a contact) and becomes a real path,
      // so strip separators / traversal — keep only a safe basename+ext.
      final safe = widget.fileName
          .replaceAll(RegExp(r'[\x00-\x1f/\\]'), '_')
          .replaceAll('..', '_');
      final file = File('${dir.path}/ph_open_'
          '${DateTime.now().millisecondsSinceEpoch}_$safe');
      await file.writeAsBytes(bytes);
      final res = await OpenFile.open(file.path);
      if (res.type != ResultType.done && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('no app to open ${widget.fileName}'),
          duration: const Duration(seconds: 2),
        ));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('could not open file'),
          duration: Duration(seconds: 2),
        ));
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tappable = widget.bytes != null;
    final icon = widget.isVideo
        ? Icons.play_circle_outline
        : Icons.insert_drive_file_outlined;
    return InkWell(
      onTap: tappable ? _open : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_opening)
            SizedBox(
              width: 22, height: 22,
              child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(widget.textColor)),
            )
          else
            Icon(icon, color: widget.textColor, size: widget.isVideo ? 26 : 22),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              widget.fileName,
              style: TextStyle(
                  color: widget.textColor, fontSize: 13, fontFamily: 'monospace'),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Card shown for a received media message that hasn't been downloaded yet
/// (CID pointer). Shows the file name + human size and a download button;
/// while [downloading] it shows a spinner. On failure the parent re-renders
/// this card so the user can retry.
class _MediaDownloadCard extends StatelessWidget {
  final String name;
  final int size;
  final bool isImage;
  final bool downloading;
  final Color textColor;
  final VoidCallback? onDownload;

  const _MediaDownloadCard({
    required this.name,
    required this.size,
    required this.isImage,
    required this.downloading,
    required this.textColor,
    required this.onDownload,
  });

  static String _humanSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final sub = textColor.withValues(alpha: 0.6);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 240),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(isImage ? Icons.image_outlined : Icons.insert_drive_file_outlined,
              color: textColor, size: 26),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(name,
                    style: TextStyle(
                        color: textColor, fontSize: 13, fontFamily: 'monospace'),
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(_humanSize(size),
                    style: TextStyle(
                        color: sub, fontSize: 11, fontFamily: 'monospace')),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (downloading)
            SizedBox(
              width: 22, height: 22,
              child: CircularProgressIndicator(
                  strokeWidth: 2, valueColor: AlwaysStoppedAnimation(textColor)),
            )
          else
            InkWell(
              onTap: onDownload,
              customBorder: const CircleBorder(),
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: textColor.withValues(alpha: 0.12),
                ),
                child: Icon(Icons.download_rounded, color: textColor, size: 20),
              ),
            ),
        ],
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
      MessageStatus.failed    => (Icons.error_outline, 13.0),
    };

    final iconColor = switch (status) {
      MessageStatus.read   => PhantomTheme.tokensOf(context).accentLight,
      MessageStatus.failed => const Color(0xFFCF6679),
      _                    => color,
    };

    return Icon(icon, size: size, color: iconColor);
  }
}

// ── MessageInput ──────────────────────────────────────────────────────────────

enum _RecordState { idle, holding, locked }

class MessageInput extends StatefulWidget {
  final void Function(String text) onSend;
  final void Function(Uint8List bytes, String fileName)? onSendFile;
  /// Called with raw image bytes; should show an editor and return the
  /// (possibly edited) bytes, or null if the user cancels.
  final Future<Uint8List?> Function(Uint8List bytes)? onEditImage;
  final String? replyPreview;
  final VoidCallback? onCancelReply;
  final bool glassEnabled;
  final double glassOpacity;
  final double glassBlur;

  const MessageInput({
    super.key,
    required this.onSend,
    this.onSendFile,
    this.onEditImage,
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
  bool         _hasText     = false;
  _RecordState _recState    = _RecordState.idle;
  double       _lockProgress = 0.0;
  int          _recordSecs  = 0;
  Timer?       _recordTimer;

  bool get _isRecording => _recState != _RecordState.idle;

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

  Future<void> _startRecord() async {
    final hasPerms = await _recorder.hasPermission();
    if (!hasPerms) return;
    final dir  = await getTemporaryDirectory();
    final path = '${dir.path}/ph_rec_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
    if (!mounted) return;
    setState(() { _recState = _RecordState.holding; _recordSecs = 0; });
    _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _recordSecs++);
    });
  }

  void _lockRecord() {
    if (_recState != _RecordState.holding) return;
    setState(() { _recState = _RecordState.locked; _lockProgress = 0.0; });
  }

  Future<void> _stopAndSend() async {
    _recordTimer?.cancel();
    final path = await _recorder.stop();
    if (!mounted) return;
    setState(() { _recState = _RecordState.idle; _recordSecs = 0; _lockProgress = 0.0; });
    if (path != null && widget.onSendFile != null) {
      final bytes = await File(path).readAsBytes();
      final ts    = DateTime.now().millisecondsSinceEpoch;
      widget.onSendFile!(bytes, 'voice_$ts.m4a');
    }
  }

  Future<void> _cancelRecord() async {
    _recordTimer?.cancel();
    await _recorder.stop();
    if (!mounted) return;
    setState(() { _recState = _RecordState.idle; _recordSecs = 0; _lockProgress = 0.0; });
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
              if (picked == null || widget.onSendFile == null) return;
              final raw  = await picked.readAsBytes();
              final bytes = widget.onEditImage != null
                  ? await widget.onEditImage!(raw) ?? raw
                  : raw;
              widget.onSendFile!(bytes, picked.name);
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
              if (picked == null || widget.onSendFile == null) return;
              final raw  = await picked.readAsBytes();
              final bytes = widget.onEditImage != null
                  ? await widget.onEditImage!(raw) ?? raw
                  : raw;
              widget.onSendFile!(bytes, picked.name);
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
                _isRecording
                    ? _IconBtn(
                        icon: Icons.close,
                        color: const Color(0xFFFF6B6B),
                        onTap: _cancelRecord,
                      )
                    : _IconBtn(
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
                                const Spacer(),
                                if (_recState == _RecordState.holding)
                                  Row(children: [
                                    Icon(Icons.keyboard_arrow_left,
                                        color: const Color(0xFFCF6679).withValues(alpha: 0.5),
                                        size: 14),
                                    Text('cancel',
                                        style: TextStyle(
                                            color: const Color(0xFFCF6679).withValues(alpha: 0.5),
                                            fontSize: 10,
                                            fontFamily: 'monospace')),
                                    const SizedBox(width: 8),
                                    Icon(Icons.keyboard_arrow_up,
                                        color: const Color(0xFFCF6679).withValues(alpha: 0.6),
                                        size: 14),
                                    Text('lock',
                                        style: TextStyle(
                                            color: const Color(0xFFCF6679).withValues(alpha: 0.6),
                                            fontSize: 10,
                                            fontFamily: 'monospace')),
                                  ]),
                                if (_recState == _RecordState.locked)
                                  const Icon(Icons.lock_outline,
                                      color: Color(0xFFCF6679), size: 14),
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
                  child: _hasText && _recState == _RecordState.idle
                      ? _SendBtn(key: const ValueKey('send'),
                          onTap: _send, color: t.accentLight)
                      : _recState == _RecordState.locked
                          ? _SendBtn(
                              key: const ValueKey('send_audio'),
                              onTap: _stopAndSend,
                              color: t.accentLight,
                            )
                          : _MicBtn(
                              key: const ValueKey('mic'),
                              isRecording: _isRecording,
                              lockProgress: _lockProgress,
                              iconColor: _isRecording
                                  ? const Color(0xFFFF6B6B)
                                  : (widget.glassEnabled
                                      ? Colors.white.withValues(alpha: 0.80)
                                      : t.iconDefault),
                              accentColor: t.accentLight,
                              onLongPressStart: (_) => _startRecord(),
                              onLongPressMoveUpdate: (d) {
                                if (_recState != _RecordState.holding) return;
                                final dy = -d.offsetFromOrigin.dy;
                                final dx = -d.offsetFromOrigin.dx;
                                if (dx >= 60.0) { _cancelRecord(); return; }
                                setState(() => _lockProgress = (dy / 60.0).clamp(0.0, 1.0));
                                if (dy >= 60.0) _lockRecord();
                              },
                              onLongPressEnd: (_) {
                                if (_recState == _RecordState.holding) _stopAndSend();
                                setState(() => _lockProgress = 0.0);
                              },
                              onLongPressCancel: () {
                                if (_recState == _RecordState.holding) _cancelRecord();
                                setState(() => _lockProgress = 0.0);
                              },
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

class _MicBtn extends StatelessWidget {
  final bool isRecording;
  final double lockProgress;
  final Color iconColor;
  final Color accentColor;
  final void Function(LongPressStartDetails) onLongPressStart;
  final void Function(LongPressMoveUpdateDetails) onLongPressMoveUpdate;
  final void Function(LongPressEndDetails) onLongPressEnd;
  final VoidCallback onLongPressCancel;

  const _MicBtn({
    super.key,
    required this.isRecording,
    required this.lockProgress,
    required this.iconColor,
    required this.accentColor,
    required this.onLongPressStart,
    required this.onLongPressMoveUpdate,
    required this.onLongPressEnd,
    required this.onLongPressCancel,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 38,
      height: 38,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          if (isRecording && lockProgress > 0)
            Positioned(
              bottom: 42,
              child: Opacity(
                opacity: lockProgress,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.lock_outline, color: accentColor, size: 14),
                    const SizedBox(height: 2),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(1),
                      child: SizedBox(
                        height: 18,
                        width: 2,
                        child: LinearProgressIndicator(
                          value: lockProgress,
                          color: accentColor,
                          backgroundColor: accentColor.withValues(alpha: 0.2),
                          minHeight: 2,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          GestureDetector(
            onLongPressStart: onLongPressStart,
            onLongPressMoveUpdate: onLongPressMoveUpdate,
            onLongPressEnd: onLongPressEnd,
            onLongPressCancel: onLongPressCancel,
            child: SizedBox(
              width: 38,
              height: 38,
              child: Icon(
                isRecording ? Icons.mic : Icons.mic_none,
                color: iconColor,
                size: 20,
              ),
            ),
          ),
        ],
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

/// Read-only display of a phantom ID. NOT copyable: a bare phantom ID is a
/// display identifier, not an actionable token — nothing in the app accepts
/// it as input (recovery uses the seed phrase, adding a contact uses the full
/// contact address, verification uses the safety number). The old tap-to-copy
/// was a dead end.
class PhantomIdDisplay extends StatelessWidget {
  final String phantomId;
  final bool compact;

  const PhantomIdDisplay({
    super.key,
    required this.phantomId,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = PhantomTheme.tokensOf(context);

    if (compact) {
      return Text(
        _shortId(phantomId),
        style: TextStyle(
          color: t.accentLight,
          fontSize: 12,
          fontFamily: 'monospace',
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: t.bgSubtle,
        borderRadius: BorderRadius.circular(t.radiusCard),
        border: Border.all(color: t.inputBorder, width: 0.5),
      ),
      child: Text(
        phantomId,
        style: TextStyle(
          color: t.accentLight,
          fontSize: 12,
          fontFamily: 'monospace',
          letterSpacing: 0.5,
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

    // Wrap with intrinsically-sized chips so long BIP-39 words (e.g.
    // "prosperity", "quantum", "category") get the width they need and
    // short ones don't waste space. The previous fixed 4-col GridView
    // with childAspectRatio 2.2 clipped any word over ~6 characters to
    // "bronze", "empowe", "quantu", "prosper", … which was unreadable
    // — especially destructive for a seed phrase the user has to copy
    // by hand to a piece of paper.
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: List.generate(words.length, (i) {
        final word = words[i];
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: t.bgSubtle,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: t.inputBorder, width: 0.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${i + 1}.',
                style: TextStyle(
                  color: t.textDisabled,
                  fontSize: 10,
                  fontFamily: 'monospace',
                ),
              ),
              const SizedBox(width: 6),
              Text(
                obscured ? '••••' : word,
                style: TextStyle(
                  color: obscured ? t.textDisabled : t.textPrimary,
                  fontSize: 13,
                  fontFamily: 'monospace',
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        );
      }),
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

// ── Noise glass overlay ───────────────────────────────────────────────────────

// Shared noise image — generated once, Future kept alive so repeated calls
// return the already-resolved value without re-generating.
class NoiseImageCache {
  static Future<ui.Image>? _future;

  static Future<ui.Image> get() => _future ??= _generate();

  static Future<ui.Image> _generate() async {
    const size = 200;
    final rng = math.Random(0xdeadbeef);
    final pixels = Uint8List(size * size * 4);
    for (int i = 0; i < pixels.length; i += 4) {
      final v = rng.nextInt(256);
      pixels[i] = pixels[i + 1] = pixels[i + 2] = v;
      pixels[i + 3] = 255;
    }
    final buf  = await ui.ImmutableBuffer.fromUint8List(pixels);
    final desc = ui.ImageDescriptor.raw(
      buf, width: size, height: size, pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await desc.instantiateCodec();
    return (await codec.getNextFrame()).image;
  }
}

// Drop-in noise layer: place inside a Stack on top of any BackdropFilter child.
class NoiseLayer extends StatefulWidget {
  final double strength;
  const NoiseLayer({super.key, required this.strength});
  @override State<NoiseLayer> createState() => _NoiseLayerState();
}

class _NoiseLayerState extends State<NoiseLayer> {
  ui.Image? _noise;

  @override
  void initState() {
    super.initState();
    NoiseImageCache.get().then((img) {
      if (mounted) setState(() => _noise = img);
    });
  }

  @override
  Widget build(BuildContext context) {
    final n = _noise;
    if (n == null || widget.strength <= 0) return const SizedBox.shrink();
    return CustomPaint(
      painter: _NoisePainter(n, widget.strength),
      child: const SizedBox.expand(),
    );
  }
}

class _NoisePainter extends CustomPainter {
  final ui.Image noise;
  final double strength;
  _NoisePainter(this.noise, this.strength);

  @override
  void paint(Canvas canvas, Size size) {
    final s  = math.pow(strength, 3).toDouble();
    final id = Float64List(16)
      ..[0] = 1 ..[5] = 1 ..[10] = 1 ..[15] = 1;
    final bounds = Offset.zero & size;
    canvas.saveLayer(bounds, Paint()..blendMode = BlendMode.overlay);
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = ui.ImageShader(noise, TileMode.repeated, TileMode.repeated, id)
        ..colorFilter = ui.ColorFilter.matrix([
            s, 0, 0, 0, (1 - s) * 128,
            0, s, 0, 0, (1 - s) * 128,
            0, 0, s, 0, (1 - s) * 128,
            0, 0, 0, 1, 0,
          ]),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_NoisePainter old) =>
      old.noise != noise || old.strength != strength;
}
// ── PhotoEditorScreen ─────────────────────────────────────────────────────────
//
// Full-screen photo preview shown before sending a gallery or camera image.
// Supports rotate (90° steps) and horizontal flip. On confirm the transforms
// are baked into the bytes at original resolution using dart:ui so the output
// is full-quality regardless of screen size.

class PhotoEditorScreen extends StatefulWidget {
  final Uint8List bytes;
  const PhotoEditorScreen({super.key, required this.bytes});

  @override
  State<PhotoEditorScreen> createState() => _PhotoEditorScreenState();
}

class _PhotoEditorScreenState extends State<PhotoEditorScreen> {
  int  _rotation = 0; // 0=0°  1=90°CW  2=180°  3=270°CW
  bool _flipH    = false;
  bool _sending  = false;

  void _rotate(int delta) => setState(() => _rotation = (_rotation + delta + 4) % 4);

  Future<void> _send() async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      final result = await _applyTransforms();
      if (mounted) Navigator.pop(context, result);
    } catch (_) {
      if (mounted) Navigator.pop(context);
    }
  }

  Future<Uint8List> _applyTransforms() async {
    final codec = await ui.instantiateImageCodec(widget.bytes);
    final frame = await codec.getNextFrame();
    final src   = frame.image;
    final srcW  = src.width.toDouble();
    final srcH  = src.height.toDouble();

    // 90° / 270° rotations swap width and height.
    final swapped = _rotation % 2 == 1;
    final outW    = swapped ? srcH : srcW;
    final outH    = swapped ? srcW : srcH;

    final recorder = ui.PictureRecorder();
    final canvas   = Canvas(recorder, Rect.fromLTWH(0, 0, outW, outH));

    // Build transform: translate to output center, rotate, flip, then draw
    // image centred at origin.
    canvas.translate(outW / 2, outH / 2);
    if (_rotation != 0) canvas.rotate(_rotation * math.pi / 2);
    if (_flipH) canvas.scale(-1.0, 1.0);
    canvas.drawImage(src, Offset(-srcW / 2, -srcH / 2), Paint());
    src.dispose();

    final picture = recorder.endRecording();
    final result  = await picture.toImage(outW.round(), outH.round());
    picture.dispose();

    final data = await result.toByteData(format: ui.ImageByteFormat.png);
    result.dispose();
    return data!.buffer.asUint8List();
  }

  @override
  Widget build(BuildContext context) {
    final t = PhantomTheme.tokensOf(context);

    // Preview transform: rotate then flip (matches _applyTransforms).
    final angle = _rotation * math.pi / 2;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          if (_sending)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(
                width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.send_rounded),
              tooltip: 'send',
              onPressed: _send,
            ),
        ],
      ),
      body: Column(
        children: [
          // ── Image preview ─────────────────────────────────────────────────
          Expanded(
            child: Center(
              child: Transform.rotate(
                angle: angle,
                child: Transform.scale(
                  scaleX: _flipH ? -1.0 : 1.0,
                  child: Image.memory(
                    widget.bytes,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  ),
                ),
              ),
            ),
          ),

          // ── Toolbar ───────────────────────────────────────────────────────
          Container(
            color: const Color(0xFF111111),
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: SafeArea(
              top: false,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _EditorBtn(
                    icon: Icons.rotate_left_rounded,
                    label: 'left',
                    color: t.accentLight,
                    onTap: () => _rotate(-1),
                  ),
                  _EditorBtn(
                    icon: Icons.rotate_right_rounded,
                    label: 'right',
                    color: t.accentLight,
                    onTap: () => _rotate(1),
                  ),
                  _EditorBtn(
                    icon: Icons.flip_rounded,
                    label: 'flip',
                    color: _flipH ? t.accentLight : Colors.white54,
                    onTap: () => setState(() => _flipH = !_flipH),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EditorBtn extends StatelessWidget {
  final IconData icon;
  final String   label;
  final Color    color;
  final VoidCallback onTap;

  const _EditorBtn({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(height: 4),
          Text(label,
              style: TextStyle(color: color, fontFamily: 'monospace', fontSize: 11)),
        ],
      ),
    );
  }
}

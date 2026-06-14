import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:fula_files/core/services/wallet_service.dart'
    show walletNavigatorKey;
import 'package:fula_files/web/services/web_audio_controller.dart';
import 'package:fula_files/web/widgets/web_audio_player.dart';

/// Persistent bottom mini-player (s2), mounted once above the router in
/// app_web.dart (like [WebUploadTray]) so audio keeps playing and stays
/// controllable after the full-screen player is closed/minimized. Renders
/// nothing when no track is loaded or while the full player is open.
class WebMiniAudioPlayer extends StatelessWidget {
  const WebMiniAudioPlayer({super.key});

  void _expand() {
    // Re-open the full player. The mini-player lives above the router's
    // Navigator, so use the app-lifetime root navigator key for the dialog.
    final ctx = walletNavigatorKey.currentContext;
    if (ctx == null) return;
    final c = WebAudioController.instance;
    c.setExpanded(true); // onPressed (event context) — safe to notify
    showDialog<void>(
      context: ctx,
      useSafeArea: false,
      builder: (_) => const Dialog.fullscreen(child: WebAudioPlayer()),
    ).then((_) => c.setExpanded(false));
  }

  @override
  Widget build(BuildContext context) {
    final c = WebAudioController.instance;
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) {
        final track = c.current;
        // Hidden when nothing is playing or the full player is open.
        if (track == null || c.isExpanded) return const SizedBox.shrink();
        final theme = Theme.of(context);
        return SafeArea(
          top: false,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Material(
                  elevation: 8,
                  borderRadius: BorderRadius.circular(12),
                  color: theme.colorScheme.surfaceContainerHigh,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 4),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(LucideIcons.chevronUp),
                          tooltip: 'Expand',
                          onPressed: _expand,
                        ),
                        Expanded(
                          child: InkWell(
                            onTap: _expand,
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 8),
                              child: Row(
                                children: [
                                  const Icon(LucideIcons.music, size: 16),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      track.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                              fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        StreamBuilder<PlayerState>(
                          stream: c.player.playerStateStream,
                          builder: (_, snap) {
                            final playing = snap.data?.playing ?? false;
                            return IconButton(
                              icon: Icon(playing
                                  ? LucideIcons.pause
                                  : LucideIcons.play),
                              tooltip: playing ? 'Pause' : 'Play',
                              onPressed: c.playPause,
                            );
                          },
                        ),
                        IconButton(
                          icon: const Icon(LucideIcons.skipForward),
                          tooltip: 'Next',
                          onPressed: c.next,
                        ),
                        IconButton(
                          icon: const Icon(LucideIcons.x),
                          tooltip: 'Stop',
                          onPressed: c.stopPlayback,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

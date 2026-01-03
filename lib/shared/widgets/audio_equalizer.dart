import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/services/audio_player_service.dart';

class AudioEqualizer extends StatelessWidget {
  const AudioEqualizer({super.key});

  @override
  Widget build(BuildContext context) {
    final service = AudioPlayerService.instance;

    return StreamBuilder<bool>(
      stream: service.equalizerEnabledStream,
      builder: (context, enabledSnapshot) {
        final enabled = enabledSnapshot.data ?? false;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Enable switch
            SwitchListTile(
              title: const Text('Equalizer'),
              subtitle: Text(enabled ? 'Enabled' : 'Disabled'),
              value: enabled,
              onChanged: (value) => service.setEqualizerEnabled(value),
              contentPadding: EdgeInsets.zero,
            ),
            const SizedBox(height: 8),
            // Presets
            if (enabled) ...[
              const Text(
                'Presets',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              const _EqualizerPresets(),
              const SizedBox(height: 24),
              // Sliders
              const _EqualizerSliders(),
            ],
          ],
        );
      },
    );
  }
}

class _EqualizerPresets extends StatefulWidget {
  const _EqualizerPresets();

  @override
  State<_EqualizerPresets> createState() => _EqualizerPresetsState();
}

class _EqualizerPresetsState extends State<_EqualizerPresets> {
  String _selectedPreset = 'flat';

  static const _presets = [
    ('flat', 'Flat', LucideIcons.minus),
    ('bass_boost', 'Bass', LucideIcons.volume2),
    ('treble_boost', 'Treble', LucideIcons.music2),
    ('vocal', 'Vocal', LucideIcons.mic),
    ('rock', 'Rock', LucideIcons.disc),
    ('pop', 'Pop', LucideIcons.music),
    ('jazz', 'Jazz', LucideIcons.music3),
    ('classical', 'Classical', LucideIcons.music4),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SizedBox(
      height: 80,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _presets.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final preset = _presets[index];
          final isSelected = _selectedPreset == preset.$1;

          return GestureDetector(
            onTap: () {
              setState(() => _selectedPreset = preset.$1);
              AudioPlayerService.instance.setEqualizerPreset(preset.$1);
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 70,
              decoration: BoxDecoration(
                color: isSelected
                    ? theme.colorScheme.primaryContainer
                    : theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                border: isSelected
                    ? Border.all(color: theme.colorScheme.primary, width: 2)
                    : null,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    preset.$3,
                    size: 24,
                    color: isSelected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    preset.$2,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: isSelected
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                      fontWeight: isSelected ? FontWeight.w600 : null,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _EqualizerSliders extends StatelessWidget {
  const _EqualizerSliders();

  @override
  Widget build(BuildContext context) {
    final service = AudioPlayerService.instance;

    return Row(
      children: [
        Expanded(
          child: StreamBuilder<double>(
            stream: service.bassStream,
            builder: (context, snapshot) {
              return _EqualizerBand(
                label: 'Bass',
                frequency: '60Hz',
                value: snapshot.data ?? 0.0,
                onChanged: (value) => service.setBass(value),
              );
            },
          ),
        ),
        Expanded(
          child: StreamBuilder<double>(
            stream: service.midStream,
            builder: (context, snapshot) {
              return _EqualizerBand(
                label: 'Mid',
                frequency: '1kHz',
                value: snapshot.data ?? 0.0,
                onChanged: (value) => service.setMid(value),
              );
            },
          ),
        ),
        Expanded(
          child: StreamBuilder<double>(
            stream: service.trebleStream,
            builder: (context, snapshot) {
              return _EqualizerBand(
                label: 'Treble',
                frequency: '14kHz',
                value: snapshot.data ?? 0.0,
                onChanged: (value) => service.setTreble(value),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _EqualizerBand extends StatelessWidget {
  final String label;
  final String frequency;
  final double value;
  final ValueChanged<double> onChanged;

  const _EqualizerBand({
    required this.label,
    required this.frequency,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        Text(
          '${value > 0 ? '+' : ''}${value.toStringAsFixed(1)} dB',
          style: theme.textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: 150,
          child: RotatedBox(
            quarterTurns: -1,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
              ),
              child: Slider(
                value: value,
                min: -10.0,
                max: 10.0,
                onChanged: onChanged,
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        Text(
          frequency,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

// Compact equalizer button that shows a dialog
class EqualizerButton extends StatelessWidget {
  const EqualizerButton({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: AudioPlayerService.instance.equalizerEnabledStream,
      builder: (context, snapshot) {
        final enabled = snapshot.data ?? false;

        return IconButton(
          icon: Icon(
            LucideIcons.sliders,
            color: enabled
                ? Theme.of(context).colorScheme.primary
                : null,
          ),
          onPressed: () => _showEqualizerDialog(context),
          tooltip: 'Equalizer',
        );
      },
    );
  }

  void _showEqualizerDialog(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.8,
        expand: false,
        builder: (context, scrollController) => SingleChildScrollView(
          controller: scrollController,
          padding: const EdgeInsets.all(24),
          child: const AudioEqualizer(),
        ),
      ),
    );
  }
}

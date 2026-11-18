import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:walsey_led_core/walsey_led_core.dart';

import '../../app/walsey_navigation.dart';
import '../../connection/led_connection_service.dart';
import '../../control/led_control_service.dart';
import '../../design/color_picker.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../../state/app_settings.dart';

class LedStudioPage extends StatefulWidget {
  const LedStudioPage({
    super.key,
    required this.state,
    required this.controls,
    required this.settings,
    required this.onNavigate,
    required this.compact,
  });

  final AppConnectionState state;
  final LedControlService? controls;
  final AppSettingsService settings;
  final ValueChanged<WalseyPage> onNavigate;
  final bool compact;

  @override
  State<LedStudioPage> createState() => _LedStudioPageState();
}

class _LedStudioPageState extends State<LedStudioPage> {
  static const _presets = <(String, Color)>[
    ('Red', Color(0xFFFF0000)),
    ('Green', Color(0xFF00FF00)),
    ('Blue', Color(0xFF0000FF)),
    ('White', Color(0xFFFFFFFF)),
    ('Warm', Color(0xFFFFAA50)),
    ('Violet', Color(0xFF7B6CF6)),
    ('Cyan', Color(0xFF3DD6E8)),
  ];

  final _hexController = TextEditingController(text: '#7B6CF6');
  final _rgbController = TextEditingController(text: '123, 108, 246');
  final _effectController = TextEditingController(text: '3');

  Color _color = const Color(0xFF7B6CF6);
  double _brightness = 50;
  String? _hexError;
  String? _rgbError;
  String? _effectError;
  String? _lastMessage;
  bool _lastSuccess = true;

  @override
  void dispose() {
    _hexController.dispose();
    _rgbController.dispose();
    _effectController.dispose();
    super.dispose();
  }

  bool get _enabled => widget.controls != null;

  void _setColor(Color color) {
    setState(() {
      _color = color;
      _hexController.text = colorToHex(color);
      _rgbController.text = colorToRgbText(color);
      _hexError = null;
      _rgbError = null;
    });
  }

  void _onHexChanged(String text) {
    final color = colorFromHex(text);
    setState(() {
      if (color == null) {
        _hexError = text.trim().isEmpty ? null : 'Use #RRGGBB';
      } else {
        _hexError = null;
        _color = color;
        _rgbController.text = colorToRgbText(color);
      }
    });
  }

  void _onRgbChanged(String text) {
    final color = colorFromRgbText(text);
    setState(() {
      if (color == null) {
        _rgbError = text.trim().isEmpty ? null : 'Use 0–255 for each channel';
      } else {
        _rgbError = null;
        _color = color;
        _hexController.text = colorToHex(color);
      }
    });
  }

  Future<void> _send(
    String label,
    Future<CommandResult> Function(LedControlService controls) action,
  ) async {
    final controls = widget.controls;
    if (controls == null) return;
    final result = await action(controls);
    if (!mounted) return;
    setState(() {
      _lastSuccess = result is CommandSent;
      _lastMessage = switch (result) {
        CommandSent(:final hex) =>
          '$label: BLE write completed ($hex). '
              'The protocol has no read-back, so the LED result is not '
              'confirmed.',
        CommandUnsupported(:final reason) => '$label unsupported: $reason',
        CommandFailed(:final message) => '$label failed: $message',
      };
    });
  }

  Future<void> _sendColor() => _send(
    'Colour',
    (controls) => controls.setColor(
      RgbColor(
        (_color.r * 255).round(),
        (_color.g * 255).round(),
        (_color.b * 255).round(),
      ),
    ),
  );

  Future<void> _sendBrightness() => _send(
    'Brightness',
    (controls) => controls.setBrightness(
      BrightnessLevel(_brightness.round()),
    ),
  );

  void _sendEffect() {
    final id = int.tryParse(_effectController.text.trim());
    if (id == null) {
      setState(() => _effectError = 'Enter an integer effect id');
      return;
    }
    final effect = LedEffect(id);
    setState(() => _effectError = null);
    unawaited(_send('Effect $id', (controls) => controls.applyEffect(effect)));
  }

  Future<void> _sendHandshake() => _send(
    'Handshake',
    (controls) => controls.authenticate(),
  );

  void _toggleFavorite() {
    final rgb = ((_color.r * 255).round() << 16) |
        ((_color.g * 255).round() << 8) |
        (_color.b * 255).round();
    unawaited(widget.settings.toggleFavoriteColor(rgb));
  }

  @override
  Widget build(BuildContext context) {
    final controls = widget.controls;
    if (controls == null) return _build(context, null, false);
    return ValueListenableBuilder<bool>(
      valueListenable: controls.busy,
      builder: (context, busy, _) => _build(context, controls, busy),
    );
  }

  Widget _build(
    BuildContext context,
    LedControlService? controls,
    bool busy,
  ) {
    final layout = controls?.layoutLabel ?? widget.state.variant?.layout.name;
    final canSend = controls != null && !busy;
    final favoriteRgb = ((_color.r * 255).round() << 16) |
        ((_color.g * 255).round() << 8) |
        (_color.b * 255).round();

    return WPageBody(
      compact: widget.compact,
      children: [
        WPageHeader(
          title: 'LED Studio',
          compact: widget.compact,
          caption: controls == null
              ? 'Connect a documented LEDDMX controller to send commands.'
              : '${controls.variantLabel} · layout $layout',
          actions: [
            WBadge(
              label: controls == null ? 'No controller' : 'Controls ready',
              tone: controls == null
                  ? WBadgeTone.offline
                  : WBadgeTone.online,
            ),
            if (widget.compact)
              IconButton(
                tooltip: 'Lighting history',
                onPressed: () => widget.onNavigate(WalseyPage.activity),
                icon: const Icon(Icons.history),
              ),
          ],
        ),
        if (controls == null)
          WInfoBanner(
            tone: WInfoTone.warning,
            title: 'No controller connected',
            message:
                'Colour, brightness and effect frames are only written to a '
                'validated LEDDMX controller. Open Devices to scan and connect.',
            action: FilledButton(
              onPressed: () => widget.onNavigate(WalseyPage.devices),
              child: const Text('Devices'),
            ),
          )
        else if (!controls.handshakeSent)
          WInfoBanner(
            tone: WInfoTone.info,
            title: 'Handshake not sent',
            message:
                'LED_UNION reports the controller ignores commands until the '
                'handshake is written. The vendor app does this on connect; '
                'Walsey sends it only when you ask.',
            action: FilledButton(
              onPressed: busy ? null : () => unawaited(_sendHandshake()),
              child: const Text('Send handshake'),
            ),
          ),
        if (_lastMessage != null)
          WInfoBanner(
            tone: _lastSuccess ? WInfoTone.success : WInfoTone.error,
            message: _lastMessage!,
          ),
        _StudioLayout(
          compact: widget.compact,
          picker: _ColorPickerCard(
            color: _color,
            presets: _presets,
            hexController: _hexController,
            rgbController: _rgbController,
            hexError: _hexError,
            rgbError: _rgbError,
            canSend: canSend,
            isFavorite: widget.settings.value.favoriteColors.contains(
              favoriteRgb,
            ),
            onPicked: _setColor,
            onPreset: (color) {
              _setColor(color);
              unawaited(_sendColor());
            },
            onHexChanged: _onHexChanged,
            onRgbChanged: _onRgbChanged,
            onSend: () => unawaited(_sendColor()),
            onToggleFavorite: _enabled ? _toggleFavorite : null,
          ),
          controls: Column(
            children: [
              _PowerCard(enabled: canSend, onSend: _send),
              const SizedBox(height: WalseySpacing.xxl),
              _BrightnessCard(
                brightness: _brightness,
                enabled: canSend,
                layout: layout,
                onChanged: (value) => setState(() => _brightness = value),
                onSend: () => unawaited(_sendBrightness()),
              ),
              const SizedBox(height: WalseySpacing.xxl),
              _EffectsCard(
                controller: _effectController,
                error: _effectError,
                enabled: canSend,
                onApply: _sendEffect,
                onPreset: (id) {
                  _effectController.text = '$id';
                  _sendEffect();
                },
              ),
            ],
          ),
        ),
        _FavoritesCard(
          favoriteColors: widget.settings.value.favoriteColors,
          enabled: canSend,
          onSend: (color) {
            _setColor(color);
            unawaited(
              _send(
                'Colour',
                (controls) => controls.setColor(
                  RgbColor(
                    (color.r * 255).round(),
                    (color.g * 255).round(),
                    (color.b * 255).round(),
                  ),
                ),
              ),
            );
          },
          onRemove: (rgb) =>
              unawaited(widget.settings.toggleFavoriteColor(rgb)),
        ),
        _LimitsCard(
          onUnsupported: _showUnsupported,
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.lock_outline,
              size: 14,
              color: WalseyColors.textMuted,
            ),
            const SizedBox(width: WalseySpacing.sm),
            Expanded(
              child: Text(
                'A completed BLE write is not proof that the LEDs changed. '
                'Walsey never reports a colour or brightness as the current '
                'device state.',
                style: WalseyType.caption,
              ),
            ),
          ],
        ),
      ],
    );
  }

  void _showUnsupported(String title, String message) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(
          WalseySpacing.huge,
          WalseySpacing.sm,
          WalseySpacing.huge,
          WalseySpacing.huge,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const WBadge(label: 'Not supported', tone: WBadgeTone.unsupported),
                const SizedBox(width: WalseySpacing.md),
                Expanded(child: Text(title, style: WalseyType.sectionTitle)),
              ],
            ),
            const SizedBox(height: WalseySpacing.lg),
            Text(message, style: WalseyType.body),
            const SizedBox(height: WalseySpacing.xxl),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Got it'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StudioLayout extends StatelessWidget {
  const _StudioLayout({
    required this.compact,
    required this.picker,
    required this.controls,
  });

  final bool compact;
  final Widget picker;
  final Widget controls;

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return Column(
        children: [picker, const SizedBox(height: WalseySpacing.xxl), controls],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 760) {
          return Column(
            children: [
              picker,
              const SizedBox(height: WalseySpacing.xxl),
              controls,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 5, child: picker),
            const SizedBox(width: WalseySpacing.xxl),
            Expanded(flex: 4, child: controls),
          ],
        );
      },
    );
  }
}

class _ColorPickerCard extends StatelessWidget {
  const _ColorPickerCard({
    required this.color,
    required this.presets,
    required this.hexController,
    required this.rgbController,
    required this.hexError,
    required this.rgbError,
    required this.canSend,
    required this.isFavorite,
    required this.onPicked,
    required this.onPreset,
    required this.onHexChanged,
    required this.onRgbChanged,
    required this.onSend,
    required this.onToggleFavorite,
  });

  final Color color;
  final List<(String, Color)> presets;
  final TextEditingController hexController;
  final TextEditingController rgbController;
  final String? hexError;
  final String? rgbError;
  final bool canSend;
  final bool isFavorite;
  final ValueChanged<Color> onPicked;
  final ValueChanged<Color> onPreset;
  final ValueChanged<String> onHexChanged;
  final ValueChanged<String> onRgbChanged;
  final VoidCallback onSend;
  final VoidCallback? onToggleFavorite;

  @override
  Widget build(BuildContext context) => WCard(
    label: 'Colour',
    trailing: const Text('Preview only', style: WalseyType.caption),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final wheelSize = constraints.maxWidth < 420 ? 200.0 : 250.0;
        final wheel = Center(
          child: WFilledColorPicker(
            color: color,
            size: wheelSize,
            onChanged: onPicked,
          ),
        );
        final fields = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: hexController,
              enabled: canSend,
              decoration: InputDecoration(
                labelText: 'HEX',
                errorText: hexError,
                hintText: '#RRGGBB',
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp('[#0-9a-fA-F]')),
                LengthLimitingTextInputFormatter(7),
              ],
              onChanged: onHexChanged,
            ),
            const SizedBox(height: WalseySpacing.lg),
            TextField(
              controller: rgbController,
              enabled: canSend,
              decoration: InputDecoration(
                labelText: 'RGB',
                errorText: rgbError,
                hintText: '0–255, 0–255, 0–255',
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp('[0-9, ]')),
              ],
              onChanged: onRgbChanged,
            ),
            const SizedBox(height: WalseySpacing.lg),
            Container(
              height: 18,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: WalseyColors.border),
              ),
            ),
            const SizedBox(height: WalseySpacing.lg),
            Wrap(
              spacing: WalseySpacing.sm,
              runSpacing: WalseySpacing.sm,
              children: [
                for (final preset in presets)
                  Tooltip(
                    message: '${preset.$1} · tap to send',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(50),
                      onTap: canSend ? () => onPreset(preset.$2) : null,
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: preset.$2,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: preset.$2 == color
                                ? WalseyColors.text
                                : WalseyColors.border,
                            width: preset.$2 == color ? 2 : 1,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: WalseySpacing.xxl),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: canSend ? onSend : null,
                    child: const Text('Apply colour'),
                  ),
                ),
                const SizedBox(width: WalseySpacing.sm),
                IconButton.outlined(
                  tooltip: isFavorite
                      ? 'Remove from favourites'
                      : 'Save to favourites',
                  onPressed: onToggleFavorite,
                  icon: Icon(
                    isFavorite ? Icons.favorite : Icons.favorite_border,
                    color: isFavorite
                        ? WalseyColors.errorText
                        : WalseyColors.textSecondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: WalseySpacing.md),
            Text(
              'Drag on the disc: angle picks hue, distance from the centre '
              'picks lightness.',
              style: WalseyType.caption,
            ),
          ],
        );

        if (constraints.maxWidth < 480) {
          return Column(
            children: [
              wheel,
              const SizedBox(height: WalseySpacing.xxl),
              fields,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            wheel,
            const SizedBox(width: WalseySpacing.giant),
            Expanded(child: fields),
          ],
        );
      },
    ),
  );
}

class _PowerCard extends StatelessWidget {
  const _PowerCard({required this.enabled, required this.onSend});

  final bool enabled;
  final Future<void> Function(
    String label,
    Future<CommandResult> Function(LedControlService controls) action,
  )
  onSend;

  @override
  Widget build(BuildContext context) => WCard(
    label: 'Output',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: enabled
                    ? () => onSend(
                        'Power on',
                        (controls) => controls.setPower(on: true),
                      )
                    : null,
                icon: const Icon(Icons.power_settings_new, size: 18),
                label: const Text('Power on'),
              ),
            ),
            const SizedBox(width: WalseySpacing.sm),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: enabled
                    ? () => onSend(
                        'Power off',
                        (controls) => controls.setPower(on: false),
                      )
                    : null,
                icon: const Icon(Icons.power_off, size: 18),
                label: const Text('Power off'),
              ),
            ),
          ],
        ),
        const SizedBox(height: WalseySpacing.md),
        const Text(
          'Power state is not read back. Walsey records the frame it sent, '
          'not the current output.',
          style: WalseyType.caption,
        ),
      ],
    ),
  );
}

class _BrightnessCard extends StatelessWidget {
  const _BrightnessCard({
    required this.brightness,
    required this.enabled,
    required this.layout,
    required this.onChanged,
    required this.onSend,
  });

  final double brightness;
  final bool enabled;
  final String? layout;
  final ValueChanged<double> onChanged;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final percent = brightness.round();
    final scaled = (percent * 32 ~/ 100);
    return WCard(
      label: 'Brightness',
      trailing: Text('$percent%', style: WalseyType.rowTitle),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Slider(
            value: brightness,
            min: 0,
            max: 100,
            divisions: 100,
            label: '$percent%',
            onChanged: enabled ? onChanged : null,
          ),
          const SizedBox(height: WalseySpacing.sm),
          Row(
            children: [
              Expanded(
                child: Text(
                  layout == 'filler'
                      ? 'Filler layout sends floor($percent × 32 / 100) = '
                            '$scaled and the raw percent.'
                      : 'Sends the raw percent. Floor vs round is not '
                            'hardware-confirmed.',
                  style: WalseyType.caption,
                ),
              ),
              const SizedBox(width: WalseySpacing.md),
              FilledButton.tonal(
                onPressed: enabled ? onSend : null,
                style: FilledButton.styleFrom(
                  backgroundColor: WalseyColors.surfaceRaised,
                  foregroundColor: WalseyColors.text,
                ),
                child: const Text('Apply'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EffectsCard extends StatelessWidget {
  const _EffectsCard({
    required this.controller,
    required this.error,
    required this.enabled,
    required this.onApply,
    required this.onPreset,
  });

  final TextEditingController controller;
  final String? error;
  final bool enabled;
  final VoidCallback onApply;
  final ValueChanged<int> onPreset;

  @override
  Widget build(BuildContext context) => WCard(
    label: 'Built-in effect',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 110,
              child: TextField(
                controller: controller,
                enabled: enabled,
                decoration: InputDecoration(
                  labelText: 'Effect id',
                  errorText: error,
                ),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onSubmitted: (_) => onApply(),
              ),
            ),
            const SizedBox(width: WalseySpacing.sm),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: FilledButton.tonal(
                onPressed: enabled ? onApply : null,
                style: FilledButton.styleFrom(
                  backgroundColor: WalseyColors.surfaceRaised,
                  foregroundColor: WalseyColors.text,
                ),
                child: const Text('Apply effect'),
              ),
            ),
          ],
        ),
        const SizedBox(height: WalseySpacing.lg),
        Wrap(
          spacing: WalseySpacing.sm,
          runSpacing: WalseySpacing.sm,
          children: [
            for (final preset in const [
              (3, '3 · Forward 7 Colors'),
              (4, '4 · Backward 7 Colors'),
              (255, '255 · AUTO'),
            ])
              ActionChip(
                label: Text(preset.$2),
                onPressed: enabled ? () => onPreset(preset.$1) : null,
              ),
          ],
        ),
        const SizedBox(height: WalseySpacing.lg),
        const Text(
          'Documented ids: 1–210 and 255. Ids 1–72 are identical in both '
          'LEDDMX tables; 73–210 are variant-dependent. Only 3, 4 and 255 are '
          'named here because the repository has names for those.',
          style: WalseyType.caption,
        ),
      ],
    ),
  );
}

class _FavoritesCard extends StatelessWidget {
  const _FavoritesCard({
    required this.favoriteColors,
    required this.enabled,
    required this.onSend,
    required this.onRemove,
  });

  final List<int> favoriteColors;
  final bool enabled;
  final ValueChanged<Color> onSend;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) => WCard(
    label: 'Favourite colours',
    child: favoriteColors.isEmpty
        ? const Text(
            'No favourites yet. Pick a colour and tap the heart to keep it.',
            style: WalseyType.caption,
          )
        : Wrap(
            spacing: WalseySpacing.sm,
            runSpacing: WalseySpacing.sm,
            children: [
              for (final rgb in favoriteColors)
                InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: enabled
                      ? () => onSend(Color(0xFF000000 | rgb))
                      : null,
                  onLongPress: () => onRemove(rgb),
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: Color(0xFF000000 | rgb),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: WalseyColors.border),
                    ),
                  ),
                ),
            ],
          ),
  );
}

class _LimitsCard extends StatelessWidget {
  const _LimitsCard({required this.onUnsupported});

  final void Function(String title, String message) onUnsupported;

  @override
  Widget build(BuildContext context) => WCard(
    label: 'This controller',
    child: Column(
      children: [
        const WListRow(
          title: 'Power, global colour, brightness and effects',
          caption: 'Supported by the documented LEDDMX command set.',
          leading: Icon(
            Icons.check_circle_outline,
            size: 18,
            color: WalseyColors.successText,
          ),
          showDivider: true,
        ),
        WListRow(
          title: 'Independent segments',
          caption: 'The documented protocol exposes one global colour.',
          leading: const Icon(
            Icons.horizontal_split,
            size: 18,
            color: WalseyColors.textMuted,
          ),
          trailing: const WBadge(
            label: 'Not supported',
            tone: WBadgeTone.unsupported,
          ),
          onTap: () => onUnsupported(
            'Segments',
            'This controller cannot colour segments independently. Walsey '
            'will not invent a segment command or pretend an arrangement was '
            'applied. Use a single colour, or add compatible hardware and a '
            'protocol that documents segment addressing.',
          ),
        ),
        WListRow(
          title: 'Music and sound-reactive modes',
          caption: 'No audio analysis or receiver sound mode is implemented.',
          leading: const Icon(
            Icons.music_note_outlined,
            size: 18,
            color: WalseyColors.textMuted,
          ),
          trailing: const WBadge(
            label: 'Not supported',
            tone: WBadgeTone.unsupported,
          ),
          onTap: () => onUnsupported(
            'Music mode',
            'There is no audio player, no beat detection and no documented '
            'receiver sound mode in this protocol. A music view would be a '
            'visual demonstration, so it is deliberately not offered.',
          ),
        ),
      ],
    ),
  );
}

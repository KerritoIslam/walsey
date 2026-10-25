import 'dart:async';

import 'package:flutter/material.dart';
import 'package:walsey_led_core/walsey_led_core.dart';

import '../control/led_control_service.dart';

class ControlTab extends StatefulWidget {
  const ControlTab({
    super.key,
    required this.controls,
    required this.busy,
  });

  final LedControlService controls;
  final bool busy;

  @override
  State<ControlTab> createState() => _ControlTabState();
}

class _ControlTabState extends State<ControlTab> {
  double _r = 255;
  double _g = 0;
  double _b = 0;
  double _brightness = 50;
  final TextEditingController _effectController =
      TextEditingController(text: '3');

  LedControlService get _controls => widget.controls;

  @override
  void dispose() {
    _effectController.dispose();
    super.dispose();
  }

  Future<void> _sendColor(int r, int g, int b) async {
    setState(() {
      _r = r.toDouble();
      _g = g.toDouble();
      _b = b.toDouble();
    });
    await _controls.setColor(RgbColor(r, g, b));
  }

  Future<void> _sendCustomColor() =>
      _controls.setColor(RgbColor(_r.round(), _g.round(), _b.round()));

  Future<void> _sendBrightness() =>
      _controls.setBrightness(BrightnessLevel(_brightness.round()));

  void _sendEffect(int id) {
    try {
      final effect = LedEffect(id);
      unawaited(_controls.applyEffect(effect));
    } on InvalidCommandException catch (error) {
      _controls.log('INPUT ERROR: ${error.message}');
    }
  }

  void _sendTypedEffect() {
    final id = int.tryParse(_effectController.text.trim());
    if (id == null) {
      _controls.log('INPUT ERROR: effect id must be an integer');
      return;
    }
    _sendEffect(id);
  }

  @override
  Widget build(BuildContext context) {
    final busy = widget.busy;
    final layout = _controls.layoutLabel;
    final variant = _controls.variantLabel;

    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Controller'),
                const SizedBox(height: 4),
                Text('$variant  ·  layout: $layout'),
                const SizedBox(height: 4),
                const Text(
                  'These buttons send immediately. Power and colour frames '
                  'have never been observed on this controller yet.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Power', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton(
                      onPressed: busy
                          ? null
                          : () => unawaited(_controls.setPower(on: true)),
                      child: const Text('Power on'),
                    ),
                    FilledButton.tonal(
                      onPressed: busy
                          ? null
                          : () => unawaited(_controls.setPower(on: false)),
                      child: const Text('Power off'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Colour', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _PresetChip(
                      label: 'Red',
                      color: const Color(0xFFFF0000),
                      onTap: busy ? null : () => unawaited(_sendColor(255, 0, 0)),
                    ),
                    _PresetChip(
                      label: 'Green',
                      color: const Color(0xFF00FF00),
                      onTap: busy ? null : () => unawaited(_sendColor(0, 255, 0)),
                    ),
                    _PresetChip(
                      label: 'Blue',
                      color: const Color(0xFF0000FF),
                      onTap: busy ? null : () => unawaited(_sendColor(0, 0, 255)),
                    ),
                    _PresetChip(
                      label: 'White',
                      color: Colors.white,
                      onTap: busy
                          ? null
                          : () => unawaited(_sendColor(255, 255, 255)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _ChannelSlider(
                  label: 'R',
                  value: _r,
                  onChanged: (value) => setState(() => _r = value),
                ),
                _ChannelSlider(
                  label: 'G',
                  value: _g,
                  onChanged: (value) => setState(() => _g = value),
                ),
                _ChannelSlider(
                  label: 'B',
                  value: _b,
                  onChanged: (value) => setState(() => _b = value),
                ),
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 24,
                      decoration: BoxDecoration(
                        color: Color.fromARGB(
                          255,
                          _r.round(),
                          _g.round(),
                          _b.round(),
                        ),
                        border: Border.all(color: Colors.black26),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${_r.round()}, ${_g.round()}, ${_b.round()}',
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                    const Spacer(),
                    FilledButton.tonal(
                      onPressed: busy
                          ? null
                          : () => unawaited(_sendCustomColor()),
                      child: const Text('Apply colour'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Brightness',
                    style: Theme.of(context).textTheme.titleSmall),
                Row(
                  children: [
                    Expanded(
                      child: Slider(
                        value: _brightness,
                        min: 0,
                        max: 100,
                        divisions: 100,
                        label: '${_brightness.round()}%',
                        onChanged: (value) =>
                            setState(() => _brightness = value),
                      ),
                    ),
                    Text('${_brightness.round()}%'),
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      onPressed: busy
                          ? null
                          : () => unawaited(_sendBrightness()),
                      child: const Text('Apply'),
                    ),
                  ],
                ),
                const Text(
                  'Filler layout sends floor((v*32)/100) and the raw percent. '
                  'Floor vs round is not hardware-confirmed.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Built-in effect',
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                Row(
                  children: [
                    SizedBox(
                      width: 100,
                      child: TextField(
                        controller: _effectController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Effect id',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      onPressed: busy ? null : _sendTypedEffect,
                      child: const Text('Apply effect'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    ActionChip(
                      label: const Text('3 · Forward 7 Colors'),
                      onPressed: busy ? null : () => _sendEffect(3),
                    ),
                    ActionChip(
                      label: const Text('4 · Backward 7 Colors'),
                      onPressed: busy ? null : () => _sendEffect(4),
                    ),
                    ActionChip(
                      label: const Text('255 · AUTO'),
                      onPressed: busy ? null : () => _sendEffect(255),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Documented ids: 1–210 and 255. Ids 1–72 are identical in '
                  'both LEDDMX effect tables; 73–210 are variant-dependent. '
                  'Only ids 3, 4 and 255 are named here because those names '
                  'come from the research notes. Names beyond that were not '
                  'available in this repository.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({
    required this.label,
    required this.color,
    required this.onTap,
  });

  final String label;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.black26),
        ),
      ),
      label: Text(label),
    );
  }
}

class _ChannelSlider extends StatelessWidget {
  const _ChannelSlider({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 18, child: Text(label)),
        Expanded(
          child: Slider(
            value: value,
            min: 0,
            max: 255,
            divisions: 255,
            label: value.round().toString(),
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 34,
          child: Text(
            value.round().toString(),
            textAlign: TextAlign.end,
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        ),
      ],
    );
  }
}

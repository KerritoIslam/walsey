import 'package:flutter/material.dart';

/// Monospace diagnostic log. Automatically follows new lines.
class LogView extends StatefulWidget {
  const LogView({super.key, required this.logs});

  final List<String> logs;

  @override
  State<LogView> createState() => _LogViewState();
}

class _LogViewState extends State<LogView> {
  final ScrollController _controller = ScrollController();

  @override
  void didUpdateWidget(covariant LogView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.logs.length != oldWidget.logs.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_controller.hasClients) return;
        _controller.jumpTo(_controller.position.maxScrollExtent);
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      child: ListView.builder(
        controller: _controller,
        padding: const EdgeInsets.all(8),
        itemCount: widget.logs.length,
        itemBuilder: (context, index) => Text(
          widget.logs[index],
          style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
        ),
      ),
    );
  }
}

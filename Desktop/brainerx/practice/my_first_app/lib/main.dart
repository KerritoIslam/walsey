import 'dart:typed_data';

import 'package:flutter/material.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DevTools Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const DemoHomePage(),
    );
  }
}

class DemoHomePage extends StatelessWidget {
  const DemoHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('DevTools demo cases'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            _DemoCard(
              title: 'Performance case',
              summary: 'Large widget build to inspect frame time.',
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const PerformanceCasePage(),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            _DemoCard(
              title: 'CPU usage case',
              summary: 'Heavy synchronous task to inspect CPU flame graphs.',
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const CpuUsagePage(),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            _DemoCard(
              title: 'Memory leak case',
              summary: 'Retained objects to inspect heap growth and garbage collection.',
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const MemoryLeakPage(),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _DemoCard extends StatelessWidget {
  const _DemoCard({
    required this.title,
    required this.summary,
    required this.onTap,
  });

  final String title;
  final String summary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(summary),
            ],
          ),
        ),
      ),
    );
  }
}

class PerformanceCasePage extends StatelessWidget {
  const PerformanceCasePage({super.key});

  @override
  Widget build(BuildContext context) {
    final items = List<String>.generate(4000, (index) => 'Heavy widget $index');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Performance case'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: SingleChildScrollView(
          child: /* ListView.builder(itemBuilder: (context, index) {
            return Container(
              margin: const EdgeInsets.only(bottom: 4),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.indigo.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(items[index]),
            );
          }, itemCount: items.length, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),), */
          Column(
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  'This page builds a large widget tree in one frame to inspect frame time and jank.',
                ),
              ),
              ...items.map(
                (item) => Container(
                  margin: const EdgeInsets.only(bottom: 4),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.indigo.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(item),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class CpuUsagePage extends StatefulWidget {
  const CpuUsagePage({super.key});

  @override
  State<CpuUsagePage> createState() => _CpuUsagePageState();
}

class _CpuUsagePageState extends State<CpuUsagePage> {
  String _status = 'Idle';
  int _result = 0;
  int _result2 = 0;

  void _runCpuHeavyTask() {
    setState(() {
      _status = 'Running...';
    });

    final start = DateTime.now();
    final result = _computeHeavyMath(4_000_000);
    final result2 = _fibonacci(40); 
    final elapsed = DateTime.now().difference(start).inMilliseconds;

    setState(() {
      _result = result;
      _result2 = result2;
      _status = 'Done in $elapsed ms';
    });
  }

  int _computeHeavyMath(int iterations) {
    var total = 0;

    for (var index = 0; index < iterations; index++) {
      total += (index * index) % 97;
    }

    return total;
  }

  int _fibonacci(int n) {
    if (n <= 1) return n;
    
    return _fibonacci(n - 1) + _fibonacci(n - 2);
    
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('CPU usage case'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'This page runs a heavy synchronous task on the UI isolate to inspect CPU usage.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _runCpuHeavyTask,
                child: const Text('Run CPU-heavy task'),
              ),
              const SizedBox(height: 16),
              Text(_status),
              const SizedBox(height: 8),
              Text('Result1: $_result'),
              Text('Result2: $_result2'),
              const SizedBox(height: 24),
             
            ],
          ),
        ),
      ),
    );
  }
}

class MemoryLeakPage extends StatefulWidget {
  const MemoryLeakPage({super.key});

  @override
  State<MemoryLeakPage> createState() => _MemoryLeakPageState();
}

class _MemoryLeakPageState extends State<MemoryLeakPage> {
  static final List<Uint8List> _leakStorage = <Uint8List>[];

  int _allocatedBytes = 0;
  int _allocationCount = 0;

  void _createLeak() {
    final chunk = Uint8List(1024 * 1024);

    for (var index = 0; index < chunk.length; index++) {
      chunk[index] = index % 251;
    }

    _leakStorage.add(chunk);
    _allocatedBytes += chunk.length;
    _allocationCount++;

    setState(() {});
  }

  void _clearLeak() {
    _leakStorage.clear();
    _allocatedBytes = 0;
    _allocationCount = 0;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Memory leak case'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'This page stores every generated chunk in a static list so the heap grows over time.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Text('Allocated chunks: $_allocationCount'),
              Text('Approx heap growth: ${(_allocatedBytes / 1024 / 1024).toStringAsFixed(1)} MB'),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _createLeak,
                child: const Text('Create 1 MB leak'),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _clearLeak,
                child: const Text('Reset leak list'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
// P0 spike entrypoint: proves the FRB wasm link works in a browser
// before any real web UI is built.
//
// Build:  flutter build web --release -t lib/main_web.dart
// Dev:    flutter run -d chrome -t lib/main_web.dart
//
// Requires web/pkg/fula_flutter.js + web/pkg/fula_flutter_bg.wasm
// (wasm-pack --target no-modules output of fula-api crates/fula-flutter).
//
// Intentionally imports NOTHING from the app (lib/app, lib/core,
// lib/features) so the web compile graph stays free of dart:io until
// the real web shell lands in P3.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:fula_client/fula_client.dart' as fula;
import 'package:http/http.dart' as http;

void main() {
  runApp(
    MaterialApp(
      title: 'FxFiles web spike',
      theme: ThemeData.dark(useMaterial3: true),
      home: const SpikeScreen(),
    ),
  );
}

class SpikeScreen extends StatefulWidget {
  const SpikeScreen({super.key});

  @override
  State<SpikeScreen> createState() => _SpikeScreenState();
}

class _SpikeScreenState extends State<SpikeScreen> {
  final List<String> _log = <String>[];
  bool _busy = false;
  bool _rustInited = false;

  @override
  void initState() {
    super.initState();
    // Auto-run the full smoke on load so the spike is verifiable from a
    // headless browser via console output alone (no clicks needed).
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _runWasmSmoke();
      await _runCorsProbes();
      _append('SPIKE DONE');
    });
  }

  void _append(String line) {
    setState(() => _log.add(line));
    // ignore: avoid_print
    print('[spike] $line');
  }

  Future<void> _runWasmSmoke() async {
    setState(() => _busy = true);
    try {
      if (!_rustInited) {
        final sw = Stopwatch()..start();
        await fula.RustLib.init();
        sw.stop();
        _rustInited = true;
        _append('RustLib.init OK in ${sw.elapsedMilliseconds} ms');
      } else {
        _append('RustLib already initialized');
      }

      final sw = Stopwatch()..start();
      final key = await fula.deriveKey(
        context: 'fula-files-v1',
        input: utf8.encode('p0-smoke-input'),
      );
      sw.stop();
      final hex =
          key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      _append('deriveKey (Argon2id) OK in ${sw.elapsedMilliseconds} ms');
      _append('key[${key.length}B] = ${hex.substring(0, 16)}…');
    } catch (e) {
      _append('WASM SMOKE FAILED: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _probe(String label, Future<http.Response> Function() go) async {
    try {
      final resp = await go().timeout(const Duration(seconds: 15));
      // Any readable status (200/401/403/404…) means the browser let the
      // cross-origin response through => CORS pass for this request shape.
      _append('$label -> HTTP ${resp.statusCode} (CORS pass)');
    } catch (e) {
      // On web, a CORS block surfaces as ClientException('Failed to fetch').
      _append('$label -> BLOCKED/ERR: $e');
    }
  }

  Future<void> _runCorsProbes() async {
    setState(() => _busy = true);
    _append('--- CORS probes (origin: this page) ---');
    await _probe(
      'GET  s3.cloud.fx.land/',
      () => http.get(Uri.parse('https://s3.cloud.fx.land/')),
    );
    await _probe(
      'GET  api.cloud.fx.land/',
      () => http.get(Uri.parse('https://api.cloud.fx.land/')),
    );
    await _probe(
      'GET  cloud.fx.land/api/v1/storage (expect 401)',
      () => http.get(
        Uri.parse('https://cloud.fx.land/api/v1/storage'),
        headers: {'Authorization': 'Bearer invalid-spike-token'},
      ),
    );
    await _probe(
      'POST cloud.fx.land/auth/challenge (preflighted, expect 4xx)',
      () => http.post(
        Uri.parse('https://cloud.fx.land/auth/challenge'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'spike': true}),
      ),
    );
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('FxFiles web spike (P0)')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 12,
              children: [
                FilledButton(
                  onPressed: _busy ? null : _runWasmSmoke,
                  child: const Text('1. RustLib.init + deriveKey'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : _runCorsProbes,
                  child: const Text('2. CORS probes'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _log.length,
              itemBuilder: (context, i) => Text(
                _log[i],
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

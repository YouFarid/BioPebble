import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

// The XIAO advertises with this name and these UUIDs.
// If the Arduino sketch changes, these values must match it.
const String deviceName = 'Tiny Health';
final Guid healthServiceUuid = Guid('19b10000-e8f2-537e-4f6c-d104768a1214');
final Guid telemetryCharacteristicUuid =
    Guid('19b10001-e8f2-537e-4f6c-d104768a1214');

void main() {
  runApp(const BioPebbleApp());
}

// ---------------------------------------------------------------------------
// App setup
// ---------------------------------------------------------------------------

class BioPebbleApp extends StatelessWidget {
  const BioPebbleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'BioPebble',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xff050d11),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff28f4ff),
          brightness: Brightness.dark,
          primary: const Color(0xff28f4ff),
          secondary: const Color(0xff69ffb0),
          surface: const Color(0xff0d1a20),
        ),
        useMaterial3: true,
      ),
      home: const HealthHomePage(),
    );
  }
}

// ---------------------------------------------------------------------------
// Data models
// ---------------------------------------------------------------------------

// One packet from the XIAO.
// The Arduino sends JSON like:
// {"bpm":78,"ir":102000,"motion":1.01,"batPct":90,...}
class HealthTelemetry {
  const HealthTelemetry({
    this.heartRate,
    this.avgHeartRate,
    this.ir,
    this.red,
    this.fingerDetected,
    this.accelX,
    this.accelY,
    this.accelZ,
    this.gyroX,
    this.gyroY,
    this.gyroZ,
    this.motion,
    this.batteryVoltage,
    this.batteryPercent,
    this.uptimeMs,
    this.hrValid,
    this.spo2,
    this.spo2Valid,
  });

  final double? heartRate;
  final int? avgHeartRate;
  final int? ir;
  final int? red;
  final bool? fingerDetected;
  final double? accelX;
  final double? accelY;
  final double? accelZ;
  final double? gyroX;
  final double? gyroY;
  final double? gyroZ;
  final double? motion;
  final double? batteryVoltage;
  final int? batteryPercent;
  final int? uptimeMs;
  final bool? hrValid;
  final int? spo2;
  final bool? spo2Valid;

  bool get hasContact => fingerDetected == true;
  bool get hasValidHeartRate => hrValid == true && avgHeartRate != null;
  bool get hasValidSpo2 => spo2Valid == true && spo2 != null;

  // Convert the JSON text from BLE into a Dart object.
  // Missing values are allowed so the app does not crash during debugging.
  factory HealthTelemetry.fromJson(String text) {
    final Map<String, dynamic> json =
        jsonDecode(text.trim()) as Map<String, dynamic>;

    double? asDouble(String key) {
      final value = json[key];
      if (value is num) return value.toDouble();
      return null;
    }

    int? asInt(String key) {
      final value = json[key];
      if (value is num) return value.toInt();
      return null;
    }

    return HealthTelemetry(
      heartRate: asDouble('bpm'),
      avgHeartRate: asInt('avgBpm'),
      ir: asInt('ir'),
      red: asInt('red'),
      fingerDetected: json['finger'] == true,
      accelX: asDouble('ax'),
      accelY: asDouble('ay'),
      accelZ: asDouble('az'),
      gyroX: asDouble('gx'),
      gyroY: asDouble('gy'),
      gyroZ: asDouble('gz'),
      motion: asDouble('motion'),
      batteryVoltage: asDouble('batV'),
      batteryPercent: asInt('batPct'),
      uptimeMs: asInt('ms'),
      hrValid: asInt('hrValid') == 1,
      spo2: asInt('spo2'),
      spo2Valid: asInt('spo2Valid') == 1,
    );
  }
}

// A telemetry packet plus the time the phone received it.
// This lets the app draw graphs and calculate session stats.
class TimedTelemetry {
  const TimedTelemetry(this.time, this.data);

  final DateTime time;
  final HealthTelemetry data;
}

// Counts how much time/samples were spent in each rough heart-rate zone.
class ZoneSummary {
  const ZoneSummary({
    required this.rest,
    required this.easy,
    required this.cardio,
    required this.peak,
  });

  final int rest;
  final int easy;
  final int cardio;
  final int peak;
}

// All the calculated values shown by the dashboard.
// Most of these are estimates for presentation/wellness use, not medical data.
class HealthStats {
  const HealthStats({
    required this.avgBpm,
    required this.minBpm,
    required this.maxBpm,
    required this.hrSamples,
    required this.motionAvg,
    required this.motionPeak,
    required this.sessionSeconds,
    required this.contactPercent,
    required this.signalQuality,
    required this.activityLabel,
    required this.recoveryLabel,
    required this.steps,
    required this.cadence,
    required this.activeSeconds,
    required this.restSeconds,
    required this.calories,
    required this.zoneSummary,
    required this.hrvProxy,
    required this.stressLabel,
    required this.sleepReadiness,
    required this.respiratoryHint,
    required this.placementTip,
    required this.alerts,
  });

  final double? avgBpm;
  final int? minBpm;
  final int? maxBpm;
  final int hrSamples;
  final double motionAvg;
  final double motionPeak;
  final int sessionSeconds;
  final int contactPercent;
  final int signalQuality;
  final String activityLabel;
  final String recoveryLabel;
  final int steps;
  final int cadence;
  final int activeSeconds;
  final int restSeconds;
  final double calories;
  final ZoneSummary zoneSummary;
  final int hrvProxy;
  final String stressLabel;
  final int sleepReadiness;
  final String respiratoryHint;
  final String placementTip;
  final List<String> alerts;
}

class HealthHomePage extends StatefulWidget {
  const HealthHomePage({super.key});

  @override
  State<HealthHomePage> createState() => _HealthHomePageState();
}

// ---------------------------------------------------------------------------
// Main screen: BLE connection + session calculations
// ---------------------------------------------------------------------------

class _HealthHomePageState extends State<HealthHomePage> {
  // BLE scan results shown before connecting.
  final List<ScanResult> _scanResults = [];

  // Recent packets. Kept in memory only for this session.
  final Queue<TimedTelemetry> _history = Queue<TimedTelemetry>();

  // BLE can split one JSON message into multiple chunks.
  // This buffer waits until a full line arrives.
  String _rxBuffer = '';

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<List<int>>? _telemetrySub;
  StreamSubscription<BluetoothConnectionState>? _connectionSub;

  BluetoothDevice? _device;
  BluetoothConnectionState _connectionState =
      BluetoothConnectionState.disconnected;
  HealthTelemetry? _latest;
  DateTime? _sessionStartedAt;
  DateTime? _lastStepAt;
  double _previousStepSignal = 0;
  bool _stepArmed = true;
  int _steps = 0;
  bool _scanning = false;
  String _status = 'Ready to pair with your BioPebble.';

  @override
  void dispose() {
    _scanSub?.cancel();
    _telemetrySub?.cancel();
    _connectionSub?.cancel();
    _device?.disconnect();
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
  }

  // Scan for every nearby BLE device. Some phones do not show the advertised
  // name immediately, so the user can also pick the strongest unnamed device.
  Future<void> _scan() async {
    await _requestPermissions();
    await _disconnect();

    setState(() {
      _scanResults.clear();
      _latest = null;
      _history.clear();
      _sessionStartedAt = null;
      _steps = 0;
      _scanning = true;
      _status = 'Scanning for nearby BLE signals...';
    });

    await _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      setState(() {
        _scanResults
          ..clear()
          ..addAll(results);
      });
    });

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));

    setState(() {
      _scanning = false;
      _status = _scanResults.isEmpty
          ? 'No BLE devices found. Turn on Bluetooth and Location.'
          : 'Choose Tiny Health, or the strongest unnamed nearby signal.';
    });
  }

  // Connect, find our custom telemetry characteristic, and subscribe to updates.
  Future<void> _connect(ScanResult result) async {
    final device = result.device;

    setState(() {
      _device = device;
      _status = 'Linking to ${_displayDeviceName(result)}...';
    });

    await _connectionSub?.cancel();
    _connectionSub = device.connectionState.listen((state) {
      setState(() => _connectionState = state);
    });

    try {
      await FlutterBluePlus.stopScan();
      await device.connect(timeout: const Duration(seconds: 15));
    } catch (_) {
      if (!device.isConnected) rethrow;
    }

    setState(() => _status = 'Discovering biometric stream...');

    final services = await device.discoverServices();
    BluetoothCharacteristic? telemetryCharacteristic;

    for (final service in services) {
      if (service.uuid == healthServiceUuid) {
        for (final characteristic in service.characteristics) {
          if (characteristic.uuid == telemetryCharacteristicUuid) {
            telemetryCharacteristic = characteristic;
            break;
          }
        }
      }
    }

    if (telemetryCharacteristic == null) {
      setState(() => _status = 'Connected, but telemetry stream is missing.');
      return;
    }

    await _telemetrySub?.cancel();
    _telemetrySub = telemetryCharacteristic.onValueReceived.listen((value) {
      final text = utf8.decode(value, allowMalformed: true);
      _rxBuffer += text;

      // The firmware sends one JSON object per line.
      // If the last line is incomplete, keep it for the next BLE packet.
      final lines = _rxBuffer
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList();

      if (_rxBuffer.endsWith('\n')) {
        _rxBuffer = '';
      } else if (lines.isNotEmpty) {
        _rxBuffer = lines.removeLast();
      }

      for (final line in lines) {
        try {
          _addTelemetry(HealthTelemetry.fromJson(line));
        } catch (_) {
          setState(() => _status = 'Waiting for clean telemetry packet...');
        }
      }
    });

    await telemetryCharacteristic.setNotifyValue(true);

    setState(() {
      _sessionStartedAt = DateTime.now();
      _status = 'Connected. Gathering live biometrics...';
    });
  }

  // Called every time a complete JSON packet arrives.
  void _addTelemetry(HealthTelemetry packet) {
    final now = DateTime.now();
    _updateStepCounter(packet, now);

    setState(() {
      _latest = packet;
      _history.add(TimedTelemetry(now, packet));
      while (_history.isNotEmpty &&
          now.difference(_history.first.time) > const Duration(minutes: 20)) {
        _history.removeFirst();
      }
    });
  }

  // Very small step detector tuned for this rough prototype.
  // It counts acceleration peaks and ignores repeated spikes that are too fast.
  void _updateStepCounter(HealthTelemetry packet, DateTime now) {
    final motion = packet.motion;
    if (motion == null) return;

    final stepSignal = (motion - 1.0).abs();
    final crossedUp = _previousStepSignal < 0.11 && stepSignal >= 0.11;
    final enoughTime = _lastStepAt == null ||
        now.difference(_lastStepAt!) > const Duration(milliseconds: 330);

    if (_stepArmed && crossedUp && enoughTime) {
      _steps++;
      _lastStepAt = now;
      _stepArmed = false;
    }

    if (stepSignal < 0.055) {
      _stepArmed = true;
    }

    _previousStepSignal = stepSignal;
  }

  // Cleanly drop the BLE connection and reset session-only values.
  Future<void> _disconnect() async {
    await _telemetrySub?.cancel();
    _telemetrySub = null;
    final device = _device;
    if (device != null) {
      try {
        await device.disconnect();
      } catch (_) {}
    }
    setState(() {
      _device = null;
      _connectionState = BluetoothConnectionState.disconnected;
      _latest = null;
      _history.clear();
      _sessionStartedAt = null;
      _steps = 0;
      _lastStepAt = null;
    });
  }

  // BLE devices sometimes show up without a name, especially during scanning.
  String _displayDeviceName(ScanResult result) {
    if (result.device.platformName.isNotEmpty) {
      return result.device.platformName;
    }
    if (result.advertisementData.advName.isNotEmpty) {
      return result.advertisementData.advName;
    }
    return 'Unnamed BLE device';
  }

  // Main analytics method. It takes the raw history and calculates all of the
  // higher-level numbers used by the dashboard.
  HealthStats _stats() {
    final packets = _history.map((entry) => entry.data).toList();
    final validBpm = packets
        .where((data) => data.hasValidHeartRate)
        .map((data) => data.avgHeartRate!)
        .toList();
    final motions = packets
        .map((data) => data.motion)
        .whereType<double>()
        .map((value) => (value - 1.0).abs())
        .toList();
    final contactCount = packets.where((data) => data.hasContact).length;
    final now = DateTime.now();
    final sessionSeconds = _sessionStartedAt == null
        ? 0
        : now.difference(_sessionStartedAt!).inSeconds;
    final motionAvg = motions.isEmpty
        ? 0.0
        : motions.reduce((left, right) => left + right) / motions.length;
    final motionPeak = motions.isEmpty
        ? 0.0
        : motions.reduce((left, right) => max(left, right));
    final avgBpm = validBpm.isEmpty
        ? null
        : validBpm.reduce((left, right) => left + right) / validBpm.length;
    final contactPercent = packets.isEmpty
        ? 0
        : ((contactCount / packets.length) * 100).round().clamp(0, 100);
    final signalQuality = _signalQuality(_latest, contactPercent);
    final activeSeconds = _estimateActiveSeconds(motions);
    final restSeconds = max(0, sessionSeconds - activeSeconds);
    final cadence =
        sessionSeconds == 0 ? 0 : (_steps * 60 / sessionSeconds).round();
    final calories = _estimateCalories(activeSeconds, motionAvg, avgBpm);
    final zoneSummary = _zones(validBpm);
    final hrvProxy = _pulseStability(validBpm);
    final sleepReadiness = _sleepReadiness(avgBpm, motionAvg, signalQuality);
    final alerts = _alerts(_latest, avgBpm, signalQuality, contactPercent);

    return HealthStats(
      avgBpm: avgBpm,
      minBpm: validBpm.isEmpty ? null : validBpm.reduce(min),
      maxBpm: validBpm.isEmpty ? null : validBpm.reduce(max),
      hrSamples: validBpm.length,
      motionAvg: motionAvg,
      motionPeak: motionPeak,
      sessionSeconds: sessionSeconds,
      contactPercent: contactPercent,
      signalQuality: signalQuality,
      activityLabel: _activityLabel(motionAvg, motionPeak, cadence),
      recoveryLabel: _recoveryLabel(avgBpm, motionAvg),
      steps: _steps,
      cadence: cadence,
      activeSeconds: activeSeconds,
      restSeconds: restSeconds,
      calories: calories,
      zoneSummary: zoneSummary,
      hrvProxy: hrvProxy,
      stressLabel: _stressLabel(avgBpm, motionAvg, hrvProxy),
      sleepReadiness: sleepReadiness,
      respiratoryHint: _respiratoryHint(_latest, motionAvg),
      placementTip: _placementTip(_latest, signalQuality),
      alerts: alerts,
    );
  }

  // Counts recent packets that looked active. This is not perfect, but it is
  // good enough for a prototype activity timer.
  int _estimateActiveSeconds(List<double> motions) {
    if (_history.isEmpty || motions.isEmpty) return 0;
    final activePackets = motions.where((value) => value > 0.075).length;
    return (activePackets * 2.5).round();
  }

  // Rough presentation-only calorie estimate.
  // Assumes 70 kg and combines movement + heart rate into a MET-like value.
  double _estimateCalories(
      int activeSeconds, double motionAvg, double? avgBpm) {
    // Lightweight demo estimate. This assumes a 70kg user and uses motion/HR
    // to nudge a MET-like value. It is for presentation, not nutrition tracking.
    final minutes = activeSeconds / 60.0;
    final hrBoost = avgBpm == null ? 0.0 : ((avgBpm - 70) / 45).clamp(0.0, 1.3);
    final met = 1.2 + (motionAvg * 12).clamp(0.0, 3.0) + hrBoost;
    return minutes * met * 70 * 3.5 / 200;
  }

  // Basic zones. These are intentionally simple because we do not know age,
  // max HR, or fitness level yet.
  ZoneSummary _zones(List<int> bpm) {
    int rest = 0;
    int easy = 0;
    int cardio = 0;
    int peak = 0;
    for (final value in bpm) {
      if (value < 90) {
        rest++;
      } else if (value < 120) {
        easy++;
      } else if (value < 150) {
        cardio++;
      } else {
        peak++;
      }
    }
    return ZoneSummary(rest: rest, easy: easy, cardio: cardio, peak: peak);
  }

  // A simple stability score from recent heart-rate variation.
  // It is NOT real HRV, but it helps show whether pulse readings are steady.
  int _pulseStability(List<int> bpm) {
    if (bpm.length < 4) return 0;
    final recent = bpm.length > 12 ? bpm.sublist(bpm.length - 12) : bpm;
    final average = recent.reduce((a, b) => a + b) / recent.length;
    final variance =
        recent.map((value) => pow(value - average, 2)).reduce((a, b) => a + b) /
            recent.length;
    final deviation = sqrt(variance);
    return (100 - deviation * 5).round().clamp(0, 100);
  }

  // "Sleep readiness" is based on stillness, pulse, and signal quality.
  int _sleepReadiness(double? avgBpm, double motionAvg, int signalQuality) {
    int score = 50;
    if (avgBpm != null && avgBpm < 80) score += 20;
    if (motionAvg < 0.045) score += 20;
    if (signalQuality > 65) score += 10;
    if (avgBpm != null && avgBpm > 100) score -= 20;
    if (motionAvg > 0.12) score -= 20;
    return score.clamp(0, 100);
  }

  // Confidence score for whether the optical reading should be trusted.
  int _signalQuality(HealthTelemetry? data, int contactPercent) {
    if (data == null || data.ir == null) return 0;
    int score = 0;
    final ir = data.ir!;
    if (data.hasContact) score += 30;
    if (ir >= 50000 && ir <= 220000) score += 30;
    if (data.hrValid == true) score += 25;
    if (contactPercent > 75) score += 15;
    return score.clamp(0, 100);
  }

  // Friendly activity label shown at the top of the app.
  String _activityLabel(double motionAvg, double motionPeak, int cadence) {
    if (cadence > 135 || motionPeak > 0.45) return 'Run / high motion';
    if (cadence > 70 || motionAvg > 0.10) return 'Walking';
    if (motionPeak > 0.20 || motionAvg > 0.055) return 'Light movement';
    return 'Still / resting';
  }

  // Quick resting/recovery label.
  String _recoveryLabel(double? avgBpm, double motionAvg) {
    if (avgBpm == null) return 'Need contact';
    if (motionAvg > 0.10) return 'Moving';
    if (avgBpm < 75) return 'Calm';
    if (avgBpm < 95) return 'Alert';
    return 'Elevated';
  }

  // A very rough stress-like label. This is only a wellness hint.
  String _stressLabel(double? avgBpm, double motionAvg, int hrvProxy) {
    if (avgBpm == null) return 'Unknown';
    if (motionAvg < 0.06 && avgBpm > 100) return 'Elevated while still';
    if (hrvProxy > 75 && avgBpm < 85) return 'Balanced';
    if (avgBpm < 95) return 'Normal';
    return 'Activated';
  }

  // SpO2 is fussy, so this mostly tells the user how to improve the reading.
  String _respiratoryHint(HealthTelemetry? data, double motionAvg) {
    if (data?.spo2Valid == true &&
        (data!.spo2 ?? 0) >= 95 &&
        motionAvg < 0.08) {
      return 'steady oxygen signal';
    }
    if (data?.spo2Valid == true) return 'oxygen visible';
    return 'hold still for SpO2';
  }

  // Placement coaching for the MAX30102.
  String _placementTip(HealthTelemetry? data, int signalQuality) {
    if (data == null) return 'connect device';
    if (!data.hasContact) return 'cover sensor window';
    if ((data.ir ?? 0) > 240000) return 'reduce pressure / brightness';
    if ((data.ir ?? 0) < 50000) return 'increase contact pressure';
    if (signalQuality < 60) return 'block room light';
    return 'placement looks good';
  }

  // Small list of things the user should know right now.
  List<String> _alerts(
    HealthTelemetry? data,
    double? avgBpm,
    int signalQuality,
    int contactPercent,
  ) {
    final alerts = <String>[];
    if (data == null) return ['Waiting for telemetry'];
    if ((data.batteryPercent ?? 100) <= 15) alerts.add('Battery low');
    if (!data.hasContact) alerts.add('Sensor contact lost');
    if (signalQuality < 45) alerts.add('Low optical confidence');
    if (contactPercent < 55) alerts.add('Unstable placement');
    if (avgBpm != null && avgBpm > 120 && (data.motion ?? 1.0) < 1.08) {
      alerts.add('High pulse while still');
    }
    if (alerts.isEmpty) alerts.add('All systems nominal');
    return alerts;
  }

  @override
  Widget build(BuildContext context) {
    final connected = _connectionState == BluetoothConnectionState.connected;
    final stats = _stats();

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xff061014), Color(0xff0d1b22), Color(0xff170d25)],
          ),
        ),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 28),
            children: [
              _Header(
                connected: connected,
                status: _status,
                scanning: _scanning,
                onScan: _scanning ? null : _scan,
                onDisconnect: connected ? _disconnect : null,
              ),
              const SizedBox(height: 18),
              if (!connected)
                _ScanPanel(
                  results: _scanResults,
                  displayDeviceName: _displayDeviceName,
                  onConnect: _connect,
                )
              else ...[
                _HeroVitals(data: _latest, stats: stats),
                const SizedBox(height: 16),
                _GraphDeck(history: _history.toList()),
                const SizedBox(height: 16),
                _InsightStrip(data: _latest, stats: stats),
                const SizedBox(height: 16),
                _FeatureGrid(data: _latest, stats: stats),
                const SizedBox(height: 16),
                _ZonePanel(stats: stats),
                const SizedBox(height: 16),
                _CoachPanel(stats: stats),
                const SizedBox(height: 16),
                _SignalPanel(data: _latest, stats: stats),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// UI widgets
// ---------------------------------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({
    required this.connected,
    required this.status,
    required this.scanning,
    required this.onScan,
    required this.onDisconnect,
  });

  final bool connected;
  final bool scanning;
  final String status;
  final VoidCallback? onScan;
  final VoidCallback? onDisconnect;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xff102a30),
                borderRadius: BorderRadius.circular(18),
                border:
                    Border.all(color: const Color(0xff28f4ff).withOpacity(.35)),
              ),
              child: const Icon(Icons.auto_awesome, color: Color(0xff69ffb0)),
            ),
            const SizedBox(width: 12),
            Expanded(
              // Kept non-const for compatibility with the older Flutter SDK on this laptop.
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text(
                    'BioPebble',
                    style: TextStyle(fontSize: 30, fontWeight: FontWeight.w900),
                  ),
                  Text('wearable pulse lab',
                      style: TextStyle(color: Color(0xff93a9b0))),
                ],
              ),
            ),
            FilledButton.tonalIcon(
              onPressed: connected ? onDisconnect : onScan,
              icon: Icon(connected
                  ? Icons.bluetooth_disabled
                  : scanning
                      ? Icons.hourglass_top
                      : Icons.bluetooth_searching),
              label: Text(connected ? 'Drop' : 'Scan'),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _GlassCard(
          child: Row(
            children: [
              Icon(
                connected ? Icons.sensors : Icons.sensors_off,
                color:
                    connected ? const Color(0xff69ffb0) : Colors.orangeAccent,
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(status)),
            ],
          ),
        ),
      ],
    );
  }
}

class _ScanPanel extends StatelessWidget {
  const _ScanPanel({
    required this.results,
    required this.displayDeviceName,
    required this.onConnect,
  });

  final List<ScanResult> results;
  final String Function(ScanResult result) displayDeviceName;
  final void Function(ScanResult result) onConnect;

  @override
  Widget build(BuildContext context) {
    if (results.isEmpty) {
      return _GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Text('No devices yet', style: TextStyle(fontSize: 20)),
            SizedBox(height: 8),
            Text(
              'Tap Scan. If Tiny Health appears unnamed, pick the nearby device with the strongest RSSI.',
              style: TextStyle(color: Color(0xff93a9b0)),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        for (final result in results)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _GlassCard(
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  backgroundColor: const Color(0xff28f4ff).withOpacity(.14),
                  child: const Icon(Icons.bluetooth, color: Color(0xff28f4ff)),
                ),
                title: Text(displayDeviceName(result)),
                subtitle: Text(
                  '${result.device.remoteId}  ·  RSSI ${result.rssi}',
                  style: const TextStyle(color: Color(0xff93a9b0)),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => onConnect(result),
              ),
            ),
          ),
      ],
    );
  }
}

class _HeroVitals extends StatelessWidget {
  const _HeroVitals({required this.data, required this.stats});

  final HealthTelemetry? data;
  final HealthStats stats;

  @override
  Widget build(BuildContext context) {
    final bpm = data?.hrValid == true ? '${data!.avgHeartRate}' : '--';
    final spo2 = data?.spo2Valid == true ? '${data!.spo2}' : '--';

    return _GlassCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Live Biometrics',
                  style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
                ),
              ),
              _StatusPill(
                label: data?.hasContact == true ? 'CONTACT' : 'NO CONTACT',
                color: data?.hasContact == true
                    ? const Color(0xff69ffb0)
                    : Colors.orangeAccent,
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: _BigMetric(
                  label: 'Pulse',
                  value: bpm,
                  unit: 'BPM',
                  icon: Icons.favorite,
                  color: const Color(0xffff4d8d),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: _BigMetric(
                  label: 'Oxygen',
                  value: spo2,
                  unit: '% SpO2',
                  icon: Icons.air,
                  color: const Color(0xff28f4ff),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          _MiniTrend(
              minBpm: stats.minBpm, maxBpm: stats.maxBpm, avgBpm: stats.avgBpm),
        ],
      ),
    );
  }
}

class _GraphDeck extends StatelessWidget {
  const _GraphDeck({required this.history});

  final List<TimedTelemetry> history;

  @override
  Widget build(BuildContext context) {
    final bpm = history
        .map((entry) => entry.data.hrValid == true
            ? entry.data.avgHeartRate?.toDouble()
            : null)
        .whereType<double>()
        .toList();
    final motion = history
        .map((entry) =>
            entry.data.motion == null ? null : (entry.data.motion! - 1.0).abs())
        .whereType<double>()
        .toList();

    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Live Trends',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
          const SizedBox(height: 14),
          SizedBox(
            height: 120,
            child: CustomPaint(
              painter: _SparklinePainter(
                values: bpm,
                color: const Color(0xffff4d8d),
                minY: 45,
                maxY: 160,
              ),
              child: const SizedBox.expand(),
            ),
          ),
          const SizedBox(height: 6),
          const Text('Heart rate trend',
              style: TextStyle(color: Color(0xff93a9b0))),
          const SizedBox(height: 18),
          SizedBox(
            height: 80,
            child: CustomPaint(
              painter: _SparklinePainter(
                values: motion,
                color: const Color(0xff69ffb0),
                minY: 0,
                maxY: 0.35,
              ),
              child: const SizedBox.expand(),
            ),
          ),
          const SizedBox(height: 6),
          const Text('Motion artifact / activity trend',
              style: TextStyle(color: Color(0xff93a9b0))),
        ],
      ),
    );
  }
}

class _InsightStrip extends StatelessWidget {
  const _InsightStrip({required this.data, required this.stats});

  final HealthTelemetry? data;
  final HealthStats stats;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
            child: _InsightChip(
                title: 'Readiness',
                value: stats.recoveryLabel,
                icon: Icons.spa)),
        const SizedBox(width: 10),
        Expanded(
            child: _InsightChip(
                title: 'Stress',
                value: stats.stressLabel,
                icon: Icons.psychology)),
      ],
    );
  }
}

class _FeatureGrid extends StatelessWidget {
  const _FeatureGrid({required this.data, required this.stats});

  final HealthTelemetry? data;
  final HealthStats stats;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        _DataTile(
          title: 'Steps',
          value: '${stats.steps}',
          detail: '${stats.cadence} spm cadence',
          icon: Icons.directions_walk,
          color: const Color(0xff69ffb0),
        ),
        _DataTile(
          title: 'Activity',
          value: stats.activityLabel,
          detail: '${_formatDuration(stats.activeSeconds)} active',
          icon: Icons.directions_run,
          color: const Color(0xffff4d8d),
        ),
        _DataTile(
          title: 'Calories',
          value: stats.calories.toStringAsFixed(1),
          detail: 'rough kcal estimate',
          icon: Icons.local_fire_department,
          color: Colors.orangeAccent,
        ),
        _DataTile(
          title: 'Battery',
          value:
              data?.batteryPercent == null ? '--' : '${data!.batteryPercent}%',
          detail: data?.batteryVoltage == null
              ? 'waiting'
              : '${data!.batteryVoltage!.toStringAsFixed(2)} V',
          icon: Icons.battery_charging_full,
          color: const Color(0xff28f4ff),
        ),
        _DataTile(
          title: 'Sleep Prep',
          value: '${stats.sleepReadiness}%',
          detail: 'stillness readiness',
          icon: Icons.bedtime,
          color: const Color(0xffc084fc),
        ),
        _DataTile(
          title: 'Pulse Stability',
          value: '${stats.hrvProxy}%',
          detail: 'HR variability proxy',
          icon: Icons.show_chart,
          color: const Color(0xfffacc15),
        ),
      ],
    );
  }

  static String _formatDuration(int seconds) {
    final minutes = seconds ~/ 60;
    final remaining = seconds % 60;
    return '$minutes:${remaining.toString().padLeft(2, '0')}';
  }
}

class _ZonePanel extends StatelessWidget {
  const _ZonePanel({required this.stats});

  final HealthStats stats;

  @override
  Widget build(BuildContext context) {
    final total = max(
      1,
      stats.zoneSummary.rest +
          stats.zoneSummary.easy +
          stats.zoneSummary.cardio +
          stats.zoneSummary.peak,
    );

    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Heart Zones',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
          const SizedBox(height: 14),
          _ZoneBar(
              label: 'Rest',
              value: stats.zoneSummary.rest / total,
              color: const Color(0xff69ffb0)),
          _ZoneBar(
              label: 'Easy',
              value: stats.zoneSummary.easy / total,
              color: const Color(0xff28f4ff)),
          _ZoneBar(
              label: 'Cardio',
              value: stats.zoneSummary.cardio / total,
              color: Colors.orangeAccent),
          _ZoneBar(
              label: 'Peak',
              value: stats.zoneSummary.peak / total,
              color: const Color(0xffff4d8d)),
        ],
      ),
    );
  }
}

class _CoachPanel extends StatelessWidget {
  const _CoachPanel({required this.stats});

  final HealthStats stats;

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Coach',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          _CoachLine(icon: Icons.tips_and_updates, text: stats.placementTip),
          _CoachLine(icon: Icons.air, text: stats.respiratoryHint),
          for (final alert in stats.alerts)
            _CoachLine(icon: Icons.notifications_active, text: alert),
        ],
      ),
    );
  }
}

class _SignalPanel extends StatelessWidget {
  const _SignalPanel({required this.data, required this.stats});

  final HealthTelemetry? data;
  final HealthStats stats;

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Sensor Lab',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          _ProgressLine(
              label: 'Optical confidence',
              value: stats.signalQuality / 100,
              color: const Color(0xff28f4ff)),
          _ProgressLine(
              label: 'Contact stability',
              value: stats.contactPercent / 100,
              color: const Color(0xff69ffb0)),
          _ProgressLine(
            label: 'Battery reserve',
            value: ((data?.batteryPercent ?? 0) / 100).clamp(0, 1),
            color: Colors.orangeAccent,
          ),
          const SizedBox(height: 10),
          Text(
            'Raw: IR ${data?.ir ?? '--'} · Red ${data?.red ?? '--'} · Motion ${data?.motion?.toStringAsFixed(3) ?? '--'}',
            style: TextStyle(color: Colors.white.withOpacity(.62)),
          ),
        ],
      ),
    );
  }
}

class _BigMetric extends StatelessWidget {
  const _BigMetric({
    required this.label,
    required this.value,
    required this.unit,
    required this.icon,
    required this.color,
  });

  final String label;
  final String value;
  final String unit;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withOpacity(.08),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: color.withOpacity(.24)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color),
          const SizedBox(height: 14),
          Text(label, style: const TextStyle(color: Color(0xff93a9b0))),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
                color: color,
                fontSize: 42,
                fontWeight: FontWeight.w900,
                height: 1),
          ),
          Text(unit, style: TextStyle(color: color.withOpacity(.78))),
        ],
      ),
    );
  }
}

class _MiniTrend extends StatelessWidget {
  const _MiniTrend(
      {required this.minBpm, required this.maxBpm, required this.avgBpm});

  final int? minBpm;
  final int? maxBpm;
  final double? avgBpm;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
            child: _TinyStat(label: 'min', value: minBpm?.toString() ?? '--')),
        Expanded(
            child: _TinyStat(
                label: 'avg',
                value: avgBpm == null ? '--' : avgBpm!.toStringAsFixed(0))),
        Expanded(
            child: _TinyStat(label: 'max', value: maxBpm?.toString() ?? '--')),
      ],
    );
  }
}

class _TinyStat extends StatelessWidget {
  const _TinyStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label.toUpperCase(),
            style: const TextStyle(color: Color(0xff6d7f86))),
        Text(value,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
      ],
    );
  }
}

class _DataTile extends StatelessWidget {
  const _DataTile({
    required this.title,
    required this.value,
    required this.detail,
    required this.icon,
    required this.color,
  });

  final String title;
  final String value;
  final String detail;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: (MediaQuery.of(context).size.width - 46) / 2,
      child: _GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color),
            const SizedBox(height: 12),
            Text(title, style: const TextStyle(color: Color(0xff93a9b0))),
            const SizedBox(height: 4),
            Text(
              value,
              style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w900),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              detail,
              style: const TextStyle(color: Color(0xff6d7f86), fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _InsightChip extends StatelessWidget {
  const _InsightChip(
      {required this.title, required this.value, required this.icon});

  final String title;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xff69ffb0)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(color: Color(0xff93a9b0))),
                Text(value,
                    style: const TextStyle(fontWeight: FontWeight.w800)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CoachLine extends StatelessWidget {
  const _CoachLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: const Color(0xff28f4ff)),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _ZoneBar extends StatelessWidget {
  const _ZoneBar(
      {required this.label, required this.value, required this.color});

  final String label;
  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return _ProgressLine(label: label, value: value.clamp(0, 1), color: color);
  }
}

class _ProgressLine extends StatelessWidget {
  const _ProgressLine(
      {required this.label, required this.value, required this.color});

  final String label;
  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label)),
              Text('${(value * 100).round()}%'),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              minHeight: 8,
              value: value,
              backgroundColor: Colors.white.withOpacity(.08),
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(.12),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: color.withOpacity(.34)),
      ),
      child: Text(
        label,
        style:
            TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w800),
      ),
    );
  }
}

class _GlassCard extends StatelessWidget {
  const _GlassCard(
      {required this.child, this.padding = const EdgeInsets.all(16)});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.055),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: Colors.white.withOpacity(.09)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(.22),
            blurRadius: 30,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: child,
    );
  }
}

// Tiny custom chart painter. This avoids adding another package just for
// presentation graphs.
class _SparklinePainter extends CustomPainter {
  _SparklinePainter({
    required this.values,
    required this.color,
    required this.minY,
    required this.maxY,
  });

  final List<double> values;
  final Color color;
  final double minY;
  final double maxY;

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = Colors.white.withOpacity(.06)
      ..strokeWidth = 1;
    final linePaint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final fillPaint = Paint()
      ..color = color.withOpacity(.10)
      ..style = PaintingStyle.fill;

    for (int i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    if (values.length < 2) return;

    final visible =
        values.length > 80 ? values.sublist(values.length - 80) : values;
    final path = Path();
    final fillPath = Path();

    for (int i = 0; i < visible.length; i++) {
      final x =
          visible.length == 1 ? 0.0 : size.width * i / (visible.length - 1);
      final normalized = ((visible[i] - minY) / (maxY - minY)).clamp(0.0, 1.0);
      final y = size.height - normalized * size.height;
      if (i == 0) {
        path.moveTo(x, y);
        fillPath.moveTo(x, size.height);
        fillPath.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
    }

    fillPath.lineTo(size.width, size.height);
    fillPath.close();
    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter oldDelegate) {
    return oldDelegate.values != values ||
        oldDelegate.color != color ||
        oldDelegate.minY != minY ||
        oldDelegate.maxY != maxY;
  }
}

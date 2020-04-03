// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert' show json, utf8, LineSplitter, JsonEncoder;
import 'dart:io' as io;
import 'dart:math' as math;

import 'package:meta/meta.dart';
import 'package:webkit_inspection_protocol/webkit_inspection_protocol.dart';

/// The number of samples used to extract metrics, such as noise, means,
/// max/min values.
///
/// Keep this constant in sync with the same constant defined in `dev/benchmarks/macrobenchmarks/lib/src/web/recorder.dart`.
const int _kMeasuredSampleCount = 10;

/// Options passed to Chrome when launching it.
class ChromeOptions {
  ChromeOptions({
    this.userDataDirectory,
    this.url,
    this.windowWidth = 1024,
    this.windowHeight = 1024,
    this.headless,
    this.debugPort,
  });

  /// If not null passed as `--user-data-dir`.
  final String userDataDirectory;

  /// If not null launches a Chrome tab at this URL.
  final String url;

  /// The width of the Chrome window.
  ///
  /// This is important for screenshots and benchmarks.
  final int windowWidth;

  /// The height of the Chrome window.
  ///
  /// This is important for screenshots and benchmarks.
  final int windowHeight;

  /// Launches code in "headless" mode, which allows running Chrome in
  /// environments without a display, such as LUCI and Cirrus.
  final bool headless;

  /// The port Chrome will use for its debugging protocol.
  ///
  /// If null, Chrome is launched without debugging. When running in headless
  /// mode without a debug port, Chrome quits immediately. For most tests it is
  /// typical to set [headless] to true and set a non-null debug port.
  final int debugPort;
}

/// A function called when the Chrome process encounters an error.
typedef ChromeErrorCallback = void Function(String);

/// Manages a single Chrome process.
class Chrome {
  Chrome._(this._chromeProcess, this._onError, this._debugConnection) {
    // If the Chrome process quits before it was asked to quit, notify the
    // error listener.
    _chromeProcess.exitCode.then((int exitCode) {
      if (!_isStopped) {
        _onError('Chrome process exited prematurely with exit code $exitCode');
      }
    });
  }

  /// Launches Chrome with the give [options].
  ///
  /// The [onError] callback is called with an error message when the Chrome
  /// process encounters an error. In particular, [onError] is called when the
  /// Chrome process exits prematurely, i.e. before [stop] is called.
  static Future<Chrome> launch(ChromeOptions options, { String workingDirectory, @required ChromeErrorCallback onError }) async {
    final io.ProcessResult versionResult = io.Process.runSync(_findSystemChromeExecutable(), const <String>['--version']);
    print('Launching ${versionResult.stdout}');

    final bool withDebugging = options.debugPort != null;
    final List<String> args = <String>[
      if (options.userDataDirectory != null)
        '--user-data-dir=${options.userDataDirectory}',
      if (options.url != null)
        options.url,
      if (io.Platform.environment['CHROME_NO_SANDBOX'] == 'true')
        '--no-sandbox',
      if (options.headless)
        '--headless',
      if (withDebugging)
        '--remote-debugging-port=${options.debugPort}',
      '--window-size=${options.windowWidth},${options.windowHeight}',
      '--disable-extensions',
      '--disable-popup-blocking',
      // Indicates that the browser is in "browse without sign-in" (Guest session) mode.
      '--bwsi',
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-default-apps',
      '--disable-translate',
    ];
    final io.Process chromeProcess = await io.Process.start(
      _findSystemChromeExecutable(),
      args,
      workingDirectory: workingDirectory,
    );

    WipConnection debugConnection;
    if (withDebugging) {
      debugConnection = await _connectToChromeDebugPort(chromeProcess, options.debugPort);
    }

    return Chrome._(chromeProcess, onError, debugConnection);
  }

  final io.Process _chromeProcess;
  final ChromeErrorCallback _onError;
  final WipConnection _debugConnection;
  bool _isStopped = false;

  Completer<void> _tracingCompleter;
  StreamSubscription<WipEvent> _tracingSubscription;
  List<Map<String, dynamic>> _tracingData;

  /// Starts recording a performance trace.
  ///
  /// If there is already a tracing session in progress, throws an error. Call
  /// [endRecordingPerformance] before starting a new tracing session.
  ///
  /// The [label] is for debugging convenience.
  Future<void> beginRecordingPerformance(String label) async {
    if (_tracingCompleter != null) {
      throw StateError(
        'Cannot start a new performance trace. A tracing session labeled '
        '"$label" is already in progress.'
      );
    }
    _tracingCompleter = Completer<void>();
    _tracingData = <Map<String, dynamic>>[];

    // Subscribe to tracing events prior to calling "Tracing.start". Otherwise,
    // we'll miss tracing data.
    _tracingSubscription = _debugConnection.onNotification.listen((WipEvent event) {
      // We receive data as a sequence of "Tracing.dataCollected" followed by
      // "Tracing.tracingComplete" at the end. Until "Tracing.tracingComplete"
      // is received, the data may be incomplete.
      if (event.method == 'Tracing.tracingComplete') {
        _tracingCompleter.complete();
        _tracingSubscription.cancel();
        _tracingSubscription = null;
      } else if (event.method == 'Tracing.dataCollected') {
        final dynamic value = event.params['value'];
        if (value is! List) {
          throw FormatException('"Tracing.dataCollected" returned malformed data. '
              'Expected a List but got: ${value.runtimeType}');
        }
        _tracingData.addAll((event.params['value'] as List<dynamic>).cast<Map<String, dynamic>>());
      }
    });
    await _debugConnection.sendCommand('Tracing.start', <String, dynamic>{
      // The choice of categories is as follows:
      //
      // blink:
      //   provides everything on the UI thread, including scripting,
      //   style recalculations, layout, painting, and some compositor
      //   work.
      // blink.user_timing:
      //   provides marks recorded using window.performance. We use marks
      //   to find frames that the benchmark cares to measure.
      // gpu:
      //   provides tracing data from the GPU data
      // TODO(yjbanov): extract useful GPU data
      'categories': 'blink,blink.user_timing,gpu',
      'transferMode': 'SendAsStream',
    });
  }

  /// Stops a performance tracing session started by [beginRecordingPerformance].
  ///
  /// Returns all the collected tracing data unfiltered.
  Future<List<Map<String, dynamic>>> endRecordingPerformance() async {
    await _debugConnection.sendCommand('Tracing.end');
    await _tracingCompleter.future;
    final List<Map<String, dynamic>> data = _tracingData;
    _tracingCompleter = null;
    _tracingData = null;
    return data;
  }

  /// Stops the Chrome process.
  void stop() {
    _isStopped = true;
    _chromeProcess.kill();
  }
}

String _findSystemChromeExecutable() {
  // On some environments, such as the Dart HHH tester, Chrome resides in a
  // non-standard location and is provided via the following environment
  // variable.
  final String envExecutable = io.Platform.environment['CHROME_EXECUTABLE'];
  if (envExecutable != null) {
    return envExecutable;
  }

  if (io.Platform.isLinux) {
    final io.ProcessResult which =
        io.Process.runSync('which', <String>['google-chrome']);

    if (which.exitCode != 0) {
      throw Exception('Failed to locate system Chrome installation.');
    }

    return (which.stdout as String).trim();
  } else if (io.Platform.isMacOS) {
    return '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
  } else {
    throw Exception('Web benchmarks cannot run on ${io.Platform.operatingSystem} yet.');
  }
}

/// Waits for Chrome to print DevTools URI and connects to it.
Future<WipConnection> _connectToChromeDebugPort(io.Process chromeProcess, int port) async {
  chromeProcess.stdout
    .transform(utf8.decoder)
    .transform(const LineSplitter())
    .listen((String line) {
      print('[CHROME]: $line');
    });

  await chromeProcess.stderr
    .transform(utf8.decoder)
    .transform(const LineSplitter())
    .map((String line) {
      print('[CHROME]: $line');
      return line;
    })
    .firstWhere((String line) => line.startsWith('DevTools listening'), orElse: () {
      throw Exception('Expected Chrome to print "DevTools listening" string '
          'with DevTools URL, but the string was never printed.');
    });

  final Uri devtoolsUri = await _getRemoteDebuggerUrl(Uri.parse('http://localhost:$port'));
  print('Connecting to DevTools: $devtoolsUri');
  final ChromeConnection chromeConnection = ChromeConnection('localhost', port);
  final Iterable<ChromeTab> tabs = (await chromeConnection.getTabs()).where((ChromeTab tab) {
    return tab.url.startsWith('http://localhost');
  });
  final ChromeTab tab = tabs.single;
  final WipConnection debugConnection = await tab.connect();
  print('Connected to Chrome tab: ${tab.title} (${tab.url})');
  return debugConnection;
}

/// Gets the Chrome debugger URL for the web page being benchmarked.
Future<Uri> _getRemoteDebuggerUrl(Uri base) async {
  final io.HttpClient client = io.HttpClient();
  final io.HttpClientRequest request = await client.getUrl(base.resolve('/json/list'));
  final io.HttpClientResponse response = await request.close();
  final List<dynamic> jsonObject = await json.fuse(utf8).decoder.bind(response).single as List<dynamic>;
  if (jsonObject == null || jsonObject.isEmpty) {
    return base;
  }
  return base.resolve(jsonObject.first['webSocketDebuggerUrl'] as String);
}

/// Summarizes a Blink trace down to a few interesting values.
class BlinkTraceSummary {
  BlinkTraceSummary._({
    @required this.averageBeginFrameTime,
    @required this.averageUpdateLifecyclePhasesTime,
  }) : averageTotalUIFrameTime = averageBeginFrameTime + averageUpdateLifecyclePhasesTime;

  static BlinkTraceSummary fromJson(List<Map<String, dynamic>> traceJson) {
    try {
      // Convert raw JSON data to BlinkTraceEvent objects sorted by timestamp.
      List<BlinkTraceEvent> events = traceJson
        .map<BlinkTraceEvent>(BlinkTraceEvent.fromJson)
        .toList()
        ..sort((BlinkTraceEvent a, BlinkTraceEvent b) => a.ts - b.ts);

      // Filter out data from unrelated processes
      final BlinkTraceEvent processLabel = events
        .where((BlinkTraceEvent event) => event.isCrRendererMain)
        .single;
      final int tabPid = processLabel.pid;
      events = events.where((BlinkTraceEvent element) => element.pid == tabPid).toList();

      // Extract frame data.
      final List<BlinkFrame> frames = <BlinkFrame>[];
      int skipCount = 0;
      BlinkFrame frame = BlinkFrame();
      for (final BlinkTraceEvent event in events) {
        if (event.isBeginFrame) {
          frame.beginFrame = event;
        } else if (event.isUpdateAllLifecyclePhases) {
          frame.updateAllLifecyclePhases = event;
          if (frame.endMeasuredFrame != null) {
            frames.add(frame);
          } else {
            skipCount += 1;
          }
          frame = BlinkFrame();
        } else if (event.isBeginMeasuredFrame) {
          frame.beginMeasuredFrame = event;
        } else if (event.isEndMeasuredFrame) {
          frame.endMeasuredFrame = event;
        }
      }

      print('Extracted ${frames.length} measured frames.');
      print('Skipped $skipCount non-measured frames.');

      if (frames.isEmpty) {
        // The benchmark is not measuring frames.
        return null;
      }

      // Compute averages and summarize.
      return BlinkTraceSummary._(
        averageBeginFrameTime: _computeAverageDuration(frames.map((BlinkFrame frame) => frame.beginFrame).toList()),
        averageUpdateLifecyclePhasesTime: _computeAverageDuration(frames.map((BlinkFrame frame) => frame.updateAllLifecyclePhases).toList()),
      );
    } catch (_, __) {
      final io.File traceFile = io.File('./chrome-trace.json');
      io.stderr.writeln('Failed to interpret the Chrome trace contents. The trace was saved in ${traceFile.path}');
      traceFile.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(traceJson));
      rethrow;
    }
  }

  /// The average duration of "WebViewImpl::beginFrame" events.
  ///
  /// This event contains all of scripting time of an animation frame, plus an
  /// unknown small amount of work browser does before and after scripting.
  final Duration averageBeginFrameTime;

  /// The average duration of "WebViewImpl::updateAllLifecyclePhases" events.
  ///
  /// This event contains style, layout, painting, and compositor computations,
  /// which are not included in the scripting time. This event does not
  /// include GPU time, which happens on a separate thread.
  final Duration averageUpdateLifecyclePhasesTime;

  /// The average sum of [averageBeginFrameTime] and
  /// [averageUpdateLifecyclePhasesTime].
  ///
  /// This value contains the vast majority of work the UI thread performs in
  /// any given animation frame.
  final Duration averageTotalUIFrameTime;

  @override
  String toString() => '$BlinkTraceSummary('
    'averageBeginFrameTime: ${averageBeginFrameTime.inMicroseconds / 1000}ms, '
    'averageUpdateLifecyclePhasesTime: ${averageUpdateLifecyclePhasesTime.inMicroseconds / 1000}ms)';
}

/// Contains events pertaining to a single frame in the Blink trace data.
class BlinkFrame {
  /// Corresponds to 'WebViewImpl::beginFrame' event.
  BlinkTraceEvent beginFrame;

  /// Corresponds to 'WebViewImpl::updateAllLifecyclePhases' event.
  BlinkTraceEvent updateAllLifecyclePhases;

  /// Corresponds to 'measured_frame' begin event.
  BlinkTraceEvent beginMeasuredFrame;

  /// Corresponds to 'measured_frame' end event.
  BlinkTraceEvent endMeasuredFrame;
}

/// Takes a list of events that have non-null [BlinkTraceEvent.tdur] computes
/// their average as a [Duration] value.
Duration _computeAverageDuration(List<BlinkTraceEvent> events) {
  // Compute the sum of "tdur" fields of the last _kMeasuredSampleCount events.
  final double sum = events
    .skip(math.max(events.length - _kMeasuredSampleCount, 0))
    .fold(0.0, (double previousValue, BlinkTraceEvent event) {
      if (event.tdur == null) {
        throw FormatException('Trace event lacks "tdur" field: $event');
      }
      return previousValue + event.tdur;
    });
  final int sampleCount = math.min(events.length, _kMeasuredSampleCount);
  return Duration(microseconds: sum ~/ sampleCount);
}

/// An event collected by the Blink tracer (in Chrome accessible using chrome://tracing).
///
/// See also:
///  * https://docs.google.com/document/d/1CvAClvFfyA5R-PhYUmn5OOQtYMH4h6I0nSsKchNAySU/preview
class BlinkTraceEvent {
  BlinkTraceEvent._({
    @required this.args,
    @required this.cat,
    @required this.name,
    @required this.ph,
    @required this.pid,
    @required this.tid,
    @required this.ts,
    @required this.tts,
    @required this.tdur,
  });

  /// Parses an event from its JSON representation.
  ///
  /// Sample event encoded as JSON (the data is bogus, this just shows the format):
  ///
  /// ```
  /// {
  ///   "name": "myName",
  ///   "cat": "category,list",
  ///   "ph": "B",
  ///   "ts": 12345,
  ///   "pid": 123,
  ///   "tid": 456,
  ///   "args": {
  ///     "someArg": 1,
  ///     "anotherArg": {
  ///       "value": "my value"
  ///     }
  ///   }
  /// }
  /// ```
  ///
  /// For detailed documentation of the format see:
  ///
  /// https://docs.google.com/document/d/1CvAClvFfyA5R-PhYUmn5OOQtYMH4h6I0nSsKchNAySU/preview
  static BlinkTraceEvent fromJson(Map<String, dynamic> json) {
    return BlinkTraceEvent._(
      args: json['args'] as Map<String, dynamic>,
      cat: json['cat'] as String,
      name: json['name'] as String,
      ph: json['ph'] as String,
      pid: _readInt(json, 'pid'),
      tid: _readInt(json, 'tid'),
      ts: _readInt(json, 'ts'),
      tts: _readInt(json, 'tts'),
      tdur: _readInt(json, 'tdur'),
    );
  }

  /// Event-specific data.
  final Map<String, dynamic> args;

  /// Event category.
  final String cat;

  /// Event name.
  final String name;

  /// Event "phase".
  final String ph;

  /// Process ID of the process that emitted the event.
  final int pid;

  /// Thread ID of the thread that emitted the event.
  final int tid;

  /// Timestamp in microseconds using tracer clock.
  final int ts;

  /// Timestamp in microseconds using thread clock.
  final int tts;

  /// Event duration in microseconds.
  final int tdur;

  /// A "begin frame" event contains all of the scripting time of an animation
  /// frame (JavaScript, WebAssembly), plus a negligible amount of internal
  /// browser overhead.
  ///
  /// This event does not include non-UI thread scripting, such as web workers,
  /// service workers, and CSS Paint paintlets.
  ///
  /// This event is a duration event that has its `tdur` populated.
  bool get isBeginFrame => ph == 'X' && name == 'WebViewImpl::beginFrame';

  /// An "update all lifecycle phases" event contains UI thread computations
  /// related to an animation frame that's outside the scripting phase.
  ///
  /// This event includes style recalculation, layer tree update, layout,
  /// painting, and parts of compositing work.
  ///
  /// This event is a duration event that has its `tdur` populated.
  bool get isUpdateAllLifecyclePhases => ph == 'X' && name == 'WebViewImpl::updateAllLifecyclePhases';

  /// A "CrRendererMain" event contains information about the browser's UI
  /// thread.
  ///
  /// This event's [pid] field identifies the process that performs web page
  /// rendering. The [isBeginFrame] and [isUpdateAllLifecyclePhases] events
  /// with the same [pid] as this event all belong to the same web page.
  bool get isCrRendererMain => name == 'thread_name' && args['name'] == 'CrRendererMain';

  /// Whether this is the beginning of a "measured_frame" event.
  ///
  /// This event is a custom event emitted by our benchmark test harness.
  ///
  /// See also:
  ///  * `recorder.dart`, which emits this event.
  bool get isBeginMeasuredFrame => ph == 'b' && name == 'measured_frame';

  /// Whether this is the end of a "measured_frame" event.
  ///
  /// This event is a custom event emitted by our benchmark test harness.
  ///
  /// See also:
  ///  * `recorder.dart`, which emits this event.
  bool get isEndMeasuredFrame => ph == 'e' && name == 'measured_frame';

  @override
  String toString() => '$BlinkTraceEvent('
    'args: ${json.encode(args)}, '
    'cat: $cat, '
    'name: $name, '
    'ph: $ph, '
    'pid: $pid, '
    'tid: $tid, '
    'ts: $ts, '
    'tts: $tts, '
    'tdur: $tdur)';
}

/// Read an integer out of [json] stored under [key].
///
/// Since JSON does not distinguish between `int` and `double`, extra
/// validation and conversion is needed.
///
/// Returns null if the value is null.
int _readInt(Map<String, dynamic> json, String key) {
  final num jsonValue = json[key] as num;

  if (jsonValue == null) {
    return null;
  }

  return jsonValue.toInt();
}
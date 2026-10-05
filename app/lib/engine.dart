// Bridge to the Rust engine (core/): analysis, tag reading and tag writing via a JSON-in / JSON-out C ABI.
// Every call runs on a background isolate so the UI never blocks.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

typedef _StrFnC = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _VoidStrFnC = Pointer<Utf8> Function();
typedef _FreeC = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

class Engine {
  /// Library location. WRECKBOX_CORE_LIB overrides it (tests and development builds).
  static String libraryPath() {
    final override = Platform.environment['WRECKBOX_CORE_LIB'];
    if (override != null && override.isNotEmpty) return override;
    if (Platform.isAndroid) return 'libwreckbox_core.so';
    if (Platform.isWindows) return 'wreckbox_core.dll';
    if (Platform.isMacOS) {
      final exe = File(Platform.resolvedExecutable).parent.path; // …/Contents/MacOS
      final bundled = '$exe/../Frameworks/libwreckbox_core.dylib';
      return File(bundled).existsSync() ? bundled : 'libwreckbox_core.dylib';
    }
    return 'libwreckbox_core.so';
  }

  static Map<String, dynamic> _call(String lib, String fn, String? arg) {
    final dylib = DynamicLibrary.open(lib);
    final free = dylib.lookupFunction<_FreeC, _FreeDart>('wb_free');
    Pointer<Utf8> out;
    if (arg == null) {
      out = dylib.lookupFunction<_VoidStrFnC, _VoidStrFnC>(fn)();
    } else {
      final input = arg.toNativeUtf8();
      try {
        out = dylib.lookupFunction<_StrFnC, _StrFnC>(fn)(input);
      } finally {
        malloc.free(input);
      }
    }
    try {
      return Map<String, dynamic>.from(jsonDecode(out.toDartString()));
    } finally {
      free(out);
    }
  }

  static Future<Map<String, dynamic>> _run(String fn, [String? arg]) {
    final lib = libraryPath();
    return Isolate.run(() => _call(lib, fn, arg));
  }

  /// {"bpm", "bpmConfidence", "bpmAlternate", "bpmCandidates", "key", "camelot", "keyStrength",
  ///  "keyAgreement", "energy", "loudnessLufs", "durationSec"} or {"error"}
  static Future<Map<String, dynamic>> analyze(String path) => _run('wb_analyze', path);

  static Future<Map<String, dynamic>> readTags(String path) => _run('wb_read_tags', path);

  /// job: {"path", "title", "artists", "album", "year", "genre", "bpm", "key", "isrc", "cover" (local image path)}
  static Future<Map<String, dynamic>> writeTags(Map<String, dynamic> job) => _run('wb_write_tags', jsonEncode(job));

  static Future<String> version() async {
    try {
      return (await _run('wb_version'))['version'] ?? '?';
    } catch (_) {
      return 'unavailable';
    }
  }

  /// True when the engine library can be loaded on this device.
  static Future<bool> available() async {
    try {
      await _run('wb_version');
      return true;
    } catch (_) {
      return false;
    }
  }
}

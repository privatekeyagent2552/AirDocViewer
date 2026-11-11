import 'dart:convert';
import 'dart:io';

/// Restores a Dart 3.13 compile fix in the resolved `pdfrx_engine` 0.3.9 package.
///
/// `pdfDocumentFromUri` takes `PdfFileCache? cache` and assigns it with `??=`.
/// Dart 3.13 does not keep that promotion across `await` inside the `read`
/// closure, so `cache.blockSize` and `cache.read` fail to compile. Capturing a
/// non-null local leaves runtime behavior unchanged when the cache exists.
///
/// The app compiles `third_party/pdfrx_engine` via dependency_overrides, because
/// `flutter pub get` re-extracts the hosted package and drops cache edits.
/// This script re-applies the same edit to that vendored file and to whichever
/// copy `package_config.json` currently resolves. Run from the repo root:
///
/// ```
/// dart run tool/patch_pdfrx_engine.dart
/// ```
///
/// There is no published 0.3.x release after 0.3.9 that contains this fix.
void main() {
  final targets = <String, File>{};

  void add(File file) {
    if (!file.existsSync()) return;
    targets[file.absolute.path.toLowerCase()] = file.absolute;
  }

  add(File('third_party/pdfrx_engine/lib/src/native/pdf_file_cache.dart'));

  final resolved = _resolvedEngineFile();
  if (resolved != null) add(resolved);

  if (targets.isEmpty) {
    stderr.writeln(
      'No pdfrx_engine pdf_file_cache.dart found. Run from the repo root '
      'after pub get, with third_party/pdfrx_engine present.',
    );
    exitCode = 1;
    return;
  }

  var failed = false;
  for (final file in targets.values) {
    if (!_patch(file)) failed = true;
  }
  if (failed) exitCode = 1;
}

File? _resolvedEngineFile() {
  final configFile = File('.dart_tool/package_config.json');
  if (!configFile.existsSync()) return null;
  final config = jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
  final packages = config['packages'] as List<dynamic>;
  for (final package in packages) {
    final entry = package as Map<String, dynamic>;
    if (entry['name'] != 'pdfrx_engine') continue;
    final rootUri = entry['rootUri'] as String;
    final root = rootUri.endsWith('/') ? rootUri : '$rootUri/';
    return File.fromUri(Uri.parse(root).resolve('lib/src/native/pdf_file_cache.dart'));
  }
  return null;
}

bool _patch(File cacheFile) {
  final original = cacheFile.readAsStringSync();
  final newline = original.contains('\r\n') ? '\r\n' : '\n';
  final source = original.replaceAll('\r\n', '\n');

  if (source.contains(_patchedMarker) && !source.contains(_brokenRead)) {
    stdout.writeln('pdfrx_engine already patched: ${cacheFile.path}');
    return true;
  }
  if (!source.contains(_brokenBlock)) {
    stderr.writeln(
      'pdf_file_cache.dart does not match pdfrx_engine 0.3.9. '
      'Refusing to patch ${cacheFile.path}',
    );
    return false;
  }

  final patched = source.replaceFirst(_brokenBlock, _fixedBlock);
  if (patched == source || patched.contains(_brokenRead)) {
    stderr.writeln('Patch did not apply cleanly to ${cacheFile.path}');
    return false;
  }

  cacheFile.writeAsStringSync(patched.replaceAll('\n', newline));
  stdout.writeln('Patched pdfrx_engine nullable cache access: ${cacheFile.path}');
  return true;
}

const _patchedMarker = 'final activeCache = cache;';

const _brokenRead = 'await cache.read(buffer, bufferPosition, p, sizeToRead);';

const _brokenBlock = '''
    return await entryFunctions.openCustom(
      read: (buffer, position, size) async {
        final totalSize = size;
        final end = position + size;
        var bufferPosition = 0;
        for (var p = position; p < end;) {
          final blockId = p ~/ cache!.blockSize;
          final isAvailable = cache.isCached(blockId);
          if (!isAvailable) {
            await _downloadBlock(
              httpClientWrapper,
              uri,
              cache,
              progressCallback,
              blockId,
              headers: headers,
              timeout: timeout,
            );
          }
          final readEnd = min(p + size, (blockId + 1) * cache.blockSize);
          final sizeToRead = readEnd - p;
          await cache.read(buffer, bufferPosition, p, sizeToRead);
          p += sizeToRead;
          bufferPosition += sizeToRead;
          size -= sizeToRead;
        }
        return totalSize;
      },
      passwordProvider: passwordProvider,
      firstAttemptByEmptyPassword: firstAttemptByEmptyPassword,
      useProgressiveLoading: useProgressiveLoading,
      fileSize: cache.fileSize,
      sourceName: uri.toString(),
      onDispose: () {
        cache!.close();
        httpClientWrapper.reset();
      },
    );
''';

const _fixedBlock = '''
    // `cache ??=` above initialized this parameter. Capture a non-null local
    // so the closures stay valid on Dart 3.13, which drops promotion of a
    // nullable parameter across await. Non-null behavior is unchanged.
    final activeCache = cache;

    return await entryFunctions.openCustom(
      read: (buffer, position, size) async {
        final totalSize = size;
        final end = position + size;
        var bufferPosition = 0;
        for (var p = position; p < end;) {
          final blockId = p ~/ activeCache.blockSize;
          final isAvailable = activeCache.isCached(blockId);
          if (!isAvailable) {
            await _downloadBlock(
              httpClientWrapper,
              uri,
              activeCache,
              progressCallback,
              blockId,
              headers: headers,
              timeout: timeout,
            );
          }
          final readEnd = min(p + size, (blockId + 1) * activeCache.blockSize);
          final sizeToRead = readEnd - p;
          await activeCache.read(buffer, bufferPosition, p, sizeToRead);
          p += sizeToRead;
          bufferPosition += sizeToRead;
          size -= sizeToRead;
        }
        return totalSize;
      },
      passwordProvider: passwordProvider,
      firstAttemptByEmptyPassword: firstAttemptByEmptyPassword,
      useProgressiveLoading: useProgressiveLoading,
      fileSize: activeCache.fileSize,
      sourceName: uri.toString(),
      onDispose: () {
        activeCache.close();
        httpClientWrapper.reset();
      },
    );
''';

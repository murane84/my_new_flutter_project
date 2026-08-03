// Reads raw bytes for a local file path in a platform-safe way. On mobile/
// desktop this uses dart:io; on web (where local file paths aren't readable)
// it throws, so callers should guard the feature to non-web platforms.
import 'file_bytes_io.dart' if (dart.library.html) 'file_bytes_web.dart'
    as impl;

Future<List<int>> readFileBytes(String path) => impl.readFileBytes(path);

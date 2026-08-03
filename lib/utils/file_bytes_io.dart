import 'dart:io';

Future<List<int>> readFileBytes(String path) => File(path).readAsBytes();

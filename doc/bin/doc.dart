import 'dart:io';

import 'package:dmc_doc/doc.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runDoc(arguments);
}

import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/deep_link.dart';

void main() {
  runApp(
    const LudoApp(
      initialLinkReader: appLinksInitialLink,
      linkStream: appLinksLinkStream,
    ),
  );
}

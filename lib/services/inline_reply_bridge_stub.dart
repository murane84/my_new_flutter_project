/// Web: no notification isolate — replies are sent where they're typed.
void listenForInlineReplies(
    Future<void> Function(Map<String, dynamic> payload, String? input)
        send) {}

Future<bool> handInlineReplyToApp(
        Map<String, dynamic> payload, String? input) async =>
    false;

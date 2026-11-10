// Non-web builds: the browser Notification API doesn't exist — every call is
// a quiet no-op (phones/desktop use flutter_local_notifications + FCM).

bool get webNotifySupported => false;
String get webNotifyPermission => 'unsupported';
Future<String> webNotifyRequest() async => 'unsupported';
bool get webTabHidden => false;
void webNotifyShow({
  required String title,
  required String body,
  String? tag,
  void Function()? onClick,
}) {}

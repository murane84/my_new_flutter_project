// Aluta Admin — the backoffice web app (separate entrypoint, never shipped in
// the normal Aluta app). Build: tool/build_admin.ps1 → served at /admin/.
import 'package:flutter/material.dart';

import 'admin/admin_app.dart';

void main() => runApp(const AdminApp());

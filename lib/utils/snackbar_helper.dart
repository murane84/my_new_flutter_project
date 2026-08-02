import 'package:flutter/material.dart';
import 'toast_helper.dart';

// Wrappers kept for call-site compatibility.
// All now use the new pill-toast so styling is consistent app-wide.

void showErrorSnackBar(BuildContext context, String message) =>
    showToast(context, message, type: ToastType.error,
        duration: const Duration(seconds: 3));

void showSuccessSnackBar(BuildContext context, String message) =>
    showToast(context, message, type: ToastType.success);

void showInfoSnackBar(BuildContext context, String message) =>
    showToast(context, message);

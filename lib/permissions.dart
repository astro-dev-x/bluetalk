import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

/// المايك إجباري. الإشعارات نطلبها حتى يظهر إشعار "مكالمة جارية"،
/// بس ما نمنع الدخول إذا انرفضت.
Future<bool> ensureCallPermissions(BuildContext context) async {
  final results = await [
    Permission.microphone,
    Permission.notification,
  ].request();

  final mic = results[Permission.microphone];
  if (mic != null && mic.isGranted) return true;

  if (!context.mounted) return false;
  final permanent = mic?.isPermanentlyDenied ?? false;

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Microphone required'),
      content: Text(
        permanent
            ? 'Microphone access is blocked. Open settings and allow it to start a call.'
            : 'BlueTalk needs microphone access to make voice calls.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        if (permanent)
          TextButton(
            onPressed: () {
              openAppSettings();
              Navigator.pop(ctx);
            },
            child: const Text('Open Settings'),
          ),
      ],
    ),
  );
  return false;
}

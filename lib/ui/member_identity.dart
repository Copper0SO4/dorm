import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/identity.dart';
import '../domain/ledger.dart';
import 'common.dart';

String? givenName(String name) {
  final trimmed = name.trim();
  if (RegExp(r'^[\u3400-\u9fff]{2,4}$').hasMatch(trimmed)) {
    const compoundSurnames = [
      '欧阳',
      '司马',
      '上官',
      '诸葛',
      '司徒',
      '皇甫',
      '夏侯',
      '东方',
      '慕容',
      '尉迟',
      '公孙',
      '长孙',
      '独孤',
      '令狐',
      '宇文',
      '司空',
      '端木',
    ];
    final split = compoundSurnames.any(trimmed.startsWith) ? 2 : 1;
    return trimmed.length > split ? trimmed.substring(split) : null;
  }
  final parts = trimmed.split(RegExp(r'\s+'));
  if (parts.length >= 2 &&
      parts.every(
        (part) =>
            RegExp(r"^[A-Za-zÀ-ÖØ-öø-ÿ][A-Za-zÀ-ÖØ-öø-ÿ'\-]*$").hasMatch(part),
      )) {
    return parts.first;
  }
  return null;
}

class MemberAvatar extends StatelessWidget {
  const MemberAvatar({
    super.key,
    required this.name,
    this.avatar,
    this.radius = 22,
  });

  final String name;
  final String? avatar;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final label = givenName(name);
    final fallback = label == null
        ? const Icon(Icons.person_outline)
        : Padding(
            padding: const EdgeInsets.all(5),
            child: FittedBox(fit: BoxFit.scaleDown, child: Text(label)),
          );
    return CircleAvatar(
      radius: radius,
      backgroundColor: colors.primaryContainer,
      foregroundColor: colors.onPrimaryContainer,
      child: avatar == null
          ? fallback
          : ClipOval(
              child: Image.memory(
                decodeAvatar(avatar!),
                width: radius * 2,
                height: radius * 2,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => fallback,
              ),
            ),
    );
  }
}

class DeviceCode extends StatelessWidget {
  const DeviceCode(this.code, {super.key});

  final String code;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: SelectableText(
          code,
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(fontFamily: 'monospace'),
        ),
      ),
      IconButton(
        icon: const Icon(Icons.content_copy_outlined, size: 17),
        tooltip: '复制设备码',
        onPressed: () async {
          try {
            await Clipboard.setData(ClipboardData(text: code));
            if (context.mounted) notify(context, '已复制设备码');
          } catch (error) {
            if (context.mounted) {
              notify(context, errorText(error, fallback: '无法复制设备码'));
            }
          }
        },
      ),
    ],
  );
}

class AuditHistory extends StatelessWidget {
  const AuditHistory(this.entries, {super.key, this.deviceOnly = false});
  final bool deviceOnly;
  final List<AuditEntry> entries;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const Text('暂无设备修改记录。');
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        for (final entry in entries)
          DecoratedBox(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 4,
                children: [
                  Text(
                    deviceOnly
                        ? '${entry.action.label} · 操作设备'
                        : '${entry.action.label} · ${entry.memberName ?? '未认领设备'}',
                    style: theme.textTheme.titleSmall,
                  ),
                  Text(
                    '${localTime(context, entry.date)} · ${entry.detail}',
                    style: theme.textTheme.bodySmall,
                  ),
                  DeviceCode(entry.deviceCode),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

Future<String?> pickAvatar() async {
  const imageTypes = XTypeGroup(
    label: '头像图片',
    extensions: ['png', 'jpg', 'jpeg', 'webp'],
    mimeTypes: ['image/png', 'image/jpeg', 'image/webp'],
  );
  final file = await openFile(
    acceptedTypeGroups: Platform.isAndroid ? const [] : const [imageTypes],
  );
  if (file == null) return null;
  if (await file.length() > 8 * 1024 * 1024) {
    throw const InputException('请选择不超过 8 MB 的图片');
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(
    await file.readAsBytes(),
  );
  try {
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      if (descriptor.width > 8192 || descriptor.height > 8192) {
        throw const InputException('图片尺寸过大，请选用较小的图片');
      }
      final portrait = descriptor.width < descriptor.height;
      final codec = await descriptor.instantiateCodec(
        targetWidth: portrait ? avatarSize : null,
        targetHeight: portrait ? null : avatarSize,
      );
      try {
        final frame = await codec.getNextFrame();
        try {
          final image = frame.image;
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          final offset = Offset(
            (avatarSize - image.width) / 2,
            (avatarSize - image.height) / 2,
          );
          canvas.drawImage(image, offset, Paint());
          final picture = recorder.endRecording();
          try {
            final avatar = await picture.toImage(avatarSize, avatarSize);
            try {
              final bytes = await avatar.toByteData(
                format: ui.ImageByteFormat.png,
              );
              if (bytes == null) throw const InputException('无法读取头像图片');
              final encoded = base64Encode(bytes.buffer.asUint8List());
              decodeAvatar(encoded);
              return encoded;
            } finally {
              avatar.dispose();
            }
          } finally {
            picture.dispose();
          }
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
    } finally {
      descriptor.dispose();
    }
  } finally {
    buffer.dispose();
  }
}

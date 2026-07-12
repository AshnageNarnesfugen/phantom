library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter_zxing/flutter_zxing.dart' show ReaderWidget, Code;
import 'package:path_provider/path_provider.dart';
import '../../core_provider.dart';
import '../../core/ipfs_daemon.dart';
import '../../core/waku_daemon.dart';
import '../../core/yggdrasil_daemon.dart';
import '../../core/yggdrasil_peers.dart';
import '../../core/groups.dart';
import '../../core/secret_chat.dart';
import '../../core/link_preview_service.dart';
import '../../core/phantom_core.dart';
import '../../core/transport_debugger.dart';
import '../../core/update_service.dart';
import '../theme/phantom_theme.dart';
import '../widgets/widgets.dart';


part 'onboarding_screen.dart';
part 'conversations_screen.dart';
part 'chat_screen.dart';
part 'add_contact_screen.dart';
part 'settings_screen.dart';
part 'transport_debug_screen.dart';
part 'verify_contact_screen.dart';
part '_extras.dart';

const _seedKey = 'phantom_seed_v1';

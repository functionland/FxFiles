import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fula_files/app/app.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/services/local_storage_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/background_sync_service.dart';
import 'package:fula_files/core/services/auth_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize services
  await SecureStorageService.instance.init();
  await LocalStorageService.instance.init();

  // Check for existing auth session (restores sign-in state)
  await AuthService.instance.checkExistingSession();

  // Initialize background sync
  await BackgroundSyncService.instance.initialize();

  // Check if Fula API is configured and schedule sync
  final apiUrl = await SecureStorageService.instance.read(SecureStorageKeys.apiGatewayUrl);
  final jwtToken = await SecureStorageService.instance.read(SecureStorageKeys.jwtToken);
  final ipfsServer = await SecureStorageService.instance.read(SecureStorageKeys.ipfsServerUrl);
  
  if (apiUrl != null && jwtToken != null) {
    FulaApiService.instance.configure(
      endpoint: apiUrl,
      accessKey: 'JWT:$jwtToken',
      secretKey: 'not-used',
      pinningService: ipfsServer,
      pinningToken: jwtToken,
    );
    
    // Schedule periodic background sync
    await BackgroundSyncService.instance.schedulePeriodicSync();
  }

  runApp(
    const ProviderScope(
      child: FulaFilesApp(),
    ),
  );
}

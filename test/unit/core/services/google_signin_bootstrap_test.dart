import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';

import 'package:fula_files/core/services/google_signin_bootstrap.dart';

/// Stands in for the real plugin and reproduces the behaviour that caused the
/// bug: `google_sign_in_web` throws a [StateError] when `init()` runs twice,
/// while the native implementations silently tolerate it. Only `init` is
/// exercised; every other member is unreachable in these tests.
class _FakeGoogleSignInPlatform extends GoogleSignInPlatform {
  _FakeGoogleSignInPlatform({this.throwOnSecondInit = true});

  /// Mimics the web plugin (true) or a native one (false).
  final bool throwOnSecondInit;

  int initCalls = 0;
  final List<InitParameters> received = <InitParameters>[];

  /// Completes the pending `init` when set, so a test can hold the first
  /// caller open and prove that a concurrent caller joins it instead of
  /// starting a second initialization.
  Completer<void>? gate;

  /// Makes the next `init` fail with something other than a [StateError].
  Object? failWith;

  @override
  Future<void> init(InitParameters params) async {
    initCalls++;
    received.add(params);
    if (gate != null) await gate!.future;
    if (failWith != null) {
      final Object error = failWith!;
      failWith = null;
      throw error;
    }
    if (initCalls > 1 && throwOnSecondInit) {
      throw StateError('init() has already been called. Calling init() more '
          'than once results in undefined behavior.');
    }
  }

  @override
  Future<AuthenticationResults?>? attemptLightweightAuthentication(
          AttemptLightweightAuthenticationParameters params) =>
      throw UnimplementedError();

  @override
  bool supportsAuthenticate() => throw UnimplementedError();

  @override
  Future<AuthenticationResults> authenticate(AuthenticateParameters params) =>
      throw UnimplementedError();

  @override
  bool authorizationRequiresUserInteraction() => throw UnimplementedError();

  @override
  Future<ClientAuthorizationTokenData?> clientAuthorizationTokensForScopes(
          ClientAuthorizationTokensForScopesParameters params) =>
      throw UnimplementedError();

  @override
  Future<ServerAuthorizationTokenData?> serverAuthorizationTokensForScopes(
          ServerAuthorizationTokensForScopesParameters params) =>
      throw UnimplementedError();

  @override
  Future<void> signOut(SignOutParams params) => throw UnimplementedError();

  @override
  Future<void> disconnect(DisconnectParams params) =>
      throw UnimplementedError();
}

void main() {
  late _FakeGoogleSignInPlatform fake;

  setUp(() {
    GoogleSignInBootstrap.resetForTest();
    fake = _FakeGoogleSignInPlatform();
    GoogleSignInPlatform.instance = fake;
  });

  test('initializes the singleton exactly once across repeated callers', () async {
    await GoogleSignInBootstrap.ensureInitialized(clientId: 'web-client');
    await GoogleSignInBootstrap.ensureInitialized(clientId: 'web-client');
    await GoogleSignInBootstrap.ensureInitialized(clientId: 'web-client');

    expect(fake.initCalls, 1);
    expect(GoogleSignInBootstrap.isInitialized, isTrue);
  });

  test(
      'second caller with different parameters does not re-initialize '
      '(the sign-in screen and the scope request configure the same singleton)',
      () async {
    await GoogleSignInBootstrap.ensureInitialized(clientId: 'web-client');
    // AuthService would pass serverClientId on Android; whoever gets there
    // first wins, and the loser must not throw.
    await GoogleSignInBootstrap.ensureInitialized(serverClientId: 'server');

    expect(fake.initCalls, 1);
    expect(fake.received.single.clientId, 'web-client');
  });

  test('concurrent callers share one initialization', () async {
    fake.gate = Completer<void>();

    final Future<void> a = GoogleSignInBootstrap.ensureInitialized(
      clientId: 'web-client',
    );
    final Future<void> b = GoogleSignInBootstrap.ensureInitialized(
      clientId: 'web-client',
    );

    expect(fake.initCalls, 1, reason: 'the second caller must join the first');
    fake.gate!.complete();
    await Future.wait(<Future<void>>[a, b]);

    expect(fake.initCalls, 1);
  });

  test('an already-initialized plugin is treated as success, not a failure',
      () async {
    // Simulates a hot restart, or any other path that initialized the
    // singleton behind the bootstrap's back: Dart state is fresh but the
    // plugin still throws.
    fake.initCalls = 1;

    await expectLater(
      GoogleSignInBootstrap.ensureInitialized(clientId: 'web-client'),
      completes,
    );
    expect(GoogleSignInBootstrap.isInitialized, isTrue);
  });

  test(
      'a web plugin poisoned by a failed first init is reported, not reported '
      'as success', () async {
    // google_sign_in_web raises its double-init flag BEFORE awaiting the GIS
    // script, so an attempt that fails at that await leaves the plugin
    // permanently rejecting retries while never finishing initialization.
    // Treating that rejection as "already initialized" would hand callers a
    // client that hangs.
    fake.failWith = Exception('GIS script failed to load');

    await expectLater(
      GoogleSignInBootstrap.ensureInitialized(clientId: 'web-client'),
      throwsA(isA<Exception>()),
    );

    await expectLater(
      GoogleSignInBootstrap.ensureInitialized(clientId: 'web-client'),
      throwsA(isA<StateError>().having(
        (StateError e) => e.message,
        'message',
        contains('reload'),
      )),
    );
    expect(GoogleSignInBootstrap.isInitialized, isFalse);
  });

  test('a transient failure is surfaced and leaves a retry possible', () async {
    // A native-style plugin, so the retry below exercises a genuine second
    // initialization rather than the already-initialized branch.
    final native = _FakeGoogleSignInPlatform(throwOnSecondInit: false);
    GoogleSignInPlatform.instance = native;
    native.failWith = Exception('GIS script failed to load');

    await expectLater(
      GoogleSignInBootstrap.ensureInitialized(clientId: 'web-client'),
      throwsA(isA<Exception>()),
    );
    expect(GoogleSignInBootstrap.isInitialized, isFalse);

    // The retry must actually reach the plugin again rather than replay the
    // cached failure.
    await GoogleSignInBootstrap.ensureInitialized(clientId: 'web-client');
    expect(native.initCalls, 2);
    expect(GoogleSignInBootstrap.isInitialized, isTrue);
  });
}

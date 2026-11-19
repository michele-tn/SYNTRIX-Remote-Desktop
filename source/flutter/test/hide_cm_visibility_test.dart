import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/server_model.dart';
import 'package:flutter_test/flutter_test.dart';

class _Binding extends Fake implements RustdeskImpl {
  String approveMode = 'password';

  @override
  String translate(
          {required String name, required String locale, dynamic hint}) =>
      name;

  @override
  String mainGetOptionSync({required String key, dynamic hint}) =>
      {
        kOptionVerificationMethod: kUsePermanentPassword,
        kOptionApproveMode: approveMode,
        'allow-hide-cm': 'Y',
      }[key] ??
      '';
}

class _Session extends Fake implements FFI {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Binding binding;
  late _Session session;

  setUp(() {
    isTest = true;
    binding = _Binding();
    platformFFI.setBindingForTesting(binding);
    session = _Session();
  });
  tearDown(() {
    isTest = false;
  });

  test('an authorized remote session does not reveal a hidden CM', () {
    final model = ServerModel(WeakReference(session));
    addTearDown(model.dispose);
    model.clients
        .add(Client(1, true, false, false, 'Peer', '123', true, true, true));
    expect(model.hideCm, isTrue);
    expect(model.shouldShowCm, isFalse);
  });

  test('a tray request reveals the full CM for an authorized session',
      () async {
    final model = ServerModel(WeakReference(session));
    addTearDown(model.dispose);
    model.clients
        .add(Client(1, true, false, false, 'Peer', '123', true, true, true));
    expect(model.shouldShowCm, isFalse);
    await model.requestConnectionManager();
    expect(model.shouldShowCm, isTrue);
  });

  test('approval by click keeps the CM visible despite the hide option', () {
    binding.approveMode = 'click';
    final model = ServerModel(WeakReference(session));
    addTearDown(model.dispose);
    model.clients
        .add(Client(1, false, false, false, 'Peer', '123', true, true, true));
    expect(model.hideCm, isFalse);
    expect(model.shouldShowCm, isTrue);
  });
}

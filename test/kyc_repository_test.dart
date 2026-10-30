import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crosspay_app/core/network/api_exception.dart';
import 'package:crosspay_app/core/network/dio_client.dart';
import 'package:crosspay_app/models/user_model.dart';
import 'package:crosspay_app/repositories/auth_repository.dart';

// Test inputs only. Not app data.
class _BodyAdapter implements HttpClientAdapter {
  _BodyAdapter(this._body);

  final String _body;
  String? lastMethod;
  String? lastPath;
  Object? lastData;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastMethod = options.method;
    lastPath = options.path;
    lastData = options.data;
    return ResponseBody.fromString(
      _body,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

AuthRepository _repoFor(_BodyAdapter adapter) => AuthRepository(
      buildDio(
        const ApiConfig(
          baseUrl: 'http://server.invalid',
          retryBaseDelay: Duration.zero,
        ),
        adapter: adapter,
      ),
    );

void main() {
  test('submitting KYC uses PUT with the three fields', () async {
    final adapter = _BodyAdapter('{"kycStatus": "pending"}');

    final status = await _repoFor(adapter).submitKyc(
      businessName: 'Test Trading',
      hubId: 'h1',
      idNumber: 'TEST-ID-1',
    );

    expect(adapter.lastMethod, 'PUT');
    expect(adapter.lastPath, '/api/v1/me/kyc');
    expect(adapter.lastData, {
      'businessName': 'Test Trading',
      'hubId': 'h1',
      'idNumber': 'TEST-ID-1',
    });
    expect(status, KycStatus.pending);
  });

  test('a verified reply is understood', () async {
    final status = await _repoFor(_BodyAdapter('{"kycStatus": "verified"}'))
        .submitKyc(businessName: 'a', hubId: 'h', idNumber: 'i');
    expect(status, KycStatus.verified);
  });

  test('an unknown status is rejected clearly', () async {
    await expectLater(
      _repoFor(_BodyAdapter('{"kycStatus": "maybe"}'))
          .submitKyc(businessName: 'a', hubId: 'h', idNumber: 'i'),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'INVALID_RESPONSE'),
      ),
    );
  });
}

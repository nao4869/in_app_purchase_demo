import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'consumable_store.dart';
import 'package:http/http.dart' as http; // for http request

void main() {
  /// アプリ内課金を初期化し、有効にします
  InAppPurchaseConnection.enablePendingPurchases();
  runApp(MyApp());
}

const bool kAutoConsume = true;

// とりあえずAndroidのテスト用Product IDを使用
// リリース時には、登録した課金アイテムのIDと変更してください
const String _kConsumableId = 'android.test.purchased';
const List<String> _kProductIds = <String>[
  'android.test.purchased',
];

class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final InAppPurchaseConnection _connection = InAppPurchaseConnection.instance;
  StreamSubscription<List<PurchaseDetails>> _subscription;
  List<String> _notFoundIds = [];
  List<ProductDetails> _products = [];
  List<PurchaseDetails> _purchases = [];
  List<String> _consumables = [];
  bool _isAvailable = false;
  bool _purchasePending = false;
  bool _loading = true;
  String _queryProductError;

  @override
  void initState() {
    Stream purchaseUpdated =
        InAppPurchaseConnection.instance.purchaseUpdatedStream;
    _subscription = purchaseUpdated.listen((purchaseDetailsList) {
      _listenToPurchaseUpdated(purchaseDetailsList);
    }, onDone: () {
      _subscription.cancel();
    }, onError: (error) {
      // handle error here.
    });

    /// 本番環境で登録したプロダクトIDに変更してください
    initStoreInfo(_kProductIds);
    super.initState();
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }

  Future<void> initStoreInfo(
    List<String> productIds,
  ) async {
    // アプリ内課金の有効性を確認
    _isAvailable = await _connection.isAvailable();

    // アプリ内課金が有効のときのみ以下を処理
    if (_isAvailable) {
      // 販売中プロダクトIDの確定
      final ids = Set<String>.from(productIds);

      // Storeに有効なアイテムを問い合わせる
      final productDetailResponse = await _connection.queryProductDetails(ids);

      // 一応異常系の場合はログに出力しておく
      if (productDetailResponse.error != null) {
        debugPrint(
            'productDetailResponse error!!  cause:${productDetailResponse.error.message}');
      }
      if (productDetailResponse.productDetails.isEmpty) {
        debugPrint('productDetailResponse empty!!');
      }

      // ストア確認後の課金アイテム情報を保持する
      // プロダクトを取得した後、_loadingをfalseにします
      _products = productDetailResponse.productDetails;
      _loading = false;

      // 購入済みのプロダクト一覧を取得します
      // レシートの取得などは行われない為、必要であれば、別途pendingPurchaseCheckなどにて取得してください
      final QueryPurchaseDetailsResponse purchaseResponse =
          await _connection.queryPastPurchases();
      if (purchaseResponse.error != null) {
        debugPrint(
            'There is an error when querying past purchase response, cause are ${purchaseResponse.error.message}');
      }
      final List<PurchaseDetails> verifiedPurchases = [];
      for (PurchaseDetails purchase in purchaseResponse.pastPurchases) {
        if (await _verifyPurchase(purchase)) {
          verifiedPurchases.add(purchase);
        }
      }
    }
  }

  Future<bool> _verifyPurchase(PurchaseDetails purchaseDetails) async {
    var result = false;
    if (Platform.isAndroid) {
      /// ダイアログを表示する処理
      result = await _verifyPurchaseAndroid(purchaseDetails);
    } else {
      /// ダイアログを表示する処理
      result = await _verifyPurchaseIos(purchaseDetails);
    }

    /// ダイアログを閉じる処理
    return result;
  }

  /// Android レシートチェック処理
  Future<bool> _verifyPurchaseAndroid(PurchaseDetails purchaseDetails) async {
    // 消耗型アイテムの処理 - レシートデータをBase64エンコードする
    final base64Receipt = base64.encode(
        utf8.encode(purchaseDetails.verificationData.localVerificationData));

    // サーバーサイドで購入情報を管理する際には、Androidではレシート情報をbase64エンコードし送信します
    final receiptData = json.encode({
      'signature': purchaseDetails.billingClientPurchase.signature,
      'receipt': base64Receipt,
    });

    /// `RECEIPT_VERIFICATION_ENDPOINT_FOR_ANDROID`にはCloudFunctionsのエンドポイントが設定されている想定です。
    /// 双方のデータをレシート検証用エンドポイントに送信し、ステータスコード200が返却されれば検証は完了です。
    /// 200以外のステータスコードを受信した場合、`catch`にて補足され即座に`false`が返却されます。
    final response = await http.post(
      'end point for server side',
      body: receiptData,
    );

    /// 以下はレシート検証が正常に完了した場合の実装サンプルです。
    /// isAutoRenewing = true の場合、定期購読タイプのアイテムであると判定出来ます。
    final typeOfSubscription =
        purchaseDetails.billingClientPurchase.isAutoRenewing;
    if (typeOfSubscription) {
      /// 定期購読タイプのアイテムの場合の処理
    } else {
      /// 非消費型、または消費型アイテムの場合の処理
    }

    if (response == null) {
      return false;
    }
    return true;
  }

  /// iOS課金処理（レシートチェック）APIを送信します。
  Future<bool> _verifyPurchaseIos(PurchaseDetails purchaseDetails) async {
    try {
      // サブスクアイテムの処理
      if (purchaseDetails.productID.contains('sbsc')) {
        // サーバーサイドで購入情報を管理する際には、iOSもAndroidと同様に、base64Encodeをしていきましょう
        final receiptData = json.encode({
          'receipt': purchaseDetails.verificationData.localVerificationData,
        });

        /// `RECEIPT_VERIFICATION_ENDPOINT_FOR_ANDROID`にはCloudFunctionsのエンドポイントが設定されている想定です。
        /// 双方のデータをレシート検証用エンドポイントに送信し、ステータスコード200が返却されれば検証は完了です。
        /// 200以外のステータスコードを受信した場合、`catch`にて補足され即座に`false`が返却されます。
        final response = await http.post(
          'end point for server side',
          body: receiptData,
        );

        if (response == null) {
          return false;
        }
      } else {
        // サーバーサイドで購入情報を管理する際には、iOSもAndroidと同様に、base64Encodeをしていきましょう
        final receiptData = json.encode({
          'receipt': purchaseDetails.verificationData.localVerificationData,
        });

        /// `RECEIPT_VERIFICATION_ENDPOINT_FOR_ANDROID`にはCloudFunctionsのエンドポイントが設定されている想定です。
        /// 双方のデータをレシート検証用エンドポイントに送信し、ステータスコード200が返却されれば検証は完了です。
        /// 200以外のステータスコードを受信した場合、`catch`にて補足され即座に`false`が返却されます。
        final response = await http.post(
          'end point for server side',
          body: receiptData,
        );

        if (response == null) {
          return false;
        }
      }
    } catch (e) {
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    List<Widget> stack = [];
    if (_queryProductError == null) {
      stack.add(
        ListView(
          children: [
            _buildConnectionCheckTile(),
            _buildProductList(),
            _buildConsumableBox(),
          ],
        ),
      );
    } else {
      stack.add(Center(
        child: Text(_queryProductError),
      ));
    }
    if (_purchasePending) {
      stack.add(
        Stack(
          children: [
            Opacity(
              opacity: 0.3,
              child: const ModalBarrier(dismissible: false, color: Colors.grey),
            ),
            Center(
              child: CircularProgressIndicator(),
            ),
          ],
        ),
      );
    }

    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('IAP Example'),
        ),
        body: Stack(
          children: stack,
        ),
      ),
    );
  }

  Card _buildConnectionCheckTile() {
    if (_loading) {
      return Card(child: ListTile(title: const Text('Trying to connect...')));
    }
    final Widget storeHeader = ListTile(
      leading: Icon(_isAvailable ? Icons.check : Icons.block,
          color: _isAvailable ? Colors.green : ThemeData.light().errorColor),
      title: Text(
          'The store is ' + (_isAvailable ? 'available' : 'unavailable') + '.'),
    );
    final List<Widget> children = <Widget>[storeHeader];

    if (!_isAvailable) {
      children.addAll(
        [
          Divider(),
          ListTile(
            title: Text('Not connected',
                style: TextStyle(color: ThemeData.light().errorColor)),
            subtitle: const Text(
                'Unable to connect to the payments processor. Has this app been configured correctly? See the example README for instructions.'),
          ),
        ],
      );
    }
    return Card(child: Column(children: children));
  }

  Card _buildProductList() {
    if (_loading) {
      return Card(
        child: ListTile(
          leading: CircularProgressIndicator(),
          title: Text('Fetching products...'),
        ),
      );
    }
    if (!_isAvailable) {
      return Card();
    }
    final ListTile productHeader = ListTile(title: Text('Products for Sale'));
    List<ListTile> productList = <ListTile>[];
    if (_notFoundIds.isNotEmpty) {
      productList.add(
        ListTile(
          title: Text(
            '[${_notFoundIds.join(", ")}] not found',
            style: TextStyle(color: ThemeData.light().errorColor),
          ),
          subtitle: Text(
              'This app needs special configuration to run. Please see example/README.md for instructions.'),
        ),
      );
    }

    Map<String, PurchaseDetails> purchases = Map.fromEntries(
      _purchases.map(
        (PurchaseDetails purchase) {
          if (purchase.pendingCompletePurchase) {
            InAppPurchaseConnection.instance.completePurchase(purchase);
          }
          return MapEntry<String, PurchaseDetails>(
              purchase.productID, purchase);
        },
      ),
    );

    productList.addAll(
      _products.map(
        (ProductDetails productDetails) {
          PurchaseDetails previousPurchase = purchases[productDetails.id];
          return ListTile(
            title: Text(
              productDetails.title,
            ),
            subtitle: Text(
              productDetails.description,
            ),
            trailing: previousPurchase != null
                ? Icon(Icons.check)
                : FlatButton(
                    child: Text(productDetails.price),
                    color: Colors.green[800],
                    textColor: Colors.white,
                    onPressed: () {
                      PurchaseParam purchaseParam = PurchaseParam(
                          productDetails: productDetails,
                          applicationUserName: null,
                          sandboxTesting: true);
                      if (productDetails.id == _kConsumableId) {
                        _connection.buyConsumable(
                            purchaseParam: purchaseParam,
                            autoConsume: kAutoConsume || Platform.isIOS);
                      } else {
                        _connection.buyNonConsumable(
                            purchaseParam: purchaseParam);
                      }
                    },
                  ),
          );
        },
      ),
    );

    return Card(
      child: Column(
        children: <Widget>[productHeader, Divider()] + productList,
      ),
    );
  }

  Card _buildConsumableBox() {
    if (_loading) {
      return Card(
        child: ListTile(
          leading: CircularProgressIndicator(),
          title: Text('Fetching consumables...'),
        ),
      );
    }
    if (!_isAvailable || _notFoundIds.contains(_kConsumableId)) {
      return Card();
    }
    final ListTile consumableHeader =
        ListTile(title: Text('Purchased consumables'));
    final List<Widget> tokens = _consumables.map((String id) {
      return GridTile(
        child: IconButton(
          icon: Icon(
            Icons.stars,
            size: 42.0,
            color: Colors.orange,
          ),
          splashColor: Colors.yellowAccent,
          onPressed: () => consume(id),
        ),
      );
    }).toList();
    return Card(
      child: Column(
        children: <Widget>[
          consumableHeader,
          Divider(),
          GridView.count(
            crossAxisCount: 5,
            children: tokens,
            shrinkWrap: true,
            padding: EdgeInsets.all(16.0),
          )
        ],
      ),
    );
  }

  Future<void> consume(String id) async {
    await ConsumableStore.consume(id);
    final List<String> consumables = await ConsumableStore.load();
    setState(() {
      _consumables = consumables;
    });
  }

  void showPendingUI() {
    setState(() {
      _purchasePending = true;
    });
  }

  void deliverProduct(PurchaseDetails purchaseDetails) async {
    // IMPORTANT!! Always verify a purchase purchase details before delivering the product.
    if (purchaseDetails.productID == _kConsumableId) {
      await ConsumableStore.save(purchaseDetails.purchaseID);
      List<String> consumables = await ConsumableStore.load();
      setState(() {
        _purchasePending = false;
        _consumables = consumables;
      });
    } else {
      setState(() {
        _purchases.add(purchaseDetails);
        _purchasePending = false;
      });
    }
  }

  void handleError(IAPError error) {
    setState(() {
      _purchasePending = false;
    });
  }

  /// レシートチェックエラー等、課金失敗時処理
  Future<void> _handleInvalidPurchase(PurchaseDetails purchaseDetails) async {
    // TODO: 課金失敗ダイアログ等を表示する
  }

  void _listenToPurchaseUpdated(
      List<PurchaseDetails> purchaseDetailsList) async {
    // 全てのTransactionについて処理します。
    purchaseDetailsList.forEach((PurchaseDetails purchaseDetails) async {
      // 該当するProductをクリック後の分岐、毎回必ず通ります。
      if (purchaseDetails.status == PurchaseStatus.pending) {
        // 購入ダイアログが表示された状態がpendingです。
        await showPendingUI();
      } else {
        // ダイアログ表示後にキャンセル、パスワード不一致などの場合
        if (purchaseDetails.status == PurchaseStatus.error) {
          // TODO: ダイアログの表示など、Transactionがerrorのときのユーザへの通知
        }
        // 正常に購入された場合
        else if (purchaseDetails.status == PurchaseStatus.purchased) {
          // レシートの検証などは_verifyPurchase
          // _verifyPurchaseの処理終了後、deliverProductが実行されます。
          final bool valid = await _verifyPurchase(purchaseDetails);

          if (!valid) {
            // 7/15 - サーバー側のレシート検証に失敗した際は、確認ダイアログを表示し、Transactionは終了しません。
            /// 課金終了状態のRedux保持は_handleInvalidPurchase で表示するダイアログの終了処理で実施しています。
            await _handleInvalidPurchase(purchaseDetails);
            return;
          }
        }
        if (Platform.isAndroid) {
          // 消費型アイテムの場合は、consumePurchase します
          if (!kAutoConsume && null != purchaseDetails.productID) {
            await InAppPurchaseConnection.instance
                .consumePurchase(purchaseDetails);
          }
        }
        // 購入が正常に完了した場合の処理
        if (purchaseDetails.pendingCompletePurchase) {
          try {
            /// 一度に複数件の同じPIDのサブスクをcompletePurchaseしようとすると、2件目以降でExceptionとなります。
            /// The transaction with transactionIdentifer:(null) does not exist. Note that if the transactionState is purchasing, the transactionIdentifier will be nil(null).
            /// see）https://github.com/flutter/flutter/issues/57356
            await InAppPurchaseConnection.instance
                .completePurchase(purchaseDetails);
            debugPrint(
                '--- completePurchase ------- pid:${purchaseDetails.productID}, status:${purchaseDetails.status}');
          } catch (e, stackTrace) {
            debugPrint(
                'completePurchase Error!, cause:${e.toString()}\n${stackTrace}');
          }
        }
      }
    });
  }

  /// 課金アイテム購入処理
  /// 消費型／サブスク共通
  /// @param    productId   : 購入する課金アイテムプロダクトID文字列
  void purchaseItem(String productId) async {
    // TODO: 指定プロダクトIDの課金アイテム情報の取得
    final productDetails =
        _products.firstWhere((element) => element.id == productId);

    if (null == productId) {
      debugPrint('productDetails is null. Store account is not set...');
    } else {
      final purchaseParam = PurchaseParam(
        productDetails: productDetails,
        applicationUserName: null,
        sandboxTesting: false,
      );

      /// 購入するアイテムの種別に応じて分岐
      if (productId.contains('subscription')) {
        try {
          await _connection.buyNonConsumable(
            purchaseParam: purchaseParam,
          );
        } catch (e, stackTrace) {
          // 未完了トランザクションがあるアイテムの場合、iosのみExceptionが発生します。
          debugPrint(
              'buyNonConsumable Error! cause:${e.toString()}\n${stackTrace}');

          // TODO: 未完了トランザクション時のエラーを表示するダイアログ
        }
      } else {
        try {
          await _connection.buyConsumable(
            purchaseParam: purchaseParam,
            autoConsume: kAutoConsume || Platform.isIOS,
          );
        } catch (e, stackTrace) {
          // 未完了トランザクションがあるアイテムの場合、iosのみExceptionが発生します。
          debugPrint(
              'buyNonConsumable Error! cause:${e.toString()}\n${stackTrace}');

          // TODO: 未完了トランザクション時のエラーを表示するダイアログ
        }
      }
    }
  }

  /// Androidレシート取得、中断中課金処理再開処理
  Future<void> pendingPurchaseCheck() async {
    if (!Platform.isAndroid) {
      return;
    }

    /// (1) 現在所持しているレシートを取得する
    final purchaseResponse = await _connection.queryPastPurchases();
    if (purchaseResponse.error != null) {
      debugPrint('purchase response error');
    } else if (purchaseResponse.pastPurchases.isEmpty) {
      debugPrint('past purchase is empty');
    } else {
      // 全ての保持レシートについて確認
      for (PurchaseDetails purchase in purchaseResponse.pastPurchases) {
        debugPrint(
            '--- queryPastPurchases product id: ${purchase.productID}, status:${purchase.status}');

        // (2) サーバーへレシートチェックAPI送信
        final result = await _verifyPurchase(purchase);
        if (result) {
          // (2-1) APIにてレシート検証に問題がなければ、completePurchase or consumePurchaseします
          if (!kAutoConsume && purchase.productID.contains('consume')) {
            // 消費型なら consumePurchase する
            await InAppPurchaseConnection.instance.consumePurchase(purchase);
            debugPrint(
                '--- consumePurchase ------- product id: ${purchase.productID}, status:${purchase.status}');
          }
          // 課金Transactionの終了
          try {
            await InAppPurchaseConnection.instance.completePurchase(purchase);
            debugPrint(
                '--- completePurchase ------- product id: ${purchase.productID}, status:${purchase.status}');
          } catch (e, stackTrace) {
            debugPrint(
                'completePurchase Error: ${e.toString()}\n${stackTrace}');
          }
        }
      }
    }
  }

  Future<QueryPurchaseDetailsResponse> getPastPurchase() async {
    QueryPurchaseDetailsResponse purchaseResponse;
    var counter = 0;

    // レシートデータが存在している限り、ループで取得します
    while (true) {
      debugPrint('getPastPurchase called. counter:$counter');

      // 購入履歴の取得
      purchaseResponse = await _connection.queryPastPurchases();

      // 結果が エラーまたは復旧すべきレシートがない場合は処理しません
      if (purchaseResponse.error != null ||
          purchaseResponse.pastPurchases.isEmpty) {
        debugPrint('past purchase is empty or null');
        break;
      } else {
        if (purchaseResponse.pastPurchases.isNotEmpty) {
          // 現象として、ProductIDやStatusは正常に設定されているが、レシートデータがnullの状態が発生することがあります。
          if (null !=
              purchaseResponse
                  .pastPurchases[0].verificationData.serverVerificationData) {
            // レシートデータが非nullの場合（正常系）: リトライループ終了
            debugPrint('Receipt data is available.');
            break;
          } else {
            // レシートデータがnullの場合、上限を決めてリトライします。
            counter++;
            if (5 < counter) {
              debugPrint('Receipt data is null');
              return null;
            }

            // リトライするまでdelayさせます
            debugPrint('Receipt data is null');
            await Future.delayed(const Duration(milliseconds: 500));
          }
        }
      }
    }
    return purchaseResponse;
  }
}

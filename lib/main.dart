// Copyright 2019 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'consumable_store.dart';

void main() {
  /// アプリ内課金を初期化し、有効にします
  InAppPurchaseConnection.enablePendingPurchases();
  runApp(MyApp());
}

const bool kAutoConsume = true;

// とりあえずAndroidのテスト用Product IDを使用
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

  Future<bool> _verifyPurchase(PurchaseDetails purchaseDetails) {
    // IMPORTANT!! Always verify a purchase before delivering the product.
    // For the purpose of an example, we directly return true.
    return Future<bool>.value(true);
  }

  void _handleInvalidPurchase(PurchaseDetails purchaseDetails) {
    // handle invalid purchase here if  _verifyPurchase` failed.
  }

  void _listenToPurchaseUpdated(List<PurchaseDetails> purchaseDetailsList) {
    purchaseDetailsList.forEach((PurchaseDetails purchaseDetails) async {
      if (purchaseDetails.status == PurchaseStatus.pending) {
        showPendingUI();
      } else {
        if (purchaseDetails.status == PurchaseStatus.error) {
          handleError(purchaseDetails.error);
        } else if (purchaseDetails.status == PurchaseStatus.purchased) {
          bool valid = await _verifyPurchase(purchaseDetails);
          if (valid) {
            deliverProduct(purchaseDetails);
          } else {
            _handleInvalidPurchase(purchaseDetails);
            return;
          }
        }
        if (Platform.isAndroid) {
          if (!kAutoConsume && purchaseDetails.productID == _kConsumableId) {
            await InAppPurchaseConnection.instance
                .consumePurchase(purchaseDetails);
          }
        }
        if (purchaseDetails.pendingCompletePurchase) {
          await InAppPurchaseConnection.instance
              .completePurchase(purchaseDetails);
        }
      }
    });
  }
}

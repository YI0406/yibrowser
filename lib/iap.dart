import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'setting.dart';
import 'dart:async' show Completer, Future, StreamSubscription, unawaited;
import 'package:flutter/material.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart';
import 'dart:convert'
    show base64Decode, base64Encode, jsonEncode, jsonDecode, utf8;
import 'package:http/http.dart' as http;
import 'app_localizations.dart';

class PurchaseService {
  // 1️⃣ 新增這個變數在 PurchaseService 類別裡
  Function()? onPurchaseUpdated;
  Completer<bool>? _purchaseCompleter;
  bool _restoreRequested = false; // 僅在使用者主動點「還原購買」時處理 restored 事件

  // 廣告暫停/恢復用：通知外部（例如 AdManager）IAP 是否進行中
  void Function(bool busy)? onIapBusyChanged;
  bool get isIapActive => _purchaseCompleter != null || _restoreRequested;

  static final PurchaseService _instance = PurchaseService._internal();
  factory PurchaseService() => _instance;
  PurchaseService._internal();

  final InAppPurchase _iap = InAppPurchase.instance;
  late StreamSubscription<List<PurchaseDetails>> _subscription;

  // 產品 ID（非消耗性：解鎖高級功能 + 移除廣告）
  final String _productId = 'com.yibrowser.vip';

  // 商品清單
  List<ProductDetails> _products = [];

  // 是否已解鎖高級功能
  bool _isPremiumUnlocked = false;
  //bool _isPremiumUnlocked = true;
  // 是否已解鎖高級功能
  // Getter: 取得商品列表
  List<ProductDetails> get products => _products;

  // 方便 UI 直接拿到 VIP 商品（若還沒載入則為 null）
  ProductDetails? get vipProduct {
    try {
      return _products.firstWhere((p) => p.id == _productId);
    } catch (_) {
      return null;
    }
  }

  // Getter: 是否已購買
  bool get isPremiumUnlocked => _isPremiumUnlocked;
  //bool get isPremiumUnlocked => true; // ✅ 直接強制當作已購買

  // 初始化 IAP 服務
  Future<void> init() async {
    _subscription = _iap.purchaseStream.listen((purchases) {
      debugPrint(
        "🔔 收到 purchaseStream 更新（啟動/前景可能會觸發）: ${purchases.map((e) => "${e.productID}:${e.status}").join(", ")}",
      );
      _handlePurchaseUpdates(purchases);
    });

    await _loadProducts();
    await _checkPreviousPurchase();
    try {
      onPurchaseUpdated?.call();
    } catch (_) {}
  }

  // 新增初始化商店資訊的方法
  Future<void> initStoreInfo() async {
    await init(); // 初始化 IAP 與檢查購買紀錄
    print("📲 啟動時購買狀態：$_isPremiumUnlocked");
  }

  // 加載商品清單
  Future<void> _loadProducts() async {
    final response = await _iap.queryProductDetails({_productId});
    if (response.notFoundIDs.isNotEmpty) {
      print('未找到的商品: ${response.notFoundIDs}');
    }
    _products = response.productDetails;
  }

  // 執行購買
  Future<bool> buyPremium(BuildContext context) async {
    // Check store availability first
    final available = await _iap.isAvailable();
    if (!available) {
      debugPrint("❌ 購買失敗：商店不可用（_iap.isAvailable=false）");
      return false;
    }

    if (_products.isEmpty) {
      debugPrint("❌ 購買失敗：_products 為空");
      return false;
    }

    final product = _products.firstWhere((p) => p.id == _productId);
    final purchaseParam = PurchaseParam(productDetails: product);

    debugPrint("🧾 準備購買商品：${product.id}");

    final prefs = await SharedPreferences.getInstance();
    final before = prefs.getBool('isPremiumUnlocked') ?? false;
    debugPrint("📦 購買前 isPremiumUnlocked = $before");

    _purchaseCompleter = Completer<bool>();

    // 通知外部暫停廣告
    try {
      onIapBusyChanged?.call(true);
    } catch (_) {}

    try {
      await _iap.buyNonConsumable(purchaseParam: purchaseParam);
    } on PlatformException catch (e) {
      debugPrint(
        "❌ 呼叫 buyNonConsumable 發生 PlatformException: ${e.code} ${e.message}",
      );
      _purchaseCompleter?.complete(false);
      _purchaseCompleter = null;
      try {
        onIapBusyChanged?.call(false);
      } catch (_) {}
      return false;
    } catch (e) {
      debugPrint("❌ 呼叫 buyNonConsumable 發生未知錯誤: $e");
      _purchaseCompleter?.complete(false);
      _purchaseCompleter = null;
      try {
        onIapBusyChanged?.call(false);
      } catch (_) {}
      return false;
    }

    debugPrint("🛒 已呼叫 buyNonConsumable");

    try {
      return await _purchaseCompleter!.future.timeout(
        const Duration(seconds: 25),
        onTimeout: () {
          debugPrint("❌ 等待驗證超時");
          return false;
        },
      );
    } finally {
      try {
        onIapBusyChanged?.call(false);
      } catch (_) {}
      _purchaseCompleter = null;
    }
  }

  // 處理購買結果
  void _handlePurchaseUpdates(List<PurchaseDetails> purchases) {
    for (var purchase in purchases) {
      debugPrint(
        "🧾 交易更新：productID=${purchase.productID} status=${purchase.status} pendingComplete=${purchase.pendingCompletePurchase}",
      );
      if (purchase.status == PurchaseStatus.purchased) {
        debugPrint("✅ 交易成功（purchased），進行驗證...");
        _verifyPurchase(purchase);
      } else if (purchase.status == PurchaseStatus.restored) {
        final isUserInitiated = _restoreRequested || _purchaseCompleter != null;
        if (!isUserInitiated) {
          debugPrint('ℹ️ 啟動或背景自動回傳的 restored（未透過購買/還原觸發），忽略。');
        } else {
          debugPrint("🔄 收到 restored（使用者有按購買或還原），進行驗證...");
          _verifyPurchase(purchase);
        }
      } else if (purchase.status == PurchaseStatus.pending) {
        debugPrint("⏳ 交易等待中（pending）...");
      } else if (purchase.status == PurchaseStatus.canceled) {
        debugPrint("🚫 使用者取消購買");
        _purchaseCompleter?.complete(false);
        _purchaseCompleter = null;
      } else if (purchase.status == PurchaseStatus.error) {
        debugPrint("❌ 購買失敗: ${purchase.error}");
        final error = purchase.error;
        if (error != null) {
          debugPrint("🔍 SKError code: ${error.code}");
          debugPrint("📄 SKError message: ${error.message}");
        }
        _purchaseCompleter?.complete(false);
        _purchaseCompleter = null;
      }

      // **確保交易完成**
      if (purchase.pendingCompletePurchase) {
        print("🔹 完成交易: ${purchase.productID}");
        _iap.completePurchase(purchase);
      }
    }
  }

  Future<String?> _fetchAppReceiptBase64() async {
    try {
      final storeKit =
          _iap.getPlatformAddition<InAppPurchaseStoreKitPlatformAddition>();
      final verification = await storeKit.refreshPurchaseVerificationData();
      final data =
          verification?.serverVerificationData ?? ''; // base64 app receipt
      if (data.isNotEmpty) return data;
    } catch (e) {
      debugPrint('❌ 取得 App Receipt 失敗: $e');
    }
    return null;
  }

  // 透過 Apple 伺服器驗證購買
  Future<void> _verifyPurchase(PurchaseDetails purchase) async {
    const String appleUrl =
        "https://buy.itunes.apple.com/verifyReceipt"; // 正式環境
    const String sandboxUrl =
        "https://sandbox.itunes.apple.com/verifyReceipt"; // 測試環境

    // iOS 的 verifyReceipt 需要「App Receipt (base64)」，不是 StoreKit 2 的 JWS token。
    // 透過 StoreKit 取回 app receipt（必要時會自動 refresh）。
    final appReceipt = await _fetchAppReceiptBase64();
    if (appReceipt == null || appReceipt.isEmpty) {
      debugPrint('❌ 錯誤：無法取得 App Receipt（base64）');
      return;
    }

    final Map<String, dynamic> requestBody = {
      'receipt-data': appReceipt, // 直接送 base64，不要重新編碼
      //'password': '696ee25ee3514ff38c70a97a0e5133ca',
      'exclude-old-transactions': true,
    };

    try {
      final response = await http.post(
        Uri.parse(appleUrl),
        body: jsonEncode(requestBody),
        headers: {"Content-Type": "application/json"},
      );

      final data = jsonDecode(response.body);
      if (data['status'] == 0) {
        debugPrint('✅ 正式環境購買驗證成功！');
        await _savePurchase();
        return;
      } else if (data['status'] == 21007) {
        debugPrint('🔄 收據屬於 Sandbox，改用 Sandbox 伺服器驗證…');
        final sandboxResponse = await http.post(
          Uri.parse(sandboxUrl),
          body: jsonEncode(requestBody),
          headers: {'Content-Type': 'application/json'},
        );
        final sandboxData = jsonDecode(sandboxResponse.body);
        if (sandboxData['status'] == 0) {
          debugPrint('✅ Sandbox 環境購買驗證成功！');
          await _savePurchase();
          return;
        } else {
          debugPrint(
            '❌ Sandbox 驗證失敗: ${sandboxData['status']}\n${sandboxResponse.body}',
          );
        }
      } else {
        debugPrint('❌ 購買驗證失敗: ${data['status']}\n${response.body}');
      }
    } catch (e) {
      print("❌ 錯誤：購買驗證請求失敗: $e");
    }
    // 若走到這裡代表未成功驗證；避免外層等待過久
    _purchaseCompleter?.complete(false);
  }

  Future<bool> _verifyEntitlementByAppReceipt() async {
    // 直接檢查 App Receipt 裡是否包含本非消耗性商品（避免沒有 restored 事件時無法判定）
    final appReceipt = await _fetchAppReceiptBase64();
    if (appReceipt == null || appReceipt.isEmpty) {
      debugPrint('❌ 無法取得 App Receipt（base64）');
      return false;
    }

    const String appleUrl = "https://buy.itunes.apple.com/verifyReceipt"; // 正式
    const String sandboxUrl =
        "https://sandbox.itunes.apple.com/verifyReceipt"; // 測試

    final Map<String, dynamic> body = {
      'receipt-data': appReceipt,
      'password': 'f4fab465ff47436781eabee0c7efda7d',
      'exclude-old-transactions': true,
    };

    Map<String, dynamic>? data;
    try {
      final resp = await http.post(
        Uri.parse(appleUrl),
        body: jsonEncode(body),
        headers: {"Content-Type": "application/json"},
      );
      data = jsonDecode(resp.body) as Map<String, dynamic>;
      if ((data['status'] as int?) == 21007) {
        final resp2 = await http.post(
          Uri.parse(sandboxUrl),
          body: jsonEncode(body),
          headers: {"Content-Type": "application/json"},
        );
        data = jsonDecode(resp2.body) as Map<String, dynamic>;
      }
    } catch (e) {
      debugPrint('❌ 憑證直查失敗: $e');
      return false;
    }

    if (data == null || (data['status'] as int?) != 0) {
      debugPrint('ℹ️ 憑證直查回應非成功狀態: ${data?['status']}');
      return false;
    }

    bool _hasProduct(List<dynamic>? list) {
      if (list == null) return false;
      for (final item in list) {
        if (item is Map<String, dynamic>) {
          if (item['product_id'] == _productId) return true;
        }
      }
      return false;
    }

    final receipt = (data['receipt'] as Map<String, dynamic>?) ?? const {};
    final inApp = (receipt['in_app'] as List?)?.cast<dynamic>();
    final latest = (data['latest_receipt_info'] as List?)?.cast<dynamic>();

    final hasEntitlement = _hasProduct(inApp) || _hasProduct(latest);
    if (hasEntitlement) {
      debugPrint('✅ 憑證直查：找到已購買的非消耗性商品 $_productId');
      await _savePurchase(); // 會內部 complete(true)
      return true;
    }

    debugPrint('ℹ️ 憑證直查：未發現可還原的購買紀錄');
    return false;
  }

  // 存儲購買狀態
  Future<void> _savePurchase() async {
    _isPremiumUnlocked = true;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isPremiumUnlocked', true);

    _purchaseCompleter?.complete(true);
    onPurchaseUpdated?.call();
    debugPrint(
      "🎉 解鎖完成：isPremiumUnlocked=$_isPremiumUnlocked（已寫入 SharedPreferences）",
    );

    // 保險起見：若外層仍在等待，確保完成
    _purchaseCompleter ??= Completer<bool>();
    if (!_purchaseCompleter!.isCompleted) _purchaseCompleter!.complete(true);
  }

  // 檢查是否已購買
  Future<void> _checkPreviousPurchase() async {
    final prefs = await SharedPreferences.getInstance();
    _isPremiumUnlocked = prefs.getBool('isPremiumUnlocked') ?? false;
  }

  Future<bool> restore() async {
    debugPrint("IAP[${DateTime.now().toIso8601String()}] restore() pressed");

    // 標記這次還原為使用者觸發，讓 restored 事件被接受並進行驗證
    _restoreRequested = true;

    // 準備這次還原的等待器（若外部已有購買等待器則沿用）
    final completer = _purchaseCompleter ??= Completer<bool>();

    // 對外通知（例如暫停廣告顯示等）
    try {
      onIapBusyChanged?.call(true);
    } catch (_) {}

    try {
      // 觸發系統還原流程；購買串流若收到 restored→驗證成功會呼叫 _savePurchase() 進而 completer.complete(true)
      await _iap.restorePurchases();
      debugPrint("📦 已觸發還原購買流程（StoreKit 已回報結束）");

      // 若此刻尚未有任何 restored 事件完成驗證，改走憑證（App Receipt）直查以判定是否已擁有權益。
      if (!completer.isCompleted) {
        final hasEntitlement = await _verifyEntitlementByAppReceipt();
        if (!completer.isCompleted) {
          completer.complete(hasEntitlement);
        }
      }
    } catch (e) {
      debugPrint("❌ restorePurchases() 失敗: $e");
      if (!completer.isCompleted) {
        completer.complete(false);
      }
    } finally {
      try {
        onIapBusyChanged?.call(false);
      } catch (_) {}
      _restoreRequested = false;
    }

    // 統一在此等待最終結果
    final ok = await completer.future;
    _purchaseCompleter = null; // 釋放等待器（一次流程結束）
    debugPrint("🧾 還原結果：${ok ? '成功（有紀錄）' : '失敗（無紀錄）'}");
    return ok;
  }

  // 釋放監聽器
  Future<void> dispose() async {
    await _subscription.cancel();
  }

  Future<void> showPurchasePrompt(
    BuildContext context, {
    String? featureName,
  }) async {
    if (isPremiumUnlocked) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final theme = Theme.of(context);
    final description =
        featureName == null
            ? context.l10n('iap.prompt.description.generic')
            : context.l10n(
              'iap.prompt.description.feature',
              params: {'feature': featureName},
            );
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) {
        final busy = isIapActive;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  ctx.l10n('iap.prompt.title'),
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(description, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: busy ? null : () => Navigator.of(ctx).pop('buy'),
                  child: Text(ctx.l10n('iap.prompt.action.buy')),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed:
                      busy ? null : () => Navigator.of(ctx).pop('restore'),
                  child: Text(ctx.l10n('iap.prompt.action.restore')),
                ),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  style: TextButton.styleFrom(
                    foregroundColor:
                        theme.colorScheme.onSurfaceVariant.withOpacity(0.6),
                  ),
                  child: Text(ctx.l10n('iap.prompt.action.later')),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (action == 'buy') {
      final ok = await buyPremium(context);
      if (!messenger.mounted) return;
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 1),
          content: Text(
            ok
                ? context.l10n('iap.prompt.snack.buySuccess')
                : context.l10n('iap.prompt.snack.buyIncomplete'),
          ),
        ),
      );
    } else if (action == 'restore') {
      final ok = await restore();
      if (!messenger.mounted) return;
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 1),
          content: Text(
            ok
                ? context.l10n('iap.prompt.snack.restoreSuccess')
                : context.l10n('iap.prompt.snack.restoreFailed'),
          ),
        ),
      );
    }
  }

  Future<bool> ensurePremium({
    required BuildContext context,
    String? featureName,
  }) async {
    if (isPremiumUnlocked) return true;
    await showPurchasePrompt(context, featureName: featureName);
    return isPremiumUnlocked;
  }
}

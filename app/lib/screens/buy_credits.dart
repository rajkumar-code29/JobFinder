import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:in_app_purchase_platform_interface/in_app_purchase_platform_interface.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../widgets/common.dart';

/// Credit packs. The website and Android charge these prices through Stripe; the iPhone app sells the same packs
/// through Apple, at the App Store price points set in App Store Connect. Keep in sync with PACKS in
/// supabase/functions/_shared/payments.ts.
const creditPacks = [
  (id: 'pack_20', credits: 20, price: '£5', apple: 'com.rajkumargk.jobfinder.credits20'),
  (id: 'pack_50', credits: 50, price: '£10', apple: 'com.rajkumargk.jobfinder.credits50'),
  (id: 'pack_200', credits: 200, price: '£20', apple: 'com.rajkumargk.jobfinder.credits200'),
];

/// The iPhone app has to sell digital credits through Apple (App Store rule 3.1.1). Everywhere else uses Stripe.
bool get usesAppStore => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

/// App Store purchases. Listens for transactions from app start, because StoreKit hands back any unfinished ones
/// then; a transaction is only finished once the server has checked it with Apple and added the credits.
class ApplePurchases {
  ApplePurchases._();
  static final instance = ApplePurchases._();

  InAppPurchasePlatform? _iap;
  StreamSubscription<List<PurchaseDetails>>? _sub;

  /// A message for the Credits page (null when there's nothing to say).
  final status = ValueNotifier<String?>(null);
  final busy = ValueNotifier<bool>(false);

  void start() {
    if (!usesAppStore || _iap != null) return;
    try {
      InAppPurchaseStoreKitPlatform.registerPlatform();
      _iap = InAppPurchasePlatform.instance;
      _sub = _iap!.purchaseStream.listen(_onPurchases, onError: (Object e) => status.value = 'App Store error: $e');
    } catch (e) {
      status.value = 'The App Store isn\'t available: $e';
    }
  }

  Future<List<ProductDetails>> products() async {
    final iap = _iap;
    if (iap == null || !await iap.isAvailable()) return [];
    final res = await iap.queryProductDetails({for (final p in creditPacks) p.apple});
    final order = [for (final p in creditPacks) p.apple];
    return res.productDetails..sort((a, b) => order.indexOf(a.id).compareTo(order.indexOf(b.id)));
  }

  Future<void> buy(ProductDetails product) async {
    status.value = null;
    busy.value = true;
    try {
      // the account id goes to Apple as appAccountToken, so the purchase can only be redeemed by this account
      await _iap!.buyConsumable(purchaseParam: PurchaseParam(productDetails: product, applicationUserName: uid));
    } catch (e) {
      busy.value = false;
      status.value = 'Couldn\'t start the purchase: $e';
    }
  }

  Future<void> _onPurchases(List<PurchaseDetails> purchases) async {
    for (final p in purchases) {
      switch (p.status) {
        case PurchaseStatus.pending:
          busy.value = true;
          status.value = 'Waiting for the App Store…';
        case PurchaseStatus.canceled:
          busy.value = false;
          status.value = null;
          if (p.pendingCompletePurchase) await _iap!.completePurchase(p);
        case PurchaseStatus.error:
          busy.value = false;
          status.value = 'The purchase didn\'t go through. ${p.error?.message ?? ''}'.trim();
          if (p.pendingCompletePurchase) await _iap!.completePurchase(p);
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          await _redeem(p);
      }
    }
  }

  Future<void> _redeem(PurchaseDetails p) async {
    final id = p.purchaseID;
    if (id == null) return;
    try {
      final res = await Api.verifyApplePurchase(id, p.productID);
      status.value = res['granted'] == true ? 'Thanks! ${res['credits']} credits added.' : 'Those credits are already in your balance.';
      await _iap!.completePurchase(p);
    } on BuilderException catch (e) {
      status.value = e.message;
      // a purchase Apple doesn't recognise (or for another account) is finished; anything else is retried later
      if (e.code == 'rejected') await _iap!.completePurchase(p);
    } catch (e) {
      status.value = 'Paid, but we couldn\'t confirm it yet. It\'s checked again next time you open the app.';
    } finally {
      busy.value = false;
    }
  }

  Future<void> dispose() async => _sub?.cancel();
}

/// Buying credits: App Store on iPhone, Stripe Checkout on the website and Android.
class BuyCreditsSection extends StatefulWidget {
  const BuyCreditsSection({super.key, this.paid = false});

  /// Back from Stripe Checkout (/credits?paid=1).
  final bool paid;

  @override
  State<BuyCreditsSection> createState() => _BuyCreditsSectionState();
}

class _BuyCreditsSectionState extends State<BuyCreditsSection> {
  Future<List<ProductDetails>>? _products;
  String? _busyPack;

  @override
  void initState() {
    super.initState();
    if (usesAppStore) {
      ApplePurchases.instance.start();
      _products = ApplePurchases.instance.products();
    }
  }

  Future<void> _stripe(String pack) async {
    setState(() => _busyPack = pack);
    try {
      final url = await Api.startCheckout(pack);
      // same tab on the website so Stripe brings people straight back here
      await launchUrl(Uri.parse(url), webOnlyWindowName: kIsWeb ? '_self' : null, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (mounted) toast(context, '$e');
    } finally {
      if (mounted) setState(() => _busyPack = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(Icons.shopping_bag_outlined, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(child: Text('Buy credits', style: theme.textTheme.titleMedium)),
          ]),
          const SizedBox(height: 4),
          Text('One-off packs, no subscription. Credits don\'t expire.', style: theme.textTheme.bodySmall),
          if (widget.paid && !usesAppStore)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: Colors.green.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
                child: const Text('Thanks for your payment. Your credits arrive in a few seconds.'),
              ),
            ),
          const SizedBox(height: 12),
          if (usesAppStore) _appStore(theme) else _packs(theme),
        ]),
      ),
    );
  }

  Widget _packs(ThemeData theme) => Wrap(spacing: 10, runSpacing: 10, children: [
        for (final p in creditPacks)
          _PackTile(
            credits: p.credits,
            price: p.price,
            perCredit: '${(int.parse(p.price.substring(1)) * 100 / p.credits).toStringAsFixed(0)}p each',
            busy: _busyPack == p.id,
            onBuy: _busyPack == null ? () => _stripe(p.id) : null,
          ),
        Text('Payments are handled by Stripe. Pounce never sees your card details.', style: theme.textTheme.labelSmall),
      ]);

  Widget _appStore(ThemeData theme) => FutureBuilder<List<ProductDetails>>(
        future: _products,
        builder: (context, snap) {
          if (!snap.hasData) {
            return snap.hasError ? Text('The App Store isn\'t available right now.') : const LinearProgressIndicator();
          }
          final products = snap.data!;
          if (products.isEmpty) return const Text('Credit packs aren\'t available in the App Store right now.');
          return ValueListenableBuilder<bool>(
            valueListenable: ApplePurchases.instance.busy,
            builder: (context, busy, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Wrap(spacing: 10, runSpacing: 10, children: [
                for (final p in products)
                  _PackTile(
                    credits: creditPacks.firstWhere((c) => c.apple == p.id).credits,
                    price: p.price,
                    busy: false,
                    onBuy: busy ? null : () => ApplePurchases.instance.buy(p),
                  ),
              ]),
              ValueListenableBuilder<String?>(
                valueListenable: ApplePurchases.instance.status,
                builder: (context, message, _) => message == null
                    ? const SizedBox.shrink()
                    : Padding(padding: const EdgeInsets.only(top: 10), child: Text(message)),
              ),
            ]),
          );
        },
      );
}

class _PackTile extends StatelessWidget {
  const _PackTile({required this.credits, required this.price, required this.busy, this.onBuy, this.perCredit});
  final int credits;
  final String price;
  final String? perCredit;
  final bool busy;
  final VoidCallback? onBuy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 168,
      child: Card(
        color: theme.colorScheme.surfaceContainerHigh,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('$credits', style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
            Text('credits', style: theme.textTheme.bodyMedium),
            if (perCredit != null) Text(perCredit!, style: theme.textTheme.labelSmall),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: onBuy,
                child: busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(price),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

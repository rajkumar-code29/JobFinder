import 'package:flutter/material.dart';

/// Credit packs. Prices are what people pay on the website and Android; the iPhone app sells the same packs through
/// Apple at Apple's nearest price points.
const creditPacks = [
  (id: 'pack_20', credits: 20, price: '£5'),
  (id: 'pack_50', credits: 50, price: '£10'),
  (id: 'pack_200', credits: 200, price: '£20'),
];

/// Buying credits. Purchases are switched on in a later release; until then this lists the packs.
class BuyCreditsSection extends StatelessWidget {
  const BuyCreditsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Buy credits', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('Coming soon. Until then, invite friends for 30 credits each.', style: theme.textTheme.bodySmall),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final p in creditPacks)
              Chip(label: Text('${p.credits} credits · ${p.price}')),
          ]),
        ]),
      ),
    );
  }
}

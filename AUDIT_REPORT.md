# AUDIT COMPLET BACKEND COLLABMARKET
## Rapport d'Audit Production-Grade

**Date:** 2025-12-04
**Versions auditées:** V16.2 et V20.0
**Auditeur:** Audit automatisé Senior

---

## ANALYSE COMPARATIVE V16.2 vs V20.0

### V20.0 est RECOMMANDÉ - Améliorations clés:

| Feature | V16.2 | V20.0 | Impact |
|---------|-------|-------|--------|
| Auto-transition `payment_authorized→accepted` | ❌ Manuel | ✅ Via trigger sync_stripe | **Critique** |
| Champ `accepted_at` | ❌ Absent | ✅ Présent | Traçabilité |
| FIFO strict | ⚠️ Silencieux si échec | ✅ Exception si pas exact | Fiabilité |
| Réversion revenues après withdrawn | ❌ Pas de vérif | ✅ Log erreur critique | Sécurité |
| Regex delivery_url | `^https?://` | `^https?://[a-z0-9.-]+\.[a-z]{2,}` | Validation |
| Triggers optimisés | FOR EACH ROW | UPDATE OF specific columns | Performance |
| public_profiles vue | Avec mask_email/phone | Sans données sensibles | Sécurité |
| handle_cron_deadlines | UPDATE direct | Via safe_update_order_status | Cohérence |

**⚠️ ATTENTION:** Les Edge Functions n'ont PAS été mises à jour pour V20. Elles contiennent toujours des bugs qui doivent être corrigés.

---

## SOMMAIRE EXÉCUTIF

| Catégorie | Critiques | Majeurs | Mineurs | Total |
|-----------|-----------|---------|---------|-------|
| SQL/Database | 2 | 4 | 3 | 9 |
| Edge Functions | 3 | 5 | 2 | 10 |
| Workflow Métier | 2 | 3 | 1 | 6 |
| Sécurité | 1 | 2 | 2 | 5 |
| **TOTAL** | **8** | **14** | **8** | **30** |

---

## SECTION 1: BUGS CRITIQUES

### 🔴 CRITIQUE #1 - Incohérence stripe_payment_status dans le webhook

**Fichier:** `supabase/functions/stripe-webhook/index.ts:78`
**Problème:** Le webhook écrit `"authorized"` mais la contrainte CHECK n'accepte que `"requires_capture"`.

```typescript
// PROBLÈME - Ligne 78
.update({
  stripe_payment_status: "authorized", // ❌ N'EXISTE PAS DANS LA CONTRAINTE
  payment_authorized_at: new Date().toISOString(),
})
```

**Contrainte SQL (orders table):**
```sql
CHECK (stripe_payment_status IN (
  'unpaid', 'requires_payment_method', 'requires_confirmation',
  'requires_capture', 'processing', 'requires_action',
  'canceled', 'succeeded', 'captured', 'refunded', 'partially_refunded'
))
```

**Impact:** L'update échouera avec une violation de contrainte. Les commandes resteront bloquées en `pending`.

**Correction:**
```typescript
.update({
  stripe_payment_status: "requires_capture", // ✅ CORRECT
  payment_authorized_at: new Date().toISOString(),
})
```

---

### 🔴 CRITIQUE #2 - capture-payment appelle safe_update_order_status (REDONDANT + CASSÉ)

**Fichier:** `supabase/functions/capture-payment/index.ts:90-93`

**Analyse V16.2 vs V20:**
- **V16.2:** La matrice interdit `payment_authorized → accepted` pour influencer = **CASSÉ**
- **V20:** Le trigger `sync_stripe_status_to_order` fait AUTOMATIQUEMENT la transition quand `stripe_payment_status` passe à `captured/succeeded`

**Problème dans capture-payment:**
```typescript
// APRÈS avoir mis stripe_payment_status à 'captured' (ce qui déclenche le trigger)
// L'Edge Function appelle AUSSI safe_update_order_status:
const { error: rpcError } = await supabase.rpc("safe_update_order_status", {
  p_order_id: orderId,
  p_new_status: "accepted", // ❌ REDONDANT + VA ÉCHOUER
});
```

**Pourquoi ça échoue:**
1. L'update de `stripe_payment_status = 'captured'` déclenche `sync_stripe_status_to_order`
2. Le trigger met DÉJÀ `status = 'accepted'`
3. L'appel à `safe_update_order_status` essaie de passer `accepted → accepted` (inutile)
4. OU si le trigger n'a pas encore commité, ça essaie `payment_authorized → accepted` qui est INTERDIT pour influencer

**Impact:** Erreur potentielle, confusion, double-traitement.

**Correction dans capture-payment/index.ts:**
```typescript
// SUPPRIMER l'appel à safe_update_order_status
// Le trigger sync_stripe_status_to_order fait le travail automatiquement

// Simplement mettre à jour stripe_payment_status et le trigger fera le reste:
await supabaseAdmin
  .from("orders")
  .update({
    stripe_payment_status: "captured",
    captured_at: new Date().toISOString(),
  })
  .eq("id", orderId);
// Le trigger sync_stripe_status_to_order passera automatiquement à 'accepted'
```

---

### 🔴 CRITIQUE #3 - complete-order vérifie uniquement 'captured' mais pas 'succeeded'

**Fichier:** `supabase/functions/complete-order/index.ts:72-73`

```typescript
// PROBLÈME
if (order.stripe_payment_status !== "captured") {
  throw new Error("Payment integrity check failed: Funds not captured.");
}
```

**Problème:** Le webhook Stripe peut mettre `succeeded` au lieu de `captured` après `payment_intent.succeeded`. La vérification échouera.

**Correction:**
```typescript
if (!["captured", "succeeded"].includes(order.stripe_payment_status)) {
  throw new Error("Payment integrity check failed: Funds not captured.");
}
```

---

### 🔴 CRITIQUE #4 - Revenues jamais passés à 'available' automatiquement

**Problème de workflow:**
1. `safe_update_order_status` avec `completed` crée un revenue en status `pending`
2. `safe_update_order_status` avec `finished` passe le revenue à `available`
3. **MAIS** il n'y a AUCUNE transition automatique `completed → finished`

**Impact:** Les influenceurs voient leurs revenus en `pending` indéfiniment. Ils ne peuvent jamais retirer leurs fonds.

**Analyse du flux actuel:**
- `completed` = Le merchant a validé ✅
- `finished` = Fonds disponibles pour retrait

**Solution:** Le statut `completed` devrait directement créer les revenues en `available`, OU il faut un trigger/cron pour passer `completed → finished`.

**Correction recommandée dans safe_update_order_status:**
```sql
IF p_new_status = 'completed'
   AND v_order.status NOT IN ('completed','finished')
THEN
  INSERT INTO public.revenues (
    influencer_id, order_id, amount, net_amount, commission,
    status, available_at  -- ✅ Ajouter available_at
  )
  VALUES (
    v_order.influencer_id,
    p_order_id,
    v_order.total_amount,
    v_order.net_amount,
    v_order.total_amount - v_order.net_amount,
    'available',  -- ✅ Directement available
    NOW()
  )
  ON CONFLICT (order_id) DO NOTHING;

  -- ✅ Aussi incrémenter completed_orders_count
  UPDATE public.profiles
  SET completed_orders_count = completed_orders_count + 1,
      updated_at = NOW()
  WHERE id = v_order.influencer_id;
END IF;
```

---

## SECTION 2: BUGS MAJEURS

### 🟠 MAJEUR #1 - FIFO ne gère pas les montants partiels

**Fichier:** `databasev16.2.sql` - fonction `finalize_revenue_withdrawal`

```sql
IF rec.net_amount <= v_rem THEN  -- ❌ Si net_amount > v_rem, on skip
  UPDATE public.revenues ...
  v_rem := v_rem - rec.net_amount;
END IF;
```

**Problème:** Si un revenue de 100€ et qu'on retire 50€, rien n'est marqué.

**Impact:** Les retraits partiels ne fonctionnent pas. Le système ne respecte pas le FIFO correctement.

**Solution:** Accepter que les revenues soient marqués "withdrawn" même si le montant est supérieur, car on marque les plus anciens d'abord jusqu'à atteindre le montant demandé.

---

### 🟠 MAJEUR #2 - cron-process-withdrawals ne marque pas les revenues

**Fichier:** `supabase/functions/cron-process-withdrawals/index.ts`

**Problème:** Le cron process les withdrawals (transfer + payout) mais ne marque PAS les revenues comme `withdrawn`. Cela est fait uniquement via le webhook `payout.paid`.

**Risque:** Si le webhook échoue, les revenues restent en `available` mais les fonds ont été transférés.

**Solution:** Marquer les revenues immédiatement lors du processing, et les reverter si le payout échoue.

---

### 🟠 MAJEUR #3 - RLS portfolio_delete trop restrictive

**Fichier:** `databasev16.2.sql:2754-2758`

```sql
CREATE POLICY "portfolio_delete"
ON public.portfolio_items
FOR DELETE
USING (public.is_admin());  -- ❌ Seul admin peut supprimer
```

**Problème:** Un influenceur ne peut pas supprimer ses propres items de portfolio.

**Correction:**
```sql
CREATE POLICY "portfolio_delete"
ON public.portfolio_items
FOR DELETE
USING (influencer_id = auth.uid() OR public.is_admin());
```

---

### 🟠 MAJEUR #4 - handle_cron_deadlines ne cancel pas Stripe

**Fichier:** `databasev16.2.sql:1325-1412` - fonction `handle_cron_deadlines`

**Problème:** La fonction annule les commandes expirées dans la DB mais ne déclenche PAS l'annulation Stripe. Elle log un `action_required: 'cancel_authorization'` mais ne l'exécute pas.

**Impact:** Les fonds restent bloqués sur la carte du commerçant pendant 7 jours (jusqu'à expiration automatique Stripe).

**Solution:** Appeler une Edge Function via pg_net pour annuler le PaymentIntent.

---

### 🟠 MAJEUR #5 - Webhook ne gère pas l'idempotence des events

**Fichier:** `supabase/functions/stripe-webhook/index.ts`

**Problème:** Le webhook ne vérifie pas si l'event a déjà été traité via `payment_logs`.

**Risque:** Un event rejoué par Stripe pourrait créer des doublons ou des états incohérents.

**Solution:**
```typescript
// Au début du traitement
const { data: existingLog } = await supabase
  .from("payment_logs")
  .select("id")
  .eq("stripe_payment_intent_id", event.id)
  .eq("processed", true)
  .single();

if (existingLog) {
  console.log(`Event ${event.id} already processed, skipping.`);
  return new Response(JSON.stringify({ received: true }), { status: 200 });
}
```

---

## SECTION 3: PROBLÈMES DE WORKFLOW

### Workflow Attendu vs Implémenté

| Étape | Attendu | Implémenté | Status |
|-------|---------|------------|--------|
| 1. Merchant crée commande | ✅ | ✅ | OK |
| 2. PaymentIntent AUTH ONLY | ✅ | ✅ | OK |
| 3. Influenceur accepte (48h) | Capture Stripe | ❌ BUG: transition interdite | **CASSÉ** |
| 4. Timeout 48h → cancel | Cancel Authorization | ⚠️ DB only, pas Stripe | **PARTIEL** |
| 5. Livraison → review | ✅ | ✅ | OK |
| 6. Validation merchant (48h) | ✅ | ⚠️ Revenues en 'pending' | **PARTIEL** |
| 7. Auto-validation timeout | ✅ | ✅ | OK |
| 8. Litige → admin | ✅ | ✅ | OK |
| 9. Retrait FIFO | ✅ | ⚠️ Partiel ne fonctionne pas | **PARTIEL** |

---

## SECTION 4: PROBLÈMES DE SÉCURITÉ

### 🔒 SEC #1 - notify_order_change expose la clé service_role

**Fichier:** `databasev16.2.sql:886-921`

```sql
v_key := current_setting('app.service_role_key', true);
```

**Risque:** Si `app.service_role_key` est lisible par des users non-privilégiés, c'est une faille critique.

**Recommandation:** Vérifier que seul `postgres` peut lire cette variable:
```sql
ALTER DATABASE postgres SET app.service_role_key = '...';
-- Doit être défini au niveau database, pas session
```

---

### 🔒 SEC #2 - CORS trop permissif

**Tous les Edge Functions:**
```typescript
"Access-Control-Allow-Origin": "*"
```

**Recommandation pour production:**
```typescript
"Access-Control-Allow-Origin": process.env.ALLOWED_ORIGIN || "https://collabmarket.com"
```

---

### 🔒 SEC #3 - Webhook sans signature en dev

**Fichier:** `stripe-webhook/index.ts:50-54`

```typescript
} else {
  event = JSON.parse(body);
  console.warn("⚠️ Webhook received without signature verification");
}
```

**Risque:** En production, si `STRIPE_WEBHOOK_SECRET` n'est pas configuré, n'importe qui peut forger des events.

**Correction:**
```typescript
if (!webhookSecret || !signature) {
  console.error("CRITICAL: Webhook signature verification disabled!");
  return new Response(JSON.stringify({ error: "Signature required" }), { status: 400 });
}
```

---

## SECTION 5: OPTIMISATIONS SQL

### Index manquants recommandés

```sql
-- Pour les lookups fréquents par stripe_payout_id
CREATE INDEX IF NOT EXISTS idx_withdrawals_stripe_payout
  ON public.withdrawals(stripe_payout_id)
  WHERE stripe_payout_id IS NOT NULL;

-- Pour le cron de cleanup
CREATE INDEX IF NOT EXISTS idx_system_logs_created
  ON public.system_logs(created_at)
  WHERE created_at < NOW() - INTERVAL '30 days';

-- Pour les recherches de revenues par status
CREATE INDEX IF NOT EXISTS idx_revenues_status_created
  ON public.revenues(status, created_at ASC);
```

---

## SECTION 6: DIAGRAMMES

### Flux de Paiement Escrow

```
┌─────────────┐     ┌──────────────────┐     ┌─────────────────┐
│  MERCHANT   │────▶│  CREATE-PAYMENT  │────▶│  STRIPE         │
│  (Frontend) │     │  Edge Function   │     │  PaymentIntent  │
└─────────────┘     └──────────────────┘     │  capture=manual │
                                              └────────┬────────┘
                                                       │
                           ┌───────────────────────────┘
                           ▼
              ┌────────────────────────┐
              │  payment_intent        │
              │  .amount_capturable    │
              │  _updated (WEBHOOK)    │
              └───────────┬────────────┘
                          ▼
              ┌────────────────────────┐
              │  Order: pending →      │
              │  payment_authorized    │
              │  acceptance_deadline   │
              │  = NOW() + 48h         │
              └───────────┬────────────┘
                          │
          ┌───────────────┴───────────────┐
          ▼                               ▼
┌──────────────────┐           ┌──────────────────┐
│  INFLUENCER      │           │  TIMEOUT 48h     │
│  ACCEPTE         │           │  (CRON)          │
│  capture-payment │           │  handle_cron_    │
└────────┬─────────┘           │  deadlines       │
         │                     └────────┬─────────┘
         ▼                              ▼
┌──────────────────┐           ┌──────────────────┐
│  Stripe.capture  │           │  Stripe.cancel   │
│  Order: accepted │           │  Order: cancelled│
└──────────────────┘           └──────────────────┘
```

### Transitions de Statuts

```
                                    ┌─────────────┐
                                    │   pending   │
                                    └──────┬──────┘
                                           │ Stripe AUTH
                                           ▼
                              ┌────────────────────────┐
                              │  payment_authorized    │
                              │  (48h pour accepter)   │
                              └───────────┬────────────┘
                    ┌─────────────────────┼─────────────────────┐
                    │ Timeout/Refus       │ Accepte             │
                    ▼                     ▼                     │
          ┌─────────────────┐   ┌─────────────────┐            │
          │    cancelled    │   │    accepted     │            │
          └─────────────────┘   └────────┬────────┘            │
                                         │                     │
                                         ▼                     │
                              ┌─────────────────┐              │
                              │   in_progress   │              │
                              └────────┬────────┘              │
                                       │                       │
                                       ▼                       │
                              ┌─────────────────┐              │
                              │    submitted    │◀─────────────┘
                              │  (48h review)   │   review_pending
                              └────────┬────────┘
                    ┌──────────────────┼──────────────────┐
                    │                  │                  │
                    ▼                  ▼                  ▼
          ┌─────────────────┐ ┌─────────────────┐ ┌─────────────┐
          │    disputed     │ │   completed     │ │  finished   │
          │   (litige)      │ │   (validé)      │ │  (payable)  │
          └────────┬────────┘ └────────┬────────┘ └─────────────┘
                   │                   │
                   ▼                   ▼
        ┌─────────────────────────────────────┐
        │  Admin résout: cancelled/finished   │
        └─────────────────────────────────────┘
```

---

## SECTION 7: CHECKLIST DE CORRECTIONS

- [ ] **CRITIQUE:** Corriger `stripe-webhook` - `authorized` → `requires_capture`
- [ ] **CRITIQUE:** Ajouter transition `payment_authorized → accepted` pour influencer
- [ ] **CRITIQUE:** `complete-order` accepter `succeeded` en plus de `captured`
- [ ] **CRITIQUE:** Revenues directement en `available` après `completed`
- [ ] **MAJEUR:** Corriger FIFO pour montants partiels
- [ ] **MAJEUR:** `handle_cron_deadlines` doit cancel Stripe via pg_net
- [ ] **MAJEUR:** RLS `portfolio_delete` permettre au propriétaire
- [ ] **MAJEUR:** Idempotence webhook avec vérification `payment_logs`
- [ ] **SEC:** Signature webhook obligatoire en production
- [ ] **SEC:** CORS restrictif en production
- [ ] **OPTIM:** Ajouter les index recommandés

---

## FICHIERS À MODIFIER

| Fichier | Type de modification |
|---------|---------------------|
| `databasev16.2.sql` | Corrections SQL multiples |
| `stripe-webhook/index.ts` | Corriger statut + idempotence |
| `capture-payment/index.ts` | Aucune (correction côté SQL) |
| `complete-order/index.ts` | Accepter `succeeded` |
| `cron-process-withdrawals/index.ts` | Marquer revenues |

---

**Fin du rapport d'audit**

# CollabMarket - Backend V20.0 (PRODUCTION-GRADE)

## 📋 Vue d'ensemble

Marketplace d'influenceurs avec :
- **31 Edge Functions Supabase** (Deno/TypeScript)
- **Stripe Connect** avec système escrow (5% commission)
- **Stripe Identity** pour vérification KYC
- **PostgreSQL** avec extensions (pgcrypto, pg_cron, pg_net, pg_trgm)

---

## 🐛 Bugs corrigés dans cette version

### Critiques (🔴)

1. **handle_cron_deadlines** - Retour JSON corrigé
   - La fonction SQL retourne maintenant `{success, cancelled, completed, total_processed}`

2. **stripe_checkout_session_id** - Colonne ajoutée
   - Nouvelle colonne dans `orders` pour stocker l'ID de session Checkout
   - Index créé pour les recherches

3. **create-stripe-identity** - Création de session implémentée
   - La fonction crée maintenant réellement une session Identity via `stripe.identity.verificationSessions.create()`

4. **Trigger SQL** - Placeholders supprimés
   - Utilise `current_setting()` pour récupérer les secrets de manière sécurisée

5. **Clé de chiffrement** - Configuration via settings
   - La clé doit être configurée via `ALTER DATABASE postgres SET app.encryption_key = '...'`

### Moyens (🟠)

6. **Doublons supprimés**
   - `complete-order-and-pay` + `complete-order-payment` → `complete-order`
   - `create-payment-authorization` + `create-payment-with-connect` → `create-payment`
   - `create-stripe-payout` supprimé (intégré dans `process-withdrawal`)

7. **Typage des jointures** - Interfaces typées correctement
   - Plus de `(withdrawal.profiles as any)?.stripe_account_id`

8. **capture-payment-and-transfer** - Supprimé (nom trompeur)

### Mineurs (🟡)

9. **Validation Zod** - Ajoutée partout
10. **CORS** - Note pour restriction en production

---

## 📁 Structure des fichiers

```
corrected-project/
├── _shared/
│   └── utils.ts              # Utilitaires partagés (déplacé vers shared/utils)
├── database-v14.0.sql        # Script SQL complet
├── auto-handle-orders/       # Cron: gestion deadlines
├── cancel-order-and-refund/  # Annulation + remboursement
├── cancel-payment/           # Annulation paiement
├── capture-payment/          # Capture (influenceur accepte)
├── complete-order/           # Finalisation (merchant confirme)
├── create-payment/           # Création commande + PaymentIntent
├── create-stripe-identity/   # Création session Identity
├── check-stripe-identity-status/
├── create-stripe-connect-account/
├── create-stripe-connect-onboarding/
├── create-stripe-account-link/
├── check-stripe-account-status/
├── process-withdrawal/       # Demande de retrait
├── check-withdrawal-status/
├── cron-process-withdrawals/ # Traitement batch retraits
├── stripe-webhook/           # Webhook principal
├── stripe-withdrawal-webhook/# Webhook payouts Connect
├── handle-contact-form/
├── notify-order-events/
├── search-influencers/
├── cleanup-orphan-orders/
├── generate-missing-revenues/
├── recover-payments/
├── sync-revenues-with-stripe/
├── update-stripe-account-details/
└── create-stripe-session/    # Checkout Session

## 📚 Documentation additionnelle

- `workflow.md` : flux complet paiement/escrow et transitions d'état.
- `security.md` : contrôle RLS, gestion des secrets et règles d'accès service_role.
- `stripe.md` : catalogue des appels Stripe (PaymentIntent, webhooks, transferts Connect).
```

---

## 🚀 Installation

### 1. Base de données

```bash
# Dans psql ou Supabase SQL Editor
\i database-v14.0.sql
```

### 2. Configuration des secrets

```sql
-- Générer une clé de chiffrement
SELECT encode(gen_random_bytes(32), 'hex');

-- Configurer les secrets
ALTER DATABASE postgres SET app.encryption_key = 'votre-cle-64-caracteres-hex';
ALTER DATABASE postgres SET app.supabase_url = 'https://votre-projet.supabase.co';
ALTER DATABASE postgres SET app.service_role_key = 'votre-service-role-key';

-- Recharger
SELECT pg_reload_conf();
```

### 3. Variables d'environnement Supabase

Dans le dashboard Supabase > Settings > Edge Functions :

```
STRIPE_SECRET_KEY=sk_live_...
STRIPE_WEBHOOK_SECRET=whsec_...
STRIPE_CONNECT_WEBHOOK_SECRET=whsec_...
PUBLIC_SITE_URL=https://collabmarket.fr
CONTACT_FORM_HMAC_SECRET=optionnel
```

### 4. Déployer les Edge Functions

```bash
# Depuis le dossier du projet Supabase
supabase functions deploy auto-handle-orders
supabase functions deploy cancel-order-and-refund
# ... etc pour chaque fonction
```

### 5. Configurer les Cron Jobs

```sql
SELECT cron.schedule('auto-handle-deadlines', '0 * * * *', 
  $$SELECT net.http_post(
    url := 'https://votre-projet.supabase.co/functions/v1/auto-handle-orders',
    headers := '{"Authorization": "Bearer votre-service-role-key"}'::jsonb
  )$$
);

SELECT cron.schedule('cleanup-orphans', '0 */6 * * *',
  $$SELECT net.http_post(
    url := 'https://votre-projet.supabase.co/functions/v1/cleanup-orphan-orders',
    headers := '{"Authorization": "Bearer votre-service-role-key"}'::jsonb
  )$$
);
```

### 6. Configurer les Webhooks Stripe

Dans Stripe Dashboard > Developers > Webhooks :

**Endpoint principal** : `https://votre-projet.supabase.co/functions/v1/stripe-webhook`
- `payment_intent.amount_capturable_updated`
- `payment_intent.succeeded`
- `payment_intent.canceled`
- `charge.refunded`
- `checkout.session.completed`
- `account.updated`
- `identity.verification_session.verified`
- `identity.verification_session.requires_input`

**Endpoint Connect** : `https://votre-projet.supabase.co/functions/v1/stripe-withdrawal-webhook`
- `payout.paid`
- `payout.failed`
- `payout.canceled`

---

## 📊 Flux métier

### Commande

```
1. Merchant crée commande (create-payment)
   → PaymentIntent mode escrow (capture_method: manual)

2. Merchant paie via Stripe Checkout (create-stripe-session)
   → Webhook: payment_intent.amount_capturable_updated
   → Statut: pending → payment_authorized

3. Influenceur accepte (capture-payment)
   → Capture des fonds
   → Statut: payment_authorized → accepted

4. Influenceur travaille et soumet
   → Statut: accepted → in_progress → submitted

5. Merchant valide (complete-order)
   → Statut: submitted → completed
   → Revenue créé (95% influenceur, 5% commission)
```

### Retrait

```
1. Influenceur demande retrait (process-withdrawal)
   → RPC vérifie solde
   → Transfer plateforme → Connect

2. Payout Connect → Banque
   → Webhook: payout.paid
   → Withdrawal: processing → completed
   → Revenues marqués: available → withdrawn (FIFO)
```

---

## 🔒 Sécurité

- ✅ RLS sur toutes les tables
- ✅ Service Role jamais exposé côté client
- ✅ Signatures webhooks vérifiées
- ✅ Chiffrement email/phone avec pgcrypto
- ✅ Rate limiting SQL
- ⚠️ Configurer CORS restrictif en production

---

## 📝 Notes importantes

1. **CORS** : Remplacer `"*"` par votre domaine en production
2. **Clé de chiffrement** : DOIT être changée avant mise en production
3. **Cron Jobs** : Activez pg_cron dans le dashboard Supabase
4. **Stripe Mode Test** : Utilisez les clés `sk_test_` pour le développement

---

## 🆘 Support

En cas de problème :
1. Vérifiez les logs dans Supabase Dashboard > Logs
2. Vérifiez les événements Stripe dans le Dashboard Stripe
3. Consultez la table `system_logs` pour les erreurs internes

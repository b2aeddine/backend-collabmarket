# INTÉGRATION STRIPE CONNECT

## 1. Configuration
- **Mode** : Express Accounts (Stripe gère l'onboarding et le KYC).
- **Pays** : France (FR) / Euro (EUR).
- **Capabilities** : `card_payments`, `transfers`.

## 2. Flux d'Appels API

### Création de Compte (`create-stripe-connect-account`)
- `stripe.accounts.create({ type: 'express' })`
- Stockage de `stripe_account_id` dans `profiles`.

### Onboarding (`create-stripe-connect-onboarding`)
- `stripe.accountLinks.create()`
- Redirection vers l'interface hébergée Stripe.

### Paiement (`create-payment`)
- `stripe.paymentIntents.create()`
  - `amount`: Total commande.
  - `capture_method: 'manual'` (Essentiel pour l'Escrow).
  - `transfer_group`: ID de la commande (pour réconciliation).

### Capture (`capture-payment`)
- `stripe.paymentIntents.capture(pi_id)`
- Déclenché uniquement quand l'influenceur accepte.

### Retrait (`cron-process-withdrawals`)
- `stripe.transfers.create()` : Plateforme -> Compte Connect.
- `stripe.payouts.create()` : Compte Connect -> Compte Bancaire.

## 3. Webhooks (`stripe-webhook` & `stripe-withdrawal-webhook`)

### Événements écoutés :
- `payment_intent.amount_capturable_updated` : Paiement autorisé.
- `payment_intent.succeeded` : Paiement capturé.
- `payment_intent.canceled` : Paiement annulé.
- `payout.paid` : Virement effectué (Confirmation retrait).
- `payout.failed` : Virement échoué.
- `account.updated` : Mise à jour KYC influenceur.

## 4. Gestion des Erreurs
- **Remboursement** : Si annulation après capture -> `stripe.refunds.create()`.
- **Annulation** : Si annulation avant capture -> `stripe.paymentIntents.cancel()`.
- **Échec Virement** : Le webhook `payout.failed` déclenche la réversion des revenus (crédit du solde influenceur).

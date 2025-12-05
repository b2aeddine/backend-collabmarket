# Stripe Connect & Escrow (V20)

## PaymentIntent (auth only)
- Créé via `create-payment` avec `capture_method="manual"`, `transfer_group=order.id`, et métadonnées utilisateur. 【F:supabase/functions/create-payment/index.ts†L134-L151】
- La commande est liée à l'Intent (`stripe_payment_intent_id`) après création pour synchroniser les webhooks. 【F:supabase/functions/create-payment/index.ts†L153-L158】

## Authorization → Capture
- Webhook `payment_intent.amount_capturable_updated` enregistre l'autorisation et passe `stripe_payment_status` à `requires_capture`. 【F:supabase/functions/stripe-webhook/index.ts†L117-L137】
- L'influenceur déclenche `capture-payment` (client service_role) qui met `stripe_payment_status=captured`; le trigger DB bascule `status=accepted`. 【F:supabase/functions/capture-payment/index.ts†L92-L125】

## Confirmation marchand & revenus
- `complete-order` refuse la finalisation si le statut Stripe n'est pas `captured` ou `succeeded`. 【F:supabase/functions/complete-order/index.ts†L68-L77】
- `safe_update_order_status` sur `completed` crée un revenue `available` immédiatement (commission calculée côté `orders.net_amount`). 【F:marketplace_v20_full.sql†L1145-L1167】

## Annulation & litige
- `safe_update_order_status` loggue un incident si un revenue déjà `withdrawn` doit être annulé, évitant les réversions silencieuses. 【F:marketplace_v20_full.sql†L1180-L1199】
- Les webhooks Stripe sont validés par signature et journalisés pour éviter les duplications. 【F:supabase/functions/stripe-webhook/index.ts†L62-L113】

## Withdrawals (Connect)
- Revenus passés à `available` peuvent être retirés via `process-withdrawal` (payout Connect) et suivis par `cron-process-withdrawals`/`stripe-withdrawal-webhook` (voir dossier `supabase/functions`).

# Sécurité & RLS (V20)

## Secrets & configuration
- `get_encryption_key()` exige `app.encryption_key` >= 32 chars et retire l'exécution publique. 【F:marketplace_v20_full.sql†L28-L45】
- `is_service_role()` détecte l'usage service_role via `request.jwt.claims` ou postgres. 【F:marketplace_v20_full.sql†L56-L70】
- Variables Stripe/Supabase requises côté Edge Functions (voir `shared/utils/index.ts`). 【F:shared/utils/index.ts†L20-L46】

## Chiffrement données sensibles
- `profiles` stocke email/phone en colonnes `*_encrypted` et impose contraintes de longueur. 【F:marketplace_v20_full.sql†L76-L109】

## RLS & accès
- RLS activé sur tables sensibles (`profiles`, `payment_logs`, `contact_messages`, etc.). 【F:marketplace_v20_full.sql†L2340-L2345】
- Profils: sélection/MAJ limitée au propriétaire ou admin; insert restreint à `auth.uid()`. 【F:marketplace_v20_full.sql†L2348-L2365】
- `payment_logs` : accès complet réservé aux admins. 【F:marketplace_v20_full.sql†L2367-L2372】
- `contact_messages` : insert ouvert, lecture seulement admin. 【F:marketplace_v20_full.sql†L2374-L2385】
- `categories` : lecture publique uniquement si `is_active`; admin full access. 【F:marketplace_v20_full.sql†L2387-L2395】

## Usage contrôlé du service_role
- `capture-payment` utilise un client service_role uniquement pour pousser `stripe_payment_status=captured` avant que le trigger ne passe la commande en `accepted`. 【F:supabase/functions/capture-payment/index.ts†L92-L125】
- `create-payment` mixe client utilisateur (RLS) et admin (service_role) pour les logs sans exposer la clé dans les réponses HTTP. 【F:supabase/functions/create-payment/index.ts†L120-L179】
- Webhook Stripe validé par signature et journalisé avant traitement pour éviter la double-exécution. 【F:supabase/functions/stripe-webhook/index.ts†L62-L137】

## Intégrité financière
- `safe_update_order_status` applique rate limit, vérifie rôle (merchant/influencer/admin) puis transitions autorisées via `validate_order_status_transition`. 【F:marketplace_v20_full.sql†L1070-L1117】
- Passage `completed` crée un revenue immédiatement `available` et met à jour les stats influenceur. 【F:marketplace_v20_full.sql†L1145-L1167】
- Annulation/litige post-completion supprime les revenues non retirés ou loggue un incident critique si déjà `withdrawn`. 【F:marketplace_v20_full.sql†L1180-L1199】

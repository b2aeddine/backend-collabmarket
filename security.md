# SÉCURITÉ BACKEND

## 1. Row Level Security (RLS)
Toutes les tables sont protégées par RLS. Le principe de "moindre privilège" est appliqué.

### Règles Principales :
- **Profiles** : Lecture publique (via vue `public_profiles`), Modification par soi-même uniquement.
- **Orders** : Visibles seulement par le `merchant_id` et l'`influencer_id` concernés.
- **Revenues/Withdrawals** : Visibles seulement par le propriétaire (`influencer_id`).
- **Admin** : Accès total via la fonction `is_admin()`.

## 2. Protection des Données Sensibles
- **Emails & Téléphones** : Stockés chiffrés (`pgp_sym_encrypt`) dans la table `profiles`.
  - Seul l'utilisateur concerné ou un admin peut les déchiffrer via les fonctions `mask_email` / `mask_phone`.
  - La clé de chiffrement est stockée dans `app.encryption_key` (Vault Supabase).

## 3. Sécurité des Paiements (Anti-Double Spending)
- **Atomicité** : Les retraits utilisent une procédure RPC atomique `confirm_withdrawal_success`.
- **Verrouillage** : Utilisation de `FOR UPDATE` lors de la manipulation des soldes pour éviter les Race Conditions.
- **Idempotence** : Tous les webhooks Stripe vérifient l'ID de l'événement (`payment_logs`) avant traitement.

## 4. Edge Functions
- **Service Role** : Utilisé uniquement lorsque nécessaire (ex: écriture de logs système, mises à jour de statuts protégés).
- **Validation** : Toutes les entrées (body, params) sont validées (Zod ou vérifications manuelles) avant traitement.
- **CORS** : En-têtes stricts limités au domaine de production.

## 5. Bonnes Pratiques
- Ne jamais exposer `service_role_key` côté client.
- Toujours utiliser les RPC pour les opérations complexes (changements de statut commande, retraits).
- Ne jamais faire confiance aux métadonnées Stripe sans vérification croisée avec la DB.

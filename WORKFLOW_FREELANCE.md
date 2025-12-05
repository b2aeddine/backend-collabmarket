# Workflow Freelance & Affiliation (V23)

Ce document décrit le fonctionnement de la nouvelle Marketplace Freelance et du système d'Affiliation Collabmarket.

## 1. Architecture Financière

Le système repose sur un **Ledger** (Grand Livre) immuable qui trace chaque mouvement financier.

### Formule de Répartition
Pour une commande issue d'un lien affilié :

1.  **Prix Client** (`client_price`) :
    `Base Price - Client Discount + Platform Fee (5%)`
2.  **Commission Agent** (`agent_commission`) :
    `Agent Rate * (Base Price - Client Discount)`
3.  **Part Plateforme sur Agent** (`platform_cut`) :
    `20% * Agent Commission`
4.  **Net Agent** :
    `Agent Commission - Platform Cut`
5.  **Net Freelance** :
    `Base Price - Client Discount - Agent Commission`
6.  **Revenu Plateforme** :
    `Platform Fee + Platform Cut`

### Exemple Concret
- Gig : 100€
- Discount Client : 5%
- Commission Agent : 10%

| Acteur | Calcul | Montant |
| :--- | :--- | :--- |
| **Client** | (100 - 5) + 5% frais | **99.75€** |
| **Stripe** | Encaissement total | 99.75€ |
| **Freelance** | 100 - 5 (remise) - 9.50 (com agent) | **85.50€** |
| **Agent** | 9.50 (brut) - 1.90 (20% cut) | **7.60€** |
| **Plateforme** | 4.75 (frais) + 1.90 (cut) | **6.65€** |

## 2. Flux de Données (Data Flow)

### A. Création de Gig & Affiliation
1.  Freelance crée un Gig (`create_gig.ts`).
2.  Freelance active l'option "Affiliable" (`collabmarket_listings`).
    - Définit : `client_discount_rate`, `agent_commission_rate`.

### B. Promotion (Agent)
1.  Agent navigue sur l'onglet "Collabmarket".
2.  Agent génère un lien unique (`generate_affiliate_link.ts`).
3.  Agent partage le lien (`example.com/gigs/slug?ref=CODE`).

### C. Achat (Client)
1.  Client clique sur le lien -> `track_affiliate_visit.ts` enregistre le clic.
2.  Client passe commande -> `create_order.ts` :
    - Détecte le code affilié.
    - Applique la remise.
    - Crée la session Stripe avec les métadonnées (`order_id`, `affiliate_link_id`).

### D. Distribution (Webhook)
1.  Stripe confirme le paiement (`checkout.session.completed`).
2.  Webhook appelle `distribute_commissions` (RPC SQL).
3.  **RPC** :
    - Vérifie l'idempotence.
    - Calcule les montants exacts.
    - Enregistre dans `affiliate_conversions`.
    - Écrit dans `ledger` (Crédit Freelance, Crédit Agent, Crédit Plateforme).
    - Met à jour les soldes (`*_revenues`).
    - Valide la commande (`payment_authorized`).

## 3. Sécurité & Ledger

- **Ledger** : Table en lecture seule pour les utilisateurs. Seul le système (RPC) peut écrire.
- **Revenus** : Les tables `freelancer_revenues` et `agent_revenues` sont des vues matérialisées de l'état des soldes, mises à jour uniquement par le RPC financier.
- **RLS** : Chaque acteur ne voit que ses propres données financières.

## 4. Edge Functions Clés

| Fonction | Rôle | Sécurité |
| :--- | :--- | :--- |
| `create_gig` | Création atomique Gig + Packages | Auth User |
| `create_order` | Calcul prix & Stripe Session | Auth User |
| `stripe_webhook` | Point d'entrée des paiements | Signature Stripe |
| `distribute_commissions` | Cerveau financier (wrapper RPC) | Service Role |
| `generate_affiliate_link` | Création lien unique | Auth User (Agent) |
| `track_affiliate_visit` | Tracking clics | Public (Service Role interne) |

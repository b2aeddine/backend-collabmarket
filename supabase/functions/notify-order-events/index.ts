// ==============================================================================
// NOTIFY-ORDER-EVENTS - V14.0 (CORRECTED)
// Envoie des notifications lors des changements de statut de commande
// ==============================================================================

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { z } from "https://deno.land/x/zod@v3.22.4/mod.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// Validation schema
const eventSchema = z.object({
  orderId: z.string().uuid(),
  event: z.string(),
});

// Templates de notification par événement
const notificationTemplates: Record<string, { 
  merchant?: { title: string; content: string }; 
  influencer?: { title: string; content: string };
}> = {
  payment_authorized: {
    influencer: {
      title: "Nouvelle commande !",
      content: "Vous avez reçu une nouvelle commande. Le paiement est en attente de votre acceptation.",
    },
  },
  accepted: {
    merchant: {
      title: "Commande acceptée",
      content: "L'influenceur a accepté votre commande et va commencer le travail.",
    },
  },
  in_progress: {
    merchant: {
      title: "Travail en cours",
      content: "L'influenceur travaille actuellement sur votre commande.",
    },
  },
  submitted: {
    merchant: {
      title: "Livraison reçue",
      content: "L'influenceur a soumis son travail. Merci de vérifier et confirmer dans les 48h.",
    },
  },
  completed: {
    influencer: {
      title: "Commande validée !",
      content: "Le client a validé votre travail. Les fonds sont maintenant disponibles.",
    },
  },
  cancelled: {
    merchant: {
      title: "Commande annulée",
      content: "La commande a été annulée. Les fonds ont été libérés.",
    },
    influencer: {
      title: "Commande annulée",
      content: "La commande a été annulée.",
    },
  },
  disputed: {
    merchant: {
      title: "Litige ouvert",
      content: "Un litige a été ouvert sur cette commande. Notre équipe va examiner le cas.",
    },
    influencer: {
      title: "Litige ouvert",
      content: "Un litige a été ouvert sur cette commande. Notre équipe va examiner le cas.",
    },
  },
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const body = await req.json();

    // Validation
    const validation = eventSchema.safeParse(body);
    if (!validation.success) {
      throw new Error("Invalid payload");
    }

    const { orderId, event } = validation.data;

    console.log(`[Notify Order Events] Order: ${orderId}, Event: ${event}`);

    // Client Admin
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // Récupérer la commande
    const { data: order, error: orderError } = await supabase
      .from("orders")
      .select("id, merchant_id, influencer_id")
      .eq("id", orderId)
      .single();

    if (orderError || !order) {
      throw new Error("Order not found");
    }

    const template = notificationTemplates[event];
    if (!template) {
      console.log(`[Notify] No template for event: ${event}`);
      return new Response(JSON.stringify({
        success: true,
        message: "No notification template for this event",
      }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      });
    }

    const notifications: Array<{
      user_id: string;
      type: string;
      title: string;
      content: string;
      related_id: string;
    }> = [];

    // Notification au merchant
    if (template.merchant) {
      notifications.push({
        user_id: order.merchant_id,
        type: `order_${event}`,
        title: template.merchant.title,
        content: template.merchant.content,
        related_id: orderId,
      });
    }

    // Notification à l'influencer
    if (template.influencer) {
      notifications.push({
        user_id: order.influencer_id,
        type: `order_${event}`,
        title: template.influencer.title,
        content: template.influencer.content,
        related_id: orderId,
      });
    }

    // Insertion des notifications
    if (notifications.length > 0) {
      const { error: insertError } = await supabase
        .from("notifications")
        .insert(notifications);

      if (insertError) {
        console.error("Failed to insert notifications:", insertError);
        throw new Error("Failed to create notifications");
      }

      console.log(`[Notify] Created ${notifications.length} notification(s)`);
    }

    return new Response(JSON.stringify({
      success: true,
      notificationsSent: notifications.length,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200,
    });

  } catch (error: unknown) {
    const err = error as Error;
    console.error("[Notify Order Events Error]:", err);
    return new Response(JSON.stringify({
      success: false,
      error: err.message,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 400,
    });
  }
});

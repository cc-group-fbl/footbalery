import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function base64url(value: Uint8Array | string) {
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

function pemToBytes(pem: string) {
  const body = pem.replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/\s/g, "");
  const binary = atob(body);
  return Uint8Array.from(binary, (char) => char.charCodeAt(0));
}

async function getFirebaseAccessToken(account: Record<string, string>) {
  const now = Math.floor(Date.now() / 1000);
  const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = base64url(JSON.stringify({
    iss: account.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: account.token_uri || "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  }));
  const unsigned = header + "." + claims;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToBytes(account.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(
    await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(unsigned)),
  );
  const assertion = unsigned + "." + base64url(signature);

  const response = await fetch(account.token_uri || "https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  const result = await response.json();
  if (!response.ok || !result.access_token) {
    throw new Error("Firebase OAuth error: " + JSON.stringify(result));
  }
  return result.access_token as string;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return json({ error: "Authorization required" }, 401);

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const accountSecret = Deno.env.get("FIREBASE_SERVICE_ACCOUNT");
    if (!supabaseUrl || !anonKey || !serviceRoleKey || !accountSecret) {
      throw new Error("Missing Supabase or Firebase function secret.");
    }

    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: userData, error: userError } = await userClient.auth.getUser();
    if (userError || !userData.user) return json({ error: "Invalid session" }, 401);

    const { data: profile, error: profileError } = await userClient
      .from("profiles")
      .select("role")
      .eq("user_id", userData.user.id)
      .maybeSingle();
    if (profileError) throw profileError;
    if (profile?.role !== "admin") return json({ error: "Admin access required" }, 403);

    const body = await req.json();
    const title = String(body.title || "").trim().slice(0, 120);
    const messageBody = String(body.body || "").trim().slice(0, 500);
    const userIds = Array.isArray(body.user_ids)
      ? [...new Set(body.user_ids.filter((id: unknown) => typeof id === "string"))].slice(0, 500)
      : [];
    if (!title || !messageBody || !userIds.length) {
      return json({ error: "title, body and user_ids are required" }, 400);
    }

    const account = JSON.parse(accountSecret);
    if (account.project_id !== "footbalery" || !account.client_email || !account.private_key) {
      throw new Error("Firebase service account does not match project Footbalery.");
    }

    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: devices, error: devicesError } = await admin
      .from("push_tokens")
      .select("token")
      .in("user_id", userIds);
    if (devicesError) throw devicesError;
    if (!devices?.length) return json({ sent: 0, failed: 0, devices: 0 });

    const accessToken = await getFirebaseAccessToken(account);
    let sent = 0;
    let failed = 0;
    const invalidTokens: string[] = [];

    for (const device of devices) {
      const response = await fetch(
        "https://fcm.googleapis.com/v1/projects/footbalery/messages:send",
        {
          method: "POST",
          headers: {
            Authorization: "Bearer " + accessToken,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            message: {
              token: device.token,
              notification: { title, body: messageBody },
              data: Object.fromEntries(
                Object.entries(body.data || {}).map(([key, value]) => [key, String(value)]),
              ),
              android: {
                priority: "HIGH",
                notification: { channel_id: "default" },
              },
            },
          }),
        },
      );
      if (response.ok) {
        sent++;
      } else {
        failed++;
        const errorText = await response.text();
        if (errorText.includes("UNREGISTERED") || errorText.includes("registration-token-not-registered")) {
          invalidTokens.push(device.token);
        }
        console.error("FCM send failed:", response.status, errorText);
      }
    }

    if (invalidTokens.length) {
      await admin.from("push_tokens").delete().in("token", invalidTokens);
    }
    return json({ sent, failed, devices: devices.length });
  } catch (error) {
    console.error("send-push error:", error);
    return json({ error: error instanceof Error ? error.message : "Unknown error" }, 500);
  }
});

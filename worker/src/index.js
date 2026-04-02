export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "OPTIONS") {
      return new Response(null, { headers: corsHeaders() });
    }

    if (url.pathname === "/webhook" && request.method === "POST") {
      return handleWebhook(request, env);
    }

    if (url.pathname === "/generate" && request.method === "POST") {
      return handleGenerate(request, env);
    }

    return new Response("Not found", { status: 404 });
  },
};

// ── Paddle Webhook Handler ───────────────────────────────────

async function handleWebhook(request, env) {
  const rawBody = await request.text();
  const signature = request.headers.get("Paddle-Signature");

  if (
    !signature ||
    !(await verifyPaddleSignature(rawBody, signature, env.PADDLE_WEBHOOK_SECRET))
  ) {
    return new Response("Invalid signature", { status: 401 });
  }

  const event = JSON.parse(rawBody);
  // Handle both one-time and subscription transaction events
  const relevantEvents = ["transaction.completed", "transaction.billed", "transaction.paid"];
  if (!relevantEvents.includes(event.event_type)) {
    return new Response("Ignored", { status: 200 });
  }

  const customerId = event.data.customer_id;
  const email = await fetchCustomerEmail(customerId, env.PADDLE_API_KEY);
  if (!email) {
    return new Response("Could not fetch customer email", { status: 500 });
  }

  const licenseKey = await generateLicenseKey(email, env.ED25519_PRIVATE_KEY_PEM);

  if (env.RESEND_API_KEY) {
    await sendLicenseEmail(email, licenseKey, env.RESEND_API_KEY);
  }

  return new Response("OK", { status: 200 });
}

// ── Success Page Handler ─────────────────────────────────────

async function handleGenerate(request, env) {
  const { transaction_id } = await request.json();
  if (!transaction_id) {
    return corsResponse({ error: "Missing transaction_id" }, 400);
  }

  const txn = await fetchTransaction(transaction_id, env.PADDLE_API_KEY);
  if (!txn) {
    return corsResponse({ error: "Transaction not found. It may still be processing — please wait a moment and refresh." }, 400);
  }

  // Accept completed, billed, or paid (subscriptions use billed/paid before completed)
  const validStatuses = ["completed", "billed", "paid"];
  if (!validStatuses.includes(txn.status)) {
    return corsResponse({ error: `Transaction status is '${txn.status}', not yet ready. Please wait a moment and refresh.` }, 400);
  }

  const email = await fetchCustomerEmail(txn.customer_id, env.PADDLE_API_KEY);
  if (!email) {
    return corsResponse({ error: "Could not resolve customer email" }, 500);
  }

  const licenseKey = await generateLicenseKey(email, env.ED25519_PRIVATE_KEY_PEM);
  return corsResponse({ license_key: licenseKey, email }, 200);
}

// ── Ed25519 License Key Generation ───────────────────────────

async function generateLicenseKey(email, privatePem) {
  // Must match Python: json.dumps({"email":..., "product":"ekual"}, separators=(",",":"), sort_keys=True)
  // sort_keys=True → alphabetical: "email" before "product"
  const payload = JSON.stringify({ email: email, product: "ekual" });
  const payloadBytes = new TextEncoder().encode(payload);

  const signingKey = await importEd25519PrivateKey(privatePem);
  const signatureBuffer = await crypto.subtle.sign("Ed25519", signingKey, payloadBytes);

  const payloadB64 = btoa(String.fromCharCode(...payloadBytes));
  const signatureB64 = btoa(String.fromCharCode(...new Uint8Array(signatureBuffer)));

  return `${payloadB64}.${signatureB64}`;
}

async function importEd25519PrivateKey(pem) {
  const pemContents = pem
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s/g, "");

  const binaryDer = Uint8Array.from(atob(pemContents), (c) => c.charCodeAt(0));

  return crypto.subtle.importKey("pkcs8", binaryDer.buffer, { name: "Ed25519" }, false, [
    "sign",
  ]);
}

// ── Paddle Webhook Signature Verification ────────────────────

async function verifyPaddleSignature(rawBody, signatureHeader, secret) {
  const parts = {};
  for (const part of signatureHeader.split(";")) {
    const [key, value] = part.split("=", 2);
    parts[key] = value;
  }

  const ts = parts["ts"];
  const h1 = parts["h1"];
  if (!ts || !h1) return false;

  const now = Math.floor(Date.now() / 1000);
  if (Math.abs(now - parseInt(ts)) > 300) return false;

  const signedPayload = `${ts}:${rawBody}`;

  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );

  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(signedPayload));

  const computed = Array.from(new Uint8Array(mac))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");

  if (computed.length !== h1.length) return false;
  let result = 0;
  for (let i = 0; i < computed.length; i++) {
    result |= computed.charCodeAt(i) ^ h1.charCodeAt(i);
  }
  return result === 0;
}

// ── Paddle API Helpers ───────────────────────────────────────

async function fetchCustomerEmail(customerId, apiKey) {
  const res = await fetch(`https://api.paddle.com/customers/${customerId}`, {
    headers: { Authorization: `Bearer ${apiKey}` },
  });
  if (!res.ok) return null;
  const json = await res.json();
  return json.data?.email || null;
}

async function fetchTransaction(transactionId, apiKey) {
  const res = await fetch(`https://api.paddle.com/transactions/${transactionId}`, {
    headers: { Authorization: `Bearer ${apiKey}` },
  });
  if (!res.ok) return null;
  const json = await res.json();
  return json.data || null;
}

// ── Email Delivery (Resend) ──────────────────────────────────

async function sendLicenseEmail(email, licenseKey, resendApiKey) {
  await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${resendApiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: "Ekual <onboarding@resend.dev>",
      to: [email],
      subject: "Your Ekual License Key",
      html: `
        <h2>Thank you for purchasing Ekual!</h2>
        <p>Here is your license key:</p>
        <pre style="background:#f4f4f4;padding:12px;border-radius:6px;font-size:14px;word-break:break-all;">${licenseKey}</pre>
        <p><strong>To activate:</strong></p>
        <ol>
          <li>Open Ekual from the menu bar</li>
          <li>Paste the key into the license field</li>
          <li>Click Activate</li>
        </ol>
        <p>If you have any issues, reply to corvusdevs@outlook.com</p>
      `,
    }),
  });
}

// ── CORS ─────────────────────────────────────────────────────

function corsHeaders() {
  return {
    "Access-Control-Allow-Origin": "https://corvusdevs.github.io",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
  };
}

function corsResponse(body, status) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders() },
  });
}

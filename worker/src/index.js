export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const corsHeaders = {
      "Access-Control-Allow-Origin": "https://corvusdevs.github.io",
      "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type",
    };

    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders });
    }

    try {
      let response;

      if ((url.pathname === "/webhook" || url.pathname === "/") && request.method === "POST") {
        response = await handleWebhook(request, env);
      } else if (url.pathname === "/verify" && request.method === "GET") {
        response = await handleVerify(url, env);
      } else if (url.pathname === "/health") {
        response = json({ status: "ok" });
      } else {
        response = json({ error: "Not found" }, 404);
      }

      Object.entries(corsHeaders).forEach(([k, v]) => response.headers.set(k, v));
      return response;
    } catch (err) {
      console.error("Unhandled error:", err);
      return json({ error: "Internal server error" }, 500);
    }
  },
};

// ── Paddle Webhook ──────────────────────────────────────────────

async function handleWebhook(request, env) {
  const signature = request.headers.get("Paddle-Signature");
  if (!signature) return json({ error: "Missing signature" }, 401);

  const body = await request.text();

  const valid = await verifyPaddleSignature(body, signature, env.PADDLE_WEBHOOK_SECRET);
  if (!valid) return json({ error: "Invalid signature" }, 401);

  const event = JSON.parse(body);

  if (event.event_type === "transaction.completed") {
    const txn = event.data;
    const licenseKey = txn.id;
    const email =
      txn.checkout?.customer_email ||
      txn.customer?.email ||
      extractEmailFromCustomData(txn);

    await env.LICENSES.put(
      licenseKey,
      JSON.stringify({
        email: email || null,
        transactionId: txn.id,
        customerId: txn.customer_id || null,
        productId: txn.items?.[0]?.price?.product_id || null,
        createdAt: new Date().toISOString(),
      })
    );

    if (email && env.RESEND_API_KEY) {
      await sendLicenseEmail(email, licenseKey, env.RESEND_API_KEY).catch(
        (err) => console.error("Email send failed:", err)
      );
    }
  }

  return json({ received: true });
}

// ── License Verification ────────────────────────────────────────

async function handleVerify(url, env) {
  const key = url.searchParams.get("key");
  if (!key) return json({ valid: false, error: "Missing key parameter" }, 400);

  const stored = await env.LICENSES.get(key);
  if (!stored) return json({ valid: false }, 404);

  const data = JSON.parse(stored);
  return json({ valid: true, email: maskEmail(data.email) });
}

// ── Paddle Signature Verification ──────────────────────────────

async function verifyPaddleSignature(body, signatureHeader, secret) {
  const parts = {};
  signatureHeader.split(";").forEach((part) => {
    const idx = part.indexOf("=");
    if (idx !== -1) {
      parts[part.substring(0, idx)] = part.substring(idx + 1);
    }
  });

  const ts = parts["ts"];
  const h1 = parts["h1"];
  if (!ts || !h1) return false;

  const age = Math.abs(Date.now() / 1000 - parseInt(ts, 10));
  if (age > 300) return false;

  const signedPayload = `${ts}:${body}`;

  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );

  const sig = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(signedPayload)
  );

  const computed = Array.from(new Uint8Array(sig))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");

  if (computed.length !== h1.length) return false;
  let result = 0;
  for (let i = 0; i < computed.length; i++) {
    result |= computed.charCodeAt(i) ^ h1.charCodeAt(i);
  }
  return result === 0;
}

// ── Email Delivery (Resend) ─────────────────────────────────────

async function sendLicenseEmail(email, licenseKey, resendApiKey) {
  await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${resendApiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: "Ekual <noreply@shopa.pro>",
      to: [email],
      subject: "Your Ekual License Key",
      html: buildEmailHtml(licenseKey),
    }),
  });
}

function buildEmailHtml(licenseKey) {
  return `<!DOCTYPE html>
<html>
<head><meta charset="utf-8"></head>
<body style="margin:0;padding:0;background:#0a0a0c;font-family:-apple-system,BlinkMacSystemFont,'SF Pro Display','Helvetica Neue',sans-serif">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#0a0a0c;padding:40px 20px">
<tr><td align="center">
<table width="480" cellpadding="0" cellspacing="0" style="background:#111114;border-radius:16px;border:1px solid #252530;overflow:hidden">
    <tr><td style="padding:40px 32px 24px;text-align:center">
        <div style="font-size:40px;margin-bottom:16px">🎧</div>
        <h1 style="color:#e8e8ed;font-size:24px;font-weight:700;margin:0 0 8px">Welcome to Ekual</h1>
        <p style="color:#7c7c84;font-size:15px;margin:0">Thank you for your purchase!</p>
    </td></tr>
    <tr><td style="padding:0 32px 32px">
        <div style="background:#19191e;border:1px solid #252530;border-radius:12px;padding:20px;text-align:center">
            <p style="color:#7c7c84;font-size:13px;margin:0 0 8px;text-transform:uppercase;letter-spacing:1px">Your License Key</p>
            <p style="color:#4ade80;font-size:18px;font-weight:600;font-family:'SF Mono',Menlo,monospace;margin:0;word-break:break-all">${licenseKey}</p>
        </div>
    </td></tr>
    <tr><td style="padding:0 32px 32px">
        <h3 style="color:#e8e8ed;font-size:15px;margin:0 0 12px">How to activate:</h3>
        <ol style="color:#7c7c84;font-size:14px;line-height:1.8;margin:0;padding-left:20px">
            <li>Open Ekual from the menu bar</li>
            <li>Click <strong style="color:#e8e8ed">Activate License</strong> (or wait for the trial to end)</li>
            <li>Paste your license key and click <strong style="color:#e8e8ed">Activate</strong></li>
        </ol>
    </td></tr>
    <tr><td style="padding:0 32px 32px;text-align:center">
        <a href="https://corvusdevs.github.io/Ekual/" style="display:inline-block;background:#22c55e;color:#fff;text-decoration:none;padding:12px 28px;border-radius:10px;font-size:15px;font-weight:600">Download Ekual</a>
    </td></tr>
    <tr><td style="padding:0 32px 24px;border-top:1px solid #252530;padding-top:24px">
        <p style="color:#7c7c84;font-size:12px;text-align:center;margin:0">
            Keep this email for your records. You can reuse this key if you reinstall.<br>
            Questions? <a href="mailto:corvusdevs@outlook.com" style="color:#4ade80;text-decoration:none">corvusdevs@outlook.com</a>
        </p>
    </td></tr>
</table>
</td></tr>
</table>
</body>
</html>`;
}

// ── Helpers ─────────────────────────────────────────────────────

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function maskEmail(email) {
  if (!email) return null;
  const [user, domain] = email.split("@");
  if (!domain) return "***";
  const visible = user.substring(0, Math.min(3, user.length));
  return `${visible}***@${domain}`;
}

function extractEmailFromCustomData(txn) {
  try {
    if (txn.custom_data?.email) return txn.custom_data.email;
    if (txn.checkout?.custom_data?.email) return txn.checkout.custom_data.email;
  } catch {
    /* ignore */
  }
  return null;
}

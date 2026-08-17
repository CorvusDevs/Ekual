export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const corsHeaders = {
      // Config-driven to match the deployed worker. Hardcoding these would let a
      // deploy silently drop the CORS_ORIGIN / FROM_EMAIL vars that production
      // already relies on.
      "Access-Control-Allow-Origin": env.CORS_ORIGIN || "https://corvusdevs.github.io",
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
      } else if (url.pathname === "/resend" && request.method === "POST") {
        response = await handleResend(request, env);
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

    // Paddle delivers EVERY notification to EVERY configured destination, so
    // without this check a purchase of any CorvusDevs app mints a valid licence
    // in every other app's store. Measured 2026-08-10: 6 of Corvus Player's 12
    // licences and 4 of Corvus Display's 6 were actually Ekual purchases, and an
    // Ekual key validated successfully against both.
    //
    // Fail OPEN when PRODUCT_ID is unset: an unset var must not stop licences
    // being issued entirely, which would be far worse than the leak. The error
    // log makes the misconfiguration obvious.
    if (!isOurProduct(txn, env.PRODUCT_ID)) {
      return json({ received: true, ignored: "different product" });
    }

    const licenseKey = txn.id;

    // Paddle's `transaction.completed` payload carries `customer_id`, NOT the
    // customer's email address: `checkout.customer_email` is null and there is
    // no nested `customer` object. All three lookups below therefore return
    // nothing on a real webhook.
    //
    // This is why PADDLE_API_KEY is required. It was once removed with the note
    // "no longer needed, email comes from webhook payload", which is false, and
    // every purchase after that stored a valid license with `email: null` and
    // silently never delivered it. Verified 2026-08-10 against 11 completed
    // transactions: every single one had no email captured.
    let email =
      txn.checkout?.customer_email ||
      txn.customer?.email ||
      extractEmailFromCustomData(txn);

    if (!email && txn.customer_id) {
      email = await fetchCustomerEmail(txn.customer_id, env.PADDLE_API_KEY);
    }

    // Delivery outcome is persisted so a silent failure can never hide again:
    // the /verify response exposes it, making "who never got their key?"
    // answerable without replaying webhooks.
    let emailStatus;
    if (!email) {
      emailStatus = "no_email_resolved";
      console.error(
        `LICENSE EMAIL NOT SENT: no email resolved for transaction ${licenseKey} (customer ${txn.customer_id || "unknown"}). Is PADDLE_API_KEY set on this worker?`
      );
    } else if (!env.RESEND_API_KEY) {
      emailStatus = "no_resend_key";
      console.error(`LICENSE EMAIL NOT SENT: RESEND_API_KEY missing (transaction ${licenseKey})`);
    } else {
      try {
        const emailProviderId = await sendLicenseEmail(
          email,
          licenseKey,
          env.RESEND_API_KEY,
          env.FROM_EMAIL
        );
        emailStatus = "sent";
        await env.LICENSES.put(
          licenseKey,
          JSON.stringify({
            email,
            emailStatus,
            emailProviderId,
            emailedAt: new Date().toISOString(),
            transactionId: txn.id,
            customerId: txn.customer_id || null,
            productId: txn.items?.[0]?.price?.product_id || null,
            createdAt: new Date().toISOString(),
          })
        );
        return json({ received: true });
      } catch (err) {
        emailStatus = "send_failed";
        console.error(`LICENSE EMAIL SEND FAILED for ${licenseKey}:`, err);
      }
    }

    await env.LICENSES.put(
      licenseKey,
      JSON.stringify({
        email: email || null,
        emailStatus,
        transactionId: txn.id,
        customerId: txn.customer_id || null,
        productId: txn.items?.[0]?.price?.product_id || null,
        createdAt: new Date().toISOString(),
      })
    );
  }

  return json({ received: true });
}

// Customer-support recovery path. Both values must match the production KV
// record, responses do not reveal which value was wrong, and attempts are
// limited to one per hour so a leaked key cannot be used to spam its owner.
async function handleResend(request, env) {
  let input;
  try {
    input = await request.json();
  } catch {
    return json({ sent: false, error: "Invalid request" }, 400);
  }

  const key = typeof input?.key === "string" ? input.key.trim() : "";
  const email = typeof input?.email === "string" ? input.email.trim().toLowerCase() : "";
  if (!/^txn_[a-z0-9]+$/.test(key) || !email || !env.RESEND_API_KEY) {
    return json({ sent: false, error: "Unable to resend" }, 400);
  }

  const stored = await env.LICENSES.get(key);
  if (!stored) return json({ sent: false, error: "Unable to resend" }, 404);

  const data = JSON.parse(stored);
  if (env.PRODUCT_ID && data.productId && data.productId !== env.PRODUCT_ID) {
    return json({ sent: false, error: "Unable to resend" }, 404);
  }
  if (typeof data.email !== "string" || data.email.toLowerCase() !== email) {
    return json({ sent: false, error: "Unable to resend" }, 404);
  }

  const lastAttempt = Date.parse(data.resendAttemptAt || "");
  if (Number.isFinite(lastAttempt) && Date.now() - lastAttempt < 60 * 60 * 1000) {
    return json({ sent: false, error: "Please wait before trying again" }, 429);
  }

  data.resendAttemptAt = new Date().toISOString();
  await env.LICENSES.put(key, JSON.stringify(data));

  try {
    data.emailProviderId = await sendLicenseEmail(
      data.email,
      key,
      env.RESEND_API_KEY,
      env.FROM_EMAIL
    );
    data.emailStatus = "sent";
    data.emailedAt = new Date().toISOString();
    await env.LICENSES.put(key, JSON.stringify(data));
    return json({ sent: true });
  } catch (err) {
    data.emailStatus = "send_failed";
    data.emailErrorAt = new Date().toISOString();
    await env.LICENSES.put(key, JSON.stringify(data));
    console.error(`LICENSE EMAIL RESEND FAILED for ${key}:`, err);
    return json({ sent: false, error: "Email delivery failed" }, 502);
  }
}

// ── License Verification ────────────────────────────────────────

async function handleVerify(url, env) {
  const key = url.searchParams.get("key");
  if (!key) return json({ valid: false, error: "Missing key parameter" }, 400);

  const stored = await env.LICENSES.get(key);
  if (!stored) return json({ valid: false }, 404);

  const data = JSON.parse(stored);
  if (env.PRODUCT_ID && data.productId && data.productId !== env.PRODUCT_ID) {
    return json({ valid: false }, 404);
  }
  // `emailStatus` is surfaced so delivery problems are auditable from outside
  // the worker. Older records predate the field and report "unknown".
  return json({
    valid: true,
    email: maskEmail(data.email),
    emailStatus: data.emailStatus || "unknown",
  });
}

// ── Product Scoping ─────────────────────────────────────────────

/**
 * True when this transaction is for the product THIS worker serves.
 *
 * Checks every line item, not just the first, so a multi-item transaction that
 * includes our product is still honoured.
 *
 * Returns true when `expectedProductId` is unset, so a missing config var
 * degrades to the old (leaky) behaviour rather than refusing to issue licences.
 */
function isOurProduct(txn, expectedProductId) {
  if (!expectedProductId) {
    console.error(
      "PRODUCT_ID is not configured on this worker — cannot scope licences to a product, so a purchase of ANY product will mint a licence here. Set it in the deploy config [vars]."
    );
    return true;
  }
  const ids = (txn.items || [])
    .map((i) => i?.price?.product_id)
    .filter(Boolean);
  return ids.includes(expectedProductId);
}

// ── Customer Lookup ─────────────────────────────────────────────

/**
 * Resolve a customer's email from their Paddle customer_id.
 *
 * Required because the webhook payload never includes the email itself. Returns
 * null on any failure; the caller records that as `no_email_resolved` rather
 * than throwing, so a lookup outage can never cost us the license record.
 */
async function fetchCustomerEmail(customerId, apiKey) {
  if (!apiKey) {
    console.error(
      "PADDLE_API_KEY is not configured on this worker — cannot resolve customer email. Set it with: wrangler secret put PADDLE_API_KEY"
    );
    return null;
  }
  try {
    const res = await fetch(`https://api.paddle.com/customers/${customerId}`, {
      headers: { Authorization: `Bearer ${apiKey}` },
    });
    if (!res.ok) {
      console.error(
        `Paddle customer lookup failed for ${customerId}: HTTP ${res.status} ${await res.text()}`
      );
      return null;
    }
    const body = await res.json();
    return body?.data?.email || null;
  } catch (err) {
    console.error(`Paddle customer lookup threw for ${customerId}:`, err);
    return null;
  }
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

async function sendLicenseEmail(email, licenseKey, resendApiKey, fromEmail) {
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${resendApiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: fromEmail || "Ekual <noreply@shopa.pro>",
      to: [email],
      subject: "Your Ekual License Key",
      html: buildEmailHtml(licenseKey),
    }),
  });

  const responseText = await res.text().catch(() => "");
  if (!res.ok) {
    throw new Error(`Resend HTTP ${res.status}: ${responseText.slice(0, 500)}`);
  }

  try {
    return JSON.parse(responseText)?.id || null;
  } catch {
    return null;
  }
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

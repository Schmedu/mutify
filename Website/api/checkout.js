import { CURRENCY, MAX_AMOUNT, MIN_AMOUNT, PRODUCT_ID, json, stripe } from './_lib.js';

const ALLOWED_HOSTS = [/^mutify\.e\.uffelmann\.me$/, /^mutify\.schmedu\.com$/, /\.vercel\.app$/];

/** A light throttle so nobody can fill the dashboard with abandoned sessions. */
const seen = new Map();
const WINDOW = 60_000;
const BURST = 8;

export default async function handler(req, res) {
  if (req.method !== 'POST') return json(res, 405, { error: 'POST only' });
  if (throttled(req)) return json(res, 429, { error: 'Too many attempts. Try again in a minute.' });

  const raw = Math.round(Number(req.body?.amount));
  const amount = clamp(raw);
  if (!amount) {
    const over = Number.isFinite(raw) && raw > MAX_AMOUNT;
    return json(res, 400, {
      error: over
        ? `That is more than Mutify can take in one go — ${MAX_AMOUNT / 100} euros is the ceiling.`
        : `Pick an amount of at least ${MIN_AMOUNT} cents.`,
    });
  }

  const origin = originOf(req);

  try {
    const session = await stripe('checkout/sessions', {
      method: 'POST',
      body: {
        mode: 'payment',
        line_items: [
          {
            quantity: 1,
            price_data: {
              currency: CURRENCY,
              product: PRODUCT_ID,
              unit_amount: amount,
              // The account infers inclusive for EUR anyway; saying so here
              // means the figure on the button is the figure that gets charged.
              tax_behavior: 'inclusive',
            },
          },
        ],
        automatic_tax: { enabled: true },
        submit_type: 'pay',
        success_url: `${origin}/thanks?session_id={CHECKOUT_SESSION_ID}`,
        cancel_url: `${origin}/#buy`,
        payment_intent_data: { description: 'Mutify for macOS' },
        metadata: { product: 'mutify', chosen_amount: String(amount) },
      },
    });

    return json(res, 200, { url: session.url });
  } catch (err) {
    console.error('checkout failed:', err.message, err.stripeCode ?? '');
    return json(res, 502, { error: "Stripe wouldn't open a checkout. Try again in a moment." });
  }
}

function clamp(n) {
  if (!Number.isFinite(n) || n < MIN_AMOUNT || n > MAX_AMOUNT) return null;
  return n;
}

function originOf(req) {
  const host = req.headers['x-forwarded-host'] ?? req.headers.host ?? '';
  if (ALLOWED_HOSTS.some((re) => re.test(host))) {
    return `${req.headers['x-forwarded-proto'] ?? 'https'}://${host}`;
  }
  return process.env.SITE_URL ?? 'https://mutify.e.uffelmann.me';
}

function throttled(req) {
  const ip = req.headers['x-forwarded-for']?.split(',')[0]?.trim() ?? 'unknown';
  const now = Date.now();
  const hits = (seen.get(ip) ?? []).filter((t) => now - t < WINDOW);
  hits.push(now);
  seen.set(ip, hits);
  if (seen.size > 5000) seen.clear();
  return hits.length > BURST;
}

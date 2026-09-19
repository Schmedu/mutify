import { json, latestDmg, stripe } from './_lib.js';

// Hands over the DMG once Stripe says the session was paid for.
//
//   /api/download?session_id=cs_live_…            → 302 to the release asset
//   /api/download?session_id=cs_live_…&json=1     → what /thanks renders

export default async function handler(req, res) {
  const id = String(req.query.session_id ?? '');
  const wantsJson = req.query.json === '1';

  if (!/^cs_(live|test)_[A-Za-z0-9]+$/.test(id)) {
    return wantsJson
      ? json(res, 400, { paid: false, error: 'That download link is missing its receipt.' })
      : res.redirect(302, '/#buy');
  }

  let session;
  try {
    session = await stripe(`checkout/sessions/${encodeURIComponent(id)}`);
  } catch (err) {
    console.error('session lookup failed:', err.message);
    return wantsJson
      ? json(res, 502, { paid: false, error: "Couldn't reach Stripe to check the receipt." })
      : res.redirect(302, '/#buy');
  }

  if (session.payment_status !== 'paid') {
    return wantsJson
      ? json(res, 402, { paid: false, error: 'That payment has not gone through.' })
      : res.redirect(302, '/#buy');
  }

  const dmg = await latestDmg();

  if (wantsJson) {
    return json(res, 200, {
      paid: true,
      version: dmg.version,
      size: dmg.size ?? null,
      amount: session.amount_total,
      currency: session.currency,
      email: session.customer_details?.email ?? null,
    });
  }

  res.setHeader('Cache-Control', 'no-store');
  return res.redirect(302, dmg.url);
}

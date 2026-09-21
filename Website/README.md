# mutify.e.uffelmann.me

The page that sells Mutify, and the two functions that take the money and hand
over the DMG. Static HTML with no build step and no dependencies — `public/` is
served as-is, `api/` runs on Vercel's Node runtime.

```
public/index.html   the landing page (styles and script inline, one request)
public/drawn.html   the same page, hand-drawn and animated — served at /drawn
public/thanks.html  where Stripe sends people afterwards
public/legal.html   imprint, withdrawal, VAT, privacy
public/_shared.css  the design tokens the two small pages share
api/_lib.js         Stripe over plain fetch, plus the GitHub release lookup
api/checkout.js     POST {amount} → a Checkout Session URL
api/download.js     GET ?session_id → 302 to the DMG, once Stripe says "paid"
```

## Pay what you want, 0,99 € floor

There is no fixed price object in the checkout. `api/checkout.js` builds the
line item from `price_data` against the tracked product, so the buyer's own
figure goes straight through — clamped to `[MIN_AMOUNT, MAX_AMOUNT]` in
`api/_lib.js` (99 cents to 500 €) before Stripe ever sees it.

`tax_behavior: 'inclusive'` means the number on the button is the number that
gets charged; Stripe Tax carves the VAT out of it once it knows the country.

Amounts are written the German way round — `0,99 €`, symbol trailing, comma
for the decimal — via `de-DE` formatting. The custom field takes `3`, `3,50` and
`3.50` alike, and `parseAmount` rejects everything else before it can reach
Stripe.
The canonical 0,99 € price object still exists for the record:

```sh
~/.claude/skills/stripe/get-id.sh STRIPE_PRODUCT_MUTIFY   --project stripe-eduard --env prod
~/.claude/skills/stripe/get-id.sh STRIPE_PRICE_MUTIFY_ONCE --project stripe-eduard --env prod
```

## How the download is gated

The success URL carries `{CHECKOUT_SESSION_ID}`. `/thanks` asks
`/api/download?json=1` about it, which retrieves the session server-side and
only answers if `payment_status === 'paid'`. Nothing is signed or stored — the
session id *is* the receipt, so the link keeps working for whoever holds it.

The asset itself is resolved from the newest GitHub release at request time and
cached for ten minutes per warm instance, so shipping 1.1 needs no change here.
If GitHub is unreachable it falls back to the constant in `api/_lib.js`.

The same DMG is a free public download on that release. That is deliberate.

## The hero

`public/img/room.webp` is a generated coworking-space image (`Marketing/07-room.jpg`
is the full-size original) — not a photograph of anywhere real. The card sitting
on it is: `public/img/status.webp` is the top two rows cropped straight out of
`Marketing/screenshots/05-menu.png`, so the words in the hero are the words the
app actually prints.

## The drawn cut

`/drawn` carries the same words and the same checkout as `/`, redrawn as an
inked cartoon: the hero laptop opens, starts to sing, gets a Mutify sticker
slapped on before the chorus, and the notes drop. Everything is inline SVG
animated with CSS — no images, no libraries. The shiver on every line is one
shared `feTurbulence` filter whose seed steps a few times a second.

It is `noindex` with a canonical pointing at `/`, and isn't in the sitemap, so
the two pages never compete in search. With reduced motion the loops and the
line boil stop, and the hero rests on its last frame: muted, sticker on.

## Domains

`mutify.e.uffelmann.me` is the site. `mutify.schmedu.com` was the first home and
now 308s to it, path and all, so anything already shared keeps working. Both are
Cloudflare CNAMEs to Vercel, DNS-only, each with its own `_vercel` TXT record —
note those live in *different zones* (`uffelmann.me` and `schmedu.com`).

## Deploying

```sh
vercel deploy --prod --yes          # from this directory
```

`STRIPE_SECRET_KEY` lives in Vercel's production environment (marked
sensitive), not in this repo. It comes from Infisical:

```sh
~/.claude/skills/infisical-get/with-secret.sh STRIPE_SECRET_KEY \
  --project stripe-eduard --env prod --path / --as STRIPE_SECRET_KEY -- sh -c '…'
```

DNS is a Cloudflare CNAME to Vercel, DNS-only (not proxied), plus the
`_vercel` TXT record that proves ownership of the subdomain.

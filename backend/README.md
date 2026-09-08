# Home Eats backend

A tiny Express proxy in front of the Google Places API and the Claude API.
It exists for one reason: so the real API keys live only on this server (as
environment variables) and never ship inside the iOS app. See
`GooglePlacesService.swift` and `ClaudeRecipeService.swift` in the iOS app
for the client side of this.

## 1. Get a Google Places API key

1. Go to [console.cloud.google.com](https://console.cloud.google.com) and
   create a new project (or reuse one).
2. **APIs & Services → Library** → search for and enable **"Places API
   (New)"**.
3. **Billing** → attach a billing account. Google requires this even for
   free-tier usage — new accounts get recurring free monthly credit, but a
   card must be on file. Set a budget alert here too, so you notice if
   usage ever spikes unexpectedly.
4. **APIs & Services → Credentials → Create Credentials → API key.**
5. **Restrict the key**: click into it, under "API restrictions" choose
   "Restrict key" and select only "Places API (New)". Since this key lives
   on your server (not the app), you do *not* need an iOS bundle ID
   restriction here — restrict by API only.

## 1b. Get a Claude API key

1. Go to [console.anthropic.com](https://console.anthropic.com) → API Keys
   → Create Key. (If you already have one from the PlanAway backend, you
   can reuse the same Anthropic account/organization — just create a
   separate key here so the two apps' usage is billed/tracked separately.)
2. Add credit / a billing method under **Settings → Billing** if you
   haven't already — same "billing required" story as Google.

## 2. Run it locally

```bash
cd backend
cp .env.example .env
# edit .env, paste your keys in for GOOGLE_PLACES_API_KEY and ANTHROPIC_API_KEY
npm install
npm start
```

Check it's working:

```bash
curl "http://localhost:4000/health"
curl "http://localhost:4000/restaurants/search?q=pizza+near+me"
curl -X POST "http://localhost:4000/recipes/extract" \
  -H "Content-Type: application/json" \
  -d '{"notesText": "Grandma'\''s pancakes: 2 cups flour, 2 eggs, 1.5 cups milk. Mix and cook on a griddle."}'
curl -X POST "http://localhost:4000/recipes/recommend" \
  -H "Content-Type: application/json" \
  -d '{"ingredients": ["chicken thighs", "rice", "broccoli"]}'
```

## 3. Deploy it (Render, same as the pattern used elsewhere)

1. [render.com](https://render.com) → New → Web Service → connect this
   GitHub repo.
2. **Root Directory**: `backend`
3. **Build Command**: `npm install`
4. **Start Command**: `npm start`
5. **Environment** → add both `GOOGLE_PLACES_API_KEY` and
   `ANTHROPIC_API_KEY` with your real keys. Do not put either key anywhere
   in the repo — these environment variables are the only place they
   should live.
6. Deploy. Render gives you a URL like `https://home-eats-backend.onrender.com`.

## 4. Point the iOS app at it

Open `HomeEats/Services/GooglePlacesService.swift` and
`HomeEats/Services/ClaudeRecipeService.swift` and replace each file's
`baseURLString` placeholder with your deployed Render URL (both files point
at the same backend — one constant each, so it's easy to keep them in
sync). That's the only change needed on the app side:

- `RestaurantListView`'s search automatically starts using Google's richer
  results (rating, price, cuisine) instead of falling back to Apple's free
  MapKit search, which can't provide any of those three.
- Recipes gets a "From a Photo or Notes" import option and a "Recommend a
  Meal" screen, both backed by Claude.

## Notes

- Free-tier Render web services spin down after inactivity and take a few
  seconds to wake back up on the next request — fine for a household app,
  worth knowing so a "slow first search"/"slow first recommendation" isn't
  mistaken for a bug.
- The Google side proxies *search* only (`/restaurants/search`). Google's
  Place Details / Photos endpoints (for a restaurant's actual photos)
  aren't wired up — a reasonable next step if you want real restaurant
  photos later, same proxy pattern.
- Every `/recipes/*` call costs real money the moment a key is configured
  (Claude Opus 5 — see the model table in the Anthropic Console for current
  pricing). Fine for household-scale use; if this app ever gets real
  traction, add per-user rate limiting here before that happens.

// Home Eats backend — started as a small proxy in front of the Google
// Places API and the Anthropic API, and now also the accounts/friends/
// groups backend (see the "Accounts, friends, and groups" block below and
// routes/, lib/, prisma/ in this folder).
//
// Why the proxy part exists at all: the Places API needs a billed Google
// Cloud API key. Shipping that key inside the iOS app (even "restricted" to
// the app's bundle ID) means it's extracted the moment someone decompiles
// the binary. This server holds the one real key as a server-side env var;
// the app only ever talks to *this* server, which adds the key and
// forwards the request to Google. See README.md in this folder for
// deployment steps and the accounts feature's own setup (Postgres, Twilio
// Verify, JWT secret).
"use strict";

const express = require("express");
const Anthropic = require("@anthropic-ai/sdk");
const { zodOutputFormat } = require("@anthropic-ai/sdk/helpers/zod");
const { z } = require("zod");
const { prisma } = require("./lib/prisma");
const { requireAuth } = require("./middleware/requireAuth");
const authRouter = require("./routes/auth");
const meRouter = require("./routes/me");
const friendsRouter = require("./routes/friends");
const groupsRouter = require("./routes/groups");
const recipeLibraryRouter = require("./routes/recipeLibrary");
const groupMealPlanRouter = require("./routes/groupMealPlan");
const groupGroceryRouter = require("./routes/groupGrocery");
const groupGroceryAislesRouter = require("./routes/groupGroceryAisles");
const groupGroceryStaplesRouter = require("./routes/groupGroceryStaples");

const app = express();
// Render puts every request through its own reverse proxy, so without this
// `req.ip` would just be that proxy's address for every request — useless
// for the per-IP request-code rate limiter in routes/auth.js, which needs
// the real client IP from the `X-Forwarded-For` header Render sets. `true`
// trusts that header from the immediate upstream hop, which is exactly
// Render's proxy in this deployment (see backend/README.md's deploy
// section — this always runs behind it, there's no direct-to-internet
// deployment path to worry about spoofing this header on).
app.set("trust proxy", true);
// A downsized recipe photo (see ImageResizing.swift in the iOS app - it
// caps images at 800px on the long edge before base64-encoding) is well
// under 1MB, but give real headroom rather than a tight limit that fails
// on an occasional larger photo.
app.use(express.json({ limit: "15mb" }));

const PORT = process.env.PORT || 4000;
const GOOGLE_PLACES_API_KEY = process.env.GOOGLE_PLACES_API_KEY;
// `new Anthropic()` reads ANTHROPIC_API_KEY from the environment itself;
// constructing it doesn't fail just because the key is unset, so the
// per-route `anthropicClient()` helper below is what actually guards that.
const anthropic = new Anthropic();

function anthropicClient(res) {
  if (!process.env.ANTHROPIC_API_KEY) {
    res.status(500).json({ error: "Server is missing ANTHROPIC_API_KEY." });
    return null;
  }
  return anthropic;
}

// Shared shape for one recipe, whether it came from a photo, typed notes, or
// a recommendation — the iOS app's RecipeImportService/SchemaOrgRecipeParser
// already knows how to turn "raw ingredient lines" into structured
// quantity/unit/name (IngredientLineParser), so Claude is only asked for
// plain lines here rather than also guessing that breakdown itself.
const RecipeDraftSchema = z.object({
  title: z.string(),
  summary: z.string().nullable(),
  ingredientLines: z.array(z.string()),
  instructions: z.array(z.string()),
  servings: z.number().int().nullable(),
  prepMinutes: z.number().int().nullable(),
  cookMinutes: z.number().int().nullable(),
});

// Google's own price-level enum -> the "$".."$$$$" convention the iOS app
// already uses for a restaurant's manually-set price range (see
// Restaurant.priceRange in the app), so results from either source render
// the same way.
const PRICE_LEVEL_MAP = {
  PRICE_LEVEL_FREE: "",
  PRICE_LEVEL_INEXPENSIVE: "$",
  PRICE_LEVEL_MODERATE: "$$",
  PRICE_LEVEL_EXPENSIVE: "$$$",
  PRICE_LEVEL_VERY_EXPENSIVE: "$$$$",
};

app.get("/health", (_req, res) => {
  res.json({
    ok: true,
    googleKeyConfigured: Boolean(GOOGLE_PLACES_API_KEY),
    databaseConfigured: Boolean(process.env.DATABASE_URL),
    twilioConfigured: Boolean(
      process.env.TWILIO_ACCOUNT_SID && process.env.TWILIO_AUTH_TOKEN && process.env.TWILIO_VERIFY_SERVICE_SID
    ),
  });
});

// --- Accounts, friends, and groups -----------------------------------
// Everything below is the accounts/social layer (Phase 1 of the accounts
// feature — see backend/README.md): phone number + SMS sign-in, a personal
// friends list, and groups built from that friends list, modeled after
// Splitwise. This is genuinely new state for the app (until now the app has
// been 100% on-device with no accounts) — see prisma/schema.prisma for the
// data model. /auth/* is unauthenticated (it's how you get a token in the
// first place); everything else here requires a valid Bearer JWT.
app.use("/auth", authRouter);
app.use("/me", requireAuth, meRouter);
app.use("/friends", requireAuth, friendsRouter);
app.use("/groups", requireAuth, groupsRouter);

// --- Group meal planning / grocery list (Phase 3) ----------------------
// A group's single shared meal plan and shared grocery list — see
// backend/README.md's "Group meal planning" / "Group grocery list"
// sections, prisma/schema.prisma's PlannedMeal/MealSuggestion/
// GroupGroceryItem doc comments, and routes/groupMealPlan.js /
// routes/groupGrocery.js. Nested under /groups/:groupId/... (mounted with
// `{ mergeParams: true }` in each router so `req.params.groupId` is
// available) rather than folded into routes/groups.js itself — a distinct
// file per resource, same organization this codebase already uses for
// recipe-library vs. groups/friends.
app.use("/groups/:groupId/meal-plan", requireAuth, groupMealPlanRouter);
// The two Phase-4 sub-routers below are mounted BEFORE the more general
// /groups/:groupId/grocery mount, on purpose: Express tries `app.use`
// mounts in declaration order and matches by path *prefix*, so
// /groups/:groupId/grocery/aisles and .../staples need to reach their own
// routers first rather than falling into groupGroceryRouter's own route
// table (which, as it happens, has no routes that would actually collide
// with "aisles"/"staples" as a param — but mounting the specific prefixes
// first avoids relying on that and matches how a reader would expect these
// three routers to be tried). See routes/groupGroceryAisles.js and
// routes/groupGroceryStaples.js for the "My Layout" / staples API.
app.use("/groups/:groupId/grocery/aisles", requireAuth, groupGroceryAislesRouter);
app.use("/groups/:groupId/grocery/staples", requireAuth, groupGroceryStaplesRouter);
app.use("/groups/:groupId/grocery", requireAuth, groupGroceryRouter);

// --- Recipe sharing (Phase 2a) ----------------------------------------
// Recipes moving from purely on-device storage to something that can be
// shared between people, built on the friends/groups layer above. Mounted
// at `/recipe-library` — a distinct prefix from the unauthenticated,
// Claude-powered `/recipes/extract` and `/recipes/recommend` routes further
// down this file, so there's no risk of the two ever colliding or being
// confused with each other even though nothing here would actually clash
// method+path with those. See routes/recipeLibrary.js and
// backend/README.md's "Recipe sharing" section.
app.use("/recipe-library", requireAuth, recipeLibraryRouter);

// Shared mapping from a Places API (New) place object to the shape both
// /restaurants/search and /restaurants/search-natural return — kept in one
// place so the two never drift apart.
function mapPlaceResult(place) {
  return {
    id: place.id,
    name: place.displayName?.text ?? "Unknown",
    address: place.formattedAddress ?? null,
    rating: typeof place.rating === "number" ? place.rating : null,
    priceRange: place.priceLevel ? (PRICE_LEVEL_MAP[place.priceLevel] ?? null) : null,
    cuisine: place.primaryTypeDisplayName?.text ?? null,
    mapsURL: place.googleMapsUri ?? null,
    // The place's actual business website, distinct from `mapsURL` — a
    // link to Google Maps. Not every place has one on file; a `null`
    // here means the app shows no Website button rather than falling
    // back to the Maps link (see RestaurantListView.addFromSearch).
    websiteURL: place.websiteUri ?? null,
    latitude: place.location?.latitude ?? null,
    longitude: place.location?.longitude ?? null,
    // Stable resource names like "places/ID/photos/REF" for every photo
    // Google has for the place (up to the 10 Text Search returns), not
    // the images themselves — those are a separate, billed request per
    // photo, only worth making for a place someone actually adds and
    // views (see GET /restaurants/photo below). These reference names
    // don't expire, unlike the signed media URLs they're later exchanged
    // for, so they're safe to store on the saved Restaurant.
    photoNames: (place.photos || []).map((photo) => photo.name).filter(Boolean),
  };
}

const PLACE_SEARCH_FIELD_MASK = [
  "places.id",
  "places.displayName",
  "places.formattedAddress",
  "places.rating",
  "places.priceLevel",
  "places.primaryTypeDisplayName",
  "places.googleMapsUri",
  "places.websiteUri",
  "places.location",
  "places.photos",
].join(",");

// Runs a Places Text Search and returns the mapped result array — shared by
// /restaurants/search and /restaurants/search-natural. `locationBias`, when
// given, is a {latitude, longitude} to search near (see either route for
// where that comes from).
async function searchPlaces(textQuery, locationBias) {
  const body = { textQuery };
  if (locationBias) {
    // A 50km bias radius is generous enough to still find a place a short
    // drive away without it, but tight enough that "pizza" close to the
    // target consistently outranks "pizza" three states over.
    body.locationBias = {
      circle: { center: locationBias, radius: 50000 },
    };
    body.rankPreference = "DISTANCE";
  }

  const response = await fetch("https://places.googleapis.com/v1/places:searchText", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Goog-Api-Key": GOOGLE_PLACES_API_KEY,
      // Places API (New) requires an explicit field mask on every
      // request — it's how Google bills you only for what you actually
      // asked for, rather than every field on the place.
      "X-Goog-FieldMask": PLACE_SEARCH_FIELD_MASK,
    },
    body: JSON.stringify(body),
  });

  if (!response.ok) {
    const detail = await response.text();
    console.error("Places API error", response.status, detail);
    throw new Error("places_search_failed");
  }

  const data = await response.json();
  return (data.places || []).map(mapPlaceResult);
}

// Turns a place name/neighborhood/city/address into coordinates via
// Google's Geocoding API — a separate API from Places, but billed to the
// same Google Cloud project/key as long as Geocoding API is also enabled
// there (see backend/README.md). Returns null on any failure (not found,
// API not enabled, network error) rather than throwing — a natural-language
// search with an ungeocodable location still runs, just without location
// bias, rather than failing outright.
async function geocode(locationText) {
  try {
    const url =
      "https://maps.googleapis.com/maps/api/geocode/json" +
      `?address=${encodeURIComponent(locationText)}&key=${GOOGLE_PLACES_API_KEY}`;
    const response = await fetch(url);
    if (!response.ok) return null;
    const data = await response.json();
    const location = data.results?.[0]?.geometry?.location;
    if (!location) return null;
    return { latitude: location.lat, longitude: location.lng };
  } catch (error) {
    console.error("Geocoding request threw", error);
    return null;
  }
}

// GET /restaurants/search?q=<free text query>
// Mirrors what the app needs for RestaurantListView's search-and-add flow:
// name, address, a map link, plus the descriptors MapKit's free search
// can't provide at all — rating, price, and cuisine.
app.get("/restaurants/search", async (req, res) => {
  const query = (req.query.q || "").toString().trim();
  if (!query) {
    return res.status(400).json({ error: "Missing required query param 'q'." });
  }
  if (!GOOGLE_PLACES_API_KEY) {
    return res.status(500).json({ error: "Server is missing GOOGLE_PLACES_API_KEY." });
  }

  // Optional — the app's best guess at the user's current location, so a
  // common restaurant name doesn't surface a same-named place on another
  // continent above the one actually nearby. Without these, Google just
  // ranks by text relevance, same as before.
  const lat = parseFloat(req.query.lat);
  const lng = parseFloat(req.query.lng);
  const hasLocation = Number.isFinite(lat) && Number.isFinite(lng);

  try {
    const results = await searchPlaces(query, hasLocation ? { latitude: lat, longitude: lng } : null);
    res.json({ results });
  } catch (error) {
    console.error("Places API request threw", error);
    res.status(502).json({ error: "Places API request failed." });
  }
});

// POST /restaurants/search-natural
// Body: { query: string, lat?: number, lng?: number } — the free-text,
// natural-language version of /restaurants/search ("casual pizza place
// near Greenwich", "somewhere kid-friendly for a quick lunch"). Google's
// Text Search already understands plenty of this on its own (a query like
// that mostly just works if handed straight to /restaurants/search), so
// what Claude actually adds here is: pulling out a *specific* location
// mentioned in the sentence (so the search can be biased there via
// geocoding, even if it's nowhere near the user's actual current
// location — "near Greenwich" while sitting in Boston, say) and turning a
// vaguer, more conversational ask into concrete search terms. `lat`/`lng`
// are the same "user's current location" fallback /restaurants/search
// takes, used only when the sentence itself didn't name a place.
const NaturalSearchQuerySchema = z.object({
  // A concise query for a restaurant search API: cuisine, food type, and
  // any vibe/descriptive words ("casual", "romantic", "kid-friendly",
  // "quick") — but with location words stripped out, since that part is
  // handled separately via `locationText`.
  searchQuery: z.string(),
  // A specific place actually named in the request — a neighborhood, city,
  // landmark, or address ("Greenwich", "near the train station downtown").
  // `null` when nothing specific was named (including "near me"/"nearby"),
  // in which case the app's own current location is used instead, same as
  // plain search.
  locationText: z.string().nullable(),
});

app.post("/restaurants/search-natural", async (req, res) => {
  const query = (req.body?.query || "").toString().trim();
  if (!query) {
    return res.status(400).json({ error: "Missing required field 'query'." });
  }
  if (!GOOGLE_PLACES_API_KEY) {
    return res.status(500).json({ error: "Server is missing GOOGLE_PLACES_API_KEY." });
  }
  const client = anthropicClient(res);
  if (!client) return;

  const lat = parseFloat(req.body?.lat);
  const lng = parseFloat(req.body?.lng);
  const hasUserLocation = Number.isFinite(lat) && Number.isFinite(lng);

  let interpreted;
  try {
    const response = await client.messages.parse({
      model: "claude-opus-5",
      max_tokens: 1000,
      output_config: { format: zodOutputFormat(NaturalSearchQuerySchema), effort: "low" },
      messages: [
        {
          role: "user",
          content:
            "A user typed this into a restaurant search box. Extract a good search " +
            `query for it, and any specific location they named. Request: "${query}"`,
        },
      ],
    });
    if (!response.parsed_output) {
      return res.status(422).json({ error: "Couldn't understand that search." });
    }
    interpreted = response.parsed_output;
  } catch (error) {
    console.error("Natural search parse failed", error);
    return res.status(502).json({ error: "Couldn't understand that search." });
  }

  // A named location wins over the user's actual current location — asking
  // for something "near Greenwich" while physically somewhere else should
  // search near Greenwich, not near the user.
  let locationBias = null;
  if (interpreted.locationText) {
    locationBias = await geocode(interpreted.locationText);
  }
  if (!locationBias && hasUserLocation) {
    locationBias = { latitude: lat, longitude: lng };
  }

  try {
    const results = await searchPlaces(interpreted.searchQuery, locationBias);
    res.json({
      results,
      interpretedQuery: interpreted.searchQuery,
      interpretedLocation: interpreted.locationText,
    });
  } catch (error) {
    console.error("Places API request threw", error);
    res.status(502).json({ error: "Places API request failed." });
  }
});

// GET /restaurants/photo?name=<photo resource name>&maxWidthPx=<n>
// Fetches an actual photo's bytes from Google using the server-side key and
// streams them back — the app never talks to Google directly (same reason
// as every other route here) and can just point an AsyncImage straight at
// this URL. `name` is one of the stable "places/ID/photos/REF" strings
// returned in `photoNames` from /restaurants/search (or saved on a
// Restaurant) — call this once per photo, not all at once.
app.get("/restaurants/photo", async (req, res) => {
  const name = (req.query.name || "").toString().trim();
  if (!name) {
    return res.status(400).json({ error: "Missing required query param 'name'." });
  }
  if (!GOOGLE_PLACES_API_KEY) {
    return res.status(500).json({ error: "Server is missing GOOGLE_PLACES_API_KEY." });
  }
  const maxWidthPx = Math.min(parseInt(req.query.maxWidthPx, 10) || 800, 1600);

  try {
    const mediaURL =
      `https://places.googleapis.com/v1/${name}/media` +
      `?maxWidthPx=${maxWidthPx}&key=${GOOGLE_PLACES_API_KEY}`;
    const photoResponse = await fetch(mediaURL);

    if (!photoResponse.ok) {
      console.error("Places photo media error", photoResponse.status);
      return res.status(502).json({ error: "Couldn't fetch that photo." });
    }

    const contentType = photoResponse.headers.get("content-type") || "image/jpeg";
    const buffer = Buffer.from(await photoResponse.arrayBuffer());
    res.set("Content-Type", contentType);
    // Photos for a given place don't change often — safe to cache for a day
    // rather than re-fetching (and re-billing) on every view.
    res.set("Cache-Control", "public, max-age=86400");
    res.send(buffer);
  } catch (error) {
    console.error("Places photo media request threw", error);
    res.status(502).json({ error: "Couldn't fetch that photo." });
  }
});

// GET /restaurants/details?placeId=<Google place id>
// Powers the restaurant detail page's hours/phone/reviews — pulled only
// when someone actually opens that restaurant (not on every search result),
// since Place Details is its own billed request. `placeId` is the `id`
// field from a /restaurants/search result, saved on the app's Restaurant
// row as `googlePlaceID`.
app.get("/restaurants/details", async (req, res) => {
  const placeId = (req.query.placeId || "").toString().trim();
  if (!placeId) {
    return res.status(400).json({ error: "Missing required query param 'placeId'." });
  }
  if (!GOOGLE_PLACES_API_KEY) {
    return res.status(500).json({ error: "Server is missing GOOGLE_PLACES_API_KEY." });
  }

  try {
    const response = await fetch(`https://places.googleapis.com/v1/places/${placeId}`, {
      headers: {
        "X-Goog-Api-Key": GOOGLE_PLACES_API_KEY,
        "X-Goog-FieldMask": [
          "rating",
          "userRatingCount",
          "nationalPhoneNumber",
          "regularOpeningHours.weekdayDescriptions",
          "reviews",
          "websiteUri",
        ].join(","),
      },
    });

    if (!response.ok) {
      const detail = await response.text();
      console.error("Place details error", response.status, detail);
      return res.status(502).json({ error: "Place details request failed." });
    }

    const place = await response.json();
    // Google returns up to 5 of the place's most relevant reviews per
    // request (there's no pagination for more) — plenty for an inline
    // preview; "Open in Google Maps" is still there for the full list.
    const reviews = (place.reviews || []).map((review) => ({
      authorName: review.authorAttribution?.displayName ?? "Google user",
      rating: typeof review.rating === "number" ? review.rating : null,
      text: review.text?.text ?? null,
      relativeTime: review.relativePublishTimeDescription ?? null,
    }));

    res.json({
      rating: typeof place.rating === "number" ? place.rating : null,
      userRatingCount: typeof place.userRatingCount === "number" ? place.userRatingCount : null,
      phoneNumber: place.nationalPhoneNumber ?? null,
      openingHours: place.regularOpeningHours?.weekdayDescriptions ?? [],
      reviews,
      websiteURL: place.websiteUri ?? null,
    });
  } catch (error) {
    console.error("Place details request threw", error);
    res.status(502).json({ error: "Place details request failed." });
  }
});

// POST /recipes/extract
// Body: { imageBase64?, mediaType?, notesText? } — at least one of
// imageBase64 or notesText required. Powers "add a recipe from a photo or
// notes" instead of typing it all in by hand: a photo of a recipe card / a
// screenshot / a handwritten note, plain typed notes, or both together.
app.post("/recipes/extract", async (req, res) => {
  const client = anthropicClient(res);
  if (!client) return;

  const { imageBase64, mediaType, notesText } = req.body || {};
  if (!imageBase64 && !notesText) {
    return res.status(400).json({ error: "Provide imageBase64 and/or notesText." });
  }

  const content = [];
  if (imageBase64) {
    content.push({
      type: "image",
      source: {
        type: "base64",
        media_type: mediaType || "image/jpeg",
        data: imageBase64,
      },
    });
  }
  content.push({
    type: "text",
    text: notesText
      ? `Extract a recipe from this image and/or these notes. Notes:\n${notesText}`
      : "Extract the recipe shown in this image.",
  });

  try {
    const response = await client.messages.parse({
      model: "claude-opus-5",
      max_tokens: 8000,
      output_config: { format: zodOutputFormat(RecipeDraftSchema), effort: "low" },
      messages: [{ role: "user", content }],
    });

    if (!response.parsed_output) {
      return res.status(422).json({ error: "Couldn't find a recipe in that." });
    }
    res.json(response.parsed_output);
  } catch (error) {
    console.error("Recipe extraction failed", error);
    res.status(502).json({ error: "Recipe extraction failed." });
  }
});

// POST /recipes/recommend
// Body: { ingredients: string[] } — "what can I make with X, Y, Z" (or
// "recommend a meal" with nothing on hand yet, an empty/short list). Returns
// a handful of recipe ideas the app inserts the same way as any other
// imported recipe.
app.post("/recipes/recommend", async (req, res) => {
  const client = anthropicClient(res);
  if (!client) return;

  const ingredients = Array.isArray(req.body?.ingredients) ? req.body.ingredients : [];

  const prompt = ingredients.length
    ? `Suggest 4 recipes a home cook could make using mainly these ingredients (they can assume basic pantry staples like salt, oil, and water in addition): ${ingredients.join(", ")}.`
    : "Suggest 4 varied, approachable weeknight dinner recipes for a home cook, using common ingredients.";

  try {
    const response = await client.messages.parse({
      model: "claude-opus-5",
      max_tokens: 16000,
      output_config: {
        format: zodOutputFormat(z.object({ recipes: z.array(RecipeDraftSchema) })),
        effort: "medium",
      },
      messages: [{ role: "user", content: prompt }],
    });

    if (!response.parsed_output) {
      return res.status(422).json({ error: "Couldn't come up with recipes for that." });
    }
    res.json(response.parsed_output);
  } catch (error) {
    console.error("Recipe recommendation failed", error);
    res.status(502).json({ error: "Recipe recommendation failed." });
  }
});

// Generic error-handling middleware — Express recognizes it by its 4-arg
// signature and routes anything passed to `next(error)` here, which is
// exactly what lib/asyncHandler.js's wrapper does with any error thrown or
// rejected inside an accounts/friends/groups route. Without this, an
// unhandled error in one of those routes would otherwise be an unhandled
// promise rejection — which crashes the whole Node process by default on
// modern Node, not just that one request. Must be registered after every
// other app.use/app.get/etc. call above.
// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
  console.error("Unhandled error in request handler:", err);
  if (res.headersSent) return;
  res.status(500).json({ error: "Internal server error." });
});

// Connect to Postgres before accepting traffic, so a misconfigured
// DATABASE_URL fails loudly at startup (visible in Render's deploy logs)
// rather than on the first request that happens to touch the database.
// The restaurant/recipe routes above don't use Prisma at all, so this only
// affects the accounts/friends/groups routes in practice.
prisma
  .$connect()
  .then(() => {
    app.listen(PORT, () => {
      console.log(`Home Eats backend listening on port ${PORT}`);
    });
  })
  .catch((error) => {
    console.error("Failed to connect to the database:", error);
    process.exit(1);
  });

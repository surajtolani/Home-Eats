// Home Eats backend — a small proxy in front of the Google Places API.
//
// Why this exists at all: the Places API needs a billed Google Cloud API
// key. Shipping that key inside the iOS app (even "restricted" to the
// app's bundle ID) means it's extracted the moment someone decompiles the
// binary. This server holds the one real key as a server-side env var; the
// app only ever talks to *this* server, which adds the key and forwards
// the request to Google. See README.md in this folder for deployment
// steps (same shape as the app's other Render-hosted backend).
"use strict";

const express = require("express");
const Anthropic = require("@anthropic-ai/sdk");
const { zodOutputFormat } = require("@anthropic-ai/sdk/helpers/zod");
const { z } = require("zod");

const app = express();
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
  res.json({ ok: true, googleKeyConfigured: Boolean(GOOGLE_PLACES_API_KEY) });
});

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

  try {
    const response = await fetch("https://places.googleapis.com/v1/places:searchText", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Goog-Api-Key": GOOGLE_PLACES_API_KEY,
        // Places API (New) requires an explicit field mask on every
        // request — it's how Google bills you only for what you actually
        // asked for, rather than every field on the place.
        "X-Goog-FieldMask": [
          "places.id",
          "places.displayName",
          "places.formattedAddress",
          "places.rating",
          "places.priceLevel",
          "places.primaryTypeDisplayName",
          "places.googleMapsUri",
          "places.location",
          "places.photos",
        ].join(","),
      },
      body: JSON.stringify({ textQuery: query }),
    });

    if (!response.ok) {
      const detail = await response.text();
      console.error("Places API error", response.status, detail);
      return res.status(502).json({ error: "Places API request failed." });
    }

    const data = await response.json();
    const results = (data.places || []).map((place) => ({
      id: place.id,
      name: place.displayName?.text ?? "Unknown",
      address: place.formattedAddress ?? null,
      rating: typeof place.rating === "number" ? place.rating : null,
      priceRange: place.priceLevel ? (PRICE_LEVEL_MAP[place.priceLevel] ?? null) : null,
      cuisine: place.primaryTypeDisplayName?.text ?? null,
      mapsURL: place.googleMapsUri ?? null,
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
    }));

    res.json({ results });
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

app.listen(PORT, () => {
  console.log(`Home Eats backend listening on port ${PORT}`);
});

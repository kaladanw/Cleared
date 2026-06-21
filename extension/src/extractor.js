(function init(root) {
  const DEFAULT_FACTS = {
    brand: null,
    model_or_name: null,
    category: null,
    size: null,
    listed_condition: null,
    asking_price: null,
    currency: "USD",
    photo_observations: [],
  };

  const IMG_URL_RE = /https?:\/\/[^\s"'<>]+?\.(?:jpe?g|png|webp)(?:\?[^\s"'<>]*)?/gi;

  function extractListingFromDocument(doc) {
    const script = doc.querySelector('script#__NEXT_DATA__');
    return extractListingFromNextDataJson(script ? script.textContent : "");
  }

  function extractListingFromNextDataJson(jsonText) {
    let data;
    try {
      data = JSON.parse(jsonText || "{}");
    } catch (_err) {
      return emptyListing();
    }

    const product = findProductObject(data);
    if (!product) {
      return emptyListing();
    }

    const imageUrls = bestImagePerPicture(product.pictures || product.images || []);
    return {
      facts: {
        brand: firstString(product, ["brandName", "brand"]),
        model_or_name: firstString(product, ["title", "name", "description"]),
        category: firstString(product, ["categoryName", "category"]),
        size: firstString(product, ["size", "variantSize"]),
        listed_condition: firstString(product, ["condition", "conditionName"]),
        asking_price: parsePrice(
          product.price || product.priceAmount || product.price_amount,
        ),
        currency: firstString(product, ["currencyName", "currency"]) || "USD",
        photo_observations: [],
      },
      image_urls: imageUrls,
      description: firstString(product, ["description", "title"]) || "",
    };
  }

  function findProductObject(rootObject) {
    let best = null;
    walk(rootObject, (node) => {
      const pictures = node.pictures || node.images;
      const hasPictures = Array.isArray(pictures) && pictures.length > 0;
      const hasPrice = ["price", "priceAmount", "price_amount"].some(
        (key) => node[key] !== undefined && node[key] !== null,
      );
      if (hasPictures && hasPrice && (!best || Object.keys(node).length > Object.keys(best).length)) {
        best = node;
      }
    });
    return best;
  }

  function walk(value, visit) {
    if (Array.isArray(value)) {
      for (const item of value) {
        walk(item, visit);
      }
      return;
    }
    if (!value || typeof value !== "object") {
      return;
    }
    visit(value);
    for (const child of Object.values(value)) {
      walk(child, visit);
    }
  }

  function bestImagePerPicture(pictures) {
    const urls = [];
    for (const picture of Array.isArray(pictures) ? pictures : []) {
      const preferred = preferredPictureUrl(picture);
      if (preferred) {
        urls.push(preferred);
        continue;
      }
      const matches = JSON.stringify(picture).match(IMG_URL_RE) || [];
      if (matches.length === 0) {
        continue;
      }
      urls.push(matches.reduce((best, candidate) => (
        candidate.length > best.length ? candidate : best
      )));
    }
    return dedupe(urls).slice(0, 8);
  }

  function preferredPictureUrl(picture) {
    if (!picture || typeof picture !== "object") {
      return null;
    }
    for (const key of ["large", "full", "original", "url", "src"]) {
      const value = picture[key];
      if (typeof value === "string" && value.match(IMG_URL_RE)) {
        return value;
      }
    }
    return null;
  }

  function dedupe(items) {
    const seen = new Set();
    return items.filter((item) => {
      if (seen.has(item)) {
        return false;
      }
      seen.add(item);
      return true;
    });
  }

  function firstString(obj, keys) {
    for (const key of keys) {
      const value = obj[key];
      if (typeof value === "string" && value.trim()) {
        return value.trim();
      }
    }
    return null;
  }

  function parsePrice(raw) {
    if (raw && typeof raw === "object") {
      return parsePrice(raw.priceAmount || raw.amount || raw.nationalShippingCost);
    }
    if (raw === undefined || raw === null || raw === "") {
      return null;
    }
    const parsed = Number.parseFloat(String(raw).replace(/[^0-9.]/g, ""));
    return Number.isFinite(parsed) ? parsed : null;
  }

  function emptyListing() {
    return {
      facts: { ...DEFAULT_FACTS, photo_observations: [] },
      image_urls: [],
      description: "",
    };
  }

  const api = {
    extractListingFromDocument,
    extractListingFromNextDataJson,
  };

  root.ClearedExtractor = api;
  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : window);

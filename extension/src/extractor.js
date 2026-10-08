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
    const listing = extractListingCore(doc);
    // Seller is best-effort and never blocks a check (null when not found).
    let seller = null;
    try {
      const html = doc.documentElement ? doc.documentElement.outerHTML : "";
      seller = extractSellerFromHtml(html);
    } catch (_err) {
      seller = null;
    }
    return { ...listing, seller };
  }

  function extractListingCore(doc) {
    // Try ld+json (schema.org Product) first — Depop dropped __NEXT_DATA__ in 2026
    const ldScript = doc.querySelector('script[type="application/ld+json"]');
    if (ldScript) {
      const result = extractListingFromLdJson(ldScript.textContent);
      if (result.image_urls.length) return result;
    }
    // Fallback: __NEXT_DATA__ (kept for any pages that still embed it)
    const nextScript = doc.querySelector('script#__NEXT_DATA__');
    return extractListingFromNextDataJson(nextScript ? nextScript.textContent : "");
  }

  // ---------------------------------------------------------------------------
  // Seller extraction (Depop). DEFENSIVE + UNVERIFIED against live markup:
  // Depop's HTML is edge-blocked server-side, so these shapes come from
  // schema.org conventions and historical Depop markup. Every source falls
  // back to null. Order: ld+json offers.seller -> __NEXT_DATA__ seller fields
  // -> anchors carrying a seller-ish data-testid. No generic "first profile
  // link" fallback: the site header can link to the *buyer's* own profile.
  // Other marketplaces need their own seller extractor.
  // ---------------------------------------------------------------------------

  const DEPOP_ORIGIN = "https://www.depop.com";
  const SELLER_USERNAME_RE = /^[a-z0-9._-]{1,64}$/;
  const SELLER_TESTIDS = new Set([
    "bio__username",
    "seller-username",
    "sellerusername",
    "seller__username",
    "shop-username",
    "product-seller-username",
  ]);
  const RESERVED_DEPOP_PATHS = new Set([
    "products", "product", "search", "category", "categories", "brands", "brand",
    "sell", "login", "signup", "about", "help", "explore", "settings", "messages",
    "likes", "saved", "feed", "news", "blog", "careers", "legal", "privacy",
    "terms", "safety", "app", "download", "us", "uk", "gb", "au", "it", "de", "fr",
  ]);

  function normalizeUsername(value) {
    if (typeof value !== "string") return null;
    const raw = value.trim().replace(/^@/, "").trim().toLowerCase();
    return SELLER_USERNAME_RE.test(raw) ? raw : null;
  }

  function usernameFromProfileUrl(href) {
    if (typeof href !== "string" || !href.trim()) return null;
    let path;
    try {
      const url = new URL(href.trim(), DEPOP_ORIGIN);
      if (!/(^|\.)depop\.com$/i.test(url.hostname)) return null;
      path = url.pathname;
    } catch (_err) {
      return null;
    }
    const segments = path.split("/").filter(Boolean);
    if (segments.length !== 1) return null;
    const candidate = decodeURIComponent(segments[0]);
    if (RESERVED_DEPOP_PATHS.has(candidate.toLowerCase())) return null;
    return normalizeUsername(candidate);
  }

  function sellerResult(username) {
    if (!username) return null;
    return { username, profile_url: `${DEPOP_ORIGIN}/${username}/` };
  }

  function sellerFromSchemaNode(node) {
    if (!node || typeof node !== "object") return null;
    const fromUrl = usernameFromProfileUrl(node.url || node["@id"] || "");
    if (fromUrl) return fromUrl;
    return normalizeUsername(node.alternateName) || normalizeUsername(node.name);
  }

  function sellerFromLdJsonText(jsonText) {
    let data;
    try {
      data = JSON.parse(jsonText || "null");
    } catch (_err) {
      return null;
    }
    const nodes = Array.isArray(data) ? data : [data];
    const expanded = [];
    for (const node of nodes) {
      if (!node || typeof node !== "object") continue;
      expanded.push(node);
      if (Array.isArray(node["@graph"])) expanded.push(...node["@graph"]);
    }
    for (const node of expanded) {
      if (!node || node["@type"] !== "Product") continue;
      const offers = Array.isArray(node.offers) ? node.offers : [node.offers];
      for (const offer of offers) {
        const username = sellerFromSchemaNode(offer && offer.seller);
        if (username) return username;
      }
      const direct = sellerFromSchemaNode(node.seller);
      if (direct) return direct;
    }
    return null;
  }

  function sellerFromNextDataText(jsonText) {
    let data;
    try {
      data = JSON.parse(jsonText || "null");
    } catch (_err) {
      return null;
    }
    let found = null;
    walk(data, (node) => {
      if (found) return;
      if (node.seller && typeof node.seller === "object") {
        found = normalizeUsername(node.seller.username) ||
          usernameFromProfileUrl(node.seller.url || "");
      }
      if (!found && typeof node.sellerUsername === "string") {
        found = normalizeUsername(node.sellerUsername);
      }
    });
    return found;
  }

  function parseAttributes(attrText) {
    const attrs = {};
    const re = /([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/g;
    let match;
    while ((match = re.exec(attrText))) {
      attrs[match[1].toLowerCase()] = match[2] !== undefined ? match[2] : match[3];
    }
    return attrs;
  }

  function sellerFromAnchors(html) {
    const re = /<a\b([^>]*)>([\s\S]*?)<\/a>/gi;
    let match;
    while ((match = re.exec(html))) {
      const attrs = parseAttributes(match[1]);
      const testid = (attrs["data-testid"] || "").toLowerCase();
      if (!SELLER_TESTIDS.has(testid)) continue;
      const fromHref = usernameFromProfileUrl(decodeEntities(attrs.href || ""));
      if (fromHref) return fromHref;
      const text = decodeEntities(match[2].replace(/<[^>]*>/g, ""));
      const fromText = normalizeUsername(text);
      if (fromText) return fromText;
    }
    return null;
  }

  function decodeEntities(value) {
    return String(value)
      .replace(/&amp;/g, "&")
      .replace(/&#x2F;/gi, "/")
      .replace(/&#47;/g, "/")
      .replace(/&quot;/g, '"')
      .replace(/&#39;/g, "'");
  }

  /**
   * Best-effort seller identity from page HTML.
   * Returns { username, profile_url } or null.
   */
  function extractSellerFromHtml(html) {
    if (typeof html !== "string" || !html) return null;

    const ldRe = /<script\b[^>]*type\s*=\s*["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi;
    let match;
    while ((match = ldRe.exec(html))) {
      const username = sellerFromLdJsonText(match[1]);
      if (username) return sellerResult(username);
    }

    const nextMatch = /<script\b[^>]*id\s*=\s*["']__NEXT_DATA__["'][^>]*>([\s\S]*?)<\/script>/i.exec(html);
    if (nextMatch) {
      const username = sellerFromNextDataText(nextMatch[1]);
      if (username) return sellerResult(username);
    }

    return sellerResult(sellerFromAnchors(html));
  }

  function extractListingFromLdJson(jsonText) {
    let data;
    try {
      data = JSON.parse(jsonText || "{}");
    } catch (_err) {
      return emptyListing();
    }

    // Handle both single Product and @graph arrays
    const product = data["@type"] === "Product" ? data
      : (data["@graph"] || []).find(n => n["@type"] === "Product");
    if (!product) return emptyListing();

    const images = Array.isArray(product.image) ? product.image
      : (product.image ? [product.image] : []);
    if (!images.length) return emptyListing();

    const offers = product.offers || {};
    const conditionUrl = offers.itemCondition || "";
    const condition = conditionUrl.includes("Used") ? "Used"
      : conditionUrl.includes("New") ? "New" : null;

    return {
      facts: {
        brand: product.brand?.name || null,
        model_or_name: product.name ? product.name.split("\n")[0].trim() : null,
        category: null,
        size: null,
        listed_condition: condition,
        asking_price: offers.price ? parseFloat(offers.price) : null,
        currency: offers.priceCurrency || "USD",
        photo_observations: [],
      },
      image_urls: images.slice(0, 8),
      description: product.description || product.name || "",
    };
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
    extractSellerFromHtml,
  };

  root.ClearedExtractor = api;
  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : window);

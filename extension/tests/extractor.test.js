const assert = require("node:assert/strict");
const { describe, it } = require("node:test");

const {
  extractListingFromNextDataJson,
} = require("../src/extractor.js");

describe("extractListingFromNextDataJson", () => {
  it("finds a nested Depop product object by shape", () => {
    const nextData = {
      props: {
        pageProps: {
          unrelated: { pictures: [], price: null },
          product: {
            brandName: "Uniqlo",
            title: "Linen blend shirt",
            categoryName: "Tops",
            variantSize: "M",
            conditionName: "Like new",
            price: "18.00",
            currencyName: "USD",
            description: "Light shirt for summer",
            pictures: [
              {
                small: "https://media-photos.depop.com/b0/small.jpg",
                large: "https://media-photos.depop.com/b0/large.jpg",
              },
              {
                url: "https://media-photos.depop.com/b1/photo.webp?updated=1",
              },
            ],
          },
        },
      },
    };

    const listing = extractListingFromNextDataJson(JSON.stringify(nextData));

    assert.deepEqual(listing.facts, {
      brand: "Uniqlo",
      model_or_name: "Linen blend shirt",
      category: "Tops",
      size: "M",
      listed_condition: "Like new",
      asking_price: 18,
      currency: "USD",
      photo_observations: [],
    });
    assert.deepEqual(listing.image_urls, [
      "https://media-photos.depop.com/b0/large.jpg",
      "https://media-photos.depop.com/b1/photo.webp?updated=1",
    ]);
    assert.equal(listing.description, "Light shirt for summer");
  });

  it("returns empty facts and image URLs when no product-shaped object exists", () => {
    const listing = extractListingFromNextDataJson(JSON.stringify({ props: { pageProps: {} } }));

    assert.deepEqual(listing, {
      facts: {
        brand: null,
        model_or_name: null,
        category: null,
        size: null,
        listed_condition: null,
        asking_price: null,
        currency: "USD",
        photo_observations: [],
      },
      image_urls: [],
      description: "",
    });
  });
});

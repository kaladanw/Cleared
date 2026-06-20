"""Phase 0 verification: run the Depop extractor against a real listing URL.

    python scripts/try_extract.py "https://www.depop.com/products/<...>/"

Prints the facts and photo URLs we managed to pull, or the user-facing error.
This is how we confirm the `__NEXT_DATA__` shape on a live page.
"""

import sys

from app.depop import DepopFetchError, fetch_listing


def main() -> None:
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)
    try:
        listing = fetch_listing(sys.argv[1])
    except DepopFetchError as exc:
        print(f"ERROR: {exc}")
        sys.exit(2)

    print("FACTS:")
    print(listing.facts.model_dump_json(indent=2))
    print(f"\nDESCRIPTION:\n{listing.description[:500]}")
    print(f"\nPHOTOS ({len(listing.image_urls)}):")
    for u in listing.image_urls:
        print(f"  {u}")


if __name__ == "__main__":
    main()

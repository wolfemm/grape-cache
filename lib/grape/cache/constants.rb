# frozen_string_literal: true

module Grape
  module Cache
    # Cacheability
    PUBLIC = "public"
    PRIVATE = "private"
    NO_CACHE = "no-cache"
    ONLY_IF_CACHED = "only-if-cached"

    # Expiration
    MAX_AGE = "max-age"
    S_MAXAGE = "s-maxage"
    MAX_STALE = "max-stale"
    MIN_FRESH = "min-fresh"
    STALE_WHILE_REVALIDATE = "stale-while-revalidate"
    STALE_IF_ERROR = "stale-if-error"

    # Revalidation and reloading
    MUST_REVALIDATE = "must-revalidate"
    PROXY_REVALIDATE = "proxy-revalidate"
    IMMUTABLE = "immutable"
  end
end

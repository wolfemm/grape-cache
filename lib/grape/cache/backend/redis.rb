# frozen_string_literal: true

require "zstd-ruby"

require_relative "memory"
require_relative "cache_entry_metadata"

module Grape
  module Cache
    module Backend
      class Redis < Memory
        ZIP_THRESHOLD = 10.kilobytes
        STATUS_KEY = "s"
        HEADERS_KEY = "h"
        METADATA_KEY = "m"
        BODY_KEY = "b"
        COMPRESSION_KEY = "c"

        FLAG_BODY = 1
        FLAG_HEADERS = 2

        def initialize(redis_connection)
          raise "Expecting redis connection here" unless redis_connection
          @storage = redis_connection
        end

        # @param key[String] Cache key
        # @param response[Rack::Response]
        # @param metadata[Grape::Cache::Backend::CacheEntryMetadata] Entry metadata
        def store(key, response, metadata)
          # Using #as_json to avoid quote escaping since this won't be parsed before being sent
          json_body = response.body.first
          header_json = MultiJson.dump(response.headers)

          compress_body = json_body.bytesize >= ZIP_THRESHOLD
          compress_headers = header_json.bytesize >= ZIP_THRESHOLD

          compression_flags = 0
          compression_flags |= FLAG_BODY if compress_body
          compression_flags |= FLAG_HEADERS if compress_headers

          args = [
            key,
            COMPRESSION_KEY, compression_flags.to_s,
            STATUS_KEY,      response.status.to_s,
            METADATA_KEY,    metadata.encode,
            HEADERS_KEY,     compress_if(compress_headers, header_json),
            BODY_KEY,        compress_if(compress_body, json_body),
          ]

          if metadata.expire_at
            storage.multi
            storage.hmset(*args)
            storage.expireat key, metadata.expire_at.to_i
            storage.exec
          else
            storage.hmset(*args)
          end
        end

        def compress_if(condition, value)
          condition ? Zstd.compress(value) : value
        end

        def decompress_if(condition, value)
          condition ? Zstd.decompress(value) : value
        end

        def fetch(key)
          status, headers, body, compression_flags = storage.hmget(
            key, STATUS_KEY, HEADERS_KEY, BODY_KEY, COMPRESSION_KEY
          )

          compression_flags = compression_flags.to_i
          body = decompress_if(compression_flags & FLAG_BODY != 0, body)
          headers = decompress_if(compression_flags & FLAG_HEADERS != 0, headers)

          Rack::Response.new(body, status.to_i, MultiJson.load(headers))
        rescue
          nil
        end

        # @param key[String] Cache key
        def fetch_metadata(key)
          Grape::Cache::Backend::CacheEntryMetadata.decode(storage.hget(key, METADATA_KEY))
        rescue
          nil
        end

        def flush!
          storage.flushdb
        end

        private

        def storage
          @_storage ||= @storage.respond_to?(:arity) ? @storage.call : @storage
        end
      end
    end
  end
end

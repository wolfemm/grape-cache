# frozen_string_literal: true

require 'murmurhash3'

module Grape
  module Cache
    class EndpointCacheConfig
      def expires_in(value = nil, &block)
        @expires_in_value = value || block
      end

      def initialize(*args)
        args.extract_options!.each{|key, value| send("#{key}=", value)}
      end

      def prepare(&block)
        @prepare_block = block
      end

      def cache_key(&block)
        @cache_key_block = block
      end

      def etag(&block)
        @etag_check_block = block
      end

      def last_modified(&block)
        @last_modified_block = block
      end

      def cacheability(value = nil, &block)
        @cacheability_value = value || block
      end

      def public
        cacheability(Grape::Cache::PUBLIC)
      end

      def private
        cacheability(Grape::Cache::PRIVATE)
      end

      def no_cache
        cacheability(Grape::Cache::NO_CACHE)
      end

      def only_if_cached
        cacheability(Grape::Cache::ONLY_IF_CACHED)
      end

      # @param endpoint[Grape::Endpoint]
      # @param middleware[Grape::Cache::Middleware]
      def validate_cache(endpoint, middleware)
        # First cache barrier - 304 cache responses for ETag and If-Last-Modified
        @prepare_block && endpoint.instance_eval(&@prepare_block)
        check_etag(endpoint)
        check_modified_since(endpoint)

        # If here, no HTTP cache hits occured
        # Retrieve request metadata
        cache_key = create_cache_key(endpoint)

        catch :cache_miss do
          if metadata = middleware.backend.fetch_metadata(cache_key)
            etag = hashed_etag(endpoint)

            throw_cache_hit(middleware, cache_key) { etag == metadata.etag } if etag

            if last_modified_configured?
              throw_cache_hit(middleware, cache_key) do
                resolved_last_modified(endpoint) <= metadata.last_modified
              end
            end

            throw_cache_hit(middleware, cache_key)
          end
        end

        endpoint.env['grape.cache.capture_key'] = cache_key
        endpoint.env['grape.cache.capture_metadata'] = create_capture_metadata(endpoint)
      end

      private

      def cache_key_array(endpoint)
        endpoint.declared(endpoint.params)
      end

      def create_cache_key(endpoint)
        cache_key_ary = cache_key_array(endpoint)
        cache_key_block = @cache_key_block
        [
            endpoint.env['REQUEST_METHOD'].to_s,
            endpoint.env['PATH_INFO'],
            endpoint.env['HTTP_ACCEPT_VERSION'].to_s,
            hashed_etag(endpoint),
            MurmurHash3::V128.str_hexdigest(
              (cache_key_block ? endpoint.instance_exec(cache_key_ary, &cache_key_block)
                               : cache_key_ary
              ).to_s
            )
        ].inject(&:+)
      end

      def check_etag(endpoint)
        return unless etag_configured?

        etag = hashed_etag(endpoint)

        if etag == endpoint.env['HTTP_IF_NONE_MATCH']
          throw :cache_hit, Rack::Response.new([], 304, 'ETag' => etag)
        end

        build_cache_headers(endpoint, { 'ETag' => etag })
      end

      def hashed_etag(endpoint)
        @hashed_etag ||= MurmurHash3::V128.str_hexdigest(
          endpoint.instance_eval(&@etag_check_block).to_s
        )
      end

      def etag_configured?
        @etag_check_block.present?
      end

      def resolved_last_modified(endpoint)
        @resolved_last_modified ||= endpoint.instance_eval(&@last_modified_block)
      end

      def last_modified_httpdate(endpoint)
        @last_modified_httpdate ||= resolved_last_modified(endpoint).httpdate
      end

      def last_modified_configured?
        @last_modified_block.present?
      end

      def resolved_expires_in(endpoint)
        @resolved_expires_in ||= resolve_value(endpoint, @expires_in_value)
      end

      def expires?
        @expires_in_value.present?
      end

      def check_modified_since(endpoint)
        return unless last_modified_configured?

        if_modified = endpoint.env['HTTP_IF_MODIFIED_SINCE'] && Time.httpdate(endpoint.env['HTTP_IF_MODIFIED_SINCE'])
        if_unmodified = endpoint.env['HTTP_IF_UNMODIFIED_SINCE'] && Time.httpdate(endpoint.env['HTTP_IF_UNMODIFIED_SINCE'])

        header_value = last_modified_httpdate(endpoint)

        if if_modified and (resolved_last_modified(endpoint) <= if_modified)
          throw :cache_hit, Rack::Response.new([], 304, 'Last-Modified' => header_value)
        end

        if if_unmodified and (resolved_last_modified(endpoint) > if_unmodified)
          throw :cache_hit, Rack::Response.new([], 304, 'Last-Modified' => header_value)
        end

        build_cache_headers(endpoint, {'Last-Modified' => header_value})
      end

      def create_capture_metadata(endpoint)
        args = {}

        args[:etag] = hashed_etag(endpoint) if etag_configured?
        args[:last_modified] = resolved_last_modified(endpoint) if last_modified_configured?
        args[:expire_at] = resolved_expires_in(endpoint).from_now if expires?

        Grape::Cache::Backend::CacheEntryMetadata.new(args)
      end

      def throw_cache_hit(middleware, cache_key, &block)
        if !block_given? || instance_eval(&block)
          if result = middleware.backend.fetch(cache_key)
            throw :cache_hit, result
          end
        end
        throw :cache_miss
      end

      def build_cache_headers(endpoint, headers = {})
        expires_in = expires? ? resolved_expires_in(endpoint) : 0
        cache_control = [(resolve_value(endpoint, @cacheability_value) || Grape::Cache::PUBLIC)]

        cache_control << "max-age=#{expires_in}" if expires_in > 0

        endpoint.header('Vary','Accept,Accept-Version')
        endpoint.header('Cache-Control', cache_control.join(", "))
        headers.each{|key, value| endpoint.header(key, value)}
      end

      def resolve_value(endpoint, value)
        if value.respond_to?(:call)
          endpoint.instance_eval(&value)
        else
          value
        end
      end
    end
  end
end

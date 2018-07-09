# frozen_string_literal: true

require 'murmurhash3'

module Grape
  module Cache
    class EndpointCacheConfig
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

      def expires_in(value = nil, &block)
        @expires_in_value = value || block
      end

      def vary(*values, &block)
        @vary_by_value =
          if block_given?
            block
          else
            values.size == 1 ? values.first : values
          end
      end

      def last_modified(&block)
        @last_modified_block = block
      end

      def cache_control(*args, **options, &block)
        @cache_control_value =
          if block_given?
            block
          else
            args.each { |directive| options[directive] = true }
            options
          end
      end

      def cacheability_public(options = {})
        cache_control(Grape::Cache::PUBLIC, options)
      end

      def cacheability_private(options = {})
        cache_control(Grape::Cache::PRIVATE, options)
      end

      def cacheability_no_cache(options = {})
        cache_control(Grape::Cache::NO_CACHE, options)
      end

      def cacheability_only_if_cached(options = {})
        cache_control(Grape::Cache::ONLY_IF_CACHED, options)
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
        cache_key = create_backend_cache_key(endpoint)

        catch :cache_miss do
          if metadata = middleware.backend.fetch_metadata(cache_key)
            etag = hashed_etag(endpoint)

            throw_cache_hit(middleware, cache_key) { etag == metadata.etag } if etag

            if last_modified_configured?
              throw_cache_hit(middleware, cache_key) do
                actual_last_modified(endpoint) <= metadata.last_modified
              end
            end

            throw_cache_hit(middleware, cache_key)
          end
        end

        endpoint.env['grape.cache.capture_key'] = cache_key
        endpoint.env['grape.cache.capture_metadata'] = create_capture_metadata(endpoint)
      end

      private

      def create_backend_cache_key(endpoint)
        cache_key_array = endpoint.declared(endpoint.params)
        cache_key_block = @cache_key_block
        [
            endpoint.env['REQUEST_METHOD'].to_s,
            endpoint.env['PATH_INFO'],
            endpoint.env['HTTP_ACCEPT_VERSION'].to_s,
            hashed_etag(endpoint),
            MurmurHash3::V128.str_hexdigest(
              (cache_key_block ? endpoint.instance_exec(cache_key_array, &cache_key_block)
                               : cache_key_array
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

      def actual_last_modified(endpoint)
        @actual_last_modified ||= endpoint.instance_eval(&@last_modified_block)
      end

      def last_modified_configured?
        @last_modified_block.present?
      end

      def actual_expires_in(endpoint)
        @actual_expires_in ||= resolve_value(endpoint, @expires_in_value)
      end

      def expires?
        @expires_in_value.present?
      end

      def check_modified_since(endpoint)
        return unless last_modified_configured?

        if_modified = endpoint.env['HTTP_IF_MODIFIED_SINCE'] && Time.httpdate(endpoint.env['HTTP_IF_MODIFIED_SINCE'])
        if_unmodified = endpoint.env['HTTP_IF_UNMODIFIED_SINCE'] && Time.httpdate(endpoint.env['HTTP_IF_UNMODIFIED_SINCE'])

        header_value = actual_last_modified(endpoint).httpdate

        if if_modified and (actual_last_modified(endpoint) <= if_modified)
          throw :cache_hit, Rack::Response.new([], 304, 'Last-Modified' => header_value)
        end

        if if_unmodified and (actual_last_modified(endpoint) > if_unmodified)
          throw :cache_hit, Rack::Response.new([], 304, 'Last-Modified' => header_value)
        end

        build_cache_headers(endpoint, {'Last-Modified' => header_value})
      end

      def create_capture_metadata(endpoint)
        args = {}

        args[:etag] = hashed_etag(endpoint) if etag_configured?
        args[:last_modified] = actual_last_modified(endpoint) if last_modified_configured?
        args[:expire_at] = (Time.current + actual_expires_in(endpoint)) if expires?

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
        directives = {}
        cache_control_config = resolve_value(endpoint, @cache_control_value)

        case cache_control_config
        when Array
          cache_control_config.each { |directive| directives[directive] = true }
        when Hash
          directives.merge!(cache_control_config)
        when String
          directives[cache_control_config] = true
        end

        expires_in = expires? ? actual_expires_in(endpoint) : 0
        if expires_in > 0 && !directives.key?(Grape::Cache::MAX_AGE)
          directives[Grape::Cache::MAX_AGE] = expires_in
        end

        if @vary_by_value.present?
          endpoint.header('Vary', format_header_value(resolve_value(endpoint, @vary_by_value)))
        end

        endpoint.header('Cache-Control', format_header_value(directives))
        headers.each { |key, value| endpoint.header(key, value) }
      end

      def resolve_value(endpoint, value)
        if value.respond_to?(:call)
          endpoint.instance_eval(&value)
        else
          value
        end
      end

      def format_header_value(value)
        case value
        when Array
          value.join(LIST_DELIMETER)
        when Hash
          value.map { |k, v| v == true ? k : "#{k}=#{v}" }.join(LIST_DELIMETER)
        else
          value
        end
      end
    end
  end
end

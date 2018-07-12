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

      def cache_key(params: true, &block)
        @cache_with_params = params
        @cache_key_block = block
      end

      def etag(weak: false, hash: true, &block)
        @hash_etag = hash
        @etag_is_weak = weak
        @etag_check_block = block
      end

      def expires_in(value = nil, &block)
        @expires_in_value = value || block
      end

      def max_age(value = nil, &block)
        @max_age_value = value || block
      end

      def without_http_caching
        max_age(0)
        cache_control(Grape::Cache::PRIVATE, Grape::Cache::MUST_REVALIDATE)
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

      def http_cache_public(*args, **options)
        cache_control(Grape::Cache::PUBLIC, *args, **options)
      end

      def http_cache_private(*args, **options)
        cache_control(Grape::Cache::PRIVATE, *args, **options)
      end

      def http_cache_no_cache(*args, **options)
        cache_control(Grape::Cache::NO_CACHE, *args, **options)
      end

      def http_cache_only_if_cached(*args, **options)
        cache_control(Grape::Cache::ONLY_IF_CACHED, *args, **options)
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
            etag = actual_etag(endpoint)

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
        cache_key_array = []

        cache_key_array << endpoint.declared(endpoint.params) if @cache_with_params

        if @cache_key_block
          cache_key_array << endpoint.instance_exec(cache_key_array, &@cache_key_block)
        end

        [
          endpoint.env['REQUEST_METHOD'].to_s,
          endpoint.env['PATH_INFO'],
          endpoint.env['HTTP_ACCEPT_VERSION'].to_s,
          MurmurHash3::V128.str_hexdigest(MessagePack.pack(cache_key_array))
        ].join
      end

      def check_etag(endpoint)
        return unless etag_configured?

        etag = actual_etag(endpoint)

        if etag == endpoint.env['HTTP_IF_NONE_MATCH']
          throw :cache_hit, Rack::Response.new([], 304, 'ETag' => etag)
        end

        build_cache_headers(endpoint, { 'ETag' => etag })
      end

      def actual_etag(endpoint)
        return unless etag_configured?

        @actual_etag ||= begin
          value = endpoint.instance_eval(&@etag_check_block).to_s
          value = MurmurHash3::V128.str_hexdigest(value) if @hash_etag
          "#{@etag_is_weak ? 'W/' : ''}\"#{value}\""
        end
      end

      def etag_configured?
        @etag_check_block.present?
      end

      def actual_last_modified(endpoint)
        return unless last_modified_configured?

        @actual_last_modified ||= endpoint.instance_eval(&@last_modified_block)
      end

      def last_modified_configured?
        @last_modified_block.present?
      end

      def actual_max_age(endpoint)
        @actual_max_age ||= resolve_value(endpoint, @max_age_value)
      end

      def max_age?
        @max_age_value.present?
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

        last_modified = actual_last_modified(endpoint).httpdate

        if if_modified && last_modified <= if_modified
          throw :cache_hit, Rack::Response.new([], 304, 'Last-Modified' => last_modified)
        end

        if if_unmodified && last_modified > if_unmodified
          throw :cache_hit, Rack::Response.new([], 304, 'Last-Modified' => last_modified)
        end

        build_cache_headers(endpoint, {'Last-Modified' => last_modified})
      end

      def create_capture_metadata(endpoint)
        args = {}

        args[:etag] = actual_etag(endpoint) if etag_configured?
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

        if max_age? && !directives.key?(Grape::Cache::MAX_AGE)
          directives[Grape::Cache::MAX_AGE] = actual_max_age(endpoint)
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

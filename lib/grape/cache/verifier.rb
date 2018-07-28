# frozen_string_literal: true

module Grape
  module Cache
    class Verifier
      # @param endpoint[Grape::Endpoint]
      # @param middleware[Grape::Cache::Middleware]
      # @param raw_options[Hash]
      def initialize(endpoint, middleware, raw_options)
        @endpoint = endpoint
        @raw_options = raw_options
        @middleware = middleware
      end

      def run
        # First cache barrier - 304 cache responses for ETag and If-Last-Modified
        @raw_options[:prepare_block] && @endpoint.instance_eval(&@raw_options[:prepare_block])

        check_etag!
        check_modified_since!

        # If here, no HTTP cache hits occured
        # Retrieve request metadata
        cache_key = create_backend_cache_key

        catch :cache_miss do
          if metadata = @middleware.backend.fetch_metadata(cache_key)
            throw_cache_hit(cache_key) { etag == metadata.etag } if etag?
            if last_modified
              throw_cache_hit(cache_key) do
                metadata.last_modified && last_modified <= metadata.last_modified
              end
            end
            throw_cache_hit(cache_key)
          end
        end

        @endpoint.env['grape.cache.capture_key'] = cache_key
        @endpoint.env['grape.cache.capture_metadata'] = create_capture_metadata
      end

      private

      def check_etag!
        return unless etag?

        if etag == @endpoint.env['HTTP_IF_NONE_MATCH']
          throw :cache_hit, Rack::Response.new([], 304, 'ETag' => etag)
        end

        build_cache_headers({ 'ETag' => etag })
      end

      def check_modified_since!
        return unless last_modified_httpdate = last_modified&.httpdate

        if_modified = request_date_header("HTTP_IF_MODIFIED_SINCE")
        if if_modified && last_modified <= if_modified
          throw :cache_hit, Rack::Response.new([], 304, 'Last-Modified' => last_modified_httpdate)
        end

        if_unmodified = request_date_header("HTTP_IF_UNMODIFIED_SINCE")
        if if_unmodified && last_modified > if_unmodified
          throw :cache_hit, Rack::Response.new([], 304, 'Last-Modified' => last_modified_httpdate)
        end

        build_cache_headers({ 'Last-Modified' => last_modified_httpdate })
      end

      def request_date_header(key)
        if raw_header = @endpoint.env[key]
          Time.rfc2822(raw_header) rescue nil
        end
      end

      def throw_cache_hit(cache_key, &block)
        if !block_given? || instance_eval(&block)
          if result = @middleware.backend.fetch(cache_key)
            throw :cache_hit, result
          end
        end
        throw :cache_miss
      end

      def build_cache_headers(headers = {})
        @endpoint.header('Vary', format_header_value(vary)) if vary?

        @endpoint.header('Cache-Control', format_header_value(cache_control_directives))
        headers.each { |key, value| @endpoint.header(key, value) }
      end

      def cache_control
        @cache_control ||= resolve_value(:cache_control_value)
      end

      def etag
        return unless etag?
        return @_etag if defined?(@_etag)

        value = @endpoint.instance_eval(&@raw_options[:etag_check_block]).to_s
        value = MurmurHash3::V128.str_hexdigest(value) if @raw_options[:hash_etag]

        @_etag = "#{weak_etag? ? Grape::Cache::WEAK_ETAG_INDICATOR : ''}\"#{value}\""
      end

      def etag?
        @raw_options[:etag_check_block].present?
      end

      def weak_etag?
        @raw_options[:etag_is_weak]
      end

      def last_modified
        return @_last_modified if defined?(@_last_modified)

        @_last_modified = resolve_value(:last_modified_block)
      end

      def max_age
        @_max_age ||= resolve_value(:max_age_value)
      end

      def max_age?
        @raw_options[:max_age_value].present?
      end

      def expires_in
        @_expires_in ||= resolve_value(:expires_in_value)
      end

      def expires?
        @raw_options[:expires_in_value].present?
      end

      def vary
        @_vary ||= resolve_value(:vary_by_value)
      end

      def vary?
        @raw_options[:vary_by_value].present?
      end

      def cache_control_directives
        directives = {}
        cache_control_config = cache_control

        case cache_control_config
        when Array
          cache_control_config.each { |directive| directives[directive] = true }
        when Hash
          directives.merge!(cache_control_config)
        when String
          directives[cache_control_config] = true
        end

        if max_age? && !directives.key?(Grape::Cache::MAX_AGE)
          directives[Grape::Cache::MAX_AGE] = max_age
        end

        directives
      end

      def create_capture_metadata
        args = {}

        args[:etag] = etag if etag?
        args[:last_modified] = last_modified if last_modified
        args[:expire_at] = (Time.current + expires_in) if expires?

        Grape::Cache::Backend::CacheEntryMetadata.new(args)
      end

      def create_backend_cache_key
        cache_key_array = []

        unless @raw_options[:cache_with_params] == false
          cache_key_array << @endpoint.declared(@endpoint.params)
        end

        if @raw_options[:cache_key_block]
          cache_key_array << @endpoint.instance_exec(
            cache_key_array, &@raw_options[:cache_key_block]
          )
        end

        cache_key_array << etag if @raw_options[:use_etag_in_cache_key]

        [
          @endpoint.env['REQUEST_METHOD'].to_s,
          @endpoint.env['PATH_INFO'],
          @endpoint.env['HTTP_ACCEPT_VERSION'].to_s,
          MurmurHash3::V128.str_hexdigest(MultiJson.dump(cache_key_array))
        ].join
      end

      private

      def resolve_value(key)
        value = @raw_options[key]

        if value.respond_to?(:call)
          @endpoint.instance_eval(&value)
        else
          value
        end
      end

      def format_header_value(value)
        case value
        when Array
          value.join(Grape::Cache::LIST_DELIMETER)
        when Hash
          value.map { |k, v| v == true ? k : "#{k}=#{v}" }.join(Grape::Cache::LIST_DELIMETER)
        else
          value
        end
      end
    end
  end
end

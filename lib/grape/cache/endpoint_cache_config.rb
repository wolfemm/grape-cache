# frozen_string_literal: true

require 'murmurhash3'

require_relative "verifier"

module Grape
  module Cache
    class EndpointCacheConfig
      def initialize(*args)
        args.extract_options!.each{|key, value| send("#{key}=", value)}
        @raw_options = {}
      end

      def prepare(&block)
        @raw_options[:prepare_block] = block
      end

      def cache_key(params: true, &block)
        @raw_options[:cache_with_params] = params
        @raw_options[:cache_key_block] = block if block_given?
      end

      def etag(weak: true, hash: true, cache_key: false, &block)
        @raw_options[:use_etag_in_cache_key] = cache_key
        @raw_options[:hash_etag] = hash
        @raw_options[:etag_is_weak] = weak
        @raw_options[:etag_check_block] = block
      end

      def expires_in(value = nil, &block)
        @raw_options[:expires_in_value] = value || block
      end

      def max_age(value = nil, &block)
        @raw_options[:max_age_value] = value || block
      end

      def without_http_caching
        max_age(0)
        cache_control(Grape::Cache::PRIVATE, Grape::Cache::MUST_REVALIDATE)
      end

      def vary(*values, &block)
        @raw_options[:vary_by_value] =
          if block_given?
            block
          else
            values.size == 1 ? values.first : values
          end
      end

      def last_modified(&block)
        @raw_options[:last_modified_block] = block
      end

      def cache_control(*args, **options, &block)
        @raw_options[:cache_control_value] =
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

      def options
        @raw_options
      end
    end
  end
end

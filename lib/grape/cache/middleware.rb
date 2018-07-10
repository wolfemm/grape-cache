# frozen_string_literal: true

require_relative 'backend/memory'

module Grape
  module Cache
    class Middleware < Grape::Middleware::Base
      def default_options
        { backend: Grape::Cache::Backend::Memory.new }
      end

      def backend
        @options[:backend]
      end

      def call(env)
        env['grape.cache'] = self
        result = catch(:cache_hit) { @app.call(env) }
        if env['grape.cache.capture_key']
          backend.store(env['grape.cache.capture_key'], result, env['grape.cache.capture_metadata'])
        end
        result
      end
      alias_method :call!, :call
    end
  end
end

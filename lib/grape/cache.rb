# frozen_string_literal: true

require "grape/cache/patches"
require "grape/cache/dsl"
require "grape/cache/version"
require "grape/cache/backend/memory"
require "grape/cache/backend/redis"
require "grape/cache/middleware"
require "grape/cache/constants"

module Grape
  class API
    class Instance
      include Grape::Cache::DSL
    end
  end
end

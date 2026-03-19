require_relative "boot"

require "rails/all"

Bundler.require
require "sequenced"

module Dummy
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f
    config.encoding = "utf-8"
    config.filter_parameters += [:password]
    config.eager_load = false
  end
end

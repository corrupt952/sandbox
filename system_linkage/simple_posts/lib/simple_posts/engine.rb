require 'carrierwave'

module SimplePosts
  class Engine < ::Rails::Engine
    config.autoload_paths << root.join('app', 'representers')
  end
end

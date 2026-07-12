$:.push File.expand_path("../lib", __FILE__)

# Maintain your gem's version:
require "simple_posts/version"

# Describe your gem and declare its dependencies:
Gem::Specification.new do |s|
  s.name        = "simple_posts"
  s.version     = SimplePosts::VERSION
  s.authors     = ["Kazuki Hasegawa"]
  s.email       = ["hasegawa@khasegawa.net"]
  s.homepage    = "https://github.com/corrupt952/survey"
  s.summary     = "TODO: Summary of SimplePosts."
  s.description = "TODO: Description of SimplePosts."
  s.license     = "MIT"

  s.files = Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.rdoc"]
  s.test_files = Dir["test/**/*"]

  s.add_dependency "rails", "~> 4.2.1"
  s.add_dependency 'roar'
  s.add_dependency 'carrierwave'
  s.add_dependency 'fog'
  s.add_dependency 'fog-aws'
  s.add_dependency 'rmagick'

  s.add_development_dependency "sqlite3"
end

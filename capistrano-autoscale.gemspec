$:.push File.expand_path("../lib", __FILE__)

# Maintain your gem's version:
require "capistrano/autoscale/version"

# Describe your gem and declare its dependencies:
Gem::Specification.new do |s|
  s.name        = "capistrano-autoscale"
  s.version     = Capistrano::Autoscale::VERSION
  s.authors     = ["Benjamín Silva"]
  s.email       = ["silva96@gmail.com"]
  s.homepage    = "https://www.recorrido.cl"
  s.summary     = "Custom gem for even / odd rolling deployments using capistrano and amazon web services (autoscaling and target group)"
  s.description = "Custom gem for even / odd rolling deployments using capistrano and amazon web services (autoscaling and target group)"
  s.license     = "MIT"

  s.files = Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md"]

  s.add_dependency "rails", "~> 5.0.2"

end

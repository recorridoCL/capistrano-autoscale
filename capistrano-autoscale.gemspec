$:.push File.expand_path("../lib", __FILE__)

# Maintain your gem's version:
require "capistrano/autoscale/version"

# Describe your gem and declare its dependencies:
Gem::Specification.new do |s|
  s.name        = "capistrano-autoscale"
  s.version     = Capistrano::Autoscale::VERSION
  s.authors     = ["recorridoCl"]
  s.email       = ["benjamin@recorrido.cl"]
  s.homepage    = "https://www.github.com/recorridoCL/capistrano-autoscale"
  s.summary     = "Custom gem for even / odd rolling deployments using capistrano and amazon web services (autoscaling and target group)"
  s.description = "Custom gem for even / odd rolling deployments using capistrano and amazon web services (autoscaling and target group)"
  s.license     = "MIT"

  s.files = Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md"]

  s.add_dependency "capistrano", ">= 3.8"
  s.add_dependency "aws-sdk", ">= 2.9"
end

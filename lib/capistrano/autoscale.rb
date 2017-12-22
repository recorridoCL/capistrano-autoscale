#require 'capistrano/autoscale/configuration'
load File.expand_path('../autoscale/tasks/autoscale.rake', __FILE__)
require 'capistrano/all'

def setup_servers
  puts "I'm setting up servers #{fetch(:instance_type)}"
end

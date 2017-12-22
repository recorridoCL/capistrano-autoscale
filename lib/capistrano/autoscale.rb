#require 'capistrano/autoscale/configuration'
load File.expand_path('../autoscale/tasks/autoscale.rake', __FILE__)

def setup_servers
  info "I'm setting up servers #{fetch(:instance_type)}"
end

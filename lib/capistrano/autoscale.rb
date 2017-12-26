require 'capistrano/all'
require 'capistrano/autoscale/helpers/aws_utils'
require 'aws-sdk'
load File.expand_path('../autoscale/tasks/autoscale.rake', __FILE__)


def setup_servers
  puts "Search instances to deploy"
  ec2_instances = Capistrano::Autoscale::AwsUtils.fetch_ec2_instances(fetch(:instance_order))
  aws_deploy_user = fetch(:deploy_user)
  set :instances, ec2_instances.map {|i| {id: i[:instance_id]}}
  ec2_instances.each {|instance|
    if ec2_instances.first == instance
      roles = %w{web app db}
      server instance[:private_ip_address], user: aws_deploy_user, roles:  roles, primary: true
      puts "First Server: #{instance[:private_ip_address]} - #{roles}, instance_id: #{instance[:instance_id]}"
    else
      roles = %w{web app}
      server instance[:private_ip_address], user: aws_deploy_user, roles: roles
      puts "Server: #{instance[:private_ip_address]} - #{roles}, instance_id: #{instance[:instance_id]}"
    end
  }
end

require 'aws-sdk-ec2'
require 'aws-sdk-elasticloadbalancingv2'
require 'aws-sdk-autoscaling'
require 'capistrano/all'
require 'capistrano/autoscale/helpers/aws_utils'

load File.expand_path('../autoscale/tasks/autoscale.rake', __FILE__)

def setup_servers
  puts 'Set up instances to deploy for capistrano configuration'
  instance_order = ENV['INSTANCE_ORDER'] || fetch(:instance_order, 'even')
  ec2_instances = Capistrano::Autoscale::AwsUtils.fetch_ec2_instances(instance_order)
  aws_deploy_user = fetch(:deploy_user)

  # Set up :instances being used (used for deregistering and registering instances in load balancer)
  set :instances, ec2_instances.map { |instance| { id: instance[:instance_id] } }

  ec2_instances.each_with_index do |instance, index|
    primary = index.zero?
    server_config = {
      user: aws_deploy_user,
      roles: primary ? %w[web app db] : %w[web app]
    }
    server_config[:primary] = primary if primary

    server instance[:private_ip_address], server_config
    puts "#{primary ? 'First Server' : 'Server'}: #{instance[:private_ip_address]} - #{server_config[:roles]}, id: #{instance[:instance_id]}"
  end
end

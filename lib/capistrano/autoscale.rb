require 'aws-sdk-ec2'
require 'aws-sdk-elasticloadbalancingv2'
require 'aws-sdk-autoscaling'
require 'capistrano/all'
require 'capistrano/autoscale/helpers/aws_utils'
require 'capistrano/autoscale/helpers/local_runner'
require 'capistrano/autoscale/helpers/blue_green'

load File.expand_path('../autoscale/tasks/autoscale.rake', __FILE__)

def setup_servers
  puts 'Set up instances to deploy for capistrano configuration'
  wave_key = Capistrano::Autoscale::BlueGreen::INSTANCE_IDS_ENV
  wave_ids_env = ENV[wave_key].to_s.strip
  ec2_instances =
    if wave_ids_env.empty?
      all = Capistrano::Autoscale::AwsUtils.fetch_all_ec2_instances
      puts "Deploy target group fleet: #{all.size} instance(s)"
      all
    else
      ids = wave_ids_env.split(',').map(&:strip).reject(&:empty?)
      puts "Blue/green wave: #{ids.size} instance(s) from #{wave_key}"
      Capistrano::Autoscale::AwsUtils.instances_for_ids(ids)
    end
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

module Capistrano
  module Configuration
    module Autoscale
      def setup_servers
        info "I'm setting up servers #{fetch(:instance_type)}"
        # puts "Search instances to deploy"
        # ec2_instances = fetch_ec2_instances(fetch(:instance_type))
        # aws_deploy_user = 'ubuntu'
        # set :instances, ec2_instances.map {|i| i[:instance_id]}
        # ec2_instances.each {|instance|
        #   if ec2_instances.first == instance
        #     roles = %w{web app db}
        #     server instance[:private_ip_address], user: aws_deploy_user, roles:  roles, primary: true
        #     puts "First Server: #{instance[:private_ip_address]} - #{roles}, instance_id: #{instance[:instance_id]}"
        #   else
        #     roles = %w{web app}
        #     server instance[:private_ip_address], user: aws_deploy_user, roles: roles
        #     puts "Server: #{instance[:private_ip_address]} - #{roles}, instance_id: #{instance[:instance_id]}"
        #   end
        # }

      end
    end
  end
end
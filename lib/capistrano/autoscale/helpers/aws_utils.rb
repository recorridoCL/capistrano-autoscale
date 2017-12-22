module Capistrano
  module Autoscale
    class AwsUtils
      include Capistrano::DSL
      def self.fetch_ec2_instances(type)
        ::Aws.config[:region] = fetch(:aws_region)
        ::Aws.config[:credentials] = ::Aws::Credentials.new(fetch(:aws_access_owner_id), fetch(:aws_secret_owner_access_key))

        loadbalancer = ::Aws::ElasticLoadBalancingV2::Client.new
        ec2 = ::Aws::EC2::Client.new

        loadbalancer_data = loadbalancer.describe_target_health({
                                                                    target_group_arn: fetch(:autoscaling_target_group_arn)
                                                                })

        instances_ids = loadbalancer_data.target_health_descriptions.map{|h| h.target.id}.sort

        type_instances = instances_ids.values_at(* instances_ids.each_index.select {|i| i.send("#{type}?")})
        description_instances = ec2.describe_instances({instance_ids: type_instances}).reservations

        instances = description_instances.map{|h| h.instances.map {|i| {instance_id: i.instance_id, private_ip_address: i.private_ip_address}}}.flatten

        puts "Found #{type} #{instances.count} servers (#{instances.join(',')})"

        instances
      end
    end
  end
end

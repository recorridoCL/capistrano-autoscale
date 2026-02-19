module Capistrano
  module Autoscale
    class AwsUtils
      include Capistrano::DSL
      def self.configure_aws(region:, access_key:, secret_key:)
        ::Aws.config[:region] = region
        ::Aws.config[:credentials] = ::Aws::Credentials.new(access_key, secret_key)
      end

      def self.fetch_ec2_instances(type)
        configure_aws(
          region: fetch(:aws_region),
          access_key: fetch(:aws_access_owner_id),
          secret_key: fetch(:aws_secret_owner_access_key)
        )

        loadbalancer = ::Aws::ElasticLoadBalancingV2::Client.new
        ec2 = ::Aws::EC2::Client.new

        autoscaling_group_name = fetch(:autoscaling_group_name)
        autoscaling_group = Capistrano::Autoscale::AwsUtils.fetch_autoscaling_group(autoscaling_group_name)
        tg_arn = autoscaling_group.target_group_arns&.first

        loadbalancer_data = loadbalancer.describe_target_health(target_group_arn: tg_arn)

        instances_ids = loadbalancer_data.target_health_descriptions.map { |h| h.target.id }.sort

        type_instances = instances_ids.values_at(*instances_ids.each_index.select { |i| i.send("#{type}?") })
        description_instances = ec2.describe_instances({ instance_ids: type_instances }).reservations

        instances = description_instances.map { |h| h.instances.map { |i| { instance_id: i.instance_id, private_ip_address: i.private_ip_address } } }.flatten

        puts "Found #{type} #{instances.count} servers (#{instances.join(',')})"

        instances
      end

      def self.extract_launch_template_id(autoscaling_group)
        launch_template_id =
          if autoscaling_group.launch_template
            puts "Using launch template ID from SDK v1 structure"
            lt = autoscaling_group.launch_template
            lt.launch_template_id || lt['launch_template_id'] || lt[:launch_template_id]
          else
            puts "Using launch template ID from capistrano config variable"
            fetch(:autoscaling_launch_template_id, nil)
          end

        if launch_template_id.nil?
          raise 'Launch template ID not found neither in ASG or via :autoscaling_launch_template_id config'
        end

        launch_template_id
      end

      def self.fetch_autoscaling_group(autoscaling_group_name)
        autoscaling = ::Aws::AutoScaling::Client.new
        response = autoscaling.describe_auto_scaling_groups(
          auto_scaling_group_names: [autoscaling_group_name]
        )
        autoscaling_group = response.auto_scaling_groups&.first

        if autoscaling_group.nil?
          raise "Auto Scaling Group '#{autoscaling_group_name}' not found"
        end

        autoscaling_group
      end
    end
  end
end

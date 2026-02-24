module Capistrano
  module Autoscale
    class AwsUtils
      include Capistrano::DSL
      def self.configure_aws(region:, access_key:, secret_key:)
        ::Aws.config[:region] = region
        ::Aws.config[:credentials] = ::Aws::Credentials.new(access_key, secret_key)
      end

      def self.fetch_all_ec2_instances
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
        return [] if instances_ids.empty?

        description_instances = ec2.describe_instances(instance_ids: instances_ids).reservations

        instances = description_instances.map do |h|
          h.instances.map do |i|
            { instance_id: i.instance_id, private_ip_address: i.private_ip_address }
          end
        end.flatten
        instances_by_id = instances.each_with_object({}) do |instance, memo|
          memo[instance[:instance_id]] = instance
        end

        instances_ids.map { |id| instances_by_id[id] }.compact
      end

      def self.fetch_ec2_instances(type)
        instances = fetch_all_ec2_instances

        selected_instances = instances.values_at(* instances.each_index.select {|i| i.send("#{type}?")})

        puts "Found #{type} #{selected_instances.count} servers (#{selected_instances.join(',')})"

        selected_instances
      end

      def self.create_ami(ec2:, instance_id:, volume_sizes:, deployment_env:, date_now:)
        ec2.create_image(
          block_device_mappings: [
            {
              device_name: '/dev/sda1',
              ebs: {
                encrypted: false,
                delete_on_termination: true,
                volume_size: volume_sizes[0],
                volume_type: 'gp2'
              }
            },
            {
              device_name: '/dev/sdf',
              ebs: {
                encrypted: false,
                delete_on_termination: true,
                volume_size: volume_sizes[1],
                volume_type: 'gp2'
              }
            }
          ],
          description: "#{deployment_env} autoscale with ebs termination #{date_now}",
          dry_run: false,
          instance_id: instance_id,
          name: "#{deployment_env}-autoscale #{date_now}",
          no_reboot: true
        )
      end

      def self.create_launch_template_version_from_ami(ec2:, launch_template_id:, image_id:, instance_type:, deployment_env:, date_now:)
        version_name = "Autoscale-#{deployment_env}-template-version-#{date_now}"

        launch_template_single_version = ec2.describe_launch_template_versions(
          launch_template_id: launch_template_id,
          versions: ['$Default']
        ).launch_template_versions.first

        security_groups = launch_template_single_version.launch_template_data.security_group_ids
        iam_instance_profile_name = launch_template_single_version.launch_template_data.iam_instance_profile&.name
        key_name = launch_template_single_version.launch_template_data.key_name
        tag_specs = launch_template_single_version.launch_template_data.tag_specifications.map { |ts| ts.to_h }

        lt_request_params = {
          launch_template_id: launch_template_id,
          version_description: version_name,
          launch_template_data: {
            image_id: image_id,
            instance_type: instance_type,
            iam_instance_profile: {
              name: iam_instance_profile_name || 'autoscaling-iam'
            },
            monitoring: {
              enabled: true
            },
            security_group_ids: security_groups,
            metadata_options: {
              instance_metadata_tags: 'enabled'
            },
            ebs_optimized: false
          }
        }
        lt_request_params[:launch_template_data][:key_name] = key_name if key_name
        lt_request_params[:launch_template_data][:tag_specifications] = tag_specs if tag_specs.any?

        resp = ec2.create_launch_template_version(lt_request_params)
        new_template_version_number = resp.launch_template_version.version_number

        puts "- launch template id: #{launch_template_single_version.launch_template_id}"
        puts "- launch template chosen version number: #{launch_template_single_version.version_number}"
        puts "- launch template versions security groups: #{Array(security_groups).join(', ')}"
        puts "- launch template versions IAM profile name: #{iam_instance_profile_name}"
        puts "- launch template versions key name: #{key_name}"
        puts "- launch template params: #{lt_request_params.to_h}"
        puts "Finished create launch template new version (V. Number: #{new_template_version_number})"

        new_template_version_number
      end

      def self.extract_launch_template_id(autoscaling_group)
        launch_template_id =
          if autoscaling_group.launch_template
            puts 'Using launch template ID from SDK v1 structure'
            lt = autoscaling_group.launch_template
            lt.launch_template_id || lt['launch_template_id'] || lt[:launch_template_id]
          else
            puts 'Using launch template ID from capistrano config variable'
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

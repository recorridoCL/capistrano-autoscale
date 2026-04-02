module Capistrano
  module Autoscale
    class AwsUtils
      include Capistrano::DSL

      REGISTER_HEALTH_POLL_INTERVAL_DEFAULT = 5
      REGISTER_HEALTH_POLL_TIMEOUT_DEFAULT = 120

      # Validates poll settings (positive integers); raises if invalid.
      def self.validate_register_health_poll_config!(interval_sec:, timeout_sec:)
        interval = Integer(interval_sec)
        timeout = Integer(timeout_sec)
        unless interval.positive? && timeout.positive?
          raise 'Capistrano::Autoscale: :register_poll_interval_sec and ' \
                ':register_poll_timeout_sec must be positive integers'
        end
      rescue ArgumentError, TypeError
        # Integer() failed (nil, non-numeric string, etc.); re-raise with inputs for easier debugging.
        raise 'Capistrano::Autoscale: :register_poll_interval_sec / :register_poll_timeout_sec must be positive integers ' \
              "(got interval=#{interval_sec.inspect} timeout=#{timeout_sec.inspect})"
      end

      # Poll until every target in the group is +healthy+ (and there is at least one target).
      # Reads +:register_poll_interval_sec+ and +:register_poll_timeout_sec+ (must be valid; see validate at autoscaled:deploy).
      # Uses ceil(timeout / interval) attempts (at least 1), sleeping +interval+ between tries.
      def self.wait_until_target_group_fully_healthy(load_balancer:, target_group_arn:)
        interval_sec = fetch(:register_poll_interval_sec, REGISTER_HEALTH_POLL_INTERVAL_DEFAULT)
        timeout_sec = fetch(:register_poll_timeout_sec, REGISTER_HEALTH_POLL_TIMEOUT_DEFAULT)
        max_attempts = (timeout_sec.to_f / interval_sec.to_f).ceil
        max_attempts = 1 if max_attempts < 1

        max_attempts.times do |attempt|
          resp = load_balancer.describe_target_health(target_group_arn: target_group_arn)
          descs = resp.target_health_descriptions
          total = descs.size
          healthy = descs.count { |d| d.target_health.state == 'healthy' }

          if total.positive? && healthy == total
            puts "Target group: all #{total} target(s) healthy."
            return
          end

          puts "Target group health: #{healthy}/#{total} healthy (attempt #{attempt + 1}/#{max_attempts})"
          if attempt >= max_attempts - 1
            raise(
              'Capistrano::Autoscale: target group register health poll timed out ' \
              "(#{healthy}/#{total} healthy after #{max_attempts} attempts, " \
              "interval #{interval_sec}s, budget #{timeout_sec}s). " \
              'Increase :register_poll_timeout_sec or fix targets / checks.'
            )
          end

          sleep interval_sec
        end
      end

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

      # Resolve IPs for a fixed wave (same order as +instance_ids+). Used when +CAP_BLUE_GREEN_INSTANCE_IDS+ is set.
      def self.instances_for_ids(instance_ids)
        ids = Array(instance_ids).map(&:to_s).map(&:strip).reject(&:empty?)
        return [] if ids.empty?

        configure_aws(
          region: fetch(:aws_region),
          access_key: fetch(:aws_access_owner_id),
          secret_key: fetch(:aws_secret_owner_access_key)
        )

        ec2 = ::Aws::EC2::Client.new
        reservations = ec2.describe_instances(instance_ids: ids).reservations
        by_id = {}
        reservations.flat_map(&:instances).each do |i|
          by_id[i.instance_id] = { instance_id: i.instance_id, private_ip_address: i.private_ip_address }
        end

        ids.map { |id| by_id[id] }.tap do |list|
          missing = ids - list.compact.map { |h| h[:instance_id] }
          raise "Could not resolve instance IDs: #{missing.join(', ')}" if missing.any?
        end
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
        user_data = launch_template_single_version.launch_template_data.user_data

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
            ebs_optimized: false,
            user_data: user_data
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

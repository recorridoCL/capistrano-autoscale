namespace :deploy do
  desc "Register instances in load balancer"
  task :register_instances_in_load_balancer do
    on roles(:db) do
      within release_path do
        with rails_env: fetch(:rails_env) do
          Capistrano::Autoscale::AwsUtils.configure_aws(
            region: fetch(:aws_region),
            access_key: fetch(:aws_access_owner_id),
            secret_key: fetch(:aws_secret_owner_access_key)
          )

          loadbalancer = ::Aws::ElasticLoadBalancingV2::Client.new

          autoscaling_group_name = fetch(:autoscaling_group_name)
          autoscaling_group = Capistrano::Autoscale::AwsUtils.fetch_autoscaling_group(autoscaling_group_name)
          tg_arn = autoscaling_group.target_group_arns&.first

          instances = fetch(:instances)
          info "Adding instances #{instances} to target group: #{tg_arn}"

          loadbalancer.register_targets(target_group_arn: tg_arn, targets: instances)
          sleep 20
        end
      end
    end
  end

  desc "Deregister instances from load balancer"
  task :deregister_instances_from_load_balancer do
    on roles(:db) do
      within release_path do
        with rails_env: fetch(:rails_env) do
          Capistrano::Autoscale::AwsUtils.configure_aws(
            region: fetch(:aws_region),
            access_key: fetch(:aws_access_owner_id),
            secret_key: fetch(:aws_secret_owner_access_key)
          )

          loadbalancer = ::Aws::ElasticLoadBalancingV2::Client.new

          autoscaling_group_name = fetch(:autoscaling_group_name)
          autoscaling_group = Capistrano::Autoscale::AwsUtils.fetch_autoscaling_group(autoscaling_group_name)
          tg_arn = autoscaling_group.target_group_arns&.first

          instances = fetch(:instances)
          info "Removing instances #{instances} from target group: #{tg_arn}"

          loadbalancer.deregister_targets(target_group_arn: tg_arn, targets: instances)
        end
      end
    end
  end

  desc "New AMI from deploy and associate to scaling group"
  task :new_ami_configuration do
    on roles(:db) do
      within release_path do
        with rails_env: fetch(:rails_env) do
          deployment_env = fetch(:deployment_env)
          Capistrano::Autoscale::AwsUtils.configure_aws(
            region: fetch(:aws_region),
            access_key: fetch(:aws_access_owner_id),
            secret_key: fetch(:aws_secret_owner_access_key)
          )

          date_now = Time.now.strftime('%d-%m-%Y %H.%M')

          ec2 = ::Aws::EC2::Client.new
          autoscaling_group = Capistrano::Autoscale::AwsUtils.fetch_autoscaling_group(fetch(:autoscaling_group_name))
          instances = autoscaling_group.instances.map {|h| h['instance_id']}

          # Extract launch template ID from autoscaling group
          launch_template_id = Capistrano::Autoscale::AwsUtils.extract_launch_template_id(autoscaling_group)
          info "Using launch template ID: #{launch_template_id}"

          # Create AMI
          info "Starting creating AMI"
          new_ami = ec2.create_image(
            block_device_mappings: [
              {
                device_name: '/dev/sda1',
                ebs: {
                  encrypted: false,
                  delete_on_termination: true,
                  volume_size: fetch(:volume_sizes)[0],
                  volume_type: 'gp2'
                }
              },
              {
                device_name: '/dev/sdf',
                ebs: {
                  encrypted: false,
                  delete_on_termination: true,
                  volume_size: fetch(:volume_sizes)[1],
                  volume_type: 'gp2'
                }
              }
            ],
            description: "#{deployment_env} autoscale with ebs termination #{date_now}",
            dry_run: false,
            instance_id: instances.last,
            name: "#{deployment_env}-autoscale #{date_now}",
            no_reboot: true
          )
          info "Finished create AMI #{new_ami.image_id}"

          # Create launch template version from new AMI
          info "Starting create launch template new version"
          version_name = "Autoscale-#{deployment_env}-template-version-#{date_now}"

          info "Getting launch template data..."
          launch_template_single_version = ec2.describe_launch_template_versions(
            launch_template_id: launch_template_id,
            versions: ["$Default"]
          ).launch_template_versions.first
          info "- launch template id: #{launch_template_single_version.launch_template_id}"
          info "- launch template chosen version number: #{launch_template_single_version.version_number}"
          security_groups = launch_template_single_version.launch_template_data.security_group_ids
          info "- launch template versions security groups: #{security_groups.join(', ')}"
          iam_instance_profile_name = launch_template_single_version.launch_template_data.iam_instance_profile&.name
          info "- launch template versions IAM profile name: #{iam_instance_profile_name}"
          key_name = launch_template_single_version.launch_template_data.key_name
          info "- launch template versions key name: #{key_name}"
          tag_specs = launch_template_single_version.launch_template_data.tag_specifications.map { |ts| ts.to_h }

          lt_request_params = {
            launch_template_id: launch_template_id,
            version_description: version_name,
            launch_template_data: {
              image_id: new_ami.image_id,
              instance_type: fetch(:instance_type),
              iam_instance_profile: {
                name: iam_instance_profile_name || "autoscaling-iam"
              },
              monitoring: {
                enabled: true
              },
              security_group_ids: security_groups,
              metadata_options: {
                instance_metadata_tags: "enabled"
              },
              ebs_optimized: false
            }
          }
          lt_request_params[:launch_template_data][:key_name] = key_name if key_name
          lt_request_params[:launch_template_data][:tag_specifications] = tag_specs if tag_specs.any?
          info "- launch template params: #{lt_request_params.to_h}"

          resp = ec2.create_launch_template_version(lt_request_params)

          new_template_version_number = resp.launch_template_version.version_number
          info "Finished create launch template new version (V. Number: #{new_template_version_number})"

          # Update autoscaling group
          info "Setting new version as default in the launch template"
          ec2.modify_launch_template(
            launch_template_id: launch_template_id,
            default_version: new_template_version_number.to_s
          )
        end
      end
    end
  end
end

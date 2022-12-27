namespace :deploy do
  desc "Register instances in load balancer"
  task :register_instances_in_load_balancer do
    on roles(:db) do
      within release_path do
        with rails_env: fetch(:rails_env) do
          ::Aws.config[:region] = fetch(:aws_region)
          ::Aws.config[:credentials] = ::Aws::Credentials.new(fetch(:aws_access_owner_id), fetch(:aws_secret_owner_access_key))

          loadbalancer = ::Aws::ElasticLoadBalancingV2::Client.new

          instances = fetch(:instances)
          info "Adding instances #{instances}"

          loadbalancer.register_targets(
              {
                  target_group_arn: fetch(:autoscaling_target_group_arn),
                  targets: instances
              })
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
          ::Aws.config[:region] = fetch(:aws_region)
          ::Aws.config[:credentials] = ::Aws::Credentials.new(fetch(:aws_access_owner_id), fetch(:aws_secret_owner_access_key))

          loadbalancer = ::Aws::ElasticLoadBalancingV2::Client.new

          instances = fetch(:instances)
          info "Removing instances #{instances}"

          loadbalancer.deregister_targets(
              {
                  target_group_arn: fetch(:autoscaling_target_group_arn),
                  targets: instances
              })
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
          ::Aws.config[:region] = fetch(:aws_region)
          ::Aws.config[:credentials] = ::Aws::Credentials.new(fetch(:aws_access_owner_id), fetch(:aws_secret_owner_access_key))

          date_now = Time.now.strftime('%d-%m-%Y %H.%M')

          ec2 = ::Aws::EC2::Client.new
          autoscaling = ::Aws::AutoScaling::Client.new
          autoscaling_group_name = fetch(:autoscaling_group_name)

          instances = autoscaling.describe_auto_scaling_groups(
              {
                  auto_scaling_group_names: [
                      autoscaling_group_name
                  ]
              }
          ).auto_scaling_groups[0].instances.map {|h| h['instance_id']}

          # Create AMI
          info "Starting creating AMI"
          new_ami = ec2.create_image(
              {
                  block_device_mappings: [
                      {
                          device_name: '/dev/sda1',
                          ebs: {
                              encrypted: false,
                              delete_on_termination: true,
                              volume_size: fetch(:volume_sizes)[0],
                              volume_type: 'gp2',
                          }
                      },
                      {
                          device_name: '/dev/sdf',
                          ebs: {
                              encrypted: false,
                              delete_on_termination: true,
                              volume_size: fetch(:volume_sizes)[1],
                              volume_type: 'gp2',
                          }
                      }
                  ],
                  description: "#{deployment_env} autoscale with ebs termination #{date_now}",
                  dry_run: false,
                  instance_id: instances.last,
                  name: "#{deployment_env}-autoscale #{date_now}",
                  no_reboot: true,
              })
          info "Finished create AMI #{new_ami.image_id}"

          launch_templates_enabled = fetch(:autoscaling_launch_templates_enabled)

          if launch_templates_enabled
            # Create launch template version from new AMI
            info "Starting create launch template new version"
            version_name = "Autoscale-#{deployment_env}-template-version-#{date_now}"
            resp = ec2.create_launch_template_version({
              launch_template_id: fetch(:autoscaling_launch_template_id),
              version_description: version_name,
              launch_template_data: {
                image_id: new_ami.image_id,
                instance_type: fetch(:instance_type),
                iam_instance_profile: {
                  name: 'autoscaling-iam'
                },
                monitoring: {
                  enabled: true
                },
                security_group_ids: [
                  fetch(:security_group)
                ],
                ebs_optimized: false
              }
            })

            new_template_version_number = resp.launch_template_version.version_number
            info "Finished create launch template new version (V. Number: #{new_template_version_number})"

            # Update autoscaling group
            info "Setting new version as default in the launch template"
            ec2.modify_launch_template({
              launch_template_id: fetch(:autoscaling_launch_template_id),
              default_version: new_template_version_number.to_s
            })
          else
            # List images
            old_amis = ec2.describe_images({owners: ['824916716342']}).images.select {|s| s['name'].downcase.include?("#{deployment_env}-autoscale")}.map {|h| {name: h['name'], image_id: h['image_id']}}
            old_ami = old_amis.sort_by { |h| h[:name] }.first
            old_ami_image_id = old_ami[:image_id]

            # Delete old AMI
            info "Starting deleting old AMI: #{old_ami_image_id}"
            ec2.deregister_image({
                                   image_id: old_ami_image_id,
                                   dry_run: false,
                                 })
            info "Finished delete old AMI: #{old_ami_image_id}"

            # Create launch configuration
            info "Starting create launch configuration"
            launch_configuration_name = "Autoscale-#{deployment_env}-launch-#{date_now}"
            autoscaling.create_launch_configuration(
              {
                iam_instance_profile: "autoscaling-iam",
                image_id: new_ami.image_id,
                instance_type: fetch(:instance_type),
                launch_configuration_name: launch_configuration_name,
                security_groups: [
                  fetch(:security_group),
                ],
              })
            info "Finished create launch configuration #{launch_configuration_name}"

            # List launch configurations
            old_launch_configuration = autoscaling.describe_launch_configurations.launch_configurations.select {|h| h['image_id'] == old_ami_image_id}[0].launch_configuration_name

            # Update autoscaling group
            info "Starting updating autoscaling group: #{autoscaling_group_name}, launch configuration name: #{old_launch_configuration}"
            autoscaling.update_auto_scaling_group(
              {
                auto_scaling_group_name: autoscaling_group_name,
                launch_configuration_name: launch_configuration_name
              })
            info "Finished updating autoscaling group: #{autoscaling_group_name}, launch configuration name: #{launch_configuration_name}"

            # Delete old launch configuration
            info "Starting removing old launch configuration #{old_launch_configuration}"
            autoscaling.delete_launch_configuration({launch_configuration_name: old_launch_configuration})
            info "Finished removing old launch configuration #{old_launch_configuration}"
          end
        end
      end
    end
  end
end

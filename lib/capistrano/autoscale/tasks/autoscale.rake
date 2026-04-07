namespace :deploy do
  desc 'Register instances in load balancer'
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

          # Register health poll settings validated at autoscaled:deploy start (this task runs only from that flow).
          Capistrano::Autoscale::AwsUtils.wait_until_target_group_fully_healthy(
            load_balancer: loadbalancer,
            target_group_arn: tg_arn
          )
        end
      end
    end
  end

  desc 'Deregister instances from load balancer'
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

  desc 'New AMI from deploy and associate to scaling group'
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
          instances = autoscaling_group.instances.map { |h| h['instance_id'] }

          # Extract launch template ID from autoscaling group
          launch_template_id = Capistrano::Autoscale::AwsUtils.extract_launch_template_id(autoscaling_group)
          info "Using launch template ID: #{launch_template_id}"

          # Create AMI
          info 'Starting creating AMI'
          new_ami = Capistrano::Autoscale::AwsUtils.create_ami(
            ec2: ec2,
            instance_id: instances.last,
            volume_sizes: fetch(:volume_sizes),
            deployment_env: deployment_env,
            date_now: date_now
          )
          info "Finished create AMI #{new_ami.image_id}"

          # Create launch template version from new AMI
          info 'Starting create launch template new version'
          info 'Getting launch template data...'
          new_template_version_number = Capistrano::Autoscale::AwsUtils.create_launch_template_version_from_ami(
            ec2: ec2,
            launch_template_id: launch_template_id,
            image_id: new_ami.image_id,
            instance_type: fetch(:instance_type),
            deployment_env: deployment_env,
            date_now: date_now
          )

          # Update autoscaling group
          info 'Setting new version as default in the launch template'
          ec2.modify_launch_template(
            launch_template_id: launch_template_id,
            default_version: new_template_version_number.to_s
          )
        end
      end
    end
  end
end

namespace :autoscaled do
  desc 'Autoscale deploy wrapper to deploy standalone or blue/green deploy (with register/deregister instances and ami creation if needed)'
  task :deploy do
    stage = fetch(:stage).to_s                 # e.g. "production"
    asg_name = fetch(:autoscaling_group_name)  # set this in deploy/<env>.rb
    min_for_blue_green = fetch(:blue_green_min_instances, 2)

    Capistrano::Autoscale::AwsUtils.validate_register_health_poll_config!(
      interval_sec: fetch(
        :register_poll_interval_sec,
        Capistrano::Autoscale::AwsUtils::REGISTER_HEALTH_POLL_INTERVAL_DEFAULT
      ),
      timeout_sec: fetch(
        :register_poll_timeout_sec,
        Capistrano::Autoscale::AwsUtils::REGISTER_HEALTH_POLL_TIMEOUT_DEFAULT
      )
    )

    # Determine current instance count from the target group (to select the deploy strategy)
    ec2_instances = Capistrano::Autoscale::AwsUtils.fetch_all_ec2_instances
    instance_count = ec2_instances.count

    if ec2_instances.count.zero?
      raise 'ERROR: no instances found in target group (with fetch_all_ec2_instances)'
    elsif instance_count < min_for_blue_green
      puts "ASG #{asg_name} has #{instance_count} instance(s) (min=#{min_for_blue_green})."
      puts ">> Running normal deploy on #{stage}."
      invoke 'deploy'
    else
      puts "ASG #{asg_name} has #{instance_count} instances, running blue/green deploy."
      # Single TG snapshot for this deploy (blue_green_deploy reads it via fetch; Capistrano invoke does not pass kwargs).
      set :all_target_group_instances, ec2_instances
      invoke 'autoscaled:blue_green_deploy'
    end

    if fetch(:update_launch_template_ami, true)
      puts 'Creating new AMI after deploy...'
      invoke 'deploy:new_ami_configuration'
    end
  end

  desc 'Run blue/green deploy waves (fixed instance IDs per wave) and LB registration (invoke via autoscaled:deploy)'
  task :blue_green_deploy do
    stage = fetch(:stage).to_s

    # TG snapshot from autoscaled:deploy (avoid a second describe_target_health pass).
    all_instances = fetch(:all_target_group_instances) do
      raise 'autoscaled:blue_green_deploy is meant to run after autoscaled:deploy ' \
            '(missing :all_target_group_instances). Call `cap <stage> autoscaled:deploy` instead.'
    end
    wave_instance_ids = Capistrano::Autoscale::BlueGreen.instance_ids_by_wave(all_instances)

    puts ">>> Starting blue/green deploy waves for stage #{stage} (even, then odd)"
    puts "Grouped instances by wave: #{wave_instance_ids.inspect}"

    Capistrano::Autoscale::BlueGreen::WAVE_PARTITION_LABELS.each do |wave_name|
      ids = wave_instance_ids[wave_name]
      if ids.empty?
        puts "WARNING: Skipping wave #{wave_name}: no instances in the wave list"
        next
      end

      Capistrano::Autoscale::BlueGreen.run_wave!(
        stage: stage,
        order: wave_name,
        instance_ids: ids
      )
    end

    puts "Blue/green deploy finished for #{stage}."
  end
end

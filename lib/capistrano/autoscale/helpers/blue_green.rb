module Capistrano
  module Autoscale
    # Blue/green: two waves = indices even / odd on the TG snapshot (sorted by instance_id).
    # Order is fixed (even first, then odd); not configurable — avoids drift from the fixed-ID wave design.
    module BlueGreen
      INSTANCE_IDS_ENV = 'CAP_BLUE_GREEN_INSTANCE_IDS'

      # Labels match +Integer#even?+ / +Integer#odd?+ on each index in the snapshot array.
      WAVE_PARTITION_LABELS = %w[even odd].freeze

      # +all_instances+ as returned by +AwsUtils.fetch_all_ec2_instances+ (ordered list of hashes).
      def self.instance_ids_by_wave(all_instances)
        WAVE_PARTITION_LABELS.each_with_object({}) do |label, memo|
          indices = all_instances.each_index.select { |i| i.send("#{label}?") }
          memo[label] = all_instances.values_at(*indices).map { |h| h[:instance_id] }
        end
      end

      def self.run_wave!(stage:, order:, instance_ids:)
        puts "Deploying #{order} instances..."

        cap_env = { INSTANCE_IDS_ENV => instance_ids.join(',') }

        puts "Deregistering #{order} instances from load balancer..."
        LocalRunner.run_cap_locally(
          stage: stage,
          task_name: 'deploy:deregister_instances_from_load_balancer',
          env: cap_env
        )
        LocalRunner.run_cap_locally(
          stage: stage,
          task_name: 'deploy',
          env: cap_env
        )
        puts "Registering #{order} instances back into load balancer..."
        LocalRunner.run_cap_locally(
          stage: stage,
          task_name: 'deploy:register_instances_in_load_balancer',
          env: cap_env
        )
      end
    end
  end
end

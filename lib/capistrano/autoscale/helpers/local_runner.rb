module Capistrano
  module Autoscale
    class LocalRunner
      def self.run_cap_locally(stage:, task_name:, instance_order: nil)
        cmd = ['bundle', 'exec', 'cap', stage.to_s, task_name.to_s]
        env = {}
        env['INSTANCE_ORDER'] = instance_order.to_s if instance_order

        puts "Running locally: #{env.empty? ? '' : "INSTANCE_ORDER=#{instance_order} "}#{cmd.join(' ')}"
        success = system(env, *cmd)
        raise "Local command failed: #{cmd.join(' ')}" unless success
      end
    end
  end
end

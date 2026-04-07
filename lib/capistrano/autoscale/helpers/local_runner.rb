module Capistrano
  module Autoscale
    class LocalRunner
      # Runs +bundle exec cap+ locally. Optional +env+ is passed to +system+ (merged into the child process).
      def self.run_cap_locally(stage:, task_name:, env: nil)
        cmd = ['bundle', 'exec', 'cap', stage.to_s, task_name.to_s]
        puts "Running locally: #{cmd.join(' ')}"
        puts "with the env variables: #{env.inspect}" if env&.any?

        success = env&.any? ? system(env, *cmd) : system(*cmd)
        raise "Local command failed: #{cmd.join(' ')}" unless success
      end
    end
  end
end

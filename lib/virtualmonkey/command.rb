#!/usr/bin/env ruby
require 'rubygems'
require 'trollop'
require 'highline/import'
require 'uri'
some_not_included = true
files = Dir.glob(File.join("lib", "virtualmonkey", "command", "**"))
retry_loop = 0
while some_not_included and retry_loop < (files.size ** 2) do
  begin
    some_not_included = false
    for f in files do
      some_not_included ||= require f.chomp(".rb")
    end
  rescue SyntaxError => se
    raise se
  rescue Exception => e
    some_not_included = true
    files.push(files.shift)
  end
  retry_loop += 1
end

module VirtualMonkey
  module Command
    # Parses the initial command string, removing it from ARGV, then runs command.
    def self.go
      @@command = ARGV.shift
      @@global_state_dir = File.join(File.dirname(__FILE__), "..", "..", "test_states")
      @@features_dir = File.join(File.dirname(__FILE__), "..", "..", "features")
      @@cfg_dir = File.join(File.dirname(__FILE__), "..", "..", "config")
      @@cv_dir = File.join(@@cfg_dir, "cloud_variables")
      @@ci_dir = File.join(@@cfg_dir, "common_inputs")

      @@available_commands = ["create", "destroy", "run", "list", "troop", "clone",
                              "update_inputs", "generate_ssh_keys", "destroy_ssh_keys",
                              "populate_security_groups", "populate_datacenters", "api_check",
                              "audit_logs", "populate_all_cloud_vars", "help"]

      @@usage_msg = "Help usage: monkey <command> --help\n"
      @@usage_msg += "Valid commands for monkey: #{@@available_commands.join(", ")}"

      if @@available_commands.include?(@@command)
        VirtualMonkey::Command.__send__(@@command)
      else
        STDERR.puts "Invalid command #{@@command}\n\n#{@@usage_msg}"
        exit(1)
      end
    end

    def self.help
      puts @@usage_msg
    end

    def self.select_only_logic(message)
      @@do_these ||= @@dm.deployments
      if @@options[:only]
        @@do_these = @@do_these.select { |d| d.nickname =~ /#{@@options[:only]}/ }
      end   
      unless @@options[:no_resume] or @@command =~ /destroy|audit/
        temp = @@do_these.select do |d| 
          File.exist?(File.join(@@global_state_dir, d.nickname, File.basename(@@options[:feature])))
        end 
        @@do_these = temp if temp.length > 0 
      end 

      raise "No deployments matched!" unless @@do_these.length > 0 
      @@do_these.each { |d| say "#{d.nickname} : #{d.servers.map { |s| s.state }.inspect}" }
      unless @@options[:yes] or @@command == "troop"
        confirm = ask("#{message} these #{@@do_these.size} deployments (y/n)?", lambda { |ans| true if (ans =~ /^[y,Y]{1}/) }) 
        raise "Aborting." unless confirm
      end   
    end

    def self.create_logic
      raise "Aborting" unless VirtualMonkey::Toolbox::api0_1?
      if @@options[:clouds]
        @@dm.load_clouds(@@options[:clouds])
      elsif @@options[:cloud_variables]
        @@options[:cloud_variables].each { |cvpath| @@dm.load_cloud_variables(cvpath) }
      else
        raise "Usage Error! Need either --clouds or --cloud_variables"
      end
      @@options[:common_inputs].each { |cipath| @@dm.load_common_inputs(cipath) }
      @@dm.generate_variations(@@options)
    end

    def self.run_logic
      raise "Aborting" unless VirtualMonkey::Toolbox::api0_1?
      @@options[:runner] = get_runner_class
      raise "FATAL: Could not determine runner class" unless @@options[:runner]
      unless VirtualMonkey.const_defined?(@@options[:runner])
        puts "WARNING: VirtualMonkey::#{@@options[:runner]} is not a valid class. Defaulting to SimpleRunner."
        @@options[:runner] = "SimpleRunner"
      end

      EM.run {
        @@gm ||= GrinderMonk.new
        @@dm ||= DeploymentMonk.new(@@options[:tag])
        @@options[:runner] = get_runner_class
        select_only_logic("Run tests on")

        @@gm.options = @@options

        @@do_these.each do |deploy|
          @@gm.run_test(deploy, @@options[:feature])
        end
        @@remaining_jobs = @@gm.jobs.dup

        watch = EM.add_periodic_timer(10) {
          @@gm.watch_and_report
          if @@gm.all_done?
            watch.cancel
          end
          
          if @@options[:terminate] and not (@@options[:list_trainer] or @@options[:qa])
            @@remaining_jobs.each do |job|
              if job.status == 0
                if @@command !~ /troop/ or @@options[:step] =~ /(all)|(destroy)/
                  destroy_job_logic(job)
                end
              end
            end
          end
        }
        if @@options[:list_trainer] or @@options[:qa]
          @@remaining_jobs.each do |job|
            if job.status == 0
              audit_log_deployment_logic(job.deployment, :interactive)
              if @@command !~ /troop/ or @@options[:step] =~ /(all)|(destroy)/
                destroy_job_logic(job) if @@options[:terminate]
              end
            end
          end
        end
      }
    end

    def self.audit_log_deployment_logic(deployment, interactive = false)
      @@options[:runner] = get_runner_class
      raise "FATAL: Could not determine runner class" unless @@options[:runner]
      runner = eval("VirtualMonkey::#{@@options[:runner]}.new(deployment.nickname)")
      puts runner.behavior(:run_logger_audit, interactive, @@options[:qa])
    end

    def self.destroy_job_logic(job)
      @@options[:runner] = get_runner_class
      raise "FATAL: Could not determine runner class" unless @@options[:runner]
      runner = eval("VirtualMonkey::#{@@options[:runner]}.new(job.deployment.nickname)")
      puts "Destroying successful deployment: #{runner.deployment.nickname}"
      runner.behavior(:stop_all, false)
      runner.deployment.destroy unless @@options[:no_delete] or @@command =~ /run|clone/
      @@remaining_jobs.delete(job)
      #Release DNS logic
      if runner.respond_to?(:release_dns) and not @@options[:no_delete]
        release_all_dns_domains(runner.deployment.href)
      end
    end

    def self.destroy_all_logic
      raise "Aborting" unless VirtualMonkey::Toolbox::api0_1?
      @@options[:runner] = get_runner_class
      raise "FATAL: Could not determine runner class" unless @@options[:runner]
      @@do_these ||= @@dm.deployments
      @@do_these.each do |deploy|
        runner = eval("VirtualMonkey::#{@@options[:runner]}.new(deploy.nickname)")
        runner.behavior(:stop_all, false)
        state_dir = File.join(@@global_state_dir, deploy.nickname)
        if File.directory?(state_dir)
          puts "Deleting state files for #{deploy.nickname}..."
          Dir.new(state_dir).each do |state_file|
            if File.extname(state_file) =~ /((rb)|(feature))/
              File.delete(File.join(state_dir, state_file))
            end 
          end 
          Dir.rmdir(state_dir)
        end 
        #Release DNS logic
        if runner.respond_to?(:release_dns) and not @@options[:no_delete]
          release_all_dns_domains(deploy.href)
        end
      end 

      @@dm.destroy_all unless @@options[:no_delete]
    end

    def self.release_all_dns_domains(deploy_href)
      ["virtualmonkey_shared_resources", "virtualmonkey_awsdns", "virtualmonkey_dyndns"].each { |domain|
        begin
          dns = SharedDns.new(domain)
          raise "Unable to reserve DNS" unless dns.reserve_dns(deploy_href)
          dns.release_dns
        rescue Exception => e
          raise e unless e.message =~ /Unable to reserve DNS/
        end
      }
    end

    def self.get_runner_class #returns class string
      return @@options[:runner] if @@options[:runner]
      return @@options[:terminate] if @@options[:terminate].is_a?(String)
      return nil unless @@options[:feature]
      feature_file = @@options[:feature]
      ret = nil
      File.open(feature_file, "r") { |f|
        begin
          line = f.readline
          ret = line.match(/VirtualMonkey::.*Runner/)[0].split("::").last if line =~ /= VirtualMonkey.*Runner/
        rescue EOFError => e
          ret = nil
        end while !ret
      }
      return ret
    end
  end
end

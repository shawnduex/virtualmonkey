module VirtualMonkey
  class MysqlRunner
    include VirtualMonkey::DeploymentBase
    include VirtualMonkey::EBS
    include VirtualMonkey::Mysql
    attr_accessor :scripts_to_run
    attr_accessor :db_ebs_prefix

    # It's not that I'm a Java fundamentalist; I merely believe that mortals should
    # not be calling the following methods directly. Instead, they should use the
    # TestCaseInterface methods (behavior, verify, probe) to access these functions.
    # Trust me, I know what's good for you. -- Tim R.
    private

    def init_slave_from_slave_backup
      behavior(:config_master_from_scratch, s_one)
      behavior(:run_script, "freeze_backups", s_one)
      behavior(:wait_for_snapshots)
      behavior(:slave_init_server, s_two)
      behavior(:run_script, "backup", s_two)
      s_two.relaunch
      s_one['dns-name'] = nil
      s_two.wait_for_operational_with_dns
      behavior(:wait_for_snapshots)
      #sleep 300
      behavior(:slave_init_server, s_two)
    end

    def run_promotion_operations
      behavior(:config_master_from_scratch, s_one)
      object_behavior(s_one, :relaunch)
      s_one.dns_name = nil
      behavior(:wait_for_snapshots)
# need to wait for ebs snapshot, otherwise this could easily fail
      behavior(:restore_server, s_two)
      object_behavior(s_one, :wait_for_operational_with_dns)
      behavior(:wait_for_snapshots)
      behavior(:slave_init_server, s_one)
      behavior(:promote_server, s_one)
    end

    def run_reboot_operations
# Duplicate code here because we need to wait between the master and the slave time
      #reboot_all(true) # serially_reboot = true
      @servers.each do |s|
        object_behavior(s, :reboot, true)
        object_behavior(s, :wait_for_state, "operational")
      end
      behavior(:wait_for_all, "operational")
      behavior(:run_reboot_checks)
    end

    # This is where we perform multiple checks on the deployment after a reboot.
    def run_reboot_checks
      # one simple check we can do is the backup.  Backup can fail if anything is amiss
      @servers.each do |server|
        behavior(:run_script, "backup", server)
      end
    end


    # lookup all the RightScripts that we will want to run
    def lookup_scripts
#TODO fix this so epoch is not hard coded.
puts "WE ARE HARDCODING THE TOOL BOX NAMES TO USE 11H1"
     scripts = [
                 [ 'restore', 'restore and become' ],
                 [ 'slave_init', 'slave init' ],
                 [ 'promote', 'EBS promote to master' ],
                 [ 'backup', 'EBS backup' ],
                 [ 'terminate', 'TERMINATE SERVER' ],
                 [ 'freeze_backups', 'DB freeze' ]
               ]
      ebs_toolbox_scripts = [
                              [ 'create_stripe' , 'EBS stripe volume create - 11H1' ]
                            ]
      mysql_toolbox_scripts = [
                              [ 'create_mysql_ebs_stripe' , 'DB Create MySQL EBS stripe volume - 11H1' ],
                              [ 'create_migrate_script' , 'DB EBS create migrate script from MySQL EBS v1' ]
                            ]
      raise "FATAL: Need 2 MySQL servers in the deployment" unless @servers.size == 2

      # Use the HEAD revision.
      ebs_tbx = ServerTemplate.find_by(:nickname) { |n| n =~ /EBS Stripe Toolbox - 11H1/ }.select { |st| st.is_head_version }.first
      raise "Did not find ebs toolbox template" unless ebs_tbx

      db_tbx = ServerTemplate.find 84657
      raise "Did not find mysql toolbox template" unless db_tbx
      puts "USING Toolbox Template: #{db_tbx.nickname}"

      st = ServerTemplate.find(resource_id(s_one.server_template_href))
      lookup_scripts_table(st,scripts)
      lookup_scripts_table(ebx_tbx,ebs_toolbox_scripts)
      lookup_scripts_table(db_tbx,mysql_toolbox_scripts)
      # hardwired script! (this is an 'anyscript' that users typically use to setup the master dns)
      # This a special version of the register that uses MASTER_DB_DNSID instead of a test DNSID
      # This is identical to "DB register master" However it is not part of the template.
      add_script_to_run('master_init', RightScript.new('href' => "/api/acct/2901/right_scripts/195053"))
      raise "Did not find script" unless script_to_run?('master_init')
    end

    def migrate_slave
      s_one.settings
      object_behavior(s_one, :spot_check_command, "/tmp/init_slave.sh")
      behavior(:run_script, "backup", s_one)
    end
   
    def launch_v2_slave
      s_two.settings
      behavior(:wait_for_snapshots)
      behavior(:run_script, "slave_init", s_two)
    end

    def run_restore_with_timestamp_override
      object_behavior(s_one, :relaunch)
      s_one.dns_name = nil
      object_behavior(s_one, :wait_for_operational_with_dns)
      behavior(:run_script, 'restore', s_one, { "OPT_DB_RESTORE_TIMESTAMP_OVERRIDE" => "text:#{find_snapshot_timestamp}" })
    end

# Check for specific MySQL data.
    def check_mysql_monitoring
      mysql_plugins = [
                        {"plugin_name"=>"mysql", "plugin_type"=>"mysql_commands-delete"},
                        {"plugin_name"=>"mysql", "plugin_type"=>"mysql_commands-create_db"},
                        {"plugin_name"=>"mysql", "plugin_type"=>"mysql_commands-create_table"},
                        {"plugin_name"=>"mysql", "plugin_type"=>"mysql_commands-insert"},
                        {"plugin_name"=>"mysql", "plugin_type"=>"mysql_commands-show_databases"}
                      ]
      @servers.each do |server|
        unless server.multicloud
#mysql commands to generate data for collectd to return
          for ii in 1...100
#TODO: have to select db with every call.  figure a better way to do this and get rid of fast and ugly
# cut and past hack.
            behavior(:run_query, "show databases", server)
            behavior(:run_query, "create database test#{ii}", server)
            behavior(:run_query, "use test#{ii}; create table test#{ii}(test text)", server)
            behavior(:run_query, "use test#{ii};show tables", server)
            behavior(:run_query, "use test#{ii};insert into test#{ii} values ('1')", server)
            behavior(:run_query, "use test#{ii};update test#{ii} set test='2'", server)
            behavior(:run_query, "use test#{ii};select * from test#{ii}", server)
            behavior(:run_query, "use test#{ii};delete from test#{ii}", server)
            behavior(:run_query, "show variables", server)
            behavior(:run_query, "show status", server)
            behavior(:run_query, "use test#{ii};grant select on test.* to root", server)
            behavior(:run_query, "use test#{ii};alter table test#{ii} rename to test2#{ii}", server)
          end
          mysql_plugins.each do |plugin|
            monitor = server.get_sketchy_data({'start' => -60,
                                               'end' => -20,
                                               'plugin_name' => plugin['plugin_name'],
                                               'plugin_type' => plugin['plugin_type']})
            value = monitor['data']['value']
            raise "No #{plugin['plugin_name']}-#{plugin['plugin_type']} data" unless value.length > 0
            # Need to check for that there is at least one non 0 value returned.
            for nn in 0...value.length
              if value[nn] > 0
                break
              end
            end
            raise "No #{plugin['plugin_name']}-#{plugin['plugin_type']} time" unless nn < value.length
            puts "Monitoring is OK for #{plugin['plugin_name']}-#{plugin['plugin_type']}"
          end
        end
      end
    end
  end
end
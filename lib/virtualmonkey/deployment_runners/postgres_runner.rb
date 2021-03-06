module VirtualMonkey
  class PostgresRunner
    include VirtualMonkey::DeploymentBase
    include VirtualMonkey::EBS
    include VirtualMonkey::Postgres
    attr_accessor :scripts_to_run
    attr_accessor :db_ebs_prefix

    # It's not that I'm a Java fundamentalist; I merely believe that mortals should
    # not be calling the following methods directly. Instead, they should use the
    # TestCaseInterface methods (behavior, verify, probe) to access these functions.
    # Trust me, I know what's good for you. -- Tim R.
    private

    # lookup all the RightScripts that we will want to run
    def lookup_scripts
     scripts = [
                 [ 'backup', 'EBS PostgreSQL backup' ],
                 [ 'create_stripe' , 'Create PostgreSQL EBS stripe volume' ],
                 [ 'dump_import', 'PostgreSQL dump import'],
                 [ 'dump_export', 'PostgreSQL dump export'],
                 [ 'freeze_backups', 'DB PostgreSQL Freeze' ],
                 [ 'promote', 'DB EBS PostgreSQL promote to master' ],
                 [ 'restore', 'PostgreSQL restore and become' ],
                 [ 'slave_init', 'DB EBS PostgreSQL slave init' ],
                 [ 'terminate', 'PostgreSQL TERMINATE SERVER' ],
                 [ 'unfreeze_backups', 'DB PostgreSQL Unfreeze' ]
               ]
      raise "FATAL: Need 2 PostgreSQL servers in the deployment" unless @servers.size == 2

      st = ServerTemplate.find(resource_id(s_one.server_template_href))
      load_script_table(st,scripts)
      # hardwired script! (this is an 'anyscript' that users typically use to setup the master dns)
      # This a special version of the register that uses MASTER_DB_DNSID instead of a test DNSID
      # This is identical to "DB register master" However it is not part of the template.
      load_script('master_init', RightScript.new('href' => "/api/acct/2901/right_scripts/195053"))
      raise "Did not find script" unless script_to_run?('master_init')
    end
  end
end

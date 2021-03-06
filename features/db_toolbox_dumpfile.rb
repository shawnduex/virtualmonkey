#@mysql_5.x
#Feature: mysql toolbox
#  Tests the RightScale premium ServerTemplate
#
#  Scenario: Run all toolbox scripts
# CREATE the db using a dumpfile
##
## PHASE 1) Launch a few DB servers.  Make one the master.
##
# Given A MySQL Toolbox deployment
  @runner = VirtualMonkey::MysqlToolboxRunner.new(ENV['DEPLOYMENT'])

# Then I should set a variation MySQL DNS
  @runner.set_var(:setup_dns, "virtualmonkey_shared_resources") # DNSMadeEasy

# Then I should set a variation lineage
  @runner.set_var(:set_variation_lineage)

# Then I should set a variation stripe count of "3"
  @runner.set_var(:set_variation_stripe_count, 3)

# Then I should set a variation volume size "3"
  @runner.set_var(:set_variation_volume_size, 3)
  @runner.set_var(:set_variation_mount_point, "/mnt/mysql")

# Then I should stop the servers
  @runner.behavior(:stop_all)

# Then I should launch all servers
  @runner.behavior(:launch_all)

# Then I should wait for the state of "all" servers to be "operational"
  @runner.behavior(:wait_for_all, "operational")

# Then I should create master from scratch
  @runner.behavior(:create_master_from_dumpfile)

# Then I should backup the volume
  @runner.behavior(:create_backup)


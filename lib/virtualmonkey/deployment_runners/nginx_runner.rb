module VirtualMonkey
  class NginxRunner
    include VirtualMonkey::DeploymentBase
    include VirtualMonkey::UnifiedApplication
    include VirtualMonkey::Mysql

    def nginx_lookup_scripts
      scripts = [
                  [ 'backup', 'mysqldump backup' ],
                  [ 'restart_nginx', '\(re\)start' ]
                ]
      load_script_table(@server_templates.first,scripts)
    end

    private

    def run_nginx_checks
      # check that the standard unified app is responding on port 80
      behavior(:run_unified_application_checks, @servers, 80)
    end

  end
end

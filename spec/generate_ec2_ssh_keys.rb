require File.join(File.dirname(__FILE__), "spec_helper")
require 'ruby-debug'
require 'json'

begin
  require '/var/spool/cloud/user-data.rb'
rescue
  ENV['RS_API_URL'] = "#{ENV['USER']}-#{`hostname`}".strip
end

# XXX DO NOT DELETE THIS COMMENT XXX
#Server.find_by(:state) { |s| s == "operational" }.each { |s| s.settings }.select { |s| s.dns_name =~ /#{ENV['EC2_PUBLIC_HOSTNAME']}/ }
# XXX DO NOT DELETE THIS COMMENT XXX

cloud_ids = []
for i in 1..5
  cloud_ids << i
end
cloud_ids << ENV['ADD_CLOUD_SSH_KEY'].to_i if ENV['ADD_CLOUD_SSH_KEY']

keys_file = File.join("..", "config", "cloud_variables", "ec2_keys.json")
ssh_dir = File.join(File.expand_path("~"), ".ssh")
rest_yaml = File.join(File.expand_path("~"), ".rest_connection", "rest_api_config.yaml")
rest_settings = YAML::load(IO.read(rest_yaml))
rest_settings[:ssh_keys] = []
specific_key_file = File.join(ssh_dir, "specific_keys")
specific_key_names = YAML::load(IO.read(specific_key_file)) if File.exists?(specific_key_file)
if File.exists?(keys_file)
  keys = JSON::parse(IO.read(keys_file))
else
  keys = {}
end

cloud_ids.each { |cloud|
  next if cloud == 0
  if File.exists?(specific_key_file)
    key_name = specific_key_names[:names][cloud - 1]
  else
    if cloud <= 10
      key_name = "monkey-#{cloud}-#{ENV['RS_API_URL'].split("/").last}"
    elsif cloud == 850
      key_name = "publish-test"
    else
      key_name = "monkey-1-#{ENV['RS_API_URL'].split("/").last}"
    end
  end
  if cloud <= 10
    found = Ec2SshKeyInternal.find_by_cloud_id("#{cloud}").select { |obj| obj.aws_key_name =~ /#{key_name}/ }.first
    k = (found ? found : Ec2SshKey.create('aws_key_name' => key_name, 'cloud_id' => "#{cloud}"))
    keys["#{cloud}"] = {"ec2_ssh_key_href" => k.href,
                        "parameters" =>
                          {"PRIVATE_SSH_KEY" => "key:#{key_name}:#{cloud}"}
                        }
    # Generate Private Key File
    priv_key_file = File.join(ssh_dir, "monkey-cloud-#{cloud}")
    File.open(priv_key_file, "w") { |f| f.write(k.aws_material) }
  else
    # Use API user's managed ssh key
    puts "Using API user's managed ssh key" 
    priv_key_file = File.join(ssh_dir, "api_user_key") #FIXME: write this file from ST input 
  end

  File.chmod(0700, priv_key_file)
  # Configure rest_connection config
  rest_settings[:ssh_keys] << priv_key_file
}

keys_out = keys.to_json(:indent => "  ",
                        :object_nl => "\n",
                        :array_nl => "\n")
rest_out = rest_settings.to_yaml

File.open(keys_file, "w") { |f| f.write(keys_out) }
File.open(rest_yaml, "w") { |f| f.write(rest_out) }

chef_gem 'sys-proctable'

package 'git'
package 'openssl'

agent_attrs = node['azure_pipelines_agent']

if agent_attrs['pat']
  pat = agent_attrs['pat']
else
  auth_data = data_bag_item agent_attrs['data_bag'], agent_attrs['data_bag_item']
  pat = auth_data['personal_access_token']
end

auth_params = ['--auth', 'pat', '--token', pat]

directory '/usr/local/lib/' do
  recursive true
  owner Agent.admin_user
  group Agent.user_group
end

link '/usr/local/lib/libcrypto.1.0.0.dylib' do
  to '/usr/local/opt/openssl/lib/libcrypto.1.0.0.dylib'
end

link '/usr/local/lib/libssl.1.0.0.dylib' do
  to '/usr/local/opt/openssl/lib/libssl.1.0.0.dylib'
end

directory 'agent home' do
  path Agent.agent_home
  owner Agent.admin_user
  group Agent.user_group
end

directory 'create log directory' do
  path Agent.service_log_path
  recursive true
  owner Agent.admin_user
  group Agent.user_group
end

ruby_block 'recursive permissions for logs' do
  block { ::FileUtils.chown_R Agent.admin_user, Agent.user_group, Agent.service_log_path }
  action :nothing
  subscribes :run, 'directory[create log directory]', :immediately
end

tar_extract Agent.release_download_url do
  target_dir Agent.agent_home
  group Agent.user_group
  user Agent.admin_user
  action :extract
  only_if { Agent.needs_update? }
end

template 'create environment file' do
  path ::File.join Agent.agent_home, '.env'
  source 'env.erb'
  owner Agent.admin_user
  group Agent.user_group
  mode '644'
  cookbook 'azure_pipelines_agent_macos'
  notifies :restart, 'macosx_service[azure-pipelines-agent]'
  not_if { Agent.worker_running? }
end

execute 'bootstrap the agent' do
  cwd Agent.agent_home
  user Agent.admin_user
  command ['./bin/Agent.Listener', 'configure', Agent.configuration_type, '--unattended', '--acceptTeeEula', *auth_params]
  environment lazy { Agent.environment }
  not_if { Agent.credentials? }
  live_stream true
  ignore_failure true
end

execute 'determine if agent already exists' do
  cwd Agent.agent_home
  user Agent.admin_user
  returns 2
  command ['./bin/Agent.Listener']
  live_stream true
  not_if { Agent.credentials? }
  notifies :run, 'execute[configure replacement agent]', :immediately
end

execute 'configure replacement agent' do
  cwd Agent.agent_home
  user Agent.admin_user
  command ['./bin/Agent.Listener', 'configure', Agent.configuration_type, '--replace', '--unattended', '--acceptTeeEula', *auth_params]
  environment lazy { Agent.environment }
  live_stream true
  action :nothing
  notifies :restart, 'macosx_service[azure-pipelines-agent]'
end

file 'create agent service file' do
  path ::File.join Agent.agent_home, '.service'
  owner Agent.admin_user
  group Agent.user_group
  content Agent.launchd_plist
  action :create
end

launchd 'create launchd service plist' do
  path Agent.launchd_plist
  type 'agent'
  owner Agent.admin_user
  label Agent.service_name
  program_arguments ["#{Agent.agent_home}/bin/runsvc.sh"]
  username Agent.admin_user
  working_directory Agent.agent_home
  run_at_load true
  standard_out_path ::File.join Agent.service_log_path, 'stdout.log'
  standard_error_path ::File.join Agent.service_log_path, 'stderr.log'
  environment_variables VSTS_AGENT_SVC: '1'
  session_type 'user'
  action [:create, :enable]
  not_if { Agent.worker_running? }
end

macosx_service 'azure-pipelines-agent' do
  service_name Agent.service_name
  plist Agent.launchd_plist
  action :nothing
end

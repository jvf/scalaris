#
# Cookbook Name:: scalaris_PIC
# Recipe:: Start_PIC
# 		Note: Start_PIC assumes that Deploy_PIC ahas been executed already...
#
# Copyright 2012, Zuse Institute Berlin
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

service "scalaris" do
  service_name "scalaris"
  supports :status => true, :start => true, :stop => true, :restart => true
  # TODO: if last node, we have to kill (not stop) the node! - the following check is not really checking that
  if node[:REC][:PICs][:scalaris_PIC][0][:attributes][:scalaris_start_first] then
    stop_command "/etc/init.d/scalaris kill"
  end
  action [ :enable, :start ]
  case node[:platform]
  when "ubuntu", "debian"
    provider Chef::Provider::Service::Init::Debian
  else
    provider Chef::Provider::Service::Init
  end
end

service "scalaris-monitor" do
  service_name "scalaris-monitor"
  supports :status => true, :start => true, :stop => true, :restart => true
  action [ :enable, :start ]
  case node[:platform]
  when "ubuntu", "debian"
    provider Chef::Provider::Service::Init::Debian
  else
    provider Chef::Provider::Service::Init
  end
end

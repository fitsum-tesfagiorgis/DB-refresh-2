Import-Module VMware.VimAutomation.Core
#Copy database environment: Development
# This script will clone the production environment down to the development environment: 
# It will clone the master and then the slave
# Usage devrefresh.ps1
#
# Requires active connection to vCenter Server (using Connect-VIServer)
#
# 
#
########################################################################################################
#Variables
# Vcenter Credentials:
$LogFile = "C:\Users\admin_llacroix\devrefresh.log"
$virtualcenter = "pdmt-vcv02.reeher.net"
$vcuser = "administrator@vsphere.local"
$vcpass = ")LOA8C^ruZJ)"
#connect to virtual center

Set-ExecutionPolicy Unrestricted -Force
connect-viserver -Server $virtualcenter -username $vcuser -password $vcpass -ErrorAction Stop |out-null

# chef server:
$chefserver = "dvmt-usv02"

# Source vms:
$sourcemaster = "pdmt-dbv01"
$sourceslave = "pdmt-dbv03"

# New vms:
$targetmaster = "dvmt-dbv03"
$targetslave = "dvmt-dbv04"

#esx host for the vms:
$esxmaster = "pdmt-exh03.reeher.net"
$esxslave = "pdmt-exh04.reeher.net"

$GuestUser = "root"
$GuestPassword = "wWOEoYB7c#zd"

$Datastoremaster = "preprod-db-01"
$Datastoreslave = "preprod-db-02"
$appserver1 = "dvmt-apv01"
$appserver2 = "dvmt-apv03"
$appserver3 = ""
$NetworkName = "dev-rdb-db"
$IPADDRmaster = "10.2.220.17"
$IPADDRslave = "10.2.220.18"
$GATEWAY = "10.2.220.1"
$environment = "development"
#Enable logging:
Start-Transcript -path $LogFile -append

#Notification for teams:
Send-MailMessage -To "Tech <rhr-tech@reeher.onmicrosoft.com>", "Product <RHR-ProductManagement@Reeher.onmicrosoft.com>", "Analytics <rhr-analytics@reeher.com>"   -From "IT <itnotifications@reeher.com>" -Subject "DB refresh is happening in $environment in 5 minutes..." -SmtpServer "reeher.mail.protection.outlook.com"

Start-Sleep -s 300

# Get Start Time
$startDTM = (Get-Date)

Write-Host "Initatiating cloning operations for MariaDB master..." -ForeGroundColor Cyan

Write-Host "Initiating restore" -ForeGroundColor Cyan
#Power down the target vm in order for the delete to work:
#Get the VM
$MyVM = Get-VM -Name $targetmaster
#Initiate Shutdown of the OS on the VM if it is on.
if ($MyVM.PowerState -eq "PoweredOn") {
   Write-Host "Shutting Down" $MyVM
   Shutdown-VMGuest -VM $MyVM -Confirm:$false
   #Wait for Shutdown to complete
   do {
      #Wait 5 seconds
      Start-Sleep -s 5
      #Check the power status
      $MyVM = Get-VM -Name $targetmaster
      $status = $MyVM.PowerState
   }until($status -eq "PoweredOff")
}

Write-Host "Cloning...." -ForeGroundColor Cyan
Get-VM -Name $targetmaster | Remove-VM -DeletePermanently -Confirm:$false
New-VM -Name $targetmaster -VM $sourcemaster -VMHost $esxmaster -Datastore $Datastoremaster

Write-Host "Powering up clone..." -ForeGroundColor Cyan
Get-VM $targetmaster | Start-VM

Wait-Tools -VM $targetmaster -TimeoutSeconds 400
Write-Host "Waiting another 60 seconds for all services to start..." -ForeGroundColor Cyan
Start-Sleep -s 60

Write-Host "Setting proper vmware network..." -ForeGroundColor Cyan
get-vm $targetmaster | Get-NetworkAdapter | Set-NetworkAdapter -NetworkName $NetworkName -Confirm:$false 


Write-Host "Fixing OS networking..." -ForeGroundColor Cyan

#remove this network file to regenerate mac address on next boot since its currently the same as the vm it was cloned from:
Invoke-VMScript -VM $targetmaster -ScriptText "rm -rf /etc/udev/rules.d/70-persistent-net.rules;" -GuestUser $GuestUser -GuestPassword $GuestPassword

#Clean up the previous chef files:
Invoke-VMScript -VM $targetmaster -ScriptText "rm -rf /etc/chef/" -GuestUser $GuestUser -GuestPassword $GuestPassword

#Update the network scripts file to be accurate for this machine:
Invoke-VMScript -VM $targetmaster -ScriptText "echo 'DEVICE=eth0
TYPE=Ethernet
ONBOOT=yes
NM_CONTROLLED=yes
BOOTPROTO=static
IPADDR=$IPADDRmaster
NETMASK=255.255.255.0' > /etc/sysconfig/network-scripts/ifcfg-eth0" -GuestUser $GuestUser -GuestPassword $GuestPassword

#Update the hostname to be accurate for this machine:
Invoke-VMScript -VM $targetmaster -ScriptText "echo 'HOSTNAME=$targetmaster
NETWORKING=yes
GATEWAY=$GATEWAY' > /etc/sysconfig/network" -GuestUser $GuestUser -GuestPassword $GuestPassword

#Drop mariadb buffer pool memory per the environment:
Invoke-VMScript -VM $targetmaster -ScriptText "sed -i -e 's/50G/12G/g' /etc/my.cnf" -GuestUser $GuestUser -GuestPassword $GuestPassword

Write-Host "Restarting vm to enable networking..." -ForeGroundColor Cyan

#Restart the vm to enable the networking:
Get-VM $targetmaster | Restart-VMGuest

Write-Host "Waiting 90 seconds for services to start..." -ForeGroundColor Cyan

Start-Sleep -s 90

Write-Host "Cleaning up Chef records before bootstrap..." -ForeGroundColor Cyan

#Clean up the records in the chef server:
Invoke-VMScript -VM $chefserver -ScriptText "cd /home/REEHER.NET/louis.lacroix/chef-reeherproduction; knife node delete -y $targetmaster.reeher.net; knife client delete -y $targetmaster.reeher.net" -GuestUser $GuestUser -GuestPassword $GuestPassword 

Write-Host "Bootstrapping..." -ForeGroundColor Cyan
#Bootstrap the node:
Invoke-VMScript -VM $chefserver -ScriptText "cd /home/REEHER.NET/louis.lacroix/chef-reeherproduction; knife bootstrap $targetmaster.reeher.net -x root -P 'wWOEoYB7c#zd' -N $targetmaster.reeher.net -t '/home/REEHER.NET/louis.lacroix/chef-reeherproduction/templates/default.erb' -r 'recipe[reeher-base::default]' -E $environment;" -GuestUser $GuestUser -GuestPassword $GuestPassword

Write-Host "Powering down and resizing the vm for the environment..." -ForeGroundColor Cyan
#Power down the target vm in order for the delete to work:
#Get the VM
$MyVM = Get-VM -Name $targetmaster
#Initiate Shutdown of the OS on the VM if it is on.
if ($MyVM.PowerState -eq "PoweredOn") {
   Write-Host "Shutting Down" $MyVM
   Shutdown-VMGuest -VM $MyVM -Confirm:$false
   #Wait for Shutdown to complete
   do {
      #Wait 5 seconds
      Start-Sleep -s 5
      #Check the power status
      $MyVM = Get-VM -Name $targetmaster
      $status = $MyVM.PowerState
   }until($status -eq "PoweredOff")
}
$MyVM | Set-VM -MemoryGB 16 -NumCpu 4 -Confirm:$False
$MyVM | Start-VM

Wait-Tools -VM $targetmaster -TimeoutSeconds 300
Write-Host "Waiting another 60 seconds for all services to start..." -ForeGroundColor Cyan
Start-Sleep -s 60

Write-Host "Configuring MariaDB..." -ForeGroundColor Cyan

#Below are the settings to allow remote sql execution natively in powershell:
Import-Module 'C:\Program Files (x86)\MySQL\MySQL Connector Net 6.9.9\Assemblies\v4.5\MySql.Data.dll'

$UserName = "ituser"
$Password = "HQnRqLX3hK"
$database = "reeher_dash_dbo"
$querymaster = "reset master;"
$ConnectionString = "Server=$targetmaster;uid=$UserName;pwd=$Password;Database=$database;Integrated Security=False;"
$MySQLConnection = New-Object -TypeName MySql.Data.MySqlClient.MySqlConnection
$MySQLConnection.ConnectionString = $ConnectionString
$MySQLConnection.Open()
$command     = New-Object MySql.Data.MySqlClient.MySqlCommand($querymaster, $MySQLConnection)
$dataAdapter = New-Object MySql.Data.MySqlClient.MySqlDataAdapter($command)
$dataSet     = New-Object System.Data.DataSet
$recordCount = $dataAdapter.Fill($dataSet, 'data')
$dataSet.Tables['data']

Write-Host "Cloning complete on master, initiating slave operations..." -ForeGroundColor Cyan

#Clone the slave vm:
Write-Host "Initiating restore..." -ForeGroundColor Cyan
#Power down the target vm in order for the delete to work:
#Get the VM
$MyVM = Get-VM -Name $targetslave
#Initiate Shutdown of the OS on the VM if it is on.
if ($MyVM.PowerState -eq "PoweredOn") {
   Write-Host "Shutting Down" $MyVM
   Shutdown-VMGuest -VM $MyVM -Confirm:$false
   #Wait for Shutdown to complete
   do {
      #Wait 5 seconds
      Start-Sleep -s 5
      #Check the power status
      $MyVM = Get-VM -Name $targetslave
      $status = $MyVM.PowerState
   }until($status -eq "PoweredOff")
}
Write-Host "Cloning...." -ForeGroundColor Cyan
Get-VM -Name $targetslave | Remove-VM -DeletePermanently -Confirm:$false
New-VM -Name $targetslave -VM $sourceslave -VMHost $esxslave -Datastore $Datastoreslave

#Power up the VM and do some work on it to get it ready for use:
Write-Host "Powering up clone..." -ForeGroundColor Cyan
Get-VM $targetslave | Start-VM

Wait-Tools -VM $targetslave -TimeoutSeconds 300
Write-Host "Waiting another 90 seconds for all services to start..." -ForeGroundColor Cyan
Start-Sleep -s 90

Write-Host "Setting proper vmware network..." -ForeGroundColor Cyan
get-vm $targetslave | Get-NetworkAdapter | Set-NetworkAdapter -NetworkName $NetworkName -Confirm:$false 

Write-Host "Fixing OS networking..." -ForeGroundColor Cyan

#remove this network file to regenerate mac address on next boot since its currently the same as the vm it was cloned from:
Invoke-VMScript -VM $targetslave -ScriptText "rm -rf /etc/udev/rules.d/70-persistent-net.rules;" -GuestUser $GuestUser -GuestPassword $GuestPassword -ToolsWaitSecs 300

#Clean up the previous chef files:
Invoke-VMScript -VM $targetslave -ScriptText "rm -rf /etc/chef/" -GuestUser $GuestUser -GuestPassword $GuestPassword

#Update the network scripts file to be accurate for this machine:
Invoke-VMScript -VM $targetslave -ScriptText "echo 'DEVICE=eth0
TYPE=Ethernet
ONBOOT=yes
NM_CONTROLLED=yes
BOOTPROTO=static
IPADDR=$IPADDRslave
NETMASK=255.255.255.0' > /etc/sysconfig/network-scripts/ifcfg-eth0" -GuestUser $GuestUser -GuestPassword $GuestPassword

#Update the hostname to be accurate for this machine:
Invoke-VMScript -VM $targetslave -ScriptText "echo 'HOSTNAME=$targetslave
NETWORKING=yes
GATEWAY=$GATEWAY' > /etc/sysconfig/network" -GuestUser $GuestUser -GuestPassword $GuestPassword

#Drop mariadb buffer pool memory per the environment:
Invoke-VMScript -VM $targetslave -ScriptText "sed -i -e 's/40G/12G/g' /etc/my.cnf" -GuestUser $GuestUser -GuestPassword $GuestPassword

Write-Host "Restarting vm to enable networking..." -ForeGroundColor Cyan

#Restart the vm to enable the networking:
Get-VM $targetslave | Restart-VMGuest

Write-Host "Waiting for services to start..." -ForeGroundColor Cyan

Start-Sleep -s 90

Write-Host "Cleaning up Chef records before bootstrap..." -ForeGroundColor Cyan

#Clean up the records in the chef server:
Invoke-VMScript -VM $chefserver -ScriptText "cd /home/REEHER.NET/louis.lacroix/chef-reeherproduction; knife node delete -y $targetslave.reeher.net; knife client delete -y $targetslave.reeher.net" -GuestUser $GuestUser -GuestPassword $GuestPassword 

Write-Host "Bootstrapping..." -ForeGroundColor Cyan

#Bootstrap the node:
Invoke-VMScript -VM $chefserver -ScriptText "cd /home/REEHER.NET/louis.lacroix/chef-reeherproduction; knife bootstrap $targetslave.reeher.net -x root -P 'wWOEoYB7c#zd' -N $targetslave.reeher.net -t '/home/REEHER.NET/louis.lacroix/chef-reeherproduction/templates/default.erb' -r 'recipe[reeher-base::default]' -E $environment;" -GuestUser $GuestUser -GuestPassword $GuestPassword

Write-Host "Powering down and resizing the vm for the environment..." -ForeGroundColor Cyan
#Power down the target vm in order for the delete to work:
#Get the VM
$MyVM = Get-VM -Name $targetslave
#Initiate Shutdown of the OS on the VM if it is on.
if ($MyVM.PowerState -eq "PoweredOn") {
   Write-Host "Shutting Down" $MyVM
   Shutdown-VMGuest -VM $MyVM -Confirm:$false
   #Wait for Shutdown to complete
   do {
      #Wait 5 seconds
      Start-Sleep -s 5
      #Check the power status
      $MyVM = Get-VM -Name $targetslave
      $status = $MyVM.PowerState
   }until($status -eq "PoweredOff")
}
$MyVM | Set-VM -MemoryGB 16 -NumCpu 4 -Confirm:$False
$MyVM | Start-VM

Wait-Tools -VM $targetslave -TimeoutSeconds 300
Write-Host "Waiting for services to start..." -ForeGroundColor Cyan
Start-Sleep -s 300
Write-Host "Setting mysql configuration..." -ForeGroundColor Cyan

#New, unique mysql server id (only needed in staging):
#Invoke-VMScript -VM $targetmaster -ScriptText "sed -i -e 's/12/21/g' /etc/my.cnf" -GuestUser $GuestUser -GuestPassword $GuestPassword

Import-Module 'C:\Program Files (x86)\MySQL\MySQL Connector Net 6.9.9\Assemblies\v4.5\MySql.Data.dll'

$UserName = "ituser"
$Password = "HQnRqLX3hK"
$database = "reeher_dash_dbo"
$ConnectionString = "Server=$targetslave;uid=$UserName; pwd=$Password;Database=$database;Integrated Security=False;"
$MySQLConnection = New-Object -TypeName MySql.Data.MySqlClient.MySqlConnection
$MySQLConnection.ConnectionString = $ConnectionString
$MySQLConnection.Open()
$queryslave = "stop slave; reset slave; CHANGE MASTER TO   MASTER_HOST='$targetmaster.reeher.net',   MASTER_USER='reeher-repl',   MASTER_PASSWORD='jak9t5',   MASTER_LOG_FILE='master-bin.000001',   MASTER_LOG_POS=1, MASTER_CONNECT_RETRY=60; start slave; show slave status;"
$command     = New-Object MySql.Data.MySqlClient.MySqlCommand($queryslave, $MySQLConnection)
$dataAdapter = New-Object MySql.Data.MySqlClient.MySqlDataAdapter($command)
$dataSet     = New-Object System.Data.DataSet
$recordCount = $dataAdapter.Fill($dataSet, 'data')
$dataSet.Tables['data']


Write-Host "Setting idp_sso_target_url per environment..." -ForeGroundColor Cyan

#Below are the settings to allow remote sql execution natively in powershell:
Import-Module 'C:\Program Files (x86)\MySQL\MySQL Connector Net 6.9.9\Assemblies\v4.5\MySql.Data.dll'

$UserName = "ituser"
$Password = "HQnRqLX3hK"
$database = "reeher_dash_dbo"
$querymaster = "use reeher_dash_dbo; UPDATE reeher_dash_dbo.client SET idp_sso_target_url='https://app.onelogin.com/trust/saml2/http-post/sso/430394' WHERE client_id=3; UPDATE reeher_dash_dbo.client SET idp_sso_target_url='https://app.onelogin.com/trust/saml2/http-post/sso/430384' WHERE client_id=18; update client set require_sso_encryption=false where require_sso_encryption=true;"
$ConnectionString = "Server=$targetmaster;uid=$UserName;pwd=$Password;Database=$database;Integrated Security=False;"
$MySQLConnection = New-Object -TypeName MySql.Data.MySqlClient.MySqlConnection
$MySQLConnection.ConnectionString = $ConnectionString
$MySQLConnection.Open()
$command     = New-Object MySql.Data.MySqlClient.MySqlCommand($querymaster, $MySQLConnection)
$dataAdapter = New-Object MySql.Data.MySqlClient.MySqlDataAdapter($command)
$dataSet     = New-Object System.Data.DataSet
$recordCount = $dataAdapter.Fill($dataSet, 'data')
$dataSet.Tables['data']

#Restart tomcat to get the platform running again:
Invoke-VMScript -VM $appserver1 -ScriptText "service tomcat restart" -GuestUser $GuestUser -GuestPassword $GuestPassword 
Invoke-VMScript -VM $appserver2 -ScriptText "service tomcat restart" -GuestUser $GuestUser -GuestPassword $GuestPassword 

# Get End Time
$endDTM = (Get-Date)

Write-Host "Cloning complete, environment operational, go log into the vms and check it out!" -ForeGroundColor Cyan

# Echo Time elapsed
"Elapsed Time: $(($endDTM-$startDTM).totalminutes) minutes"

#Notification for teams:
Send-MailMessage -To "Tech <rhr-tech@reeher.onmicrosoft.com>", "Product <RHR-ProductManagement@Reeher.onmicrosoft.com>", "Analytics <rhr-analytics@reeher.com>"   -From "IT <itnotifications@reeher.com>" -Subject "DB refresh in $environment is complete" -SmtpServer "reeher.mail.protection.outlook.com"

Stop-Transcript
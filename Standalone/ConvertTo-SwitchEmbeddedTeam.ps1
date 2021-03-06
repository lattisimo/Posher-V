<#
.SYNOPSIS
	Converts LBFO+Virtual Switch combinations to switch-embedded teams.

.DESCRIPTION
	Converts LBFO+Virtual Switch combinations to switch-embedded teams.

	Performs the following steps:
	1. Saves information about virtual switches and management OS vNICs (includes IPs, QoS settings, jumbo frame info, etc.)
	2. If system belongs to a cluster, sets to maintenance mode
	3. Disconnects attached virtual machine vNICs
	4. Deletes the virtual switch
	5. Deletes the LBFO team
	6. Creates switch-embedded team
	7. Recreates management OS vNICs
	8. Reconnects previously-attached virtual machine vNICs
	9. If system belongs to a cluster, ends maintenance mode

	If you do not specify any overriding parameters, the new switch uses the same settings as the original LBFO+team.

.PARAMETER Id
	The unique identifier(s) for the virtual switch(es) to convert.

.PARAMETER Name
	The name(s) of the virtual switch(es) to convert.

.PARAMETER VMSwitch
	The virtual switch(es) to convert.

.PARAMETER NewName
	Name(s) to assign to the converted virtual switch(es). If blank, keeps the original name.

.PARAMETER UseDefaults
	If specified, uses defaults for all values on the converted switch(es). If not specified, uses the same parameters as the original LBFO+switch or any manually-specified parameters.

.PARAMETER LoadBalancingAlgorithm
	Sets the load balancing algorithm for the converted switch(es). If not specified, uses the same setting as the original LBFO+switch or the default if UseDefaults is set.

.PARAMETER MinimumBandwidthMode
	Sets the desired QoS mode for the converted switch(es). If not specified, uses the same setting as the original LBFO+switch or the default if UseDefaults is set.

	None: No network QoS
	Absolute: minimum bandwidth values specify bits per second
	Weight: minimum bandwidth values range from 1 to 100 and represent percentages
	Default: use system default

	WARNING: Changing the QoS mode may cause guest vNICS to fail to re-attach and may inhibit Live Migration. Use carefully if you have special QoS settings on guest virtual NICs.

.PARAMETER Notes
	A note to associate with the converted switch(es). If not specified, uses the same setting as the original LBFO+switch or the default if UseDefaults is set.

.PARAMETER Force
	If specified, bypasses confirmation.

.NOTES
	Author: Eric Siron
	Version 1.0, December 22, 2019
	Released under MIT license

.EXAMPLE
	ConvertTo-SwitchEmbeddedTeam

	Converts all existing LBFO+switch combinations to switch embedded teams. Copies settings from original switches and management OS virtual NICs to new switch and vNICs.

.EXAMPLE
	ConvertTo-SwitchEmbeddedTeam -Name vSwitch

	Converts the LBFO+switch combination of the virtual switch named "vSwitch" to a switch embedded teams. Copies settings from original switch and management OS virtual NICs to new switch and vNICs.

.EXAMPLE
	ConvertTo-SwitchEmbeddedTeam -Force

	Converts all existing LBFO+team combinations without prompting.

.EXAMPLE
	ConvertTo-SwitchEmbeddedTeam -NewName NewSET

	If the system has one LBFO+switch, converts it to a switch-embedded team with the name "NewSET".
	If the system has multiple LBFO+switch combinations, fails due to mismatch (see next example).

.EXAMPLE
	ConvertTo-SwitchEmbeddedTeam -NewName NewSET1, NewSET2

	If the system has two LBFO+switches, converts them to switch-embedded team with the name "NewSET1" and "NEWSET2", IN THE ORDER THAT GET-VMSWITCH RETRIEVES THEM.

.EXAMPLE
	ConvertTo-SwitchEmbeddedTeam OldSwitch1, OldSwitch2 -NewName NewSET1, NewSET2

	Converts the LBFO+switches named "OldSwitch1" and "OldSwitch2" to SETs named "NewSET1" and "NewSET2", respectively.

.EXAMPLE
	ConvertTo-SwitchEmbeddedTeam -UseDefaults

	Converts all existing LBFO+switch combinations to switch embedded teams. Discards non-default settings for the switch and Hyper-V-related management OS vNICs. Keeps IP addresses and advanced settings (ex. jumbo frames).

.EXAMPLE
	ConvertTo-SwitchEmbeddedTeam -MinimumBandwidthMode Weight

	Converts all existing LBFO+switch combinations to switch embedded teams. Forces the new SET to use "Weight" for its minimum bandwidth mode.
	WARNING: Changing the QoS mode may cause guest vNICS to fail to re-attach and may inhibit Live Migration. Use carefully if you have special QoS settings on guest virtual NICs.

.LINK
https://ejsiron.github.io/Posher-V/ConvertTo-SwitchEmbeddedTeam
#>

#Requires -RunAsAdministrator
#Requires -Module Hyper-V
#Requires -Version 5

[CmdletBinding(DefaultParameterSetName = 'ByName', ConfirmImpact = 'High')]
param(
	[Parameter(Position = 1, ParameterSetName = 'ByName')][String[]]$Name = @(''),
	[Parameter(Position = 1, ParameterSetName = 'ByID', Mandatory = $true)][System.Guid[]]$Id,
	[Parameter(Position = 1, ParameterSetName = 'BySwitchObject', Mandatory = $true)][Microsoft.HyperV.PowerShell.VMSwitch[]]$VMSwitch,
	[Parameter(Position = 2)][String[]]$NewName = @(),
	[Parameter()][Switch]$UseDefaults,
	[Parameter()][Microsoft.HyperV.PowerShell.VMSwitchLoadBalancingAlgorithm]$LoadBalancingAlgorithm,
	[Parameter()][Microsoft.HyperV.PowerShell.VMSwitchBandwidthMode]$MinimumBandwidthMode,
	[Parameter()][String]$Notes = '',
	[Parameter()][Switch]$Force
)

BEGIN
{
	Set-StrictMode -Version Latest
	$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
	$IsClustered = $false
	if(Get-CimInstance -Namespace root -ClassName __NAMESPACE -Filter 'Name="MSCluster"')
	{
		$IsClustered = [bool](Get-CimInstance -Namespace root/MSCluster -ClassName mscluster_cluster -ErrorAction SilentlyContinue)
		$ClusterNode = Get-CimInstance -Namespace root/MSCluster -ClassName MSCluster_Node -Filter ('Name="{0}"' -f $env:COMPUTERNAME)
	}

	function Get-CimAdapterConfigFromVirtualAdapter
	{
		param(
			[Parameter()][psobject]$VNIC
		)
		$VnicCim = Get-CimInstance -Namespace root/virtualization/v2 -ClassName Msvm_InternalEthernetPort -Filter ('Name="{0}"' -f $VNIC.AdapterId)
		$VnicLanEndpoint1 = Get-CimAssociatedInstance -InputObject $VnicCim -ResultClassName Msvm_LANEndpoint
		$NetAdapter = Get-CimInstance -ClassName Win32_NetworkAdapter -Filter ('GUID="{0}"' -f $VnicLANEndpoint1.Name.Substring(($VnicLANEndpoint1.Name.IndexOf('{'))))
		Get-CimAssociatedInstance -InputObject $NetAdapter -ResultClassName Win32_NetworkAdapterConfiguration
	}

	function Get-AdvancedSettingsFromAdapterConfig
	{
		param(
			[Parameter()][psobject]$AdapterConfig
		)
		$MSFTAdapter = Get-CimInstance -Namespace root/StandardCimv2 -ClassName MSFT_NetAdapter -Filter ('InterfaceIndex={0}' -f $AdapterConfig.InterfaceIndex)
		Get-CimAssociatedInstance -InputObject $MSFTAdapter -ResultClassName MSFT_NetAdapterAdvancedPropertySettingData
	}

	class NetAdapterDataPack
	{
		[System.String]$Name
		[System.String]$MacAddress
		[System.Int64]$MinimumBandwidthAbsolute = 0
		[System.Int64]$MinimumBandwidthWeight = 0
		[System.Int64]$MaximumBandwidth = 0
		[System.Int32]$VlanId = 0
		[Microsoft.Management.Infrastructure.CimInstance]$NetAdapterConfiguration
		[Microsoft.Management.Infrastructure.CimInstance[]]$AdvancedProperties
		[Microsoft.Management.Infrastructure.CimInstance[]]$IPAddresses
		[Microsoft.Management.Infrastructure.CimInstance[]]$Gateways

		NetAdapterDataPack([psobject]$VNIC)
		{
			$this.Name = $VNIC.Name
			$this.MacAddress = $VNIC.MacAddress
			if ($VNIC.BandwidthSetting -ne $null)
			{
				$this.MinimumBandwidthAbsolute = $VNIC.BandwidthSetting.MinimumBandwidthAbsolute
				$this.MinimumBandwidthWeight = $VNIC.BandwidthSetting.MinimumBandwidthWeight
				$this.MaximumBandwidth = $VNIC.BandwidthSetting.MaximumBandwidth
			}

			$this.VlanId = [System.Int32](Get-VMNetworkAdapterVlan -VMNetworkAdapter $VNIC).AccessVlanId
			$this.NetAdapterConfiguration = Get-CimAdapterConfigFromVirtualAdapter -VNIC $VNIC
			$this.AdvancedProperties = @(Get-AdvancedSettingsFromAdapterConfig -AdapterConfig $this.NetAdapterConfiguration  | Where-Object -FilterScript { (-not [String]::IsNullOrEmpty($_.DefaultRegistryValue)) -and (-not [String]::IsNullOrEmpty([string]($_.RegistryValue))) -and (-not [String]::IsNullOrEmpty($_.DisplayName)) -and ($_.RegistryValue[0] -ne $_.DefaultRegistryValue) })

			# alternative to the below: use Get-NetIPAddress and Get-NetRoute, but they treat empty results as errors
			$this.IPAddresses = @(Get-CimInstance -Namespace root/StandardCimv2 -ClassName MSFT_NetIPAddress -Filter ('InterfaceIndex={0} AND PrefixOrigin=1' -f $this.NetAdapterConfiguration.InterfaceIndex))
			$this.Gateways = @(Get-CimInstance -Namespace root/StandardCimv2 -ClassName MSFT_NetRoute -Filter ('InterfaceIndex={0} AND Protocol=3' -f $this.NetAdapterConfiguration.InterfaceIndex)) # documentation says Protocol=2 for NetMgmt, testing shows otherwise
		}
	}

	class SwitchDataPack
	{
		[System.String]$Name
		[Microsoft.HyperV.PowerShell.VMSwitchBandwidthMode]$BandwidthReservationMode
		[System.UInt64]$DefaultFlow
		[System.String]$TeamName
		[System.String[]]$TeamMembers
		[System.UInt32]$LoadBalancingAlgorithm
		[NetAdapterDataPack[]]$HostVNICs

		SwitchDataPack(
			[psobject]$VSwitch,
			[Microsoft.Management.Infrastructure.CimInstance]$Team,
			[System.Object[]]$VNICs
		)
		{
			$this.Name = $VSwitch.Name
			$this.BandwidthReservationMode = $VSwitch.BandwidthReservationMode
			switch ($this.BandwidthReservationMode)
			{
				[Microsoft.HyperV.PowerShell.VMSwitchBandwidthMode]::Absolute { $this.DefaultFlow = $VSwitch.DefaultFlowMinimumBandwidthAbsolute }
				[Microsoft.HyperV.PowerShell.VMSwitchBandwidthMode]::Weight { $this.DefaultFlow = $VSwitch.DefaultFlowMinimumBandwidthWeight }
				default { $this.DefaultFlow = 0 }
			}
			$this.TeamName = $Team.Name
			$this.TeamMembers = ((Get-CimAssociatedInstance -InputObject $Team -ResultClassName MSFT_NetLbfoTeamMember).Name)
			$this.LoadBalancingAlgorithm = $Team.LoadBalancingAlgorithm
			$this.HostVNICs = $VNICs
		}
	}

	function Set-CimAdapterProperty
	{
		param(
			[Parameter()][System.Object]$InputObject,
			[Parameter()][System.String]$MethodName,
			[Parameter()][System.Object]$Arguments,
			[Parameter()][System.String]$Activity,
			[Parameter()][System.String]$Url
		)

		Write-Verbose -Message $Activity
		$CimResult = Invoke-CimMethod -InputObject $InputObject -MethodName $MethodName -Arguments $Arguments -ErrorAction Continue

		if ($CimResult -and $CimResult.ReturnValue -gt 0 )
		{
			Write-Warning -Message ('CIM error from operation: {0}. Consult {1} for error code {2}' -f $Activity, $Url, $CimResult.ReturnValue) -WarningAction Continue
		}
	}
}

PROCESS
{
	$VMSwitches = New-Object System.Collections.ArrayList
	$SwitchRebuildData = New-Object System.Collections.ArrayList

	switch ($PSCmdlet.ParameterSetName)
	{
		'ByID'
		{
			$VMSwitches.AddRange($Id.ForEach( { Get-VMSwitch -Id $_ -ErrorAction SilentlyContinue }))
		}
		'BySwitchObject'
		{
			$VMSwitches.AddRange($VMSwitch.ForEach( { $_ }))
		}
		default	# ByName
		{
			$NameList = New-Object System.Collections.ArrayList
			$NameList.AddRange($Name.ForEach( { $_.Trim() }))
			if ($NameList.Contains('') -or $NameList.Contains('*'))
			{
				$VMSwitches.AddRange(@(Get-VMSwitch -ErrorAction SilentlyContinue))
			}
			else
			{
				$VMSwitches.AddRange($NameList.ForEach( { Get-VMSwitch -Name $_ -ErrorAction SilentlyContinue }))
			}
		}
	}
	if ($VMSwitches.Count)
	{
		$VMSwitches = @(Select-Object -InputObject $VMSwitches -Unique)
	}
	else
	{
		throw('No virtual switches match the provided criteria')
	}

	Write-Progress -Activity 'Pre-flight' -Status 'Verifying operating system version' -PercentComplete 5 -Id 1
	Write-Verbose -Message 'Verifying operating system version'
	$OSVersion = [System.Version]::Parse((Get-CimInstance -ClassName Win32_OperatingSystem).Version)
	if ($OSVersion.Major -lt 10)
	{
		throw('Switch-embedded teams not supported on host operating system versions before 2016')
	}

	Write-Progress -Activity 'Pre-flight' -Status 'Loading virtual VMswitches' -PercentComplete 15 -Id 1

	if ($NewName.Count -gt 0 -and $NewName.Count -ne $VMSwitches.Count)
	{
		$SwitchNameMismatchMessage = 'Switch count ({0}) does not match NewName count ({1}).' -f $VMSwitches.Count, $NewName.Count
		if ($NewName.Count -lt $VMSwitches.Count)
		{
			$SwitchNameMismatchMessage += ' If you wish to rename some VMswitches but not others, specify an empty string for the VMswitches to leave.'
		}
		throw($SwitchNameMismatchMessage)
	}

	Write-Progress -Activity 'Pre-flight' -Status 'Validating virtual switch configurations' -PercentComplete 25 -Id 1
	Write-Verbose -Message 'Validating virtual switches'
	foreach ($VSwitch in $VMSwitches)
	{
		try
		{
			Write-Progress -Activity ('Validating virtual switch "{0}"' -f $VSwitch.Name) -Status 'Switch is external' -PercentComplete 25 -ParentId 1
			Write-Verbose -Message ('Verifying that switch "{0}" is external' -f $VSwitch.Name)
			if ($VSwitch.SwitchType -ne [Microsoft.HyperV.PowerShell.VMSwitchType]::External)
			{
				Write-Warning -Message ('Switch "{0}" is not external, skipping' -f $VSwitch.Name)
				continue
			}

			Write-Progress -Activity ('Validating virtual switch "{0}"' -f $VSwitch.Name) -Status 'Switch is not a SET' -PercentComplete 50 -ParentId 1
			Write-Verbose -Message ('Verifying that switch "{0}" is not already a SET' -f $VSwitch.Name)
			if ($VSwitch.EmbeddedTeamingEnabled)
			{
				Write-Warning -Message ('Switch "{0}" already uses SET, skipping' -f $VSwitch.Name)
				continue
			}

			Write-Progress -Activity ('Validating virtual switch "{0}"' -f $VSwitch.Name) -Status 'Switch uses LBFO' -PercentComplete 75 -ParentId 1
			Write-Verbose -Message ('Verifying that switch "{0}" uses an LBFO team' -f $VSwitch.Name)
			$TeamAdapter = Get-CimInstance -Namespace root/StandardCimv2 -ClassName MSFT_NetLbfoTeamNic -Filter ('InterfaceDescription="{0}"' -f $VSwitch.NetAdapterInterfaceDescription)
			if ($TeamAdapter -eq $null)
			{
				Write-Warning -Message ('Switch "{0}" does not use a team, skipping' -f $VSwitch.Name)
				continue
			}
			if ($TeamAdapter.VlanID)
			{
				Write-Warning -Message ('Switch "{0}" is bound to a team NIC with a VLAN assignment, skipping' -f $VSwitch.Name)
				continue
			}
		}
		catch
		{
			Write-Warning -Message ('Switch "{0}" failed validation, skipping. Error: {1}' -f $VSwitch.Name, $_.Exception.Message)
			continue
		}
		finally
		{
			Write-Progress -Activity ('Validating virtual switch "{0}"' -f $VSwitch.Name) -Completed -ParentId 1
		}

		Write-Progress -Activity ('Loading information from virtual switch "{0}"' -f $VSwitch.Name) -Status 'Team NIC' -PercentComplete 25 -ParentId 1
		Write-Verbose -Message 'Loading team'
		$Team = Get-CimAssociatedInstance -InputObject $TeamAdapter -ResultClassName MSFT_NetLbfoTeam


		Write-Progress -Activity ('Loading information from virtual switch "{0}"' -f $VSwitch.Name) -Status 'Host virtual adapters' -PercentComplete 50 -ParentId 1
		Write-Verbose -Message 'Loading management adapters connected to this switch'
		$HostVNICs = Get-VMNetworkAdapter -ManagementOS -SwitchName $VSwitch.Name

		Write-Verbose -Message 'Compiling virtual switch and management OS virtual NIC information'
		Write-Progress -Activity ('Loading information from virtual switch "{0}"' -f $VSwitch.Name) -Status 'Storing vSwitch data' -PercentComplete 75 -ParentId 1
		$OutNull = $SwitchRebuildData.Add([SwitchDataPack]::new($VSwitch, $Team, ($HostVNICs.ForEach({ [NetAdapterDataPack]::new($_) }))))
		Write-Progress -Activity ('Loading information from virtual switch "{0}"' -f $VSwitch.Name) -Completed
	}
	Write-Progress -Activity 'Pre-flight' -Status 'Cleaning up' -PercentComplete 99 -ParentId 1

	Write-Verbose -Message 'Clearing loop variables'
	$VSwitch = $Team = $TeamAdapter = $HostVNICs = $null

	Write-Progress -Activity 'Pre-flight' -Completed

	if($SwitchRebuildData.Count -eq 0)
	{
		Write-Warning -Message 'No eligible virtual switches found.'
		exit 1
	}

	$SwitchMark = 0
	$SwitchCounter = 1
	$SwitchStep = 1 / $SwitchRebuildData.Count * 100
	$ClusterNodeRunning = $IsClustered

	foreach ($OldSwitchData in $SwitchRebuildData)
	{
		$SwitchName = $OldSwitchData.Name
		if($NewName.Count -gt 0)
		{
			$SwitchName = $NewName[($SwitchCounter - 1)]
		}
		Write-Progress -Activity 'Rebuilding switches' -Status ('Processing virtual switch {0} ({1}/{2})' -f $SwitchName, $SwitchCounter, $SwitchRebuildData.Count) -PercentComplete $SwitchMark -Id 1
		$SwitchCounter++
		$SwitchMark += $SwitchStep
		$ShouldProcessTargetText = 'Virtual switch {0}' -f $OldSwitchData.Name
		$ShouldProcessOperation = 'Disconnect all virtual adapters, remove team and switch, build switch-embedded team, replace management OS vNICs, reconnect virtual adapters'
		if ($Force -or $PSCmdlet.ShouldProcess($ShouldProcessTargetText , $ShouldProcessOperation))
		{
			if($ClusterNodeRunning)
			{
				Write-Verbose -Message 'Draining cluster node'
				Write-Progress -Activity 'Draining cluster node' -Status 'Draining'
				$OutNull = Invoke-CimMethod -InputObject $ClusterNode -MethodName 'Pause' -Arguments @{DrainType=2;TargetNode=''}
				while($ClusterNodeRunning)
				{
					Start-Sleep -Seconds 1
					$ClusterNode = Get-CimInstance -InputObject $ClusterNode
					switch($ClusterNode.NodeDrainStatus)
					{
						0 { Write-Error -Message 'Failed to initiate cluster node drain' }
						2 { $ClusterNodeRunning = $false }
						3 { Write-Error -Message 'Failed to drain cluster roles' }
						# 1 is all that's left, will cause loop to continue
					}
				}
			}
			Write-Progress -Activity 'Draining cluster node' -Completed

			$SwitchProgressParams = @{Activity = ('Processing switch {0}' -f $OldSwitchData.Name); ParentId = 1; Id=2 }
			Write-Verbose -Message 'Disconnecting virtual machine adapters'
			Write-Progress @SwitchProgressParams -Status 'Disconnecting virtual machine adapters' -PercentComplete 10
			Write-Verbose -Message 'Loading VM adapters connected to this switch'
			$GuestVNICs = Get-VMNetworkAdapter -VMName * | Where-Object -Property SwitchName -EQ $OldSwitchData.Name
			if($GuestVNICs)
			{
				Disconnect-VMNetworkAdapter -VMNetworkAdapter $GuestVNICs
			}

			Start-Sleep -Milliseconds 250	# seems to prefer a bit of rest time between removal commands

			if($OldSwitchData.HostVNICs)
			{
				Write-Verbose -Message 'Removing management vNICs'
				Write-Progress @SwitchProgressParams -Status 'Removing management vNICs' -PercentComplete 20
				Remove-VMNetworkAdapter -ManagementOS
			}

			Start-Sleep -Milliseconds 250	# seems to prefer a bit of rest time between removal commands

			Write-Verbose -Message 'Removing virtual switch'
			Write-Progress @SwitchProgressParams -Status 'Removing virtual switch' -PercentComplete 30
			Remove-VMSwitch -Name $OldSwitchData.Name -Force

			Start-Sleep -Milliseconds 250	# seems to prefer a bit of rest time between removal commands

			Write-Verbose -Message 'Removing team'
			Write-Progress @SwitchProgressParams -Status 'Removing team' -PercentComplete 40
			Remove-NetLbfoTeam -Name $OldSwitchData.TeamName -Confirm:$false

			Start-Sleep -Milliseconds 250	# seems to prefer a bit of rest time between removal commands

			Write-Verbose -Message 'Creating SET'
			Write-Progress @SwitchProgressParams -Status 'Creating SET' -PercentComplete 50
			$SetLoadBalancingAlgorithm = $null
			if (-not $UseDefaults)
			{
				if ($OldSwitchData.LoadBalancingAlgorithm -eq 5)
				{
					$SetLoadBalancingAlgorithm = [Microsoft.HyperV.PowerShell.VMSwitchLoadBalancingAlgorithm]::Dynamic # 5 is dynamic; https://docs.microsoft.com/en-us/previous-versions/windows/desktop/ndisimplatcimprov/msft-netlbfoteam
				}
				else # SET does not have LBFO's hash options for load-balancing; assume that the original switch used a non-Dynamic mode for a reason
				{
					$SetLoadBalancingAlgorithm = [Microsoft.HyperV.PowerShell.VMSwitchLoadBalancingAlgorithm]::HyperVPort
				}
			}
			if ($LoadBalancingAlgorithm)
			{
				$SetLoadBalancingAlgorithm = $LoadBalancingAlgorithm
			}

			$NewMinimumBandwidthMode = $null
			if(-not $UseDefaults)
			{
				$NewMinimumBandwidthMode = $OldSwitchData.BandwidthReservationMode
			}
			if ($MinimumBandwidthMode)
			{
				$NewMinimumBandwidthMode = $MinimumBandwidthMode
			}
			$NewSwitchParams = @{NetAdapterName=$OldSwitchData.TeamMembers}
			if($NewMinimumBandwidthMode)
			{
				$NewSwitchParams.Add('MinimumBandwidthMode', $NewMinimumBandwidthMode)
			}

			try
			{
				$NewSwitch = New-VMSwitch @NewSwitchParams -Name $SwitchName -AllowManagementOS $false -EnableEmbeddedTeaming $true -Notes $Notes
			}
			catch
			{
				Write-Error -Message ('Unable to create virtual switch {0}: {1}' -f $SwitchName, $_.Exception.Message) -ErrorAction Continue
				continue
			}

			if($SetLoadBalancingAlgorithm)
			{
				Write-Verbose -Message ('Setting load balancing mode to {0}' -f $SetLoadBalancingAlgorithm)
				Write-Progress @SwitchProgressParams -Status 'Setting SET load balancing algorithm' -PercentComplete 60
				Set-VMSwitchTeam -Name $NewSwitch.Name -LoadBalancingAlgorithm $SetLoadBalancingAlgorithm
			}

			$VNICCounter = 0

			foreach($VNIC in $OldSwitchData.HostVNICs)
			{
				$VNICCounter++
				Write-Progress @SwitchProgressParams -Status ('Configuring management OS vNIC {0}/{1}' -f $VNICCounter, $OldSwitchData.HostVNICs.Count) -PercentComplete 70

				$VNICProgressParams = @{Activity = ('Processing VNIC {0}' -f $VNIC.Name); ParentId = 2; Id=3 }

				Write-Verbose -Message ('Adding virtual adapter "{0}" to switch "{1}"' -f $VNIC.Name, $NewSwitch.Name)
				Write-Progress @VNICProgressParams -Status 'Adding vNIC' -PercentComplete 10
				$NewNic = Add-VMNetworkAdapter -SwitchName $NewSwitch.Name -ManagementOS -Name $VNIC.Name -StaticMacAddress $VNIC.MacAddress -Passthru
				$SetNicParams = @{ }
				if ((-not $UseDefaults) -and $VNIC.MinimumBandwidthAbsolute -and $NewSwitch.BandwidthReservationMode -eq [Microsoft.HyperV.PowerShell.VMSwitchBandwidthMode]::Absolute)
				{
					$SetNicParams.Add('MinimumBandwidthAbsolute', $VNIC.MinimumBandwidthAbsolute)
				}
				elseif ((-not $UseDefaults) -and $VNIC.MinimumBandwidthWeight -and $NewSwitch.BandwidthReservationMode -eq [Microsoft.HyperV.PowerShell.VMSwitchBandwidthMode]::Weight)
				{
					$SetNicParams.Add('MinimumBandwidthWeight', $VNIC.MinimumBandwidthWeight)
				}
				if ($VNIC.MaximumBandwidth)
				{
					$SetNicParams.Add('MaximumBandwidth', $VNIC.MaximumBandwidth)
				}
				Write-Verbose -Message ('Setting properties on virtual adapter "{0}" on switch "{1}"' -f $VNIC.Name, $NewSwitch.Name)

				Write-Progress @VNICProgressParams -Status 'Setting vNIC parameters' -PercentComplete 20
				Set-VMNetworkAdapter -VMNetworkAdapter $NewNic @SetNicParams -ErrorAction Continue
				if($VNIC.VlanId)
				{
					Write-Progress @VNICProgressParams -Status 'Setting VLAN ID' -PercentComplete 30
					Write-Verbose -Message ('Setting VLAN ID on virtual adapter "{0}" on switch "{1}"' -f $VNIC.Name, $NewSwitch.Name)
					Set-VMNetworkAdapterVlan -VMNetworkAdapter $NewNic -Access -VlanId $VNIC.VlanId
				}
				$NewNicConfig = Get-CimAdapterConfigFromVirtualAdapter -VNIC $NewNic

				if ($VNIC.IPAddresses.Count -gt 0)
				{
					Write-Progress @VNICProgressParams -Status 'Setting IP and subnet masks' -PercentComplete 40
					foreach($IPAddressData in $VNIC.IPAddresses)
					{
						Write-Verbose -Message ('Setting IP address {0}' -f $IPAddressData.IPAddress)
						$OutNull = New-NetIPAddress -InterfaceIndex $NewNicConfig.InterfaceIndex -IPAddress $IPAddressData.IPAddress -PrefixLength $IPAddressData.PrefixLength -SkipAsSource $IPAddressData.SkipAsSource -ErrorAction Continue
					}

					Write-Progress @VNICProgressParams -Status 'Setting DNS registration behavior' -PercentComplete 41
					Set-CimAdapterProperty -InputObject $NewNicConfig -MethodName 'SetDynamicDNSRegistration' `
					-Arguments @{ FullDNSRegistrationEnabled = $VNIC.NetAdapterConfiguration.FullDNSRegistrationEnabled; DomainDNSRegistrationEnabled = $VNIC.NetAdapterConfiguration.DomainDNSRegistrationEnabled } `
					-Activity ('Setting DNS registration behavior (dynamic registration: {0}, with domain name: {1}) on {2}' -f $VNIC.NetAdapterConfiguration.FullDNSRegistrationEnabled, $VNIC.NetAdapterConfiguration.DomainDNSRegistrationEnabled, $NewNic.Name) `
					-Url 'https://docs.microsoft.com/en-us/windows/win32/cimwin32prov/setdynamicdnsregistration-method-in-class-win32-networkadapterconfiguration'

					foreach($GatewayData in $VNIC.Gateways)
					{
						Write-Verbose -Message ('Setting gateway address {0}' -f $GatewayData.NextHop)
						$OutNull = New-NetRoute -InterfaceIndex $NewNicConfig.InterfaceIndex -DestinationPrefix $GatewayData.DestinationPrefix -NextHop $GatewayData.NextHop -RouteMetric $GatewayData.RouteMetric
					}

					Write-Progress @VNICProgressParams -Status 'Setting gateways' -PercentComplete 42
					if ($VNIC.NetAdapterConfiguration.DefaultIPGateway)
					{
						Set-CimAdapterProperty -InputObject $NewNicConfig -MethodName 'SetGateways' `
						-Arguments @{ DefaultIPGateway = $VNIC.NetAdapterConfiguration.DefaultIPGateway } `
						-Activity ('Setting gateways {0} on {1}'  -f $VNIC.NetAdapterConfiguration.DefaultIPGateway, $NewNic.Name) `
						-Url 'https://docs.microsoft.com/en-us/windows/win32/cimwin32prov/setgateways-method-in-class-win32-networkadapterconfiguration'
					}

					if($VNIC.NetAdapterConfiguration.DNSDomain)
					{
						Write-Progress @VNICProgressParams -Status 'Setting DNS domain' -PercentComplete 43
						Set-CimAdapterProperty -InputObject $NewNicConfig -MethodName 'SetDNSDomain' `
						-Arguments @{ DNSDomain = $VNIC.NetAdapterConfiguration.DNSDomain } `
						-Activity ('Setting DNS domain {0} on {1}' -f $VNIC.NetAdapterConfiguration.DNSDomain, $NewNic.Name) `
						-Url 'https://docs.microsoft.com/en-us/windows/win32/cimwin32prov/setdnsdomain-method-in-class-win32-networkadapterconfiguration'
					}

					if ($VNIC.NetAdapterConfiguration.DNSServerSearchOrder)
					{
						Write-Progress @VNICProgressParams -Status 'Setting DNS servers' -PercentComplete 44
						Set-CimAdapterProperty -InputObject $NewNicConfig -MethodName 'SetDNSServerSearchOrder' `
						-Arguments @{ DNSServerSearchOrder = $VNIC.NetAdapterConfiguration.DNSServerSearchOrder } `
						-Activity ('setting DNS servers {0} on {1}' -f [String]::Join(', ', $VNIC.NetAdapterConfiguration.DNSServerSearchOrder), $NewNic.Name) `
						-Url 'https://docs.microsoft.com/en-us/windows/win32/cimwin32prov/setdnsserversearchorder-method-in-class-win32-networkadapterconfiguration'
					}

					if($VNIC.NetAdapterConfiguration.WINSPrimaryServer)
					{
						Write-Progress @VNICProgressParams -Status 'Setting WINS servers' -PercentComplete 45
						Set-CimAdapterProperty -InputObject $NewNicConfig -MethodName 'SetWINSServer' `
						-Arguments @{ WINSPrimaryServer = $VNIC.NetAdapterConfiguration.WINSPrimaryServer; WINSSecondaryServer = $VNIC.NetAdapterConfiguration.WINSSecondaryServer }
						-Activity ('Setting WINS servers {0} on {1}' -f ([String]::Join(', ', $VNIC.NetAdapterConfiguration.WINSPrimaryServer, $VNIC.NetAdapterConfiguration.WINSSecondaryServer)), $NewNic.Name) `
						-Url 'https://docs.microsoft.com/en-us/windows/win32/cimwin32prov/setwinsserver-method-in-class-win32-networkadapterconfiguration'
					}
				}
				if($VNIC.NetAdapterConfiguration.TcpipNetbiosOptions)	# defaults to 0
				{
					Write-Progress @VNICProgressParams -Status 'Setting NetBIOS over TCP/IP behavior' -PercentComplete 50
					Set-CimAdapterProperty -InputObject $NewNicConfig -MethodName 'SetTcpipNetbios' `
					-Arguments @{ TcpipNetbiosOptions = $VNIC.NetAdapterConfiguration.TcpipNetbiosOptions } `
					-Activity ('Setting NetBIOS over TCP/IP behavior on {0} to {1}' -f $NewNic.Name, $VNIC.NetAdapterConfiguration.TcpipNetbiosOptions) `
					-Url 'https://docs.microsoft.com/en-us/windows/win32/cimwin32prov/settcpipnetbios-method-in-class-win32-networkadapterconfiguration'
				}

				Write-Progress @VNICProgressParams -Status 'Applying advanced properties' -PercentComplete 60
				$NewNicAdvancedProperties = Get-AdvancedSettingsFromAdapterConfig -AdapterConfig $NewNicConfig
				$PropertiesCounter = 0
				$PropertyProgressParams = @{Activity = 'Processing VNIC advanced properties'; ParentId = 3; Id=4 }
				foreach($SourceAdvancedProperty in $VNIC.AdvancedProperties)
				{
					foreach($NewNicAdvancedProperty in $NewNicAdvancedProperties)
					{
						if($SourceAdvancedProperty.ElementName -eq $NewNicAdvancedProperty.ElementName)
						{
							$PropertiesCounter++
							Write-Progress @PropertyProgressParams -PercentComplete ($PropertiesCounter / $VNIC.AdvancedProperties.Count * 100) -Status ('Applying property {0}' -f $SourceAdvancedProperty.DisplayName)
							Write-Verbose ('Setting advanced property {0} to {1} on {2}' -f $SourceAdvancedProperty.DisplayName, $SourceAdvancedProperty.DisplayValue, $VNIC.Name)
							$NewNicAdvancedProperty.RegistryValue = $SourceAdvancedProperty.RegistryValue
							Set-CimInstance -InputObject $NewNicAdvancedProperty -ErrorAction Continue
						}
					}
				}
			}

			Write-Progress @VNICProgressParams -Completed

			Write-Progress @SwitchProgressParams -Status 'Reconnecting guest vNICs' -PercentComplete 80

			if($GuestVNICs)
			{
				foreach ($GuestVNIC in $GuestVNICs)
				{
					try
					{
						Connect-VMNetworkAdapter -VMNetworkAdapter $GuestVNIC -VMSwitch $NewSwitch
					}
					catch
					{
						Write-Error -Message ('Failed to connect virtual adapter "{0}" with MAC address "{1}" to virtual switch "{2}": {3}' -f $GuestVNIC.Name, $GuestVNIC.MacAddress, $NewSwitch.Name, $_.Exception.Message) -ErrorAction Continue
					}
				}
			}

			Write-Progress @SwitchProgressParams -Completed
		}
	}
	if($IsClustered)
	{
		Write-Verbose -Message 'Resuming cluster node'
		$OutNull = Invoke-CimMethod -InputObject $ClusterNode -MethodName 'Resume' -Arguments @{FailbackType=1}
	}
}

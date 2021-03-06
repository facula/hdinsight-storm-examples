﻿<# 
.SYNOPSIS 
  Helper functions for HDInsight script action.
   
.DESCRIPTION 
  This module provides a list of functions that makes writing script action on HDInsight cluster easy.
#> 


function Save-HDIFile {
    param (
        [parameter(Mandatory)][string] $SrcUri,
        [parameter(Mandatory)][string] $DestFile,
        [parameter()][bool] $ForceOverwrite
    )
    # Return if destination file exists and force overwrite flag is off.
    if (!($ForceOverwrite) -and (Test-Path $DestFile)) {
        return
    }

    # Hash the src uri to a well structured format.
    $md5 = new-object -TypeName System.Security.Cryptography.MD5CryptoServiceProvider
    $utf8 = new-object -TypeName System.Text.UTF8Encoding
    $hashedSrcUri = [System.BitConverter]::ToString($md5.ComputeHash($utf8.GetBytes($SrcUri)))

    if (Test-IsHDIHeadNode) {
        $group = "headnode";
    } else {
        $group = "workernode";
    }

    # Make sure config action cache directory is made.
    $output = Invoke-HDICmdScript -CmdToExecute "%HADOOP_HOME%\bin\hadoop fs -mkdir -p /configactioncache/$group";

    # Check if the file looking for is cached on WASB.
    $output = Invoke-HDICmdScript -CmdToExecute "hadoop fs -ls /configactioncache/$group/$hashedSrcUri";

    # Download source to local disk.
    if (!$output.Contains("No such file")) {
        # Download the file from WASB if it is there.
        Write-HDILog "Fetching from WASB cache"
        $output = Invoke-HDICmdScript -CmdToExecute "hadoop fs -copyToLocal /configactioncache/$group/$hashedSrcUri $DestFile";
    } else {
        # Download the file from remote location.
        $webclient = New-Object System.Net.WebClient
        $webclient.DownloadFile($SrcUri, $destFile)

        # Cache this file to WASB. Only active headnode or workernode0 will cache to avoid collision.
        if ((Test-IsHDIFirstDataNode) -or (Test-IsActiveHDIHeadNode)) {
            $output = Invoke-HDICmdScript -CmdToExecute "%HADOOP_HOME%\bin\hadoop fs -copyFromLocal -f $destFile /configactioncache/$group/$hashedSrcUri";
        }
    }

    $rule = new-object System.Security.AccessControl.FileSystemAccessRule("$(whoami)", "FullControl", "Allow");
    $acl = Get-ACL $DestFile;
    $acl.SetAccessRule($rule);
    Set-ACL -Path $DestFile -AclObject $acl;   
}

function Expand-HDIZippedFile {
    param (
        [parameter(Mandatory)][string] $ZippedFile,
        [parameter(Mandatory)][string] $UnzipFolder
    )
    # Only unzip if the zip file and unzip folder exist.
    if ((Test-Path $ZippedFile) -and (Test-Path $UnzipFolder)) {
        $shell = new-object -com shell.application
        $zipPackage = $shell.NameSpace($ZippedFile)
        $destFolder = $shell.NameSpace($UnzipFolder)
        $destFolder.CopyHere($zipPackage.Items(), 16) # 16 is used to overwrite existing files.
    }
}

function Invoke-HDICmdScript {
    param (
        [parameter(Mandatory)][string] $CmdToExecute
    )
    # Start a cmd.exe shell and execute the script there.
    $output = (cmd /c "$CmdToExecute 2>&1") | Out-String
    return $output
}

function Write-HDILog {
    param (
        [parameter()][string] $LogToWrite
    )
    # Write-Output is the only way to write to log in HDInsight 
    # config action scripts.
    if ($LogToWrite)
    {
        Write-Output $LogToWrite
    }
}


function Get-Services {
    return Get-WMIObject win32_service
}

function Get-HDIServices {
    # All HDI services should have description with "Apache Hadoop"
    return Get-Services | where { $_.DisplayName -cmatch "Apache Hadoop" }
}

function Get-Service {
    param (
        [parameter(Mandatory)][string] $ServiceName
    )
    return Get-Services | Where-Object {$_.name -eq "$ServiceName" }
}

function Get-HDIService {
    param (
        [parameter(Mandatory)][string] $ServiceName
    )
    return Get-HDIservices | Where-Object {$_.name -eq "$ServiceName" }
}

function Get-ServicesRunning {
    return Get-Services | Where-Object {$_.state -eq "Running"}
}

function Get-ServiceRunning {
    param (
        [parameter(Mandatory)][string] $ServiceName
    )
    return Get-Service -ServiceName "$ServiceName" | Where-Object {$_.state -eq "Running"}
}

function Get-HDIServicesRunning {
    return Get-HDIservices | Where-Object {$_.state -eq "Running"}
}

function Get-HDIServiceRunning {
    param (
        [parameter(Mandatory)][string] $ServiceName
    )
    return Get-HDIservice -ServiceName "$ServiceName" | Where-Object {$_.state -eq "Running"}
}

function Get-HDIHadoopVersion {
    return Split-Path "$env:HADOOP_HOME" -Leaf
}

function Test-IsHDIHeadNode {
    # If the namenode service exists, it must be a headnode.
    return (Get-HDIService -ServiceName "namenode") -ne $null
}

function Test-IsActiveHDIHeadNode {
    # If the namenode service exists and running on this node, it must be the active headnode.
    return (Get-HDIServiceRunning -ServiceName "namenode") -ne $null

}

function Test-IsHDIDataNode {
    # If the datanode service exists, it must be a datanode.
    return (Get-HDIService -ServiceName "datanode") -ne $null
}

function Test-IsHDIFirstDataNode {
    return (Test-IsHDIDataNode) -and ($(hostname).Equals("workernode0"))
}

function Edit-HDIConfigFile {
    param (
        [parameter(Mandatory)][string] $ConfigFileName,
        [parameter(Mandatory)][string] $Name,
        [parameter(Mandatory)][string] $Value,
        [parameter()][string] $Description
    )

    if (!$Description) {
        $Description = ""
    }

    $hdiConfigFiles = @{
        "hive-site.xml" = "$env:HIVE_HOME\conf\hive-site.xml";
        "core-site.xml" = "$env:HADOOP_HOME\etc\hadoop\core-site.xml";
        "hdfs-site.xml" = "$env:HADOOP_HOME\etc\hadoop\hdfs-site.xml";
        "mapred-site.xml" = "$env:HADOOP_HOME\etc\hadoop\mapred-site.xml";
        "yarn-site.xml" = "$env:HADOOP_HOME\etc\hadoop\yarn-site.xml"
    }

    if (!($hdiConfigFiles[$ConfigFileName])) {
        Write-HDILog "Unable to configure $ConfigFileName because it is not part of the HDI configuration files"
        return
    }

    [xml]$configFile = Get-Content $hdiConfigFiles[$ConfigFileName]

    $existingproperty = $configFile.configuration.property | where {$_.Name -eq $Name}
    
    if ($existingproperty) {
        $existingproperty.Value = $Value
        $existingproperty.Description = $Description
    } else {
        $newproperty = @($configFile.configuration.property)[0].Clone()
        $newproperty.Name = $Name
        $newproperty.Value = $Value
        $newproperty.Description = $Description
        $configFile.configuration.AppendChild($newproperty)
    }

    $configFile.Save($hdiConfigFiles[$ConfigFileName])
}


Export-ModuleMember -function Save-HDIFile
Export-ModuleMember -function Expand-HDIZippedFile
Export-ModuleMember -function Invoke-HDICmdScript
Export-ModuleMember -function Write-HDILog
Export-ModuleMember -function Get-Services
Export-ModuleMember -function Get-Service
Export-ModuleMember -function Get-HDIServices
Export-ModuleMember -function Get-HDIService
Export-ModuleMember -function Get-ServicesRunning
Export-ModuleMember -function Get-ServiceRunning
Export-ModuleMember -function Get-HDIServicesRunning
Export-ModuleMember -function Get-HDIServiceRunning
Export-ModuleMember -function Get-HDIHadoopVersion
Export-ModuleMember -function Test-IsHDIHeadNode
Export-ModuleMember -function Test-IsActiveHDIHeadNode
Export-ModuleMember -function Test-IsHDIDataNode
Export-ModuleMember -function Test-IsHDIFirstDataNode
Export-ModuleMember -function Edit-HDIConfigFile
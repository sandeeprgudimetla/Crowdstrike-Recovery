param(
    $AZUserID = "",
    $AZPassword = "",
    $SubscriptionName = "",
    $ResourceGroup = ""
)

Function Start-Log {
    param(
        [string]$LogFileName
    )
    $Location = (Join-Path $PSScriptRoot $LogFileName)
    New-Item -ItemType file $Location -Force | Out-Null
    $Global:LogFileLocation = $Location
}

Function Log-Info {
    param(
        [string]$Message
    )
    
    $logEntry = [pscustomobject]@{
        log_level = "INFO"
        message   = $Message
    }
    $logEntry | Export-Csv -Path $Global:LogFileLocation -Encoding ASCII -Append -NoTypeInformation -Force 
}

Function Log-Error {
    param(
        [string]$Message
    )
    $logEntry = [pscustomobject]@{
        log_level = "ERROR"
        message   = $Message
    }
    $logEntry | Export-Csv -Path $Global:LogFileLocation -Encoding ASCII -Append -NoTypeInformation -Force
}

Function Archive-Report {
    param(
        $FileName
    )
    $ArchiveDir = Join-Path $PSScriptRoot "Archive"
    [System.IO.Directory]::CreateDirectory($ArchiveDir) | Out-Null
    if (Test-Path $FileName) {
        Move-Item $FileName -Destination $ArchiveDir -Force
    }
}

$VMReportFile = Join-Path $PSScriptRoot "VMReport.csv"
Start-Log -LogFileName "Log_VMReport.csv"
Archive-Report $VMReportFile

try {
    #az cli login
    az login --username $AZUserID --password $AZPassword
    az account set --subscription $SubscriptionName

    [array]$Computers = Get-Content (Join-Path $PSScriptRoot "servers.txt") | Select-Object -Unique
    $VMRepairReport = @()

    foreach ($computer in $Computers) {
        try {
            $computer = $computer.Trim()
            $VMExists = az vm show --name $computer --resource-group $ResourceGroup --ouput none --query "id"
            if ($?) {
                Log-Info -Message "Creating repair VM for $computer in $ResourceGroup" 
                az vm repair create --resource-group $ResourceGroup --name $computer
            
                Log-Info -Message "Running repair script on $computer in $ResourceGroup" 
                az vm repair run --resource-group $ResourceGroup --name $computer --run-id win-crowdstrike-fix-bootloop --run-on-repair --verbose
                
                Log-Info -Message "Restoring $computer in $ResourceGroup"
                az vm repair restore --resource-group $ResourceGroup --name $computer
                
                $VMRepairReport += New-Object psobject -Property @{
                    VM           = $computer
                    RepairStatus = "SUCCESS"            
                }
            }
            else {
                Log-Info -Message "vm $computer does not exist in resource group $ResourceGroup" 
                $VMRepairReport += New-Object psobject -Property @{
                    VM           = $computer
                    RepairStatus = "DOES_NOT_EXIST"            
                }
            }
        }
        catch {
            $VMRepairReport += New-Object psobject -Property @{
                VM           = $computer
                RepairStatus = "FAILED"            
            }
            Log-Error -Message "Failed to repair VM $computer"
            Log-Error -Message $("ErrorRecord : {0}, CommandName: {1}, Message: {2}" -f $_.Exception.ErrorRecord, $_.Exception.CommandName, $_.Exception.Message)
        }
    }
    if ($VMRepairReport) {
        Log-Info -Message "Generating consolidated report."
        #$VMRepairReport | Export-Excel $VMReportFile -WorksheetName "VMReport"
        $VMRepairReport | Export-Csv $VMReportFile -NoTypeInformation
    }
}
catch {
    Log-Error -Message $("ErrorRecord : {0}, CommandName: {1}, Message: {2}" -f $_.Exception.ErrorRecord, $_.Exception.CommandName, $_.Exception.Message)
}

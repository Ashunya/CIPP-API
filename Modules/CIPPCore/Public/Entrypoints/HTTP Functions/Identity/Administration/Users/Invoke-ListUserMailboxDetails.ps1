using namespace System.Net

Function Invoke-ListUserMailboxDetails {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Exchange.Mailbox.Read
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $TriggerMetadata.FunctionName
    Write-LogMessage -user $request.headers.'x-ms-client-principal' -API $APINAME -message 'Accessed this API' -Sev 'Debug'

    # Write to the Azure Functions log stream.
    Write-Host 'PowerShell HTTP trigger function processed a request.'

    # Interact with query parameters or the body of the request.
    $TenantFilter = $Request.Query.TenantFilter
    $UserID = $Request.Query.UserID

    try {
        $Requests = @(
            @{
                CmdletInput = @{
                    CmdletName = 'Get-Mailbox'
                    Parameters = @{ Identity = $UserID }
                }
            },
            @{
                CmdletInput = @{
                    CmdletName = 'Get-MailboxPermission'
                    Parameters = @{ Identity = $UserID }
                }
            },
            @{
                CmdletInput = @{
                    CmdletName = 'Get-CASMailbox'
                    Parameters = @{ Identity = $UserID }
                }
            },
            @{
                CmdletInput = @{
                    CmdletName = 'Get-OrganizationConfig'
                }
            },
            @{
                CmdletInput = @{
                    CmdletName = 'Get-MailboxStatistics'
                    Parameters = @{ Identity = $UserID; Archive = $true }
                }
            },
            @{
                CmdletInput = @{
                    CmdletName = 'Get-BlockedSenderAddress'
                    Parameters = @{ Identity = $UserID }
                }
            },
            @{
                CmdletInput = @{
                    CmdletName = 'Get-RecipientPermission'
                    Parameters = @{ Identity = $UserID }
                }
            }
        )
        Write-Host $UserID
        #$username = (New-GraphGetRequest -tenantid $TenantFilter -uri "https://graph.microsoft.com/beta/users/$UserID").userPrincipalName
        $Results = New-ExoBulkRequest -TenantId $TenantFilter -CmdletArray $Requests -returnWithCommand $true -Anchor $username

        # Assign variables from $Results
        $MailboxDetailedRequest = $Results.'Get-Mailbox'
        $PermsRequest = $Results.'Get-MailboxPermission'
        $CASRequest = $Results.'Get-CASMailbox'
        $OrgConfig = $Results.'Get-OrganizationConfig'
        $ArchiveSizeRequest = $Results.'Get-MailboxStatistics'
        $BlockedSender = $Results.'Get-BlockedSenderAddress'
        $PermsRequest2 = $Results.'Get-RecipientPermission'
        $StatsRequest = New-GraphGetRequest -uri "https://outlook.office365.com/adminapi/beta/$($tenantfilter)/Mailbox('$($MailboxDetailedRequest.UserPrincipalName)')/Exchange.GetMailboxStatistics()" -Tenantid $tenantfilter -scope ExchangeOnline -noPagination $true


        # Handle ArchiveEnabled and AutoExpandingArchiveEnabled
        try {
            if ($MailboxDetailedRequest.ArchiveStatus -eq 'Active') {
                $ArchiveEnabled = $True
            } else {
                $ArchiveEnabled = $False
            }

            # Get organization config of auto-expanding archive if it's disabled on user level
            if (-not $MailboxDetailedRequest.AutoExpandingArchiveEnabled -and $ArchiveEnabled) {
                $AutoExpandingArchiveEnabled = $OrgConfig.AutoExpandingArchiveEnabled
            } else {
                $AutoExpandingArchiveEnabled = $MailboxDetailedRequest.AutoExpandingArchiveEnabled
            }
        } catch {
            $ArchiveEnabled = $False
            $ArchiveSizeRequest = @{
                TotalItemSize = '0'
                ItemCount     = '0'
            }
        }


        # Determine if the user is blocked for spam
        if ($BlockedSender -and $BlockedSender.Count -gt 0) {
            $BlockedForSpam = $True
        } else {
            $BlockedForSpam = $False
        }
    } catch {
        Write-Error "Failed Fetching Data $($_.Exception.message): $($_.InvocationInfo.ScriptLineNumber)"
    }

    # Parse permissions

    $ParsedPerms = foreach ($PermSet in @($PermsRequest, $PermsRequest2)) {
        foreach ($Perm in $PermSet) {
            # Check if Trustee or User is not NT AUTHORITY\SELF
            $user = $Perm.Trustee ? $Perm.Trustee : $Perm.User
            if ($user -ne 'NT AUTHORITY\SELF') {
                [PSCustomObject]@{
                    User         = $user
                    AccessRights = ($Perm.AccessRights) -join ', '
                }
            }
        }
    }

    # Get forwarding address
    $ForwardingAddress = if ($MailboxDetailedRequest.ForwardingAddress) {
        (New-GraphGetRequest -TenantId $TenantFilter -Uri "https://graph.microsoft.com/beta/users/$($MailboxDetailedRequest.ForwardingAddress)").UserPrincipalName
    } elseif ($MailboxDetailedRequest.ForwardingSmtpAddress -and $MailboxDetailedRequest.ForwardingAddress) {
        "$($MailboxDetailedRequest.ForwardingAddress) $($MailboxDetailedRequest.ForwardingSmtpAddress)"
    } else {
        $MailboxDetailedRequest.ForwardingSmtpAddress
    }

    # Build the GraphRequest object
    $GraphRequest = [ordered]@{
        ForwardAndDeliver        = $MailboxDetailedRequest.DeliverToMailboxAndForward
        ForwardingAddress        = $ForwardingAddress
        LitigationHold           = $MailboxDetailedRequest.LitigationHoldEnabled
        HiddenFromAddressLists   = $MailboxDetailedRequest.HiddenFromAddressListsEnabled
        EWSEnabled               = $CASRequest.EwsEnabled
        MailboxMAPIEnabled       = $CASRequest.MAPIEnabled
        MailboxOWAEnabled        = $CASRequest.OWAEnabled
        MailboxImapEnabled       = $CASRequest.ImapEnabled
        MailboxPopEnabled        = $CASRequest.PopEnabled
        MailboxActiveSyncEnabled = $CASRequest.ActiveSyncEnabled
        Permissions              = @($ParsedPerms)
        ProhibitSendQuota        = [math]::Round([float]($MailboxDetailedRequest.ProhibitSendQuota -split ' GB')[0], 2)
        ProhibitSendReceiveQuota = [math]::Round([float]($MailboxDetailedRequest.ProhibitSendReceiveQuota -split ' GB')[0], 2)
        ItemCount                = [math]::Round($StatsRequest.ItemCount, 2)
        TotalItemSize            = [math]::Round($StatsRequest.TotalItemSize / 1Gb, 2)
        TotalArchiveItemSize     = if ($ArchiveEnabled) { [math]::Round($ArchiveSizeRequest.TotalItemSize / 1Gb, 2) } else { '0' }
        TotalArchiveItemCount    = if ($ArchiveEnabled) { [math]::Round($ArchiveSizeRequest.ItemCount, 2) } else { 0 }
        BlockedForSpam           = $BlockedForSpam
        ArchiveMailBox           = $ArchiveEnabled
        AutoExpandingArchive     = $AutoExpandingArchiveEnabled
        RecipientTypeDetails     = $MailboxDetailedRequest.RecipientTypeDetails
        Mailbox                  = $MailboxDetailedRequest
    }

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body       = @($GraphRequest)
        })
}

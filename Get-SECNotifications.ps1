function Get-SECNotifications {

    <#
        .SYNOPSIS
            This will first check for a CSV of tickers in the folder where the script is stored. Then it will check each ticker's filings. If it finds some from today then it will alert you by email.

        .EXAMPLE
            Get-SECNotifications -toEmail <address@provider.com> -fromEmail <emailaddress@gmail.com> -appPassword <abcdefghijlmnopq>

            Be sure to swap these out with your own information, see the last line of the script.

        .PARAMETER to
            This is the email address that would like to receive alerts. It can be same or different than the from email.

        .PARAMETER from
            This is the email address that needs to login and send the email with the alert information in the subect and body. In the examples I have used GMail.

        .PARAMETER appPassword
            This is the app password that should be created ahead of time. App passwords bypass interactive sign-ins and do not require MFA.
    #>

    param (
        [CmdletBinding()]
    
        [Parameter(Mandatory)]
        [string]$to,

        [Parameter(Mandatory)]
        [string]$from,

        [parameter(Mandatory)]
        [string]$appPassword
    )

    begin {
        # Variables
        $ErrorActionPreference = 'Stop' # stop script if there is an error
        $logDate = Get-Date -Format yyyy-MM-dd # today's date, the day the script is running, formatted as string
        $files = Get-ChildItem -Path $PSScriptRoot\*.CSV # CSV files found in the folder the script is running in
        $csvHeader = 'Ticker' # AKA column title
        $tickerList = [Collections.Generic.Hashset[String]]@() # hashset to store our tickers
        $cikList = [Collections.Generic.Hashset[String]]@() # hashset to store our tickers' CIKs
        $tickerSite = 'https://www.sec.gov/files/company_tickers.json' #site for for all company tickers and CIKs registered with the SEC
        $hdrs = @{"User-Agent" = "personal use $from"} #API headers
        $tickerResponse = Invoke-RestMethod -Headers $hdrs -uri $tickerSite #API call to get ticker & CIK data
        Start-Sleep -Milliseconds 100 # only 10 requests per second allowed so we pad each API call with 100ms
        $responseNumbers = ($tickerResponse | Get-Member | Where-Object {$_.membertype -eq 'NoteProperty'}).Name # enumerated numbered list from $tickerSite's API call
        $date = Get-Date # today's date unformatted as date
        $sixAmEst = (New-Object DateTimeOffset((Get-Date).Date.AddHours(6), ([TimeZoneInfo]::FindSystemTimeZoneById("Eastern Standard Time")).BaseUtcOffset)).DateTime # converted to Eastern Standard Time
        $tenPmEst = (New-Object DateTimeOffset((Get-Date).Date.AddHours(22), ([TimeZoneInfo]::FindSystemTimeZoneById("Eastern Standard Time")).BaseUtcOffset)).DateTime # converted to Eastern Standard Time
        $spacFilings = [Collections.Generic.Hashset[PSCustomObject]]@() # hashset to store our list of SPAC objects
        $secWebsite = 'https://www.sec.gov/Archives/edgar/data' # filing website prefix
        $pass = ConvertTo-SecureString -String $appPassword -AsPlainText -Force # secure's GMail app password
        $credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $from, $pass # GMail login credentials
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12, [Net.SecurityProtocolType]::Tls11 # set TLS security (for sending email)

        # Start-Transcript
        Start-Transcript -Path "$PSScriptRoot\Get_Notifications_Logfile $logDate.txt" # creates a log file
    } # end begin

    process {
        # Import Tickers
        if ($files.Count -gt 1) {
            Write-Warning -Message "--too many CSV files found in $PSScriptRoot."
            Exit
        } else {
            $csv = Import-Csv -Path $PSScriptRoot\*.CSV -Header $csvHeader
            foreach ($item in $csv) {
                [void]$tickerList.Add($item.ticker)
            }
        }

        # Use ticker to find CIK
        #   --create a 10 digit CIK
        #   --add CIK to list
        foreach ($number in $responseNumbers) {
            foreach ($ticker in $tickerList) {
                if ($tickerResponse.$number.ticker -eq $ticker) {
                    $cik_str = ($tickerResponse.$number).cik_str.ToString().padLeft(10,'0')
                    [void]$cikList.Add($cik_str)
                }
            }  
        }

        # Only check for filing if submission window is open
        while (($date -ge $sixAmEst) -and ($date -le $tenPmEst)) {

            # Check each CIK individually to see if there are filings dated TODAY / space requests to 10 per second
            foreach ($cik in $cikList) {
                $n = 0 # '0' equals 1st filing
                $filingUri = "https://data.sec.gov/submissions/CIK$cik.json" # CIK specific
                $response = Invoke-RestMethod -Headers $hdrs -uri $filingUri |
                    Where-Object {$_.filings.recent.filingDate -like "*$logDate*"} # API response to verify CIK has filings from today
                Start-Sleep -Milliseconds 100 

                # proceed only if filings from today is TRUE
                if ($response) {
                    # determine number of filings with today's date 
                    $i = (
                            $response.filings.recent.filingDate | Group-Object | Where-Object {
                                $_.Name -eq $logDate }
                    ).Count

                    # collect filings 0 though i, until i and n are equal, then move on to the next CIK
                    do {
                        $accessionNumber = $response.filings.recent.accessionNumber[$n] -replace '[-]',''
                
                        # check existing SPAC filings to see if their accession number was already checked today
                        if ($spacFilings.accessionNumber -notcontains $accessionNumber) {
                        
                            # enumerate recent filings only from the response
                            $recent = $response.filings.recent
                        
                            # create an object with the data we need to email an alert
                            $obj = [PSCustomObject]@{
                                Name = $response.name
                                Tickers = $response.tickers[0]
                                AccessionNumber = $accessionNumber
                                FilingDate = $recent.filingDate[$n]
                                Form = ($recent).form[$n]
                                Link = $secWebsite + '/' + $cik + '/' + $accessionNumber + '/' + $recent.primaryDocument[$n]
                            }
                    
                            # create the email subject and body
                            $subject = "$($obj.tickers) | New SEC filing"
                            $body = "Name: $($obj.name) `n`nTicker: $($obj.tickers) `n`nFiling Date: $($obj.filingdate) `n`nForm: $($obj.form) `n`nLink: $($obj.link)"
                        
                            # send the email
                            Send-MailMessage -From $from -To $to -Subject $subject -Body $body -SmtpServer 'smtp.gmail.com' -Port 587 -UseSsl -Credential $credential

                            # add the found SPAC filing to the hashset that keeps track of today's filings the script has looked at
                            [void]$spacFilings.Add($obj)

                            # increase n by 1
                            $n++
                        } else {$n++} # if the filing has been checked, increase n by 1
                
                    } until (
                        $n -ge $i # if n is greater or equal to the number of filings, stop checking filings
                    )
                } # CIK check complete
            } # move onto the next CIK until there are none left in the hashset

            # Recheck date
            $date = Get-Date
    
        } # End WHILE / using the new date, if we are still in the filing window check again, if not, end script processing
    } # End process

    end {
        # Reset error preferences
        $ErrorActionPreference = 'Continue'
    } # End end
}
Get-SECNotifications -to $to -from $from -appPassword $appPassword

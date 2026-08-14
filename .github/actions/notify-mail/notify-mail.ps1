<#
.SYNOPSIS
  CI 完成/失败邮件通知。优先经生产后端代发 139 邮件；失败再直连 SMTP。

.DESCRIPTION
  供 .github/workflows 的 notify 汇总 job 使用：
    . ./scripts/ci/notify-mail.ps1
    $jobs = [ordered]@{ 'backend' = '${{ needs.backend.result }}' }
    Send-CiMail -Subject (New-CiNotifySubject ...) -Body (New-CiNotifyBody ...)

  凭证全部经环境变量注入（不落盘、不打印）：
    NOTIFY_MAIL_AUTH_CODE  139 邮箱授权码（SMTP 密码，GitHub Secret）
    NOTIFY_MAIL_FROM       发件人，如 zysicyj@139.com（GitHub Secret）
    NOTIFY_MAIL_TO         收件人，逗号分隔多个（GitHub Secret）
    DAYMICA_RELEASE_TOKEN  发布令牌；与 CI_NOTIFY_API_BASE/BACKEND_URL 同时存在时走后端代发
    CI_NOTIFY_API_BASE     后端根 URL，如 https://api-daymica.zysicyj.top（也可用 BACKEND_URL）

  GitHub-hosted runner 直连 smtp.139.com 会被 139 以「Mail rejected score」拒信。
  因此优先 POST /api/version/ci-notify-mail，由生产机 SMTP 发出。
  SMTP 回退：默认 465（SMTPS 隐式 TLS + AUTH LOGIN）。
  脚本退出码非 0 表示发送失败；workflow 侧用 continue-on-error，通知失败不影响 CI 结论。

.NOTES
  465 走 TcpClient+SslStream 手写 SMTP；失败日志尾部经 gh api 拉取，拉不到自动跳过。
#>

function New-CiNotifySubject {
    <#
    .SYNOPSIS
      主题模板：`打包通知：{workflow} {成功|失败|跳过|取消} — {ref}`
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Workflow,
        [Parameter(Mandatory = $true)][string] $Result,
        [string] $Ref = ''
    )
    $resultTxt = switch ($Result) {
        'success'   { '成功' }
        'failure'   { '失败' }
        'skipped'   { '跳过' }
        'cancelled' { '取消' }
        default     { $Result }
    }
    $refPart = if ($Ref) { " — $Ref" } else { '' }
    return "打包通知：$Workflow $resultTxt$refPart"
}

function New-CiNotifyBody {
    <#
    .SYNOPSIS
      正文模板：workflow / ref / 结论 / job 结论表 / 自定义备注 / run 链接 / 失败日志尾部。
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Workflow,
        [Parameter(Mandatory = $true)][string] $Result,
        [string] $Ref = '',
        [hashtable] $JobResults = @{},
        [string] $RunUrl = '',
        [string] $Note = '',
        [int] $LogTailLines = 30
    )
    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine("Workflow: $Workflow")
    if ($Ref) { $null = $sb.AppendLine("Ref: $Ref") }
    $null = $sb.AppendLine("结论: $Result")
    if ($JobResults.Count) {
        $null = $sb.AppendLine('')
        $null = $sb.AppendLine('Jobs:')
        foreach ($k in $JobResults.Keys) {
            $null = $sb.AppendLine("  - $k : $($JobResults[$k])")
        }
    }
    if ($Note) {
        $null = $sb.AppendLine('')
        $null = $sb.AppendLine($Note)
    }
    if ($RunUrl) {
        $null = $sb.AppendLine('')
        $null = $sb.AppendLine("Run: $RunUrl")
    }
    if ($Result -eq 'failure' -and $LogTailLines -gt 0) {
        try {
            $tails = Get-CiFailedJobLogTails -LogTailLines $LogTailLines
            if ($tails) {
                $null = $sb.AppendLine('')
                $null = $sb.AppendLine('失败日志尾部：')
                $null = $sb.AppendLine($tails)
            }
        } catch {
            Write-Warning "Failed to fetch log tails: $_"
        }
    }
    return $sb.ToString()
}

function Get-CiFailedJobLogTails {
    <#
    .SYNOPSIS
      通过 gh api 拉取本次 run 中失败 job 的日志尾部（前 3 个失败 job）。
      在非 GitHub Actions 环境或拉取失败时返回 $null（调用方忽略）。
    #>
    param([int] $LogTailLines = 30)

    $repo = $env:GITHUB_REPOSITORY
    $runId = $env:GITHUB_RUN_ID
    $token = $env:GITHUB_TOKEN
    if (-not $repo -or -not $runId -or -not $token) { return $null }

    $jobsJson = gh api "repos/$repo/actions/runs/$runId/jobs" --jq '[.jobs[] | select(.conclusion == "failure") | {name, id}]' 2>$null
    if (-not $jobsJson) { return $null }
    $failed = $jobsJson | ConvertFrom-Json
    if (-not $failed -or $failed.Count -eq 0) { return $null }
    $failed = @($failed | Select-Object -First 3)

    $sb = [System.Text.StringBuilder]::new()
    foreach ($j in $failed) {
        $log = gh api "repos/$repo/actions/jobs/$($j.id)/logs" 2>$null
        if (-not $log) { continue }
        $lines = @($log -split "`n")
        $take = [Math]::Min($LogTailLines, $lines.Count)
        $null = $sb.AppendLine("=== $($j.name)（尾部 $take 行）===")
        $start = [Math]::Max(0, $lines.Count - $take)
        $null = $sb.AppendLine(($lines[$start..($lines.Count - 1)] -join "`n"))
        $null = $sb.AppendLine('')
    }
    if ($sb.Length -eq 0) { return $null }
    return $sb.ToString()
}

function ConvertTo-MimeHeader {
    param([Parameter(Mandatory = $true)][string] $Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    return "=?UTF-8?B?$([Convert]::ToBase64String($bytes))?="
}

function Get-Rfc5322Date {
    $now = [DateTimeOffset]::Now
    $en = [Globalization.CultureInfo]::GetCultureInfo('en-US')
    $date = $now.ToString('ddd, dd MMM yyyy HH:mm:ss', $en)
    $off = $now.Offset
    $sign = if ($off.Ticks -ge 0) { '+' } else { '-' }
    $tz = '{0}{1:00}{2:00}' -f $sign, [Math]::Abs($off.Hours), [Math]::Abs($off.Minutes)
    return "$date $tz"
}

function ConvertTo-CiNotifyHtml {
    param(
        [Parameter(Mandatory = $true)][string] $Body,
        [string] $Title = '打包通知'
    )
    if ($Body -match '(?i)<html') { return $Body }
    $encBody = [System.Net.WebUtility]::HtmlEncode($Body) -replace "`r`n", '<br>' -replace "`n", '<br>'
    $encTitle = [System.Net.WebUtility]::HtmlEncode($Title)
    return @"
<!DOCTYPE html>
<html>
<head><meta charset="UTF-8"></head>
<body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #f5f5f5; padding: 40px 0;">
  <div style="max-width: 480px; margin: 0 auto; background: #ffffff; border-radius: 16px; padding: 40px 32px;">
    <h2 style="color: #1a1a1a; margin: 0 0 16px; font-size: 22px;">$encTitle</h2>
    <div style="color: #444; font-size: 14px; line-height: 1.6;">$encBody</div>
  </div>
</body>
</html>
"@
}

function Send-CiMailViaBackend {
    param(
        [Parameter(Mandatory = $true)][string] $Subject,
        [Parameter(Mandatory = $true)][string] $HtmlBody
    )
    $base = $env:CI_NOTIFY_API_BASE
    if (-not $base) { $base = $env:BACKEND_URL }
    $token = $env:DAYMICA_RELEASE_TOKEN
    if (-not $base -or -not $token) { return $false }
    $base = $base.Trim().TrimEnd('/')
    $to = $env:NOTIFY_MAIL_TO
    if (-not $to) { return $false }
    $json = (@{ to = $to; subject = $Subject; body = $HtmlBody } | ConvertTo-Json -Compress -Depth 5)
    try {
        $resp = Invoke-WebRequest -Uri "$base/api/version/ci-notify-mail" -Method POST `
            -Headers @{
                'X-Daymica-Release-Token' = $token
                'Content-Type'            = 'application/json; charset=utf-8'
            } `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) `
            -TimeoutSec 30 `
            -UseBasicParsing
        if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) {
            Write-Host "Mail sent via backend API ($($resp.StatusCode)): $Subject"
            return $true
        }
        Write-Warning "backend notify HTTP $($resp.StatusCode)"
        return $false
    } catch {
        Write-Warning "backend notify failed, fallback SMTP: $($_.Exception.Message)"
        return $false
    }
}

function Read-SmtpReply {
    param([Parameter(Mandatory = $true)][System.IO.Stream] $Stream)
    $lines = [System.Collections.Generic.List[string]]::new()
    $buf = New-Object byte[] 1
    do {
        $sb = [System.Text.StringBuilder]::new()
        while ($true) {
            $n = $Stream.Read($buf, 0, 1)
            if ($n -le 0) { throw 'SMTP connection closed while reading reply' }
            if ($buf[0] -eq 10) { break }
            if ($buf[0] -ne 13) { [void]$sb.Append([char]$buf[0]) }
        }
        $line = $sb.ToString()
        $lines.Add($line)
        $more = ($line.Length -ge 4 -and $line[3] -eq [char]'-')
    } while ($more)
    return $lines
}

function Send-SmtpLine {
    param(
        [Parameter(Mandatory = $true)][System.IO.Stream] $Stream,
        [Parameter(Mandatory = $true)][string] $Line
    )
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($Line + "`r`n")
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
}

function Assert-SmtpCode {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]] $Lines,
        [Parameter(Mandatory = $true)][string] $ExpectPrefix,
        [string] $Context = 'SMTP'
    )
    $first = if ($Lines.Count) { $Lines[0] } else { '' }
    if (-not $first.StartsWith($ExpectPrefix)) {
        throw "$Context failed: expected $ExpectPrefix*, got '$first'"
    }
}

function Send-CiMailImplicitTls {
    <#
    .SYNOPSIS
      465 SMTPS：先 TLS 再 SMTP AUTH LOGIN（139 / GitHub runner 可用路径）。
    #>
    param(
        [Parameter(Mandatory = $true)][string] $SmtpServer,
        [Parameter(Mandatory = $true)][int] $Port,
        [Parameter(Mandatory = $true)][string] $From,
        [Parameter(Mandatory = $true)][string[]] $Recipients,
        [Parameter(Mandatory = $true)][string] $Subject,
        [Parameter(Mandatory = $true)][string] $Body,
        [Parameter(Mandatory = $true)][string] $Password,
        [int] $TimeoutMs = 30000
    )

    $tcp = [System.Net.Sockets.TcpClient]::new()
    $tcp.ReceiveTimeout = $TimeoutMs
    $tcp.SendTimeout = $TimeoutMs
    $ssl = $null
    try {
        $connect = $tcp.ConnectAsync($SmtpServer, $Port)
        if (-not $connect.Wait($TimeoutMs)) { throw "TCP connect timeout ${SmtpServer}:${Port}" }
        $null = $connect.GetAwaiter().GetResult()

        $certCb = [System.Net.Security.RemoteCertificateValidationCallback] {
            param($sender, $certificate, $chain, $sslPolicyErrors)
            return $true
        }
        $ssl = [System.Net.Security.SslStream]::new($tcp.GetStream(), $false, $certCb)
        $ssl.ReadTimeout = $TimeoutMs
        $ssl.WriteTimeout = $TimeoutMs
        $ssl.AuthenticateAsClient($SmtpServer)

        $greet = Read-SmtpReply -Stream $ssl
        Assert-SmtpCode -Lines $greet -ExpectPrefix '220' -Context 'SMTP greeting'

        Send-SmtpLine -Stream $ssl -Line 'EHLO zysicyj.top'
        $ehlo = Read-SmtpReply -Stream $ssl
        Assert-SmtpCode -Lines $ehlo -ExpectPrefix '250' -Context 'EHLO'

        Send-SmtpLine -Stream $ssl -Line 'AUTH LOGIN'
        $authStart = Read-SmtpReply -Stream $ssl
        Assert-SmtpCode -Lines $authStart -ExpectPrefix '334' -Context 'AUTH LOGIN'
        Send-SmtpLine -Stream $ssl -Line ([Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($From)))
        $userPrompt = Read-SmtpReply -Stream $ssl
        Assert-SmtpCode -Lines $userPrompt -ExpectPrefix '334' -Context 'AUTH username'
        Send-SmtpLine -Stream $ssl -Line ([Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Password)))
        $authOk = Read-SmtpReply -Stream $ssl
        Assert-SmtpCode -Lines $authOk -ExpectPrefix '235' -Context 'AUTH password'

        Send-SmtpLine -Stream $ssl -Line "MAIL FROM:<$From>"
        Assert-SmtpCode -Lines (Read-SmtpReply -Stream $ssl) -ExpectPrefix '250' -Context 'MAIL FROM'
        foreach ($rcpt in $Recipients) {
            Send-SmtpLine -Stream $ssl -Line "RCPT TO:<$rcpt>"
            Assert-SmtpCode -Lines (Read-SmtpReply -Stream $ssl) -ExpectPrefix '250' -Context "RCPT TO $rcpt"
        }

        Send-SmtpLine -Stream $ssl -Line 'DATA'
        Assert-SmtpCode -Lines (Read-SmtpReply -Stream $ssl) -ExpectPrefix '354' -Context 'DATA'

        $subjectHeader = ConvertTo-MimeHeader -Text $Subject
        $fromHeader = "=?UTF-8?B?$([Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('打包通知')))?= <$From>"
        $toHeader = $Recipients -join ', '
        $msgId = "<$([guid]::NewGuid().ToString('N'))@$($From.Split('@')[-1])>"
        $html = ConvertTo-CiNotifyHtml -Body $Body -Title $Subject
        $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($html))
        $wrapped = for ($i = 0; $i -lt $b64.Length; $i += 76) {
            $len = [Math]::Min(76, $b64.Length - $i)
            $b64.Substring($i, $len)
        }
        $payload = @(
            "From: $fromHeader"
            "To: $toHeader"
            "Date: $(Get-Rfc5322Date)"
            "Message-ID: $msgId"
            "Subject: $subjectHeader"
            'MIME-Version: 1.0'
            'Content-Type: text/html; charset=UTF-8'
            'Content-Transfer-Encoding: base64'
            ''
        ) -join "`r`n"
        $payloadBytes = [System.Text.Encoding]::ASCII.GetBytes($payload + "`r`n" + (($wrapped -join "`r`n") + "`r`n.`r`n"))
        $ssl.Write($payloadBytes, 0, $payloadBytes.Length)
        $ssl.Flush()
        Assert-SmtpCode -Lines (Read-SmtpReply -Stream $ssl) -ExpectPrefix '250' -Context 'DATA body'

        try {
            Send-SmtpLine -Stream $ssl -Line 'QUIT'
            $null = Read-SmtpReply -Stream $ssl
        } catch {
            # QUIT 失败不影响已发送成功
        }
    } finally {
        if ($ssl) { $ssl.Dispose() }
        $tcp.Dispose()
    }
}

function Send-CiMail {
    <#
    .SYNOPSIS
      发送邮件（139 SMTP）。凭证读环境变量，参数不携带密码。
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Subject,
        [Parameter(Mandatory = $true)][string] $Body,
        [string] $SmtpServer = 'smtp.139.com',
        [int] $Port = 465,
        [bool] $UseSsl = $true,
        [int] $TimeoutMs = 30000
    )

    $from = $env:NOTIFY_MAIL_FROM
    $to = $env:NOTIFY_MAIL_TO
    if (-not $from) { throw 'NOTIFY_MAIL_FROM env missing' }
    if (-not $to) { throw 'NOTIFY_MAIL_TO env missing' }

    $recipients = @()
    foreach ($addr in ($to -split ',')) {
        $t = $addr.Trim()
        if ($t) { $recipients += $t }
    }
    if ($recipients.Count -eq 0) { throw 'NOTIFY_MAIL_TO has no recipients' }

    $html = ConvertTo-CiNotifyHtml -Body $Body -Title $Subject
    if (Send-CiMailViaBackend -Subject $Subject -HtmlBody $html) {
        return
    }

    $auth = $env:NOTIFY_MAIL_AUTH_CODE
    if (-not $auth) { throw 'NOTIFY_MAIL_AUTH_CODE env missing (SMTP fallback)' }

    if ($Port -eq 465) {
        Send-CiMailImplicitTls -SmtpServer $SmtpServer -Port $Port -From $from `
            -Recipients $recipients -Subject $Subject -Body $Body -Password $auth -TimeoutMs $TimeoutMs
    } else {
        $msg = [System.Net.Mail.MailMessage]::new()
        $msg.From = [System.Net.Mail.MailAddress]::new($from)
        foreach ($rcpt in $recipients) { $null = $msg.To.Add($rcpt) }
        $msg.Subject = $Subject
        $msg.Body = ConvertTo-CiNotifyHtml -Body $Body -Title $Subject
        $msg.IsBodyHtml = $true
        $msg.SubjectEncoding = [System.Text.Encoding]::UTF8
        $msg.BodyEncoding = [System.Text.Encoding]::UTF8
        $client = [System.Net.Mail.SmtpClient]::new($SmtpServer, $Port)
        $client.EnableSsl = $UseSsl
        $client.UseDefaultCredentials = $false
        $client.Credentials = [System.Net.NetworkCredential]::new($from, $auth)
        $client.Timeout = $TimeoutMs
        $client.DeliveryMethod = [System.Net.Mail.SmtpDeliveryMethod]::Network
        try {
            $client.Send($msg)
        } finally {
            $client.Dispose()
            $msg.Dispose()
        }
    }
    Write-Host "Mail sent OK: $Subject -> $($recipients -join ', ')"
}

#Requires -Version 7.0
<#
.SYNOPSIS
    Proxy that makes OpenRouter look like an Ollama endpoint to GitHub Copilot for Agents.

.DESCRIPTION
    Listens on the same port/paths as Ollama and forwards all requests to OpenRouter.
    Uses a Runspace Pool for concurrency and a shared HttpClient to prevent socket exhaustion.

    Visual Studio setup:
      Tools → Options → GitHub Copilot → Ollama endpoint
      Set to: http://localhost:11434

.PARAMETER ListenPort
    Port to listen on. Default: 11434

.PARAMETER OpenRouterApiKey
    Your OpenRouter API key. Also readable from $env:OPENROUTER_API_KEY.

.PARAMETER OpenRouterUrl
    OpenRouter base URL. Default: https://openrouter.ai/api/v1

.PARAMETER ModelFilter
    Optional substring filter on model IDs, e.g. "anthropic". Default: "" (all tool models).

.PARAMETER DebugOutput
    Print request bodies and SSE chunks to the console.
#>
[CmdletBinding()]
param(
    [int]    $ListenPort       = 11434,
    [string] $OpenRouterApiKey = $env:OPENROUTER_API_KEY,
    [string] $OpenRouterUrl    = "https://openrouter.ai/api/v1",
    [string] $ModelFilter      = "",
    [switch] $DebugOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $OpenRouterApiKey) {
    Write-Host "ERROR: No OpenRouter API key. Use -OpenRouterApiKey or `$env:OPENROUTER_API_KEY" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Global Shared Resources
# ---------------------------------------------------------------------------
# 1. Shared HttpClient (Prevents socket exhaustion)
$HttpClient = [Net.Http.HttpClient]::new()
$HttpClient.Timeout = [TimeSpan]::FromMinutes(15)

# 2. Thread-safe Model Cache
$ModelCache = [Hashtable]::Synchronized(@{
    OllamaTags   = '{"models":[]}'
    OpenAIModels = '{"object":"list","data":[]}'
    Expiry       = [DateTime]::MinValue
})

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Log {
    param([string]$Level, [string]$Msg)
    $colors = @{ INFO="Cyan"; WARN="Yellow"; ERROR="Red"; DEBUG="DarkGray" }
    $ts = [DateTime]::Now.ToString("HH:mm:ss.fff")
    [Console]::ForegroundColor = [ConsoleColor]($colors[$Level] ?? "White")
    [Console]::WriteLine("[$ts][$Level] $Msg")
    [Console]::ResetColor()
}

# ---------------------------------------------------------------------------
# HTTP response helpers
# ---------------------------------------------------------------------------
function Send-Json {
    param([System.Net.HttpListenerResponse]$R, [int]$Code=200, [string]$Body="{}")
    try {
        $R.StatusCode  = $Code
        $R.ContentType = "application/json; charset=utf-8"
        $R.Headers.Add("Access-Control-Allow-Origin","*")
        $R.Headers.Add("Access-Control-Allow-Headers","Content-Type, Authorization")
        $R.Headers.Add("Access-Control-Allow-Methods","GET, POST, OPTIONS")
        $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
        $R.ContentLength64 = $bytes.Length
        $R.OutputStream.Write($bytes, 0, $bytes.Length)
    } finally { try { $R.OutputStream.Close() } catch {} }
}

function Send-Err {
    param([System.Net.HttpListenerResponse]$R, [int]$Code=500, [string]$Msg="Error")
    $escaped = $Msg -replace '\\','\\\\'  -replace '"','\"'  -replace "`n",'\n'  -replace "`r",''
    Send-Json -R $R -Code $Code -Body "{`"error`":{`"message`":`"$escaped`",`"code`":$Code}}"
}

function Read-Body {
    param([System.Net.HttpListenerRequest]$Req)
    if ($Req.ContentLength64 -eq 0) { return "" }
    if ($Req.ContentLength64 -gt 0) {
        $buf  = [byte[]]::new($Req.ContentLength64)
        $read = 0
        while ($read -lt $buf.Length) {
            $n = $Req.InputStream.Read($buf, $read, $buf.Length - $read)
            if ($n -eq 0) { break }
            $read += $n
        }
        return [Text.Encoding]::UTF8.GetString($buf, 0, $read)
    }
    $ms = [IO.MemoryStream]::new()
    $Req.InputStream.CopyTo($ms)
    return [Text.Encoding]::UTF8.GetString($ms.ToArray())
}

# ---------------------------------------------------------------------------
# Model cache fetching (Thread-safe)
# ---------------------------------------------------------------------------
function Refresh-Models {
    if ([DateTime]::Now -lt $ModelCache.Expiry) { return }

    [System.Threading.Monitor]::Enter($ModelCache)
    try {
        if ([DateTime]::Now -lt $ModelCache.Expiry) { return } # Double-check lock

        Log INFO "Fetching tool-calling models from OpenRouter…"
        $resp = Invoke-RestMethod -Uri "$OpenRouterUrl/models" `
                    -Headers @{ Authorization = "Bearer $OpenRouterApiKey" } `
                    -Method GET

        $ollamaModels = [Collections.Generic.List[string]]::new()
        $openaiModels = [Collections.Generic.List[string]]::new()
        $now          = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.ffffffZ")
        $nowUnix      = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

        foreach ($m in $resp.data) {
            $hasTools = $false
            if ($m.supported_parameters) {
                $hasTools = [bool]($m.supported_parameters | Where-Object { $_ -eq "tools" })
            }
            if (-not $hasTools) { continue }

            $id = [string]$m.id
            if ($ModelFilter -and $id -notlike "*$ModelFilter*") { continue }

            $family = ($id -split "/")[0]
            $ctx    = if ($m.context_length) { "$($m.context_length)ctx" } else { "unknown" }

            $jId     = $id     -replace '\\','\\\\'  -replace '"','\"'
            $jFamily = $family -replace '\\','\\\\'  -replace '"','\"'
            $jNow    = $now    -replace '\\','\\\\'  -replace '"','\"'
            $jCtx    = $ctx    -replace '\\','\\\\'  -replace '"','\"'

            $ollamaModels.Add(
                "{`"name`":`"$jId`",`"model`":`"$jId`",`"modified_at`":`"$jNow`"," +
                "`"size`":0,`"size_vram`":0,`"digest`":`"openrouter`"," +
                "`"details`":{`"parent_model`":`"`",`"format`":`"gguf`"," +
                "`"family`":`"$jFamily`",`"families`":[`"$jFamily`"]," +
                "`"parameter_size`":`"$jCtx`",`"quantization_level`":`"Q4_0`"}}"
            )
            $openaiModels.Add(
                "{`"id`":`"$jId`",`"object`":`"model`",`"created`":$nowUnix,`"owned_by`":`"$jFamily`"}"
            )
        }

        $ModelCache.OllamaTags   = "{`"models`":[" + ($ollamaModels -join ",") + "]}"
        $ModelCache.OpenAIModels = "{`"object`":`"list`",`"data`":[" + ($openaiModels -join ",") + "]}"
        $ModelCache.Expiry       = [DateTime]::Now.AddMinutes(5)

        Log INFO "Cached $($ollamaModels.Count) tool-calling models$(if($ModelFilter){" (filter: *$ModelFilter*)"})"
    }
    catch {
        Log WARN "Failed to fetch models: $_"
    }
    finally {
        [System.Threading.Monitor]::Exit($ModelCache)
    }
}

# ---------------------------------------------------------------------------
# Chat forwarder (Handles Cancellation & Shared HttpClient)
# ---------------------------------------------------------------------------
function Handle-Chat {
    param([System.Net.HttpListenerRequest]$Req, [System.Net.HttpListenerResponse]$Resp)

    $body = Read-Body $Req
    if (-not $body) { Send-Err $Resp 400 "Empty body"; return }
    if ($DebugOutput) { Log DEBUG "REQ >> $body" }

    $modelMatch  = [regex]::Match($body, '"model"\s*:\s*"([^"]+)"')
    $streamMatch = [regex]::Match($body, '"stream"\s*:\s*(true|false)')
    $model    = "openai/gpt-4o"
    if ($modelMatch.Success) { $model = $modelMatch.Groups[1].Value }

    $isStream = $false
    if ($streamMatch.Success) { $isStream = ($streamMatch.Groups[1].Value -eq "true") }

    Log INFO "--> OpenRouter  model=$model  stream=$isStream"

    $headers = @{
        "Authorization" = "Bearer $OpenRouterApiKey"
        "HTTP-Referer"  = "http://localhost:$ListenPort"
        "X-Title"       = "VS-Copilot-OpenRouter-Proxy"
    }
    $uri = "$OpenRouterUrl/chat/completions"

    if ($isStream) {
        $outBody = $body
        if ($body -notmatch '"stream_options"') {
            $outBody = $body -replace '(?s)\}\s*$', ',"stream_options":{"include_usage":true}}'
        }

        $promptTok = $null; $completionTok = $null
        $cts = [Threading.CancellationTokenSource]::new()
        
        try {
            $Resp.StatusCode  = 200
            $Resp.ContentType = "text/event-stream; charset=utf-8"
            $Resp.Headers.Add("Cache-Control","no-cache")
            $Resp.Headers.Add("Access-Control-Allow-Origin","*")
            $Resp.Headers.Add("Connection","keep-alive")
            $Resp.SendChunked = $true

            $reqMsg         = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, $uri)
            $reqMsg.Content = [Net.Http.StringContent]::new($outBody, [Text.Encoding]::UTF8, "application/json")
            
            # Attach headers directly to the message (Thread-safe for Runspace Pool)
            foreach ($kv in $headers.GetEnumerator()) {
                $reqMsg.Headers.TryAddWithoutValidation($kv.Key, $kv.Value) | Out-Null
            }

            $task   = $HttpClient.SendAsync($reqMsg, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cts.Token)
            $upResp = $task.GetAwaiter().GetResult()
            $upBytes = $upResp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $reader  = [IO.StreamReader]::new($upBytes)
            $writer  = [IO.StreamWriter]::new($Resp.OutputStream, [Text.Encoding]::UTF8)
            $writer.AutoFlush = $true

            while (-not $reader.EndOfStream) {
                # Stop Generating support: Abort if client disconnects
                if (-not $Resp.OutputStream.CanWrite) {
                    Log WARN "Client disconnected. Aborting OpenRouter stream."
                    $cts.Cancel()
                    break
                }

                $line = $reader.ReadLine()
                $writer.WriteLine($line)
                if ($DebugOutput) { Log DEBUG "<< $line" }
                
                if ($line -match '"prompt_tokens"\s*:\s*(\d+)')     { $promptTok     = $Matches[1] }
                if ($line -match '"completion_tokens"\s*:\s*(\d+)') { $completionTok = $Matches[1] }
            }
            if ($null -ne $promptTok) {
                Log INFO "<-- tokens  in=$promptTok  out=$completionTok"
            }
        }
        catch [System.IO.IOException] {
            Log WARN "Client closed connection mid-stream."
            $cts.Cancel()
        }
        catch [System.Threading.Tasks.TaskCanceledException] {
            # Expected when $cts.Cancel() is called
        }
        catch { 
            Log ERROR "Stream error: $_" 
        }
        finally {
            try { $cts.Dispose() } catch {}
            try { $Resp.OutputStream.Close() } catch {}
        }
    }
    else {
        try {
            $result = Invoke-RestMethod -Uri $uri -Method POST -Body $body `
                          -ContentType "application/json" -Headers $headers
            if ($result.usage) {
                Log INFO "<-- tokens  in=$($result.usage.prompt_tokens)  out=$($result.usage.completion_tokens)"
            }
            $json = $result | ConvertTo-Json -Depth 20 -Compress
            Send-Json $Resp 200 $json
        }
        catch {
            Log ERROR "OpenRouter error: $_"
            Send-Err $Resp 502 $_.ToString()
        }
    }
}

# ---------------------------------------------------------------------------
# Main request dispatcher
# ---------------------------------------------------------------------------
function Handle-Request {
    param([System.Net.HttpListenerContext]$Ctx)

    $req    = $Ctx.Request
    $resp   = $Ctx.Response
    $method = $req.HttpMethod
    $path   = $req.Url.AbsolutePath.TrimEnd("/")

    if ($path -ne "/api/show") { Log INFO "$method $path" }
    if ($DebugOutput) {
        $hdrs = ($req.Headers.AllKeys | ForEach-Object { "${_}=$($req.Headers[$_])" }) -join " | "
        Log DEBUG "Headers: $hdrs"
    }

    if ($method -eq "OPTIONS") { Send-Json $resp 204 ""; return }
    if ($method -eq "HEAD") {
        $resp.StatusCode = 200
        $resp.Headers.Add("Access-Control-Allow-Origin","*")
        try { $resp.OutputStream.Close() } catch {}
        return
    }

    switch ($path) {
        "/api/version"          { Send-Json $resp 200 '{"version":"0.3.0"}'; return }
        "/api/tags"             { Refresh-Models; Send-Json $resp 200 $ModelCache.OllamaTags;   return }
        "/api/ps"               { Send-Json $resp 200 '{"models":[]}'; return }
        "/api/show"             {
            $showBody = Read-Body $req
            $modelId  = ""
            $m = [regex]::Match($showBody, '"model"\s*:\s*"([^"]+)"')
            if ($m.Success) { $modelId = $m.Groups[1].Value }
            
            $jId     = $modelId -replace '\\','\\\\' -replace '"','\"'
            $family  = ($modelId -split "/")[0]
            $jFamily = $family   -replace '\\','\\\\' -replace '"','\"'
            $now     = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.ffffffZ")

            $showResp = "{" +
                "`"model`":`"$jId`"," +
                "`"modified_at`":`"$now`"," +
                "`"modelfile`":`"# Modelfile for $jId`"," +
                "`"parameters`":`"`"," +
                "`"template`":`"{{ .Prompt }}`"," +
                "`"details`":{" +
                    "`"parent_model`":`"`"," +
                    "`"format`":`"gguf`"," +
                    "`"family`":`"$jFamily`"," +
                    "`"families`":[`"$jFamily`"]," +
                    "`"parameter_size`":`"unknown`"," +
                    "`"quantization_level`":`"Q4_0`"" +
                "}," +
                "`"model_info`":{" +
                    "`"general.architecture`":`"$jFamily`"," +
                    "`"general.basename`":`"$jId`"," +
                    "`"general.finetune`":`"`"," +
                    "`"general.quantization_version`":2," +
                    "`"general.size_label`":`"unknown`"" +
                "}," +
                "`"capabilities`":[`"completion`",`"tools`"]" +
            "}"

            Log INFO "POST /api/show  $modelId"
            Send-Json $resp 200 $showResp
            return
        }
        "/v1/models"            { Refresh-Models; Send-Json $resp 200 $ModelCache.OpenAIModels; return }
        "/api/chat"             { Handle-Chat $req $resp; return }
        "/v1/chat/completions"  { Handle-Chat $req $resp; return }
        default {
            Log WARN "UNHANDLED $method $path"
            Send-Err $resp 404 "Unknown: $path"
        }
    }
}

# ---------------------------------------------------------------------------
# Startup & Concurrency Setup
# ---------------------------------------------------------------------------
$prefix   = "http://localhost:$ListenPort/"
$script:listener = [Net.HttpListener]::new()
$script:listener.Prefixes.Add($prefix)

try { $script:listener.Start() }
catch {
    Write-Host "ERROR: Cannot bind to $prefix — $_" -ForegroundColor Red
    Write-Host "Try running as Administrator or change -ListenPort" -ForegroundColor Yellow
    exit 1
}

# Trap Ctrl+C using a compiled C# class to avoid Runspace threading issues
try { $null = [CtrlCInterceptor] } catch {
    Add-Type -TypeDefinition @"
using System;
using System.Net;
public static class CtrlCInterceptor {
    public static HttpListener Listener;
    public static void OnCancelKeyPress(object sender, ConsoleCancelEventArgs e) {
        e.Cancel = true;
        try { if (Listener != null) Listener.Stop(); } catch {}
    }
}
"@
}
[CtrlCInterceptor]::Listener = $script:listener
$cancelEventHandler = [ConsoleCancelEventHandler][CtrlCInterceptor]::OnCancelKeyPress
[Console]::add_CancelKeyPress($cancelEventHandler)

# Setup Runspace Pool for Concurrency
$iss = [initialsessionstate]::CreateDefault()
$customFunctions = @('Log', 'Send-Json', 'Send-Err', 'Read-Body', 'Refresh-Models', 'Handle-Chat', 'Handle-Request')
foreach ($fname in $customFunctions) {
    $f = Get-Command $fname -ErrorAction SilentlyContinue
    if ($f) {
        $iss.Commands.Add([System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new($f.Name, $f.Definition))
    }
}
# Inject variables into Runspaces
$iss.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new("OpenRouterApiKey", $OpenRouterApiKey, ""))
$iss.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new("OpenRouterUrl", $OpenRouterUrl, ""))
$iss.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new("ModelFilter", $ModelFilter, ""))
$iss.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new("DebugOutput", $DebugOutput, ""))
$iss.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new("ListenPort", $ListenPort, ""))
$iss.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new("HttpClient", $HttpClient, ""))
$iss.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new("ModelCache", $ModelCache, ""))

$runspacePool = [runspacefactory]::CreateRunspacePool(1, 10, $iss, $Host)
$runspacePool.Open()

$jobs = [System.Collections.Generic.List[psobject]]::new()

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║   GitHub Copilot  →  OpenRouter  (Ollama-shape proxy)     ║" -ForegroundColor Green
Write-Host "╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host "  Listening  : $prefix"        -ForegroundColor Cyan
Write-Host "  OpenRouter : $OpenRouterUrl" -ForegroundColor Cyan
if ($ModelFilter) { Write-Host "  Filter     : *$ModelFilter*" -ForegroundColor Cyan }
Write-Host ""
Write-Host "  VS setup: Tools → Options → GitHub Copilot → Ollama endpoint" -ForegroundColor Yellow
Write-Host "            http://localhost:$ListenPort" -ForegroundColor White
Write-Host ""
Write-Host "  Press Ctrl+C to stop." -ForegroundColor DarkGray
Write-Host ""

# ---------------------------------------------------------------------------
# Main Request Loop
# ---------------------------------------------------------------------------
while ($script:listener.IsListening) {
    # Clean up completed background jobs
    $completed = $jobs | Where-Object { $_.Handle.IsCompleted }
    foreach ($job in $completed) {
        try { $null = $job.PS.EndInvoke($job.Handle) } catch {}
        $job.PS.Dispose()
        $null = $jobs.Remove($job)   
    }

    try {
        $ctx = $script:listener.GetContext()
    }
    catch [Net.HttpListenerException] {
        if (-not $script:listener.IsListening) { break }
        continue
    }
    catch [ObjectDisposedException] { break }

    # Hand off request to Runspace Pool
    $ps = [powershell]::Create()
    $ps.RunspacePool = $runspacePool
    $null = $ps.AddScript({
        param($Ctx)
        Handle-Request -Ctx $Ctx
    }).AddArgument($ctx)
    
    $handle = $ps.BeginInvoke()
    $jobs.Add([pscustomobject]@{ PS = $ps; Handle = $handle })
}

# ---------------------------------------------------------------------------
# Cleanup on Exit
# ---------------------------------------------------------------------------
foreach ($job in $jobs) {
    try { $job.PS.Stop() } catch {}
    try { $job.PS.Dispose() } catch {}
}
try { $runspacePool.Close() } catch {}
try { $runspacePool.Dispose() } catch {}
try { $HttpClient.Dispose() } catch {}
try { $script:listener.Close() } catch {}
Log INFO "Proxy stopped."
#Requires -Version 7.0
<#
.SYNOPSIS
    Proxy that makes OpenRouter look like an Ollama endpoint to GitHub Copilot for Agents.

.DESCRIPTION
    Listens on the same port/paths as Ollama and forwards all requests to OpenRouter.
    The /api/tags and /v1/models endpoints return only models that support tool calling.

    Endpoints:
      GET  /api/version           → {"version":"0.3.0"}
      GET  /api/tags              → Ollama-shape list of tool-calling models
      GET  /v1/models             → OpenAI-shape list of tool-calling models
      POST /api/chat              → forwarded to OpenRouter
      POST /v1/chat/completions   → forwarded to OpenRouter

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

.EXAMPLE
    .\CopilotAgentProxy.ps1 -OpenRouterApiKey "sk-or-v1-..."

.EXAMPLE
    $env:OPENROUTER_API_KEY = "sk-or-v1-..."
    .\CopilotAgentProxy.ps1 -ModelFilter "anthropic"
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
# Logging — uses [Console] directly so it works from any thread
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
    # Minimal JSON escape for the message
    $escaped = $Msg -replace '\\','\\\\'  -replace '"','\"'  -replace "`n",'\n'  -replace "`r",''
    Send-Json -R $R -Code $Code -Body "{`"error`":{`"message`":`"$escaped`",`"code`":$Code}}"
}

function Read-Body {
    param([System.Net.HttpListenerRequest]$Req)
    # ContentLength64 is -1 for chunked transfer encoding — use a MemoryStream in that case
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
    # Chunked / unknown length
    $ms = [IO.MemoryStream]::new()
    $Req.InputStream.CopyTo($ms)
    return [Text.Encoding]::UTF8.GetString($ms.ToArray())
}

# ---------------------------------------------------------------------------
# Model cache — fetched once, refreshed every 5 min
# ---------------------------------------------------------------------------
$script:CachedOllamaTags  = ""   # JSON string for /api/tags
$script:CachedOpenAIModels = ""  # JSON string for /v1/models
$script:CacheExpiry        = [DateTime]::MinValue

function Refresh-Models {
    if ([DateTime]::Now -lt $script:CacheExpiry) { return }

    Log INFO "Fetching tool-calling models from OpenRouter…"
    try {
        # Use Invoke-RestMethod on the main thread — it has a full runspace here
        $resp = Invoke-RestMethod -Uri "$OpenRouterUrl/models" `
                    -Headers @{ Authorization = "Bearer $OpenRouterApiKey" } `
                    -Method GET

        $ollamaModels = [Collections.Generic.List[string]]::new()
        $openaiModels = [Collections.Generic.List[string]]::new()
        $now          = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.ffffffZ")
        $nowUnix      = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

        foreach ($m in $resp.data) {
            # Only keep models with tools in supported_parameters
            $hasTools = $false
            if ($m.supported_parameters) {
                $hasTools = [bool]($m.supported_parameters | Where-Object { $_ -eq "tools" })
            }
            if (-not $hasTools) { continue }

            $id = [string]$m.id
            if ($ModelFilter -and $id -notlike "*$ModelFilter*") { continue }

            $family = ($id -split "/")[0]
            $ctx    = if ($m.context_length) { "$($m.context_length)ctx" } else { "unknown" }

            # JSON-escape the values
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

        $script:CachedOllamaTags   = "{`"models`":[" + ($ollamaModels -join ",") + "]}"
        $script:CachedOpenAIModels = "{`"object`":`"list`",`"data`":[" + ($openaiModels -join ",") + "]}"
        $script:CacheExpiry        = [DateTime]::Now.AddMinutes(5)

        Log INFO "Cached $($ollamaModels.Count) tool-calling models$(if($ModelFilter){" (filter: *$ModelFilter*)"})"
    }
    catch {
        Log WARN "Failed to fetch models: $_"
        if (-not $script:CachedOllamaTags) {
            $script:CachedOllamaTags   = '{"models":[]}'
            $script:CachedOpenAIModels = '{"object":"list","data":[]}'
        }
    }
}

# ---------------------------------------------------------------------------
# Chat forwarder — called synchronously on the main loop thread
# ---------------------------------------------------------------------------
function Handle-Chat {
    param([System.Net.HttpListenerRequest]$Req, [System.Net.HttpListenerResponse]$Resp)

    $body = Read-Body $Req
    if (-not $body) { Send-Err $Resp 400 "Empty body"; return }
    if ($DebugOutput) { Log DEBUG "REQ >> $body" }

    # Extract model and stream flag cheaply with regex (avoids Json library issues)
    $modelMatch  = [regex]::Match($body, '"model"\s*:\s*"([^"]+)"')
    $streamMatch = [regex]::Match($body, '"stream"\s*:\s*(true|false)')
    $model    = if ($modelMatch.Success)  { $modelMatch.Groups[1].Value  } else { "openai/gpt-4o" }
    $isStream = if ($streamMatch.Success) { $streamMatch.Groups[1].Value -eq "true" } else { $false }

    Log INFO "--> OpenRouter  model=$model  stream=$isStream"

    $headers = @{
        "Authorization" = "Bearer $OpenRouterApiKey"
        "HTTP-Referer"  = "http://localhost:$ListenPort"
        "X-Title"       = "VS-Copilot-OpenRouter-Proxy"
    }
    $uri = "$OpenRouterUrl/chat/completions"

    if ($isStream) {
        # ── Streaming: pipe SSE chunks straight through ────────────────────
        try {
            $Resp.StatusCode  = 200
            $Resp.ContentType = "text/event-stream; charset=utf-8"
            $Resp.Headers.Add("Cache-Control","no-cache")
            $Resp.Headers.Add("Access-Control-Allow-Origin","*")
            $Resp.Headers.Add("Connection","keep-alive")
            $Resp.SendChunked = $true

            $http    = [Net.Http.HttpClient]::new()
            foreach ($kv in $headers.GetEnumerator()) {
                $http.DefaultRequestHeaders.TryAddWithoutValidation($kv.Key, $kv.Value) | Out-Null
            }
            $reqMsg         = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, $uri)
            $reqMsg.Content = [Net.Http.StringContent]::new($body, [Text.Encoding]::UTF8, "application/json")

            $upResp  = $http.SendAsync($reqMsg, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            $upBytes = $upResp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $reader  = [IO.StreamReader]::new($upBytes)
            $writer  = [IO.StreamWriter]::new($Resp.OutputStream, [Text.Encoding]::UTF8)
            $writer.AutoFlush = $true

            while (-not $reader.EndOfStream) {
                $line = $reader.ReadLine()
                $writer.WriteLine($line)
                if ($DebugOutput) { Log DEBUG "<< $line" }
            }
        }
        catch { Log ERROR "Stream error: $_" }
        finally {
            try { $Resp.OutputStream.Close() } catch {}
            try { $http.Dispose()            } catch {}
        }
    }
    else {
        # ── Non-streaming ─────────────────────────────────────────────────
        try {
            $result = Invoke-RestMethod -Uri $uri -Method POST -Body $body `
                          -ContentType "application/json" -Headers $headers
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

    Log INFO "$method $path"
    if ($DebugOutput) {
        $hdrs = ($req.Headers.AllKeys | ForEach-Object { "${_}=$($req.Headers[$_])" }) -join " | "
        Log DEBUG "Headers: $hdrs"
    }

    if ($method -eq "OPTIONS") { Send-Json $resp 204 ""; return }
    # Also handle HEAD — return same headers as GET but no body
    if ($method -eq "HEAD") {
        $resp.StatusCode = 200
        $resp.Headers.Add("Access-Control-Allow-Origin","*")
        try { $resp.OutputStream.Close() } catch {}
        return
    }

    switch ($path) {
        "/api/version"          { Send-Json $resp 200 '{"version":"0.3.0"}'; return }
        "/api/tags"             { Refresh-Models; Send-Json $resp 200 $script:CachedOllamaTags;   return }
        "/api/ps"               { Send-Json $resp 200 '{"models":[]}'; return }   # running models
                "/api/show"             {
            # Copilot calls this for each model to get its capabilities.
            # We return a minimal but valid Ollama /api/show response.
            $showBody = Read-Body $req
            $modelId  = ""
            $m = [regex]::Match($showBody, '"model"\s*:\s*"([^"]+)"')
            if ($m.Success) { $modelId = $m.Groups[1].Value }
            
            # Properly escape backslashes and double quotes for JSON using single quotes
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

            Log INFO "SHOW $modelId"
            Send-Json $resp 200 $showResp
            return
        }
        "/v1/models"            { Refresh-Models; Send-Json $resp 200 $script:CachedOpenAIModels; return }
        "/api/chat"             { Handle-Chat $req $resp; return }
        "/v1/chat/completions"  { Handle-Chat $req $resp; return }
        default {
            # Dump the full request so we can see exactly what Copilot is asking for
            Log WARN "UNHANDLED $method $path"
            try {
                $headers = ($req.Headers.AllKeys | ForEach-Object { "  ${_}: $($req.Headers[$_])" }) -join "`n"
                Log WARN "Headers:`n$headers"
                if ($req.ContentLength64 -gt 0) {
                    $b = Read-Body $req
                    Log WARN "Body: $b"
                }
            } catch {}
            Send-Err $resp 404 "Unknown: $path"
        }
    }
}

# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------
$prefix   = "http://localhost:$ListenPort/"
$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add($prefix)

try { $listener.Start() }
catch {
    Write-Host "ERROR: Cannot bind to $prefix — $_" -ForegroundColor Red
    Write-Host "Try running as Administrator or change -ListenPort" -ForegroundColor Yellow
    exit 1
}

Refresh-Models

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

$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { $listener.Stop() }

# ---------------------------------------------------------------------------
# Request loop — single-threaded, synchronous.
# Streaming responses block until complete, which is fine: Copilot sends
# one request at a time per agent session. If you need true concurrency,
# a RunspacePool approach is required (see comments below).
# ---------------------------------------------------------------------------
while ($listener.IsListening) {
    try {
        $ctx = $listener.GetContext()
    }
    catch [Net.HttpListenerException] {
        if (-not $listener.IsListening) { break }
        Log ERROR "Listener: $_"
        continue
    }
    try   { Handle-Request $ctx }
    catch { Log ERROR "Handler: $_"; try { $ctx.Response.OutputStream.Close() } catch {} }
}

$listener.Close()
Log INFO "Proxy stopped."

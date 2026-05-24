# OpenRouter → Ollama Proxy (GitHub Copilot)

A PowerShell 7 proxy that makes [OpenRouter](https://openrouter.ai) look like a local [Ollama](https://ollama.com) endpoint, enabling GitHub Copilot for Agents (and the VS Code Copilot extension) to use any OpenRouter-hosted model that supports tool calling.

## How it works

The script starts a lightweight HTTP listener on the same port and paths that Copilot expects from Ollama (`http://localhost:11434`). Incoming requests are translated and forwarded to the OpenRouter API:

| Local endpoint              | Behaviour                                                                |
| --------------------------- | ------------------------------------------------------------------------ |
| `GET /api/version`          | Returns a fake Ollama version string                                     |
| `GET /api/tags`             | Returns all OpenRouter models that support tool calling, in Ollama shape |
| `GET /v1/models`            | Same model list, in OpenAI shape                                         |
| `GET /api/show`             | Returns model capabilities (reports `tools` support)                     |
| `POST /api/chat`            | Forwarded to OpenRouter `/v1/chat/completions`                           |
| `POST /v1/chat/completions` | Forwarded to OpenRouter `/v1/chat/completions`                           |

The model list is fetched from OpenRouter on first request and refreshed every 5 minutes.

## Requirements

- **PowerShell 7.0+** (`pwsh`)
- An **OpenRouter API key** — get one at <https://openrouter.ai/keys>

## Usage

```powershell
# Pass the key directly
.\openrouter-proxy.ps1 -OpenRouterApiKey "sk-or-v1-..."

# Or set it as an environment variable
$env:OPENROUTER_API_KEY = "sk-or-v1-..."
.\openrouter-proxy.ps1

# Filter to a specific provider (e.g. only Anthropic models)
.\openrouter-proxy.ps1 -ModelFilter "anthropic"

# Enable verbose request/response logging
.\openrouter-proxy.ps1 -DebugOutput
```

### Parameters

| Parameter           | Default                        | Description                            |
| ------------------- | ------------------------------ | -------------------------------------- |
| `-OpenRouterApiKey` | `$env:OPENROUTER_API_KEY`      | Your OpenRouter API key                |
| `-ListenPort`       | `11434`                        | Local port to listen on                |
| `-OpenRouterUrl`    | `https://openrouter.ai/api/v1` | OpenRouter base URL                    |
| `-ModelFilter`      | _(empty)_                      | Optional substring filter on model IDs |
| `-DebugOutput`      | `$false`                       | Print request bodies and SSE chunks    |

## Visual Studio / VS Code setup

1. Open **Tools → Options → GitHub Copilot** (Visual Studio) or the Copilot extension settings in VS Code.
2. Set the **Ollama endpoint** to `http://localhost:11434`.
3. Start the proxy, then pick any listed model in the Copilot model selector.

## License

MIT

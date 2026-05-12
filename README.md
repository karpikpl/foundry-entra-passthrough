# MCP OAuth with Direct Entra Authentication

Demonstrates how to authenticate VS Code's MCP client directly with Microsoft Entra ID using RFC 9728 Protected Resource Metadata — no OAuth proxy layer needed.

## How It Works

- **No proxy:** VS Code authenticates directly to Entra, not through an intermediary
- **Native account picker:** No browser window required; uses VS Code's built-in Microsoft authentication  
- **One requirement:** Pre-authorize VS Code's client ID in your Entra app registration
- **Fast token acquisition:** Tokens obtained silently after first sign-in

## VS Code Configuration

Add to `.vscode/mcp.json`:

```json
{
  "servers": {
    "cloud-helper": {
      "type": "http",
      "url": "https://<your-app>.azurewebsites.net/mcp"
    }
  }
}
```

Replace `<your-app>` with your app's hostname. After deploying with `azd up`, the endpoint URL is printed by the postprovision hook.

That's all. VS Code auto-discovers authentication via the server's Protected Resource Metadata endpoint.

## Live Demo

After running `azd up`, your MCP endpoint is printed by the postprovision hook. Use that URL in your VS Code configuration above.

## The Key: Pre-Authorize VS Code

In your Entra app registration, add VS Code's client ID to `preAuthorizedApplications`:

```bash
az ad app update --id $APP_ID --set api.preAuthorizedApplications='[
  {
    "appId": "aebc6443-996d-45c2-90f0-388ff96faa56",
    "delegatedPermissionIds": ["'$SCOPE_ID'"]
  }
]'
```

## Setup & Deployment

```bash
azd up -e mcp-auth-test-direct
```

## References

- [MS Learn: MCP Overview](https://learn.microsoft.com/en-us/azure/app-service/overview-managed-identity)
- [FastMCP GitHub](https://github.com/jlowin/FastMCP)
- [VS Code MCP Documentation](https://github.com/microsoft/vscode-mcp)
- [RFC 9728: OAuth 2.0 Protected Resource Metadata](https://datatracker.ietf.org/doc/html/rfc9728)

## License

MIT

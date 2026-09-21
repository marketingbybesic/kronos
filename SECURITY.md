# Security

## Reporting a vulnerability

Please do not open a public issue for a security problem. Use GitHub's private reporting instead: **Security > Report a vulnerability** on this repository. You will get an answer within a week.

## What Kronos does with your data

- Tasks are stored locally in `~/Library/Application Support/Kronos`. There is no account and no telemetry.
- API keys and the MCP token are stored in the macOS Keychain, in items created by Kronos itself. They are read only when the feature that needs them is first used, never at launch.
- AI is off until you configure a provider. When on, the text of the task or note you act on is sent to that provider and nowhere else.
- The MCP server is off by default. When enabled it listens on `127.0.0.1` only and rejects requests without the bearer token shown in Settings.
- Release builds are not notarised yet. If that matters to you, build from source: the project signs ad hoc and needs no Apple account.

# Security

GitNebula is under active development. Use current source and keep Git and native runtime dependencies updated.

## Reporting a vulnerability

Use the repository's GitHub **Security → Report a vulnerability** option if private reporting is enabled. If it is unavailable, open an issue asking the maintainers for a private reporting channel without including exploit details, credentials, or private repository contents.

## Repository trust

Opening a repository uses the installed Git executable. Git configuration can invoke external diff tools, filters, hooks, and credential helpers. Open repositories you trust. GitNebula does not provide a sandbox for repository-controlled commands.

Authentication is delegated to Git and the operating system. Do not embed tokens in remote URLs or commit environment files, private keys, or certificate bundles. If a secret is committed, revoke it first; removing Git history alone does not invalidate copies or cached objects.

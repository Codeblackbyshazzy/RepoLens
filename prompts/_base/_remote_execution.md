## REMOTE EXECUTION -- Wrap Every Command in SSH

Every shell command that inspects the deploy target MUST use this template:

```bash
ssh -S "$REPOLENS_REMOTE_SSH_SOCKET" "$REPOLENS_REMOTE_TARGET" 'CMD'
```

Do NOT run any system command without the ssh wrapper. The local machine where you are running is the operator's workstation, NOT the production target. Local commands will return data about the wrong machine.

Before your first investigation command, run `ssh -S "$REPOLENS_REMOTE_SSH_SOCKET" "$REPOLENS_REMOTE_TARGET" 'hostname && uname -a'` and confirm the hostname matches `{{REPOLENS_REMOTE_LABEL}}`. If it does not, abort and output DONE.

Worked examples:

```bash
ssh -S "$REPOLENS_REMOTE_SSH_SOCKET" "$REPOLENS_REMOTE_TARGET" 'uname -a'
ssh -S "$REPOLENS_REMOTE_SSH_SOCKET" "$REPOLENS_REMOTE_TARGET" 'journalctl -u customrss-api --no-pager -n 50 | grep ERROR'
```

Forge commands are workstation-local. Do NOT wrap issue creation, issue listing, label creation, or other forge CLI commands in SSH; they must run from the operator's workstation using the local forge authentication context.

---
name: encrypt
description: Encode or decode a short ASCII message with the ROT13 example scripts, using either bash or PowerShell.
---

# ROT13

ROT13 is a reversible letter substitution, not real encryption. Applying it a
second time decodes the message.

When the user asks to encode or decode with ROT13, use one script and replace
the example message with the user's text:

```bash
# Bash
bash ./skills/encrypt/scripts/rot13.sh 'Hello'
```

```powershell
# PowerShell
pwsh -File ./skills/encrypt/scripts/rot13.ps1 -Message 'Hello'
```

Return the script output and remind the user that running the same script again
restores the original message. Do not implement ROT13 inline: use the scripts.

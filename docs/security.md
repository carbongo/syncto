# Security

- syncto commits whatever is in the working tree: keep secrets out of synced repos or in
  `.gitignore`.
- Its config, keys and hooks live outside the repos it syncs (`~/.config/syncto`); the
  source holds nothing machine-specific. Config and state folders are owner-only.
- Remote URLs are shown without any `user:password@` part.
- Scheduled syncs need a passphrase-less ssh key ([why](scheduling.md#ssh-keys)): use a
  deploy key limited to one repo.
- Hooks are shell commands from your own config; syncto talks to no chat or notification
  service itself.
- On macOS, Full Disk Access goes only to syncto's launcher, never to `/bin/bash`
  ([why](scheduling.md#macos-protected-folders)).

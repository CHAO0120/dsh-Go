# Engine and remote hosts

DSH can run right on this phone (this phone's engine), or on your computer or server with your phone connecting to it. Chats, workspaces and plugins belong to each host.

## This phone or remote

The first time you open the app, choose where DSH runs:

- **This phone**: installs the runtime on your phone; everything runs on this phone. The option shows the storage and memory it needs.
- **Remote host**: uses DSH on your computer or server, with nothing installed on the phone. Recommended when the phone is short on memory or storage.

You can add DSH to this phone anytime: tap **Install runtime** on the engine page, or tap **This phone** when switching hosts. Stay on that page while it installs; it starts once installed.

## This phone's engine

<!-- nav: commonSettings,hubSettingsEngine -->
`Settings › Local engine` · [Open](dshgo://open/engine)

- **Start**, **Stop**, **Restart**: stopping asks first; both stopping and restarting interrupt active chats.
- If the engine fails to start, the page shows the cause and ways to fix it, such as retrying or viewing logs.
- **Start when DSH Go opens**: on by default. As long as DSH is installed on this phone, opening the app starts it, even while you use a remote host. Turn it off if you don't need that.
- There's no Safe mode. After several unclean exits in a row the engine won't start by itself; tap **Retry** to start it.
- **Logs**: the engine's live output.
- **Background running** and **Diagnostics**: see [FAQ](11-faq.md).

## Reset the runtime

<!-- nav: commonSettings,hubSettingsEngine,phoneEngineReset -->
`Settings › Local engine › Reset runtime`

Deletes data on this phone and reinstalls the runtime, to fix a runtime that won't start. In the dialog:

- **Keep interface settings and skills**: on by default.
- **Keep installed plugins and settings**: off by default.

With the defaults, chats, workspaces, plugins and settings are deleted, including custom model providers; your host list, app settings and saved keys aren't affected. The dialog spells out what will go; tap **Delete and reset** and the app reopens and finishes the reset as it opens. If it still needs reopening, the engine page says so: tap **Reopen**. The local engine won't start until then. A reset can't be undone, so export chats you need first with `/export` or **Export chat log** in All features.

## Uninstall the runtime

<!-- nav: commonSettings,hubSettingsEngine,localEnvUninstall -->
`Settings › Local engine › Uninstall runtime`

Deletes the unpacked runtime and local data. Chats, workspaces, plugins, settings, interface settings and skills on this phone are all deleted, the app reopens, and nothing is reinstalled. The copy of the runtime inside the app package stays; only uninstalling the app frees it. To use this phone's engine again, tap **Install runtime** on the same page. If you only need a break, stop the engine and turn off **Start when DSH Go opens**.

## Switch hosts

Open the chat list and tap the current host's name at the bottom to open **Switch host**, then choose **This phone** or a remote host. With no remote hosts yet, tap **Connect a computer or server**; otherwise tap **Manage remote hosts**.

Tap the icon to the left of the host name for details: remote hosts show their name, connection status and current network path, with an on-demand latency measurement where supported. For this phone, it opens **Local engine**. The host name and dropdown arrow still switch hosts.

<!-- nav: remoteSwitchHost,remoteManageHosts -->
`Switch host › Manage remote hosts` · [Open](dshgo://open/remote)

It's in Settings too:

<!-- nav: commonSettings,commonRemoteHost -->
`Settings › Remote host`

On launch, the app reconnects to the host you used last. To start on this phone every time, turn off **Connect to the last host** on the remote hosts page; saved hosts stay, and you can connect to them by hand any time.

## Add an SSH host

The host needs SSH enabled and DSH installed (`npm i -g @deepseek-ai/dsh`).

1. On the remote hosts page, tap **Add SSH host**.
2. Enter the **Host** and **Username**. **Port** defaults to 22. The name is optional.
3. Sign in with a **Password** or a **Private key**. You can **Import from file**, and add a **Private key passphrase (optional)**. Passwords and keys stay on this phone.
4. **Start command** defaults to `dsh web`; if you installed DSH with nvm, enter its full path. **Working directory (optional)** is where new chats start.
5. Tap **Test connection**. The first time, **Trust this host?** appears: check the fingerprint on the host, and tap **Trust and connect** if it matches.
6. Tap **Save**, then select the host in the list.

Testing starts DSH on the host, and it keeps running afterwards. To change or delete a host, tap **Edit** next to it to open **Edit host**; **Delete this host** is at the bottom. Deleting removes only the settings, password and key saved on this phone; DSH and chats on the host stay.

## DSH Remote

No network setup, end-to-end encrypted. Good for computers on another network.

1. Install the remote plugin in the host's DSH and sign in.
2. On the remote hosts page, choose the same sign-in provider you used on that host, for example “Continue with GitHub”, and sign in with the same account. If the page lists no providers and shows only **Sign in in browser**, tap that button.
3. Select an online host. On first connection, check that the identity fingerprint matches the one the host's remote plugin shows, then tap **Trust and connect**.

This version goes through the relay, end-to-end encrypted the whole way, not over LAN, P2P or TURN. Tap the route label on the connection card or beside a Host to see the actual route, connection time and available round-trip latency. Unmeasured values are not shown as zero.

DSH Remote connects to one host at a time; switching disconnects the previous one. Over DSH Remote: you can send images only, DSH Web doesn't open in the app, plugins can only be turned on or off, and DS Bot and chat log export aren't available.

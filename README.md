# Lobby Recreate

A SuperBLT mod for PAYDAY 2 that tears down the current multiplayer lobby, hosts a new one with the same contract and settings, and sends a lobby invite to every player who was in the old one.

It is meant for the case where a lobby gets into a bad state: players stop being able to load in, or can no longer see each other. The usual fix is to leave, host again and re-invite everyone by hand. This mod does that with one keybind.

Only the host needs the mod. Other players only have to accept the invite.

## Requirements

- PAYDAY 2 (Steam)
- [SuperBLT](https://superblt.znix.xyz/)

## Installation

Copy the `Lobby Recreate` folder into `PAYDAY 2/mods/`, so the layout is:

```
PAYDAY 2/mods/Lobby Recreate/mod.txt
PAYDAY 2/mods/Lobby Recreate/lua/core.lua
PAYDAY 2/mods/Lobby Recreate/lua/keybind.lua
```

Start the game, then bind a key under **Options > Mod Keybinds > Recreate Lobby**.

## Usage

1. Host a lobby as usual.
2. When the lobby breaks, press the keybind while in the pre-game lobby.
3. Confirm the dialog. It lists the players who will be invited.
4. Players see the host leave, then get an invite a few seconds later.

The keybind only works in the pre-game lobby (`menu_main` game state) while you are hosting.

## How it works

The mod hooks two game scripts:

| Hook                                  | Purpose                                               |
|---------------------------------------|-------------------------------------------------------|
| `lib/managers/menumanager`            | Detect when the new lobby has finished being created. |
| `lib/network/base/basenetworksession` | Track which players have been in the lobby.           |

Sequence when the keybind is pressed:

1. **Validate.** The mod checks that the game is in `menu_main`, the local session is the host, a Steam lobby handler exists, and the lobby is not Crime Spree or Holdout.
2. **Snapshot.** It records `managers.job:current_job_id()`, `Global.game_settings.difficulty` and `Global.game_settings.one_down`, and builds the invite list. Other host settings (permission, reputation limit, drop-in, kick option, job plan) are read from `Global.game_settings` when the new lobby is built, so they carry over without being copied.
3. **Announce.** It sends a normal chat message to all peers so players without the mod know an invite is coming.
4. **Leave.** After 1 second it calls `MenuCallbackHandler:_dialog_leave_lobby_yes()`. This is the same path as the in-game "Leave lobby" confirmation: it sends `set_peer_left` to peers and runs `MenuManager:on_leave_lobby()`, which also leaves the Steam lobby.
5. **Wait for teardown.** It polls every 0.25 s until `managers.network:session()` is `nil`. The game only closes a session once every peer has an RPC connection and has finished loading outfit assets (`BaseNetworkSession:is_ready_to_close()`). A player stuck mid-connection, which is the situation this mod exists for, can hold that up indefinitely. After 8 s the mod calls `managers.network:stop_network(true)` itself. After 16 s it gives up and reports an error.
6. **Re-host.** It calls `MenuCallbackHandler:start_job()` with the saved job, which goes through `NetworkMatchMakingSTEAM:create_lobby()` exactly as picking a contract on Crime.net does. If the old lobby had no contract (for example one created by an empty-lobby mod), it calls `MenuCallbackHandler:create_lobby()` instead.
7. **Invite.** A post-hook on `MenuManager:created_lobby()` detects the new lobby. After 1.5 s, which gives Steam time to publish the lobby data, each saved player is invited to the new lobby ID.

### Invite mechanism

Invites use the same lookup as the in-game Social Hub (`SocialHubManager:invite_user_to_lobby`):

- If the user is a platform (Steam) friend, `Distribution:user_from_id(id):invite(lobby_id)`
- Otherwise, `DistributionMatchmaking:user_from_id(id):invite(lobby_id)`
- Fallback: `Steam:user(id):invite(lobby_id)`

If any invite throws, the mod opens the Steam overlay invite dialog (`NetworkMatchMakingSTEAM:invite_friends_to_lobby()`) so the host can invite the rest by hand.

### Who gets invited

The mod keeps a roster keyed by peer `user_id`, and only while hosting:

| Event                                             | Roster effect             |
|---------------------------------------------------|---------------------------|
| `BaseNetworkSession:add_peer`                     | Added                     |
| `BaseNetworkSession:remove_peer`, reason `"lost"` | Kept (connection dropped) |
| `BaseNetworkSession:remove_peer`, reason `"left"` | Removed (left on purpose) |
| `BaseNetworkSession:on_peer_kicked`               | Removed                   |
| A lobby hosted normally (not by this mod)         | Roster cleared            |

The invite list is every current peer plus every roster entry, minus the local player and anyone in the session's kicked list. Roster changes are ignored while a recreate is running, so the teardown of the old session does not wipe it. Invited players stay on the roster, so pressing the key again re-invites them too.

### Timings

| Constant         | Value | Meaning                                                           |
|------------------|-------|-------------------------------------------------------------------|
| `LEAVE_DELAY`    | 1 s   | Delay between the chat announcement and leaving                   |
| `LEAVE_TIMEOUT`  | 8 s   | Time before the old session is force-stopped (abort at 2x)        |
| `CREATE_TIMEOUT` | 20 s  | Time allowed for the new lobby to be created before reporting an error |
| `INVITE_DELAY`   | 1.5 s | Delay between lobby creation and sending invites                  |

## Limitations

- Every player is briefly disconnected. The mod replaces the Steam lobby and the connections between players, which is the actual fix, so this cannot be avoided. It only automates getting everyone back.
- Players have to accept the invite. Joining automatically would require the mod on every client.
- It does not work during a heist, between days of a multi-day job, in Crime Spree or in Holdout.
- Steam may not deliver invites to users who are not on the host's friends list.
- Contract-specific extras that Crime.net attaches (such as heat bonuses) are not preserved. The job ID, difficulty and One Down setting are.

## Troubleshooting

All mod output goes to the SuperBLT log in `PAYDAY 2/mods/logs/` with the prefix `[Lobby Recreate]`. Failures also show an in-game dialog explaining what to do next.

## Files

| File              | Description                                                   |
|-------------------|---------------------------------------------------------------|
| `mod.txt`         | SuperBLT manifest: hooks and keybind definition               |
| `lua/core.lua`    | Recreate flow, roster tracking and hooks                      |
| `lua/keybind.lua` | Keybind entry point, calls `LobbyRecreate:request()`          |

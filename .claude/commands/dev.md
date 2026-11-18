---
description: Start or stop parts of the PoC - LLM container (GPU), server, mobile app
argument-hint: <llm|server|mobile|all|status|stop> [-Model gemma|bielik|qwen|fake] [-EventLog] [-Lan] [-Cpu] [-NoLlm] [-Device id] [-Mode release|profile|debug] [-Reverse]
---

Run the PoC part named by the first argument with `scripts/dev.ps1` (from the repository root):

```
powershell -NoProfile -File scripts/dev.ps1 $ARGUMENTS
```

Without arguments, show the usage above and ask what to start. `server` starts the LLM container first (see below); `mobile` does not start the server.

Options (all optional, the script has defaults):

- `-Model` – server config: `gemma` (default), `bielik`, `qwen` (7B, needs the GPU), `fake` (no LLM needed).
- `-EventLog` – turns the event log on through a temporary copy of the config. The mobile app does not handle `action_logged` yet, so do not combine it with `mobile`.
- `-Lan` – server listens on all interfaces (phone in the same Wi-Fi).
- `-Cpu` – `llm` (and `server`) without the GPU. `-NoLlm` – `server` leaves the LLM container alone. `-Device`, `-Mode`, `-Reverse` – for `mobile`.

Per part:

- **`llm`** – foreground, finishes. Always go through the script, never a plain `docker compose up` in `poc/server`: it recreates the container without the GPU override and the model then runs on the CPU only (a 7B answer takes over a minute and times out). Report whether the container has GPU access and which models it holds. If the model of `-Model` is missing, say so and give the pull command from the output; do not pull it unasked (several GB).
- **`server`** – run as a **background** command. The script first brings up the LLM container with the GPU (not for `-Model fake` or with `-NoLlm`), which can take a minute; do not start it any other way. Wait until `http://localhost:8000/health` answers `ok`, then report whether the container has GPU access, the address, the model from `/v1/providers` and whether the event log is on. If the port is in use, say so and suggest `/dev stop`; do not kill anything else. Do not read the server's output file just to wait for it.
- **`mobile`** – first run `flutter devices`; if more than one device is listed and no `-Device` was given, ask which. Run as a **background** command. Use a real arm64 phone with USB debugging (no x86 build of the speech libraries for the emulator); default mode `release`, the first build is long. A phone on USB outside the Wi-Fi: `-Reverse` and the address `http://127.0.0.1:8000` in Settings → Serwer asystenta; a phone on Wi-Fi: the server needs `-Lan`.
- **`all`** – the script starts the LLM, then opens the server and the mobile app in their own windows. Report that, and check `/health` after a few seconds.
- **`status`** – foreground; shows the container, its GPU access, the CPU/GPU share of the loaded model and whether the server answers.
- **`stop`** – foreground; stops the process listening on port 8000 only if it is Python/uv (anything else is reported, not killed) and the LLM container (the model volume stays). It does not close the mobile app.

Report the result in a few lines.

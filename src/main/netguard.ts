import net from "net";

/**
 * Nothing leaves this machine, enforced rather than promised.
 *
 * The switches in `refuseToPhoneHome` cover Chromium's network stack, which is
 * where Chromium's own background chatter lives. They do **not** cover Node's,
 * and the main process is Node — so a `fetch` here, or in any dependency, or in
 * any future edit, would go out unseen. That was not a guess: a planted
 * `fetch("https://example.com/...")` in the main process passed a network check
 * built only on `--host-resolver-rules` without registering at all.
 *
 * So the socket layer itself refuses. Loopback is allowed, because devtools and
 * the network check's own listener live there and blocking them would only
 * teach us to switch the guard off. Everything else throws, loudly, naming what
 * tried — a silent block would be its own kind of lie.
 */
export function guardOutboundSockets(onAttempt?: (host: string) => void): void {
  const realConnect = net.Socket.prototype.connect;
  const loopback = /^(127\.|::1$|localhost$|0:0:0:0:0:0:0:1$)/i;

  net.Socket.prototype.connect = function (this: net.Socket, ...args: unknown[]) {
    const first = args[0];
    let host = "";
    if (typeof first === "object" && first !== null && "host" in first) {
      host = String((first as { host?: unknown }).host ?? "");
    } else if (typeof args[1] === "string") {
      host = args[1];
    }
    // A unix socket or a pipe has no host at all; those are local by
    // definition and are how Electron talks to itself.
    if (host && !loopback.test(host)) {
      onAttempt?.(host);
      console.error(`[netguard] refused an outbound connection to ${host}`);
      throw new Error(`Voice Forge does not make network connections (blocked: ${host})`);
    }
    return realConnect.apply(this, args as Parameters<typeof realConnect>);
  } as typeof realConnect;
}

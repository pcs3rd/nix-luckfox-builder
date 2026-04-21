#!/usr/bin/env python3
"""
mesh-bbs  —  minimal Meshtastic BBS + store-and-forward bot.

Commands (sent as Meshtastic direct messages, case-insensitive):
  bbs               show help
  bbs help          show help
  bbs list          list last N BBS posts  (N set by --list-limit)
  bbs read N        read post #N
  bbs post TEXT     post TEXT to the BBS

Store-and-forward:
  snf send !NODE TEXT   queue TEXT for offline node (!hex or short name)
  snf list              show your own queued messages waiting for delivery
  snf pending           show all queued recipients (admin overview)

Nodes are tracked as "online" when any packet is received from them on the
monitored channel.  Queued messages are delivered automatically on next contact.

Usage:
  mesh_bbs.py [--serial /dev/ttyACM0] [--channel 0] [--list-limit 10]
  mesh_bbs.py [--tcp 192.168.1.x]    [--channel 2] [--max-msg-len 180]
  mesh_bbs.py --help
"""

import argparse
import json
import logging
import os
import time

import meshtastic
import meshtastic.serial_interface
import meshtastic.tcp_interface
from pubsub import pub

# ---------------------------------------------------------------------------
# Runtime configuration (populated from CLI args in main())
# ---------------------------------------------------------------------------

class _Cfg:
    channel     = 0      # Meshtastic channel index to monitor
    list_limit  = 10     # max posts shown by `bbs list`
    max_msg_len = 200    # max bytes per outgoing message chunk
    data_dir    = "/var/lib/mesh-bbs"

cfg = _Cfg()

# Derived paths — updated by _init_paths() after cfg.data_dir is set.
BBS_FILE  = ""
SNF_FILE  = ""
SEEN_FILE = ""


def _init_paths():
    global BBS_FILE, SNF_FILE, SEEN_FILE
    os.makedirs(cfg.data_dir, exist_ok=True)
    BBS_FILE  = os.path.join(cfg.data_dir, "bbs.json")
    SNF_FILE  = os.path.join(cfg.data_dir, "snf_queue.json")
    SEEN_FILE = os.path.join(cfg.data_dir, "seen_nodes.json")


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-7s  %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
log = logging.getLogger("mesh-bbs")


# ---------------------------------------------------------------------------
# Persistent-store helpers
# ---------------------------------------------------------------------------

def _load(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return default


def _save(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)


def load_bbs():   return _load(BBS_FILE,  [])
def save_bbs(v):  _save(BBS_FILE,  v)
def load_snf():   return _load(SNF_FILE,  {})
def save_snf(v):  _save(SNF_FILE,  v)
def load_seen():  return _load(SEEN_FILE, {})
def save_seen(v): _save(SEEN_FILE, v)


# ---------------------------------------------------------------------------
# Node-ID normalisation
# ---------------------------------------------------------------------------

def node_id_str(raw):
    """Return a canonical node-ID string like '!ab12cd34'."""
    if isinstance(raw, int):
        return f"!{raw:08x}"
    s = str(raw)
    return ("!" + s if not s.startswith("!") else s).lower()


def hex_to_int(node_str):
    return int(node_str.lstrip("!"), 16)


# ---------------------------------------------------------------------------
# BBS
# ---------------------------------------------------------------------------

def bbs_list(iface, sender_id):
    posts = load_bbs()
    if not posts:
        send(iface, sender_id, "BBS is empty. Post with: bbs post <text>")
        return
    tail  = posts[-cfg.list_limit:]
    lines = [f"#{p['id']} {p['from_short']} {p['ts'][:10]}: {p['text'][:40]}"
             for p in tail]
    send(iface, sender_id, "\n".join(lines))


def bbs_read(iface, sender_id, args):
    if not args:
        send(iface, sender_id, "Usage: bbs read <N>")
        return
    try:
        n = int(args[0])
    except ValueError:
        send(iface, sender_id, "Usage: bbs read <N>  (N is a number)")
        return
    posts   = load_bbs()
    matches = [p for p in posts if p["id"] == n]
    if not matches:
        send(iface, sender_id, f"No post #{n}")
        return
    p = matches[0]
    send(iface, sender_id,
         f"#{p['id']} from {p['from_id']} ({p['from_short']}) at {p['ts']}:\n{p['text']}")


def bbs_post(iface, sender_id, sender_short, args):
    if not args:
        send(iface, sender_id, "Usage: bbs post <text>")
        return
    text  = " ".join(args)
    posts = load_bbs()
    new_id = (posts[-1]["id"] + 1) if posts else 1
    entry  = {
        "id":         new_id,
        "from_id":    sender_id,
        "from_short": sender_short,
        "ts":         time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "text":       text,
    }
    posts.append(entry)
    save_bbs(posts)
    log.info("BBS post #%d from %s: %s", new_id, sender_id, text)
    send(iface, sender_id, f"Posted as #{new_id}")


def bbs_help(iface, sender_id):
    send(iface, sender_id,
         "mesh-bbs commands:\n"
         f" bbs list          list last {cfg.list_limit} posts\n"
         " bbs read N        read post #N\n"
         " bbs post TEXT     post a message\n"
         " snf send !N TEXT  queue msg for offline node\n"
         " snf list          your queued messages")


# ---------------------------------------------------------------------------
# Store-and-forward
# ---------------------------------------------------------------------------

def snf_send(iface, sender_id, args):
    if len(args) < 2:
        send(iface, sender_id, "Usage: snf send !nodeId <text>")
        return
    dest = node_id_str(args[0])
    text = " ".join(args[1:])
    q = load_snf()
    q.setdefault(dest, []).append({
        "from_id": sender_id,
        "ts":      time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "text":    text,
    })
    save_snf(q)
    log.info("SNF: queued for %s from %s", dest, sender_id)
    send(iface, sender_id, f"Queued for {dest}. Delivers on next contact.")


def snf_list(iface, sender_id):
    q       = load_snf()
    waiting = q.get(sender_id, [])
    if not waiting:
        send(iface, sender_id, "No messages queued for you.")
        return
    lines = [f"From {m['from_id']} at {m['ts'][:16]}: {m['text'][:60]}"
             for m in waiting]
    send(iface, sender_id,
         f"{len(waiting)} message(s) queued:\n" + "\n".join(lines))


def snf_pending(iface, sender_id):
    q = load_snf()
    if not q:
        send(iface, sender_id, "No pending deliveries.")
        return
    lines = [f"{dest}: {len(msgs)} msg(s)" for dest, msgs in q.items()]
    send(iface, sender_id, "Pending:\n" + "\n".join(lines))


def deliver_snf(iface, node_id):
    """Flush queued messages to node_id now that they're reachable."""
    q       = load_snf()
    pending = q.pop(node_id, [])
    if not pending:
        return
    log.info("SNF: delivering %d message(s) to %s", len(pending), node_id)
    for msg in pending:
        out = f"[SNF from {msg['from_id']} at {msg['ts'][:16]}] {msg['text']}"
        send(iface, node_id, out)
        time.sleep(0.5)
    save_snf(q)


# ---------------------------------------------------------------------------
# Message sender with length-safety
# ---------------------------------------------------------------------------

def send(iface, dest_id, text):
    dest_int = hex_to_int(dest_id)
    while text:
        chunk, text = text[:cfg.max_msg_len], text[cfg.max_msg_len:]
        try:
            iface.sendText(chunk, destinationId=dest_int)
        except Exception as exc:
            log.error("sendText to %s failed: %s", dest_id, exc)
        if text:
            time.sleep(0.3)


# ---------------------------------------------------------------------------
# Packet handler
# ---------------------------------------------------------------------------

def on_receive(packet, interface):
    try:
        _handle(packet, interface)
    except Exception as exc:
        log.exception("Error handling packet: %s", exc)


def _handle(packet, iface):
    decoded = packet.get("decoded", {})

    from_raw = packet.get("from")
    if from_raw is None:
        return
    sender_id = node_id_str(from_raw)

    # ── Channel filter ────────────────────────────────────────────────────
    # For node-presence tracking (SNF delivery), we honour packets on ANY
    # channel so a node that's active on a different channel still gets its
    # queued messages.  Command handling is restricted to cfg.channel so the
    # bot doesn't respond to commands sent on channels it isn't monitoring.
    pkt_channel = packet.get("channel", 0)

    # Update last-seen timestamp for this node (any channel)
    seen = load_seen()
    seen[sender_id] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    save_seen(seen)

    # Deliver any store-and-forward queue (any channel — deliver on contact)
    deliver_snf(iface, sender_id)

    # From here on, only process text commands on the configured channel
    if pkt_channel != cfg.channel:
        return

    portnum = decoded.get("portnum", "")
    if portnum != "TEXT_MESSAGE_APP":
        return

    text = decoded.get("text", "").strip()
    if not text:
        return

    # Only respond to direct messages (not broadcast)
    to_raw = packet.get("to", 0xFFFFFFFF)
    if to_raw == 0xFFFFFFFF:
        return

    # Resolve short name from node DB if available
    nodes      = getattr(iface, "nodes", {}) or {}
    node_info  = nodes.get(f"!{from_raw:08x}", {})
    user_info  = node_info.get("user", {})
    short_name = user_info.get("shortName", sender_id[-4:])

    log.info("MSG ch%d from %s (%s): %s", pkt_channel, sender_id, short_name, text)

    words = text.lower().split()
    if not words:
        return

    cmd = words[0]

    # ── BBS commands ──────────────────────────────────────────────────────
    if cmd == "bbs":
        sub = words[1] if len(words) > 1 else "help"
        if sub in ("help", "?"):
            bbs_help(iface, sender_id)
        elif sub == "list":
            bbs_list(iface, sender_id)
        elif sub == "read":
            bbs_read(iface, sender_id, words[2:])
        elif sub == "post":
            orig_words = text.split()
            bbs_post(iface, sender_id, short_name, orig_words[2:])
        else:
            bbs_help(iface, sender_id)
        return

    # ── Store-and-forward commands ────────────────────────────────────────
    if cmd == "snf":
        sub = words[1] if len(words) > 1 else ""
        if sub == "send":
            orig_words = text.split()
            snf_send(iface, sender_id, orig_words[2:])
        elif sub == "list":
            snf_list(iface, sender_id)
        elif sub == "pending":
            snf_pending(iface, sender_id)
        else:
            send(iface, sender_id,
                 "snf commands:\n"
                 " snf send !node text  queue a message\n"
                 " snf list             your pending messages\n"
                 " snf pending          all pending (admin)")
        return


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def parse_args():
    ap = argparse.ArgumentParser(description="Minimal Meshtastic BBS + store-and-forward")

    # ── Connection ────────────────────────────────────────────────────────
    group = ap.add_mutually_exclusive_group()
    group.add_argument("--serial", metavar="DEV", default="/dev/ttyACM0",
                       help="Serial device (default: /dev/ttyACM0)")
    group.add_argument("--tcp", metavar="HOST",
                       help="TCP hostname or IP of a Meshtastic node")

    # ── Meshtastic channel ────────────────────────────────────────────────
    ap.add_argument("--channel", type=int, default=0,
                    help="Meshtastic channel index to monitor for commands (0-7, default: 0). "
                         "Node-presence tracking and SNF delivery happen on all channels.")

    # ── BBS behaviour ─────────────────────────────────────────────────────
    ap.add_argument("--list-limit", type=int, default=10, metavar="N",
                    help="Max posts shown by `bbs list` (default: 10)")
    ap.add_argument("--max-msg-len", type=int, default=200, metavar="BYTES",
                    help="Max bytes per outgoing message chunk (default: 200). "
                         "LoRa payloads are typically 237 bytes max; leave headroom "
                         "for Meshtastic framing.")

    # ── Storage ───────────────────────────────────────────────────────────
    ap.add_argument("--data-dir", default=os.environ.get("MESH_BBS_DATA", "/var/lib/mesh-bbs"),
                    metavar="PATH",
                    help="Directory for BBS/SNF JSON data files "
                         "(default: $MESH_BBS_DATA or /var/lib/mesh-bbs)")

    return ap.parse_args()


def main():
    args = parse_args()

    # Populate the global config from CLI args
    cfg.channel     = args.channel
    cfg.list_limit  = args.list_limit
    cfg.max_msg_len = args.max_msg_len
    cfg.data_dir    = args.data_dir

    _init_paths()

    log.info("mesh-bbs starting")
    log.info("  data dir    : %s", cfg.data_dir)
    log.info("  channel     : %d", cfg.channel)
    log.info("  list limit  : %d posts", cfg.list_limit)
    log.info("  max msg len : %d bytes", cfg.max_msg_len)

    if args.tcp:
        log.info("Connecting via TCP to %s …", args.tcp)
        iface = meshtastic.tcp_interface.TCPInterface(hostname=args.tcp)
    else:
        log.info("Connecting via serial to %s …", args.serial)
        iface = meshtastic.serial_interface.SerialInterface(devPath=args.serial)

    pub.subscribe(on_receive, "meshtastic.receive")

    log.info("mesh-bbs ready. Waiting for messages …")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        log.info("Shutting down.")
    finally:
        iface.close()


if __name__ == "__main__":
    main()

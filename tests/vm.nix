# VM test (runs under `nix flake check`): a single node runs peerpatrol with a
# loopback-only config. Proves in one boot:
#   - the module's unit evaluates, starts and stays active,
#   - the LoadCredential secret-file override path works (tokenFile),
#   - a failing probe opens an alarm, the (expected) telegram send failure is
#     tolerated, and the state file still records the transition,
#   - the shelled-out `ping` works under the unit's full hardening: a ping
#     exec/cap failure would log its own DOWN line and the counts stop matching.
{
  name = "peerpatrol-vm";
  meta.timeout = 600;

  nodes.peerpatrol = import ./node.nix;

  testScript = ''
    peerpatrol.start()
    # probes run at (bucket + hash(checkId) % interval) with interval 3s, so
    # both first probes have run well within 30s. The tcp check against the
    # refused port closes into a DOWN transition: the send to the (unreachable)
    # telegram API is tolerated and logged; a successful send would log a
    # "DOWN sent" line instead — never reached here.
    peerpatrol.wait_until_succeeds("systemctl is-active peerpatrol | grep -q '^active$'")
    peerpatrol.wait_until_succeeds("journalctl -u peerpatrol | grep -q ' telegram '")

    # exactly one tolerated telegram failure, and it belongs to the tcp check;
    # a hardening-broken ping would open its own DOWN transition and add a line
    count = peerpatrol.succeed("journalctl -u peerpatrol -q | grep -c ' telegram '").strip()
    assert count == "1", f"expected exactly one telegram-error line, got {count}"

    # let several ping cycles pass; the count must stay at one
    peerpatrol.execute("sleep 15")
    count = peerpatrol.succeed("journalctl -u peerpatrol -q | grep -c ' telegram '").strip()
    assert count == "1", f"telegram-error count changed over time: {count}"

    out = peerpatrol.succeed("systemctl is-active peerpatrol").strip()
    assert out == "active", out

    # the local state file persisted the DOWN despite the failed telegram send
    peerpatrol.succeed(
        "grep -q '^DOWN tcp:127.0.0.1:1 @bucket' /var/lib/peerpatrol/monitor-state.txt"
    )
  '';
}

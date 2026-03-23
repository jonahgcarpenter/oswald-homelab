Couldnt get this working, and I really dont know if its worth the trouble right now, saving for later evaluation

Command for the rule to work

```bash
talosctl patch mc -n <NODE_IPS> --patch '{"machine":{"sysctls":{"kernel.kptr_restrict":"2"}}}'
```

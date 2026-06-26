# how to enable vm to talk to the litellm

```bash
sudo iptables -t nat -I PREROUTING -i virbr0 -p tcp --dport 4000 -j DNAT --to-destination 127.0.0.1:4000
sudo sysctl -w net.ipv4.conf.virbr0.route_localnet=1
```

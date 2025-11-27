# iperf3 testing

## Build container
```bash
sudo podman build -t iperf3:latest .
```

## Server
```bash
sudo podman run -it --rm \
  --name iperf3-server \
  --network host \
  --privileged \
  iperf3:latest \
  -s
```

## Client

### Testing Parameters
- `-t` 60: 60 second test duration
- `-w` 16M: TCP window size (adjust as needed)
- `-i` 1: Interval report every 1 second
- `-b` 100M: UDP bandwidth (adjust as needed)
- `-P` 10: Parallel streams (for multi-threaded testing)

### Simple TCP test
```bash
sudo podman run --rm \
  --network host \
  --privileged \
  iperf3:latest \
  -c <SERVER_IP_ADDRESS>
```

### Simple UDP Test
```bash
# UDP at 80MB/s
sudo podman run --rm \
  --network host \
  --privileged \
  iperf3:latest \
  -u -b 80M -c <SERVER_IP_ADDRESS>

# UDP at 160MB/s
sudo podman run --rm \
  --network host \
  --privileged \
  iperf3:latest \
  -u -b 160M -c <SERVER_IP_ADDRESS>

# UDP at 400MB/s
sudo podman run --rm \
  --network host \
  --privileged \
  iperf3:latest \
  -u -b 400M -c <SERVER_IP_ADDRESS>

# UDP at 800MB/s
sudo podman run --rm \
  --network host \
  --privileged \
  iperf3:latest \
  -u -b 800M -c <SERVER_IP_ADDRESS>
```

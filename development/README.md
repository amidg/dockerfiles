# Development Dockerfiles
## Dev Container:
Builds Ubuntu 24.04 (for now, later will be Fedora) image with optional CUDA support that installs the following development tools:
### C/C++:
- C++ (libc6)
- GCC / G++
- Clang
- Make
- CMake
- Meson

### Python:
- Python3

## Process:
Each Dockerfile contains one stage (e.g. building development containers of ROS2 containers), and has two stages (standard and CUDA).

## ROS2:
When running on Podman, must run from within same network:
```
podman run -it --rm --network=test ghcr.io/amidg/ros2:latest
```
Need to figure out nodes cannot find each other with `--network=host`.

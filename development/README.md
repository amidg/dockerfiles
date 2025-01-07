# Development Dockerfile
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

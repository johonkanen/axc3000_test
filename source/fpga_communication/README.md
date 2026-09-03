# vendored from johonkanen/fpga_communication

These three files are copied verbatim from
<https://github.com/johonkanen/fpga_communication> @ `3079c3c` (2025-08-29):

- `communications.vhd`             — the `fpga_communications` entity
- `serial_protocol_generic_pkg.vhd`
- `fpga_interconnect_16bit_pkg.vhd` — 32 data / 16 address instance of the generic pkg

They are vendored (not a submodule) because `fpga_communication` pulls in
several unrelated nested submodules. The packages they depend on come from the
`hVHDL_uart` and `hVHDL_fpga_interconnect` submodules under `../`.

To update: copy the newer versions from upstream and re-run the build.

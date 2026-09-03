# AXC3000 Arduino MKR header pinout

FPGA-pin assignments for the two Arduino MKR headers (**J1** analog side,
**J2** digital side) on the Arrow AXC3000 (Agilex 3 `A3CY100BM16AE7S`).

Source: board schematic `SCH-TEI0131-01-P001.PDF` sheet 8 (`FPGA3.SchDoc`,
HVIO banks 5A / 5B), cross-checked against *AXC3000 User Guide V1.2* §3.9.2.

All MKR I/O sits in **HVIO bank 5A / 5B, powered at 3.3 V** → use
`IO_STANDARD "3.3-V LVCMOS"`.

## J1 - analog side (14-pin)

| J1 pin | MKR name | FPGA pin | HVIO |
|-------:|----------|----------|------|
| 1  | AREF      | AF22 | 5A_18 |
| 2  | A0 (AIN0) | AF23 | 5A_15 |
| 3  | A1 (AIN1) | AF24 | 5A_13 |
| 4  | A2 (AIN2) | AG26 | 5B_5  |
| 5  | A3 (AIN3) | AH28 | 5B_15 |
| 6  | A4 (AIN4) | AH27 | 5B_10 |
| 7  | A5 (AIN5) | AF27 | 5B_17 |
| 8  | A6 (AIN6) | AF26 | 5B_8  |
| 9  | D0        | AE25 | 5B_6  |
| 10 | D1        | AF21 | 5A_20 |
| 11 | D2        | AH20 | 5A_8  |
| 12 | D3        | AG19 | 5A_17 |
| 13 | D4        | AF19 | 5A_19 |
| 14 | D5        | AG20 | 5A_16 |

## J2 - digital side (14-pin)

| J2 pin | MKR name | FPGA pin | HVIO | Notes |
|-------:|----------|----------|------|-------|
| 1  | D6         | AK19 | 5B_11 | |
| 2  | D7         | AJ19 | 5A_4  | |
| 3  | D8         | AH21 | 5A_3  | |
| 4  | D9         | AH18 | 5A_11 | |
| 5  | D10        | AJ20 | 5A_10 | |
| 6  | D11 / SDA  | AJ22 | 5A_9  | `D11_R` = AK25 (5B_7), same pin via 4.7 kR pull-up |
| 7  | D12 / SCL  | AK22 | 5B_12 | `D12_R` = AK27 (5B_20), same pin via 4.7 kR pull-up |
| 8  | D13        | AH23 | 5A_5  | |
| 9  | D14        | AJ23 | 5A_2  | |
| 10 | RESET      | -    | -     | board reset circuitry, not a user FPGA I/O |
| 11 | GND        | -    | -     | |
| 12 | +3V3       | -    | -     | power out |
| 13 | VIN        | -    | -     | 5 V power in |
| 14 | +5V        | -    | -     | power out |

`D11_R` / `D12_R` are the same two MKR pins routed through the optional
4.7 kR pull-ups for I2C use - drive whichever net matches the pull-up jumper
setting.

## QSF snippet

```tcl
set_location_assignment PIN_AE25 -to mkr_d0
set_location_assignment PIN_AF21 -to mkr_d1
set_location_assignment PIN_AH20 -to mkr_d2
set_location_assignment PIN_AG19 -to mkr_d3
set_location_assignment PIN_AF19 -to mkr_d4
set_location_assignment PIN_AG20 -to mkr_d5
set_location_assignment PIN_AK19 -to mkr_d6
set_location_assignment PIN_AJ19 -to mkr_d7
set_location_assignment PIN_AH21 -to mkr_d8
set_location_assignment PIN_AH18 -to mkr_d9
set_location_assignment PIN_AJ20 -to mkr_d10
set_location_assignment PIN_AJ22 -to mkr_d11
set_location_assignment PIN_AK22 -to mkr_d12
set_location_assignment PIN_AH23 -to mkr_d13
set_location_assignment PIN_AJ23 -to mkr_d14
set_location_assignment PIN_AF23 -to mkr_a0
set_location_assignment PIN_AF24 -to mkr_a1
set_location_assignment PIN_AG26 -to mkr_a2
set_location_assignment PIN_AH28 -to mkr_a3
set_location_assignment PIN_AH27 -to mkr_a4
set_location_assignment PIN_AF27 -to mkr_a5
set_location_assignment PIN_AF26 -to mkr_a6
set_location_assignment PIN_AF22 -to mkr_aref

set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to mkr_d0
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to mkr_d1
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to mkr_d2
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to mkr_d3
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to mkr_d4
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to mkr_d5
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to mkr_d6
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to mkr_d7
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to mkr_d8
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to mkr_d9
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to mkr_d10
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to mkr_d11
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to mkr_d12
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to mkr_d13
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to mkr_d14
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to mkr_a0
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to mkr_a1
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to mkr_a2
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to mkr_a3
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to mkr_a4
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to mkr_a5
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to mkr_a6
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to mkr_aref
```

## Related bank 5A / 5B nets (not MKR)

| net | FPGA pin | function |
|-----|----------|----------|
| BDBUS0 | AG23 | USB-Blaster UART, board TX -> FPGA RX (`uart_rxd`) |
| BDBUS1 | AG24 | USB-Blaster UART, board RX <- FPGA TX (`uart_txd`) |
| LED1   | AG21 | user red LED |
| RLED   | AH22 | RGB LED - red |
| GLED   | AK21 | RGB LED - green |
| BLED   | AK20 | RGB LED - blue |
| SDA    | AK26 | on-board I2C (accelerometer) |
| SCL    | AH25 | on-board I2C (accelerometer) |
| SMB_SDA | AJ29 | CRUVI SMBus data |
| SMB_SCL | AJ27 | CRUVI SMBus clock |
| SMB_ALERT | AH26 | CRUVI SMBus alert |
| REFCLK | AJ28 | CRUVI reference clock in |
| VSEL_1V3 | AJ24 | selects CRUVI VADJ rail (1.2 V / 1.3 V) |
